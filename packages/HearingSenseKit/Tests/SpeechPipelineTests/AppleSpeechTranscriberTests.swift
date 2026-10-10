import AVFAudio
import Foundation
import HearingSenseDomain
import os
import Testing
@testable import SpeechPipeline

/// Paths relative to this file (tests run from the package directory, Xcode or the Simulator).
enum SpeechTestSignals {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SpeechPipelineTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // HearingSenseKit
        .deletingLastPathComponent()  // packages
        .deletingLastPathComponent()  // repository root
        .appending(path: "data/test_signals/window3")

    /// Synthetic speech made by tools/make_speech_test_signals.sh (macOS text-to-speech).
    static func url(_ id: String) -> URL { directory.appending(path: "\(id).aiff") }
    static func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    /// Channel 0 of an audio file as Float32 at the file's sample rate.
    static func samples(_ id: String) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url(id))
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadUnknown)
        }
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return (samples, format.sampleRate)
    }
}

/// Collects transcription events delivered from the recognizer's own context.
final class EventCollector: Sendable {
    private let events = OSAllocatedUnfairLock(initialState: [TranscriptionEvent]())

    func append(_ event: TranscriptionEvent) { events.withLock { $0.append(event) } }
    var all: [TranscriptionEvent] { events.withLock { $0 } }

    var isDone: Bool {
        all.contains { if case .update = $0 { false } else { true } }
    }

    var updates: [TranscriptionUpdate] {
        all.compactMap { if case .update(let update) = $0 { update } else { nil } }
    }

    func waitUntilDone(timeout: TimeInterval = 20) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !isDone, Date.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

/// Real on-device recognition (Apple `SpeechTranscriber`) on synthetic speech. These tests check
/// that the integration works; they are not an accuracy measurement. They are skipped where the
/// recognizer does not exist (the iOS Simulator) or the test signals have not been generated.
@Suite struct AppleSpeechTranscriberTests {
    @Test func availabilityCheckReturnsAStateWithoutDownloading() async {
        let english = await AppleSpeechTranscriber(locale: Locale(identifier: "en-US")).availability()
        #expect(english != .unknown)
        // Recorded in the test log so results can be attributed to the right environment: when
        // the recognizer is unavailable (e.g. no model in this runtime) the tests below return early.
        print("[environment] on-device transcription (en-US): \(english.displayName)")
        let unsupported = await AppleSpeechTranscriber(locale: Locale(identifier: "tlh")).availability()
        #expect(!unsupported.isUsable)
    }

    @Test(.enabled(if: AppleSpeechTranscriber.isSupportedOnThisDevice && SpeechTestSignals.exists("package_not_arrived")))
    func transcribesAnUtteranceOnTheSessionAudioClock() async throws {
        let transcriber = AppleSpeechTranscriber()
        guard await transcriber.availability() == .available else { return }  // model not installed
        let (samples, sampleRate) = try SpeechTestSignals.samples("package_not_arrived")
        let collector = EventCollector()
        let utterance = try await transcriber.beginUtterance(at: 100) { collector.append($0) }
        let step = Int(sampleRate / 10)
        for start in stride(from: 0, to: samples.count, by: step) {
            await utterance.append(Array(samples[start ..< min(start + step, samples.count)]), sampleRate: sampleRate)
        }
        await utterance.finish()
        await collector.waitUntilDone()

        guard case .finished = collector.all.last else {
            Issue.record("transcription did not finish: \(String(describing: collector.all.last))")
            return
        }
        var assembler = TranscriptAssembler()
        for update in collector.updates { assembler.apply(update) }
        #expect(TranscriptText.normalized(assembler.finalText) == "your package has not arrived")
        let range = try #require(assembler.audioTime)
        let duration = Double(samples.count) / sampleRate
        #expect(range.start >= 100 && range.end <= 100 + duration + 0.5)
        #expect(assembler.quality.meanConfidence != nil)
    }

    @Test(.enabled(if: AppleSpeechTranscriber.isSupportedOnThisDevice && SpeechTestSignals.exists("class_3pm")))
    func aCancelledUtteranceDeliversNothingMore() async throws {
        let transcriber = AppleSpeechTranscriber()
        guard await transcriber.availability() == .available else { return }
        let (samples, sampleRate) = try SpeechTestSignals.samples("class_3pm")
        let collector = EventCollector()
        let utterance = try await transcriber.beginUtterance(at: 0) { collector.append($0) }
        await utterance.append(samples, sampleRate: sampleRate)
        await utterance.cancel()
        let count = collector.all.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(collector.all.count == count)
        #expect(!collector.all.contains { if case .finished = $0 { true } else { false } })
        await utterance.finish()  // no effect after cancel
        await transcriber.releaseResources()
    }

    @Test(.enabled(if: AppleSpeechTranscriber.isSupportedOnThisDevice))
    func finishingWithoutAudioEndsCleanly() async throws {
        let transcriber = AppleSpeechTranscriber()
        guard await transcriber.availability() == .available else { return }
        let collector = EventCollector()
        let utterance = try await transcriber.beginUtterance(at: 0) { collector.append($0) }
        await utterance.finish()
        await collector.waitUntilDone(timeout: 5)
        guard case .finished = collector.all.last else {
            Issue.record("expected .finished, got \(String(describing: collector.all.last))")
            return
        }
        #expect(collector.updates.isEmpty)
    }
}
