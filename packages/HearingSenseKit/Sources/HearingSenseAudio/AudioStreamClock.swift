import Foundation

/// Assigns monotonic positions to incoming buffers.
///
/// - Session audio clock: seconds of input since the listening session began (see
///   `AudioTimeRange`). It advances by every buffer, including buffers dropped under backlog,
///   and by input gaps detected from `AVAudioTime.sampleTime`, so timestamps track real input.
/// - Segments: a new analyzer segment (frame position restarting at 0) begins after a capture
///   restart or a sample-rate change, because `SNAudioStreamAnalyzer` is bound to one format.
///
/// Every `AudioStreamConsumer` that applies this clock to the same buffers (Window 2 sound
/// recognition, Window 3 pre-roll buffer) gets the same timestamps, so their results can be
/// compared on one audio clock.
public struct AudioStreamClock: Sendable {
    public struct Placement: Sendable, Hashable {
        public var generation: Int
        public var segmentID: Int
        public var segmentStart: TimeInterval
        public var sampleRate: Double
        /// Frame position within the segment, passed to `analyze(_:atAudioFramePosition:)`.
        public var framePosition: Int64

        public var startTime: TimeInterval { segmentStart + Double(framePosition) / sampleRate }
    }

    public private(set) var generation = 0
    public private(set) var segmentID = 0
    public private(set) var gapFrames: Int64 = 0
    private var segmentStart: TimeInterval = 0
    private var segmentFrames: Int64 = 0
    private var sampleRate: Double = 0
    private var nextSampleTime: Int64?
    private var needsNewSegment = true

    public init() {}

    /// Session audio clock position after the last placed buffer.
    public var currentTime: TimeInterval {
        sampleRate > 0 ? segmentStart + Double(segmentFrames) / sampleRate : segmentStart
    }

    /// Next buffer starts a new analyzer segment (capture started, stopped or restarted).
    public mutating func markDiscontinuity() {
        needsNewSegment = true
    }

    /// Starts a new listening session: clock back to 0, results of older sessions become stale.
    public mutating func resetSession() {
        generation += 1
        gapFrames = 0
        segmentStart = 0
        segmentFrames = 0
        sampleRate = 0
        nextSampleTime = nil
        needsNewSegment = true
    }

    /// - Parameter sampleTime: the buffer's `AVAudioTime.sampleTime` if valid.
    public mutating func place(frameCount: Int, sampleRate rate: Double, sampleTime: Int64?) -> Placement {
        if needsNewSegment || rate != sampleRate {
            segmentStart = currentTime
            segmentID += 1
            segmentFrames = 0
            sampleRate = rate
            nextSampleTime = nil
            needsNewSegment = false
        }
        if let sampleTime, let expected = nextSampleTime, sampleTime > expected {
            let gap = sampleTime - expected
            segmentFrames += gap
            gapFrames += gap
        }
        let placement = Placement(generation: generation, segmentID: segmentID, segmentStart: segmentStart,
                                  sampleRate: rate, framePosition: segmentFrames)
        segmentFrames += Int64(frameCount)
        if let sampleTime { nextSampleTime = sampleTime + Int64(frameCount) }
        return placement
    }
}
