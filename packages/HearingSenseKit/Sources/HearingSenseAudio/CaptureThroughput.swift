import Foundation

/// Counts delivered microphone audio so a device test can show whether capture kept
/// running while the app was in the background or the screen was locked.
///
/// Counting happens on the capture thread (inside `MicrophoneCapture`), so the numbers do
/// not depend on the main thread being scheduled in the background.
public struct CaptureThroughput: Sendable, Equatable {
    public private(set) var buffers = 0
    public private(set) var frames: Int64 = 0
    public private(set) var sampleRate: Double = 0

    public init() {}

    /// Seconds of audio delivered so far, using the most recent sample rate.
    public var capturedSeconds: Double {
        sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    public mutating func record(frameCount: Int, sampleRate: Double) {
        buffers += 1
        frames += Int64(frameCount)
        self.sampleRate = sampleRate
    }

    public mutating func reset() {
        self = CaptureThroughput()
    }

    public struct Checkpoint: Sendable, Equatable {
        public var date: Date
        public var frames: Int64
        public var buffers: Int
    }

    public func checkpoint(at date: Date) -> Checkpoint {
        Checkpoint(date: date, frames: frames, buffers: buffers)
    }

    public struct Interval: Sendable, Equatable {
        public var wallClockSeconds: Double
        public var capturedSeconds: Double
        public var buffers: Int
        /// Captured audio divided by elapsed wall-clock time. About 1.0 means no gap.
        public var coverage: Double { wallClockSeconds > 0 ? capturedSeconds / wallClockSeconds : 0 }
    }

    /// Audio delivered between `checkpoint` and `now`. Approximate if the sample rate changed.
    public func interval(since checkpoint: Checkpoint, now: Date) -> Interval? {
        let elapsed = now.timeIntervalSince(checkpoint.date)
        guard elapsed > 0, sampleRate > 0, frames >= checkpoint.frames else { return nil }
        return Interval(wallClockSeconds: elapsed,
                        capturedSeconds: Double(frames - checkpoint.frames) / sampleRate,
                        buffers: buffers - checkpoint.buffers)
    }
}
