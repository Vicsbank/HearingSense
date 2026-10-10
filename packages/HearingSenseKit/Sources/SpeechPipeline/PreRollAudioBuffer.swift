import Foundation
import HearingSenseAudio
import os

/// A bounded, in-memory ring buffer holding the most recent seconds of microphone audio (mono
/// Float32 at the input sample rate), addressed on the session audio clock.
///
/// Why it exists: the sound classifier needs 1.5–2.25 s of audio before it reports speech. By
/// then the beginning of a short sentence is over. Transcription therefore starts from this
/// buffer, at the estimated onset of the speech, not from "now".
///
/// ```
/// tap thread ── append(samples, placement) ──▶ [ ring: capacity seconds, oldest overwritten ]
///                                                   ▲ cursor(at: onset)        ▲ read(from: cursor)
///                                     speech pipeline (any thread, any number of readers)
/// ```
///
/// Properties:
/// - **Bounded**: one allocation of `capacity × sampleRate` samples per stream segment (about
///   0.96 MB for 5 s at 48 kHz). Old audio is overwritten; nothing grows.
/// - **Timestamps**: positions come from `AudioStreamClock.Placement`, the same clock the sound
///   classifier uses, so `ClassificationFrame.audioTime` can be looked up directly. Capture gaps
///   reported by the clock are zero-filled so later audio keeps its position.
/// - **Format changes**: a new clock segment (capture restart, route change, new sample rate) or
///   a new session discards the content and starts over; readers are told (`.discontinuity`).
/// - **Tap-thread cost**: `append` takes an unfair lock for the duration of a `memcpy` and does
///   not allocate (except once per segment). Readers hold the same lock only while copying the
///   requested samples out (≈ 1 MB at most).
/// - **Readers**: each reader owns a `Cursor`; readers never affect each other or the writer. A
///   reader that falls more than `capacity` behind loses the overwritten audio and is told how
///   many frames it skipped.
/// - **Privacy**: memory only. `clear()` zeroes the samples; a disabled buffer stores nothing.
public final class PreRollAudioBuffer: Sendable {
    /// A reader's position in the stream.
    public struct Cursor: Hashable, Sendable {
        public var generation: Int
        public var segmentID: Int
        /// Next frame to read, counted within the segment.
        public var frame: Int64
    }

    /// Contiguous audio copied out of the buffer.
    public struct Chunk: Sendable {
        public var samples: [Float]
        public var sampleRate: Double
        /// Session audio clock time of the first sample.
        public var startTime: TimeInterval
        /// Frames between the reader's cursor and `startTime` that had already been overwritten.
        public var skippedFrames: Int64

        public var duration: TimeInterval { Double(samples.count) / sampleRate }
        public var endTime: TimeInterval { startTime + duration }
    }

    public enum ReadResult: Sendable {
        case chunk(Chunk, next: Cursor)
        /// Nothing new since the cursor.
        case empty
        /// The stream restarted (new segment or session) since the cursor was taken. The audio
        /// the cursor pointed at is gone; `next` is the start of the current content, if any.
        case discontinuity(next: Cursor?)
    }

    public struct Status: Hashable, Sendable {
        public var isEnabled = true
        public var capacitySeconds: TimeInterval = 0
        public var sampleRate: Double = 0
        /// Session audio clock range currently held (nil when empty).
        public var oldestTime: TimeInterval?
        public var newestTime: TimeInterval?
        public var framesWritten: Int64 = 0
        public var gapFramesFilled: Int64 = 0
        /// Times the content was discarded because the stream restarted or changed format.
        public var resets = 0

        public var bufferedSeconds: TimeInterval {
            guard let oldestTime, let newestTime else { return 0 }
            return newestTime - oldestTime
        }

        public var memoryBytes: Int { Int(capacitySeconds * sampleRate) * MemoryLayout<Float>.size }
    }

    private struct State {
        var isEnabled = true
        var capacitySeconds: TimeInterval
        var storage: [Float] = []
        var sampleRate: Double = 0
        var generation = -1
        var segmentID = -1
        var segmentStart: TimeInterval = 0
        var firstFrame: Int64 = 0
        var nextFrame: Int64 = 0
        var lastWriteDate: Date?
        var framesWritten: Int64 = 0
        var gapFramesFilled: Int64 = 0
        var resets = 0

        var hasContent: Bool { !storage.isEmpty && nextFrame > firstFrame }
        var oldestFrame: Int64 { max(firstFrame, nextFrame - Int64(storage.count)) }
        func time(of frame: Int64) -> TimeInterval { segmentStart + Double(frame) / sampleRate }
    }

    public static let capacityRange: ClosedRange<TimeInterval> = 0.1 ... 30

    private let state: OSAllocatedUnfairLock<State>

    /// - Parameter capacitySeconds: seconds of audio to keep (clamped to `capacityRange`).
    public init(capacitySeconds: TimeInterval = 5) {
        state = OSAllocatedUnfairLock(initialState: State(capacitySeconds: Self.clamp(capacitySeconds)))
    }

    private static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, capacityRange.lowerBound), capacityRange.upperBound)
    }

    // MARK: - Writer (audio tap thread)

    /// Appends one buffer of mono samples at the position the stream clock assigned to it.
    ///
    /// Real-time notes: no allocation unless the segment, session or sample rate changed; the
    /// lock is held for a bounded `memcpy`.
    public func append(_ samples: UnsafeBufferPointer<Float>, placement: AudioStreamClock.Placement,
                       capturedAt: Date)
    {
        guard !samples.isEmpty, placement.sampleRate > 0 else { return }
        // `withLockUnchecked`: the pointer is not Sendable, but it is only read synchronously
        // inside this call while the caller keeps the buffer alive.
        state.withLockUnchecked { state in
            guard state.isEnabled else { return }
            if state.generation != placement.generation || state.segmentID != placement.segmentID
                || state.sampleRate != placement.sampleRate
            {
                Self.startSegment(&state, placement: placement)
            }
            let capacity = Int64(state.storage.count)
            guard capacity > 0 else { return }

            // Frames the clock skipped (capture gap) stay silent so later audio keeps its time.
            let gap = placement.framePosition - state.nextFrame
            if gap > 0 {
                let fill = min(gap, capacity)
                Self.write(&state, at: placement.framePosition - fill, count: Int(fill), from: nil)
                state.gapFramesFilled += gap
                state.nextFrame = placement.framePosition
            }

            // A buffer longer than the ring keeps only its newest `capacity` frames.
            let drop = max(Int64(samples.count) - capacity, 0)
            let kept = UnsafeBufferPointer(rebasing: samples[Int(drop)...])
            Self.write(&state, at: state.nextFrame + drop, count: kept.count, from: kept.baseAddress)
            state.nextFrame += Int64(samples.count)
            state.framesWritten += Int64(samples.count)
            state.lastWriteDate = capturedAt
        }
    }

    private static func startSegment(_ state: inout State, placement: AudioStreamClock.Placement) {
        let frames = max(Int((state.capacitySeconds * placement.sampleRate).rounded()), 1)
        if state.storage.count == frames {
            state.storage.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        } else {
            state.storage = [Float](repeating: 0, count: frames)
        }
        if state.generation != -1 { state.resets += 1 }
        state.generation = placement.generation
        state.segmentID = placement.segmentID
        state.sampleRate = placement.sampleRate
        state.segmentStart = placement.segmentStart
        state.firstFrame = placement.framePosition
        state.nextFrame = placement.framePosition
    }

    /// Writes `count` frames starting at absolute frame `frame` (wrapping); nil source = zeros.
    private static func write(_ state: inout State, at frame: Int64, count: Int, from source: UnsafePointer<Float>?) {
        guard count > 0 else { return }
        state.storage.withUnsafeMutableBufferPointer { ring in
            let capacity = ring.count
            let offset = Int(frame % Int64(capacity))
            let first = min(count, capacity - offset)
            let base = ring.baseAddress!
            if let source {
                (base + offset).update(from: source, count: first)
                if count > first { base.update(from: source + first, count: count - first) }
            } else {
                (base + offset).update(repeating: 0, count: first)
                if count > first { base.update(repeating: 0, count: count - first) }
            }
        }
    }

    // MARK: - Readers (any thread)

    /// A cursor at the given session audio clock time, clamped to the audio still available
    /// (a time older than the buffer yields the oldest sample; a future time the newest).
    /// Nil when the buffer is empty or disabled.
    public func cursor(at time: TimeInterval) -> Cursor? {
        state.withLock { state in
            guard state.hasContent else { return nil }
            let wanted = Int64(((time - state.segmentStart) * state.sampleRate).rounded())
            let frame = min(max(wanted, state.oldestFrame), state.nextFrame)
            return Cursor(generation: state.generation, segmentID: state.segmentID, frame: frame)
        }
    }

    /// Session audio clock time a cursor points at (nil if the cursor is from an older segment).
    public func time(of cursor: Cursor) -> TimeInterval? {
        state.withLock { state in
            guard state.sampleRate > 0, cursor.generation == state.generation,
                  cursor.segmentID == state.segmentID
            else { return nil }
            return state.time(of: cursor.frame)
        }
    }

    /// Copies up to `maxFrames` frames starting at the cursor.
    public func read(from cursor: Cursor, maxFrames: Int = .max) -> ReadResult {
        state.withLock { state in
            guard cursor.generation == state.generation, cursor.segmentID == state.segmentID else {
                let next = state.hasContent
                    ? Cursor(generation: state.generation, segmentID: state.segmentID, frame: state.oldestFrame)
                    : nil
                return .discontinuity(next: next)
            }
            guard state.hasContent else { return .empty }
            let start = max(cursor.frame, state.oldestFrame)
            let available = state.nextFrame - start
            guard available > 0, maxFrames > 0 else { return .empty }
            let count = Int(min(available, Int64(min(maxFrames, state.storage.count))))
            let capacity = state.storage.count
            let offset = Int(start % Int64(capacity))
            let first = min(count, capacity - offset)
            let samples = [Float](unsafeUninitializedCapacity: count) { destination, initialized in
                state.storage.withUnsafeBufferPointer { ring in
                    destination.baseAddress!.initialize(from: ring.baseAddress! + offset, count: first)
                    if count > first {
                        (destination.baseAddress! + first).initialize(from: ring.baseAddress!, count: count - first)
                    }
                }
                initialized = count
            }
            let chunk = Chunk(samples: samples, sampleRate: state.sampleRate, startTime: state.time(of: start),
                              skippedFrames: start - cursor.frame)
            return .chunk(chunk, next: Cursor(generation: cursor.generation, segmentID: cursor.segmentID,
                                              frame: start + Int64(count)))
        }
    }

    /// Wall-clock time at which the audio at `audioTime` was captured, estimated from the
    /// arrival time of the newest buffer. Nil when empty.
    public func date(forAudioTime audioTime: TimeInterval) -> Date? {
        state.withLock { state in
            guard state.hasContent, let lastWriteDate = state.lastWriteDate else { return nil }
            return lastWriteDate.addingTimeInterval(audioTime - state.time(of: state.nextFrame))
        }
    }

    public var status: Status {
        state.withLock { state in
            var status = Status(isEnabled: state.isEnabled, capacitySeconds: state.capacitySeconds,
                                sampleRate: state.sampleRate, framesWritten: state.framesWritten,
                                gapFramesFilled: state.gapFramesFilled, resets: state.resets)
            if state.hasContent {
                status.oldestTime = state.time(of: state.oldestFrame)
                status.newestTime = state.time(of: state.nextFrame)
            }
            return status
        }
    }

    // MARK: - Control

    /// Discards and zeroes all buffered audio. Cursors taken before become discontinuous.
    public func clear() {
        state.withLock { Self.wipe(&$0) }
    }

    /// A disabled buffer drops incoming audio and holds none (speech transcription off).
    public func setEnabled(_ isEnabled: Bool) {
        state.withLock { state in
            state.isEnabled = isEnabled
            if !isEnabled { Self.wipe(&state) }
        }
    }

    /// Changes the capacity. Discards the current content (the ring is reallocated).
    public func setCapacity(seconds: TimeInterval) {
        state.withLock { state in
            state.capacitySeconds = Self.clamp(seconds)
            Self.wipe(&state)
            state.storage = []
        }
    }

    private static func wipe(_ state: inout State) {
        state.storage.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        state.generation = -1
        state.segmentID = -1
        state.sampleRate = 0
        state.segmentStart = 0
        state.firstFrame = 0
        state.nextFrame = 0
        state.lastWriteDate = nil
    }
}
