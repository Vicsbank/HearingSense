import AVFAudio
import Foundation
import HearingSenseDomain
import Testing
@testable import SoundEventDetection

@Suite struct StreamClockTests {
    @Test func positionsAreMonotonicAndGapsAdvanceTheClock() {
        var clock = StreamClock()
        let a = clock.place(frameCount: 4800, sampleRate: 48_000, sampleTime: 1000)
        let b = clock.place(frameCount: 4800, sampleRate: 48_000, sampleTime: 5800)
        let c = clock.place(frameCount: 4800, sampleRate: 48_000, sampleTime: 15_400)  // 4800 frames missing
        #expect(a.framePosition == 0 && b.framePosition == 4800 && c.framePosition == 14_400)
        #expect(clock.gapFrames == 4800)
        #expect(abs(c.startTime - 0.3) < 1e-9)
        #expect(Set([a.segmentID, b.segmentID, c.segmentID]).count == 1)
    }

    @Test func restartAndSampleRateChangeStartNewSegmentsOnOneClock() {
        var clock = StreamClock()
        _ = clock.place(frameCount: 48_000, sampleRate: 48_000, sampleTime: nil)
        clock.markDiscontinuity()
        let restarted = clock.place(frameCount: 4800, sampleRate: 48_000, sampleTime: 0)
        #expect(restarted.framePosition == 0)
        #expect(restarted.segmentStart == 1.0)
        let resampled = clock.place(frameCount: 1600, sampleRate: 16_000, sampleTime: 4800)
        #expect(resampled.segmentID == restarted.segmentID + 1)
        #expect(abs(resampled.startTime - 1.1) < 1e-9)
    }

    @Test func newSessionResetsTheClockAndBumpsTheGeneration() {
        var clock = StreamClock()
        _ = clock.place(frameCount: 4800, sampleRate: 48_000, sampleTime: nil)
        clock.resetSession()
        let first = clock.place(frameCount: 4800, sampleRate: 48_000, sampleTime: nil)
        #expect(first.generation == 1 && first.startTime == 0)
    }
}

@Suite struct AudioChunkTests {
    @Test func copiesChannelZeroFromDeinterleavedAndInterleavedBuffers() throws {
        let planar = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: planar, frameCapacity: 3))
        buffer.frameLength = 3
        for i in 0 ..< 3 {
            buffer.floatChannelData![0][i] = Float(i)
            buffer.floatChannelData![1][i] = -1
        }
        #expect(AudioChunk.copyChannelZero(of: buffer) == [0, 1, 2])

        let interleaved = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let ibuffer = try #require(AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: 3))
        ibuffer.frameLength = 3
        for i in 0 ..< 3 {
            ibuffer.floatChannelData![0][2 * i] = Float(i)
            ibuffer.floatChannelData![0][2 * i + 1] = -1
        }
        #expect(AudioChunk.copyChannelZero(of: ibuffer) == [0, 1, 2])
    }

    @Test func rejectsNonFloatBuffers() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10))
        buffer.frameLength = 10
        #expect(AudioChunk.copyChannelZero(of: buffer) == nil)
    }
}

/// Runs real audio through the production engine and Apple's real classifier (forward-only).
/// Assertions concern structure and timing, not specific labels, except for the real speech file.
@Suite(.serialized) struct SoundRecognitionEngineTests {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// Feeds `seconds` of a generated signal in 4800-frame buffers (what the iPhone delivered).
    static func feed(_ engine: SoundRecognitionEngine, seconds: Double, sampleTimeOffset: Int64 = 0,
                     signal: (Int) -> Float) -> Int
    {
        engine.captureDidStart(format: format)
        let chunk = 4800
        let total = Int(seconds * 48_000) / chunk
        for index in 0 ..< total {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
            buffer.frameLength = AVAudioFrameCount(chunk)
            for i in 0 ..< chunk { buffer.floatChannelData![0][i] = signal(index * chunk + i) }
            let time = AVAudioTime(sampleTime: sampleTimeOffset + Int64(index * chunk), atRate: 48_000)
            engine.captureDidReceive(buffer, at: time)
        }
        return total
    }

    static func collect(_ engine: SoundRecognitionEngine) async -> [SoundRecognitionOutput] {
        await engine.drain()
        engine.endSession()
        await engine.drain()
        var outputs: [SoundRecognitionOutput] = []
        for await output in engine.outputs {
            outputs.append(output)
            if case .sessionEnded = output { break }
        }
        return outputs
    }

    @Test func producesWindowsEveryHopWithMonotonicAudioTime() async {
        let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5,
                                                                                   backlogLimit: nil))
        let buffers = Self.feed(engine, seconds: 6) { i in 0.1 * sin(2 * .pi * 440 * Float(i) / 48_000) }
        engine.captureDidStop()
        let outputs = await Self.collect(engine)
        let frames = outputs.compactMap { if case .frame(let report) = $0 { report.frame } else { nil } }
        // 6 s, 1.5 s windows every 0.75 s → windows ending at 1.5 … 6.0 = 7 (plus possibly a flushed tail).
        #expect(frames.count >= 7)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.audioTime.start < $1.audioTime.start })
        #expect(abs(frames[1].audioTime.start - frames[0].audioTime.start - 0.75) < 0.01)
        #expect(abs(frames[0].audioTime.duration - 1.5) < 0.01)
        #expect(frames.allSatisfy { $0.inputLevel != nil && $0.capturedAt != nil })
        guard case .sessionEnded(let diagnostics) = outputs.last else {
            Issue.record("missing sessionEnded")
            return
        }
        #expect(diagnostics.chunksAnalyzed == buffers)
        #expect(diagnostics.chunksDropped == 0)
        #expect(diagnostics.results == frames.count)
        #expect(diagnostics.inferenceCalls.count > 0)
    }

    @Test func silenceIsReportedAsQuietWithoutEvents() async {
        let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5,
                                                                                   backlogLimit: nil))
        _ = Self.feed(engine, seconds: 4) { _ in 0 }
        engine.captureDidStop()
        let outputs = await Self.collect(engine)
        let statuses = outputs.compactMap { if case .frame(let report) = $0 { report.status } else { nil } }
        #expect(!statuses.isEmpty)
        #expect(statuses.allSatisfy { $0 == .quiet })
        #expect(!outputs.contains { if case .event = $0 { true } else { false } })
    }

    @Test func fullBacklogDropsBuffersInsteadOfBlocking() async {
        let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5,
                                                                                   backlogLimit: 0))
        _ = Self.feed(engine, seconds: 1) { _ in 0 }
        let outputs = await Self.collect(engine)
        guard case .sessionEnded(let diagnostics) = outputs.last else {
            Issue.record("missing sessionEnded")
            return
        }
        #expect(diagnostics.chunksAnalyzed == 0)
    }

    @Test func detectsInputGapsFromSampleTime() async {
        let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5,
                                                                                   backlogLimit: nil))
        _ = Self.feed(engine, seconds: 2) { _ in 0 }
        // Next buffers claim a sample time 1 s later than expected.
        let format = Self.format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        engine.captureDidReceive(buffer, at: AVAudioTime(sampleTime: 96_000 + 48_000, atRate: 48_000))
        let outputs = await Self.collect(engine)
        guard case .sessionEnded(let diagnostics) = outputs.last else {
            Issue.record("missing sessionEnded")
            return
        }
        #expect(diagnostics.inputGapFrames == 48_000)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: RepositoryPaths.speechSample.path)))
    func realSpeechRecordingProducesASpeechEvent() async throws {
        let file = try AVAudioFile(forReading: RepositoryPaths.speechSample)
        let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5,
                                                                                   backlogLimit: nil))
        let format = file.processingFormat
        engine.captureDidStart(format: format)
        var position: Int64 = 0
        while position < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            try file.read(into: buffer, frameCount: 4800)
            if buffer.frameLength == 0 { break }
            engine.captureDidReceive(buffer, at: AVAudioTime(sampleTime: position, atRate: format.sampleRate))
            position += Int64(buffer.frameLength)
        }
        engine.captureDidStop()
        let outputs = await Self.collect(engine)
        let started = outputs.compactMap { if case .event(.started(let event)) = $0 { event } else { nil } }
        #expect(started.contains { $0.kind.id == "speech" })
    }
}
