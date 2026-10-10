import AVFAudio
import Foundation
import HearingSenseAudio
import Testing
@testable import SpeechPipeline

/// Writes a ramp (sample value = number of samples written before it) through the stream clock,
/// so every sample read back can be checked against its position. Synthetic test signal.
struct RampWriter {
    let buffer: PreRollAudioBuffer
    var clock = AudioStreamClock()
    var written = 0
    var sampleTime: Int64 = 0

    init(capacitySeconds: TimeInterval) {
        buffer = PreRollAudioBuffer(capacitySeconds: capacitySeconds)
    }

    mutating func write(_ count: Int, sampleRate: Double = 1_000) {
        let samples = (written ..< written + count).map(Float.init)
        let placement = clock.place(frameCount: count, sampleRate: sampleRate, sampleTime: sampleTime)
        samples.withUnsafeBufferPointer { buffer.append($0, placement: placement, capturedAt: .now) }
        written += count
        sampleTime += Int64(count)
    }

    /// Reads everything from the given audio time.
    func read(from time: TimeInterval) -> PreRollAudioBuffer.Chunk? {
        guard let cursor = buffer.cursor(at: time), case .chunk(let chunk, _) = buffer.read(from: cursor) else {
            return nil
        }
        return chunk
    }
}

func isRamp(_ samples: [Float], startingAt first: Float) -> Bool {
    samples.enumerated().allSatisfy { $0.element == first + Float($0.offset) }
}

@Suite struct PreRollAudioBufferTests {
    @Test func keepsSamplesContinuousAcrossVaryingBufferSizes() throws {
        var writer = RampWriter(capacitySeconds: 5)
        for count in [480, 1, 333, 1024, 7, 4_096, 100, 2, 959] { writer.write(count, sampleRate: 48_000) }
        let chunk = try #require(writer.read(from: 0))
        #expect(chunk.samples.count == writer.written)
        #expect(isRamp(chunk.samples, startingAt: 0))
        #expect(chunk.startTime == 0 && chunk.sampleRate == 48_000 && chunk.skippedFrames == 0)
    }

    @Test func overwritesTheOldestAudioAndStaysBounded() throws {
        var writer = RampWriter(capacitySeconds: 1)
        for _ in 0 ..< 35 { writer.write(100) }  // 3.5 s at 1 kHz into a 1 s ring
        let status = writer.buffer.status
        #expect(status.oldestTime == 2.5 && status.newestTime == 3.5)
        #expect(status.bufferedSeconds == 1)
        #expect(status.memoryBytes == 1_000 * MemoryLayout<Float>.size)
        let chunk = try #require(writer.read(from: 0))  // older than the buffer: clamped to the oldest sample
        #expect(chunk.startTime == 2.5)
        #expect(chunk.samples.count == 1_000 && isRamp(chunk.samples, startingAt: 2_500))
    }

    @Test func wrapsCorrectlyForBufferSizesThatDoNotDivideTheCapacity() throws {
        var writer = RampWriter(capacitySeconds: 1)
        for _ in 0 ..< 50 { writer.write(77) }
        let chunk = try #require(writer.read(from: 0))
        #expect(chunk.samples.count == 1_000)
        #expect(isRamp(chunk.samples, startingAt: Float(writer.written - 1_000)))
    }

    @Test func cursorTimestampsFollowTheStreamClock() throws {
        var writer = RampWriter(capacitySeconds: 5)
        for _ in 0 ..< 30 { writer.write(100) }
        let cursor = try #require(writer.buffer.cursor(at: 1.234))
        #expect(writer.buffer.time(of: cursor) == 1.234)
        let chunk = try #require(writer.read(from: 1.234))
        #expect(chunk.samples.first == 1_234)
        #expect(abs(chunk.endTime - 3.0) < 1e-9)
        // A time in the future yields an empty read at the newest position.
        let future = try #require(writer.buffer.cursor(at: 99))
        if case .empty = writer.buffer.read(from: future) {} else { Issue.record("expected empty read") }
    }

    @Test func readersAreIndependentAndCanReadIncrementally() throws {
        var writer = RampWriter(capacitySeconds: 5)
        writer.write(1_000)
        var slow = try #require(writer.buffer.cursor(at: 0))
        var fast = try #require(writer.buffer.cursor(at: 0.5))
        guard case .chunk(let a, let nextSlow) = writer.buffer.read(from: slow, maxFrames: 300),
              case .chunk(let b, let nextFast) = writer.buffer.read(from: fast)
        else {
            Issue.record("expected data")
            return
        }
        slow = nextSlow
        fast = nextFast
        #expect(a.samples.count == 300 && isRamp(a.samples, startingAt: 0))
        #expect(b.samples.count == 500 && isRamp(b.samples, startingAt: 500))
        writer.write(200)
        guard case .chunk(let c, _) = writer.buffer.read(from: slow), case .chunk(let d, _) = writer.buffer.read(from: fast)
        else {
            Issue.record("expected data")
            return
        }
        #expect(c.samples.count == 900 && isRamp(c.samples, startingAt: 300))
        #expect(d.samples.count == 200 && isRamp(d.samples, startingAt: 1_000))
    }

    @Test func aReaderThatFallsBehindLearnsHowMuchItLost() throws {
        var writer = RampWriter(capacitySeconds: 1)
        writer.write(500)
        let cursor = try #require(writer.buffer.cursor(at: 0.2))
        writer.write(2_000)  // overwrites everything the cursor pointed at
        guard case .chunk(let chunk, _) = writer.buffer.read(from: cursor) else {
            Issue.record("expected data")
            return
        }
        #expect(chunk.skippedFrames == 1_300)
        #expect(chunk.startTime == 1.5 && isRamp(chunk.samples, startingAt: 1_500))
    }

    @Test func captureGapsAreZeroFilledSoLaterAudioKeepsItsTime() throws {
        var writer = RampWriter(capacitySeconds: 5)
        writer.write(1_000)
        writer.sampleTime += 500  // the hardware skipped 0.5 s
        writer.write(1_000)
        let chunk = try #require(writer.read(from: 0))
        #expect(chunk.samples.count == 2_500)
        #expect(isRamp(Array(chunk.samples[0 ..< 1_000]), startingAt: 0))
        #expect(chunk.samples[1_000 ..< 1_500].allSatisfy { $0 == 0 })
        #expect(isRamp(Array(chunk.samples[1_500...]), startingAt: 1_000))
        #expect(writer.buffer.status.gapFramesFilled == 500)
        // A gap longer than the ring leaves only the audio after it.
        writer.sampleTime += 60_000
        writer.write(100)
        let tail = try #require(writer.read(from: 0))
        #expect(tail.samples.count == 5_000)
        #expect(tail.samples.dropLast(100).allSatisfy { $0 == 0 })
        #expect(isRamp(Array(tail.samples.suffix(100)), startingAt: 2_000))
    }

    @Test func aFormatChangeStartsOverAndTellsExistingReaders() throws {
        var writer = RampWriter(capacitySeconds: 2)
        writer.write(1_000, sampleRate: 1_000)
        let oldCursor = try #require(writer.buffer.cursor(at: 0))
        writer.write(800, sampleRate: 2_000)  // new sample rate: new segment starting at 1.0 s
        guard case .discontinuity(let next) = writer.buffer.read(from: oldCursor) else {
            Issue.record("expected discontinuity")
            return
        }
        let cursor = try #require(next)
        guard case .chunk(let chunk, _) = writer.buffer.read(from: cursor) else {
            Issue.record("expected data")
            return
        }
        #expect(chunk.sampleRate == 2_000 && chunk.startTime == 1.0)
        #expect(chunk.samples.count == 800 && isRamp(chunk.samples, startingAt: 1_000))
        let status = writer.buffer.status
        #expect(status.resets == 1 && status.oldestTime == 1.0 && status.newestTime == 1.4)
        #expect(status.memoryBytes == 4_000 * MemoryLayout<Float>.size)
    }

    @Test func aCaptureRestartOrNewSessionDiscardsOldAudio() throws {
        var writer = RampWriter(capacitySeconds: 2)
        writer.write(1_000)
        writer.clock.markDiscontinuity()  // engine restart after a route change
        writer.write(300)
        var chunk = try #require(writer.read(from: 0))
        #expect(chunk.startTime == 1.0 && chunk.samples.count == 300)

        writer.clock.resetSession()  // Stop, then Start: the audio clock restarts at 0
        writer.write(200)
        chunk = try #require(writer.read(from: 0))
        #expect(chunk.startTime == 0 && chunk.samples.count == 200 && isRamp(chunk.samples, startingAt: 1_300))
    }

    @Test func aBufferLongerThanTheRingKeepsItsNewestSamples() throws {
        var writer = RampWriter(capacitySeconds: 1)
        writer.write(100)
        writer.write(2_500)
        let chunk = try #require(writer.read(from: 0))
        #expect(chunk.samples.count == 1_000 && isRamp(chunk.samples, startingAt: 1_600))
        #expect(abs(chunk.startTime - 1.6) < 1e-9)
    }

    @Test func clearAndDisableLeaveNoAudioBehind() throws {
        var writer = RampWriter(capacitySeconds: 1)
        writer.write(700)
        let cursor = try #require(writer.buffer.cursor(at: 0))
        writer.buffer.clear()
        #expect(writer.buffer.status.bufferedSeconds == 0)
        #expect(writer.buffer.cursor(at: 0) == nil)
        if case .discontinuity(let next) = writer.buffer.read(from: cursor) { #expect(next == nil) } else {
            Issue.record("expected discontinuity after clear")
        }

        writer.buffer.setEnabled(false)
        writer.write(500)
        #expect(writer.buffer.status.bufferedSeconds == 0 && writer.buffer.status.isEnabled == false)
        writer.buffer.setEnabled(true)
        writer.write(100)
        // Only audio captured after re-enabling is present; nothing older reappears.
        let chunk = try #require(writer.read(from: 0))
        #expect(chunk.samples.count == 100 && isRamp(chunk.samples, startingAt: 1_200))
    }

    @Test func capacityIsConfigurableAndClamped() {
        var writer = RampWriter(capacitySeconds: 3)
        writer.write(5_000)
        #expect(writer.buffer.status.bufferedSeconds == 3)
        writer.buffer.setCapacity(seconds: 4)
        #expect(writer.buffer.status.bufferedSeconds == 0)
        writer.write(5_000)
        #expect(writer.buffer.status.bufferedSeconds == 4)
        #expect(PreRollAudioBuffer(capacitySeconds: 10_000).status.capacitySeconds == 30)
    }

    @Test func wallClockDatesAreEstimatedFromTheNewestBuffer() throws {
        let buffer = PreRollAudioBuffer(capacitySeconds: 5)
        var clock = AudioStreamClock()
        let arrival = Date(timeIntervalSince1970: 2_000)
        let samples = [Float](repeating: 0, count: 1_000)
        let placement = clock.place(frameCount: 1_000, sampleRate: 1_000, sampleTime: nil)
        samples.withUnsafeBufferPointer { buffer.append($0, placement: placement, capturedAt: arrival) }
        #expect(buffer.date(forAudioTime: 1.0) == arrival)
        #expect(buffer.date(forAudioTime: 0.25) == arrival.addingTimeInterval(-0.75))
    }

    /// One writer and several readers at the same time: every chunk a reader gets must be a
    /// contiguous piece of the ramp at the position its timestamp claims.
    @Test func concurrentReadersNeverSeeTornData() async {
        let buffer = PreRollAudioBuffer(capacitySeconds: 0.5)
        let total = 400_000
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var clock = AudioStreamClock()
                var written = 0
                while written < total {
                    let count = 1 + (written * 7) % 479
                    let samples = (written ..< written + count).map(Float.init)
                    let placement = clock.place(frameCount: count, sampleRate: 48_000, sampleTime: nil)
                    samples.withUnsafeBufferPointer { buffer.append($0, placement: placement, capturedAt: .now) }
                    written += count
                    if written % 5 == 0 { await Task.yield() }
                }
                return true
            }
            for reader in 0 ..< 3 {
                group.addTask {
                    var cursor: PreRollAudioBuffer.Cursor?
                    var consistent = true
                    var readFrames = 0
                    while (buffer.status.framesWritten < Int64(total) || readFrames == 0) && consistent {
                        if cursor == nil { cursor = buffer.cursor(at: 0) }
                        guard let current = cursor else {
                            await Task.yield()
                            continue
                        }
                        switch buffer.read(from: current, maxFrames: 100 + reader * 900) {
                        case .chunk(let chunk, let next):
                            let first = Float((chunk.startTime * 48_000).rounded())
                            consistent = isRamp(chunk.samples, startingAt: first)
                            readFrames += chunk.samples.count
                            cursor = next
                        case .empty:
                            await Task.yield()
                        case .discontinuity(let next):
                            cursor = next
                        }
                    }
                    return consistent && readFrames > 0
                }
            }
            for await result in group { #expect(result) }
        }
        #expect(buffer.status.framesWritten >= Int64(total))
        #expect(abs(buffer.status.bufferedSeconds - 0.5) < 1e-6)
    }
}

@Suite struct SpeechAudioTapTests {
    static func buffer(frames: Int, channels: AVAudioChannelCount = 1, interleaved: Bool = false,
                       sampleRate: Double = 16_000, first: Float = 0) -> AVAudioPCMBuffer
    {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels,
                                   interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0 ..< frames {
            if interleaved {
                for channel in 0 ..< Int(channels) {
                    buffer.floatChannelData![0][frame * Int(channels) + channel] = channel == 0 ? first + Float(frame) : -1
                }
            } else {
                for channel in 0 ..< Int(channels) {
                    buffer.floatChannelData![channel][frame] = channel == 0 ? first + Float(frame) : -1
                }
            }
        }
        return buffer
    }

    @Test func buffersChannelZeroOnTheSharedClock() throws {
        let tap = SpeechAudioTap(buffer: PreRollAudioBuffer(capacitySeconds: 5))
        tap.captureDidReceive(Self.buffer(frames: 1_600), at: AVAudioTime(sampleTime: 0, atRate: 16_000))
        tap.captureDidReceive(Self.buffer(frames: 800, channels: 2, first: 1_600),
                              at: AVAudioTime(sampleTime: 1_600, atRate: 16_000))
        tap.captureDidReceive(Self.buffer(frames: 800, channels: 2, interleaved: true, first: 2_400),
                              at: AVAudioTime(sampleTime: 2_400, atRate: 16_000))
        let cursor = try #require(tap.buffer.cursor(at: 0))
        guard case .chunk(let chunk, _) = tap.buffer.read(from: cursor) else {
            Issue.record("expected data")
            return
        }
        #expect(chunk.samples.count == 3_200 && isRamp(chunk.samples, startingAt: 0))
        #expect(abs(tap.currentTime - 0.2) < 1e-9)

        // The same buffers placed by a clock of the sound recognition engine get the same times.
        var reference = AudioStreamClock()
        _ = reference.place(frameCount: 1_600, sampleRate: 16_000, sampleTime: 0)
        _ = reference.place(frameCount: 800, sampleRate: 16_000, sampleTime: 1_600)
        let last = reference.place(frameCount: 800, sampleRate: 16_000, sampleTime: 2_400)
        #expect(last.startTime == 0.15 && reference.currentTime == tap.currentTime)
    }

    @Test func ignoresNonFloatBuffersAndRestartsTheClockPerSession() throws {
        let tap = SpeechAudioTap(buffer: PreRollAudioBuffer(capacitySeconds: 5))
        let integerFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                                       interleaved: false))
        let integer = try #require(AVAudioPCMBuffer(pcmFormat: integerFormat, frameCapacity: 100))
        integer.frameLength = 100
        tap.captureDidReceive(integer, at: AVAudioTime(sampleTime: 0, atRate: 16_000))
        #expect(tap.currentTime == 0 && tap.buffer.status.framesWritten == 0)

        tap.captureDidReceive(Self.buffer(frames: 1_600), at: AVAudioTime(sampleTime: 0, atRate: 16_000))
        tap.captureDidStop()
        tap.resetSession()
        tap.buffer.clear()
        #expect(tap.currentTime == 0)
        tap.captureDidReceive(Self.buffer(frames: 160), at: AVAudioTime(sampleTime: 0, atRate: 16_000))
        #expect(tap.buffer.status.oldestTime == 0 && abs(tap.currentTime - 0.01) < 1e-9)
    }
}
