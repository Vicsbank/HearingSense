import AVFAudio
import Accelerate
import Foundation

/// A Sendable copy of one microphone buffer, prepared on the tap thread for the analysis queue.
///
/// Only channel 0 is kept: `SNClassifySoundRequest` analyzes the first channel by default, so a
/// mono copy matches what the classifier would use and makes the analyzer format independent of
/// the input's channel count and interleaving.
struct AudioChunk: Sendable {
    var samples: [Float]
    var placement: StreamClock.Placement
    /// Wall-clock arrival of the buffer at the tap (≈ capture time of its last sample).
    var capturedAt: Date
    /// Linear RMS and peak of `samples`.
    var rms: Float
    var peak: Float
    /// Tap-side counters at the time this chunk was enqueued.
    var droppedChunksSoFar: Int
    var gapFramesSoFar: Int64
    var backlogAtEnqueue: Int

    var frameCount: Int { samples.count }
    var startTime: TimeInterval { placement.startTime }
    var endTime: TimeInterval { placement.startTime + Double(samples.count) / placement.sampleRate }

    /// Copies channel 0 of a float PCM buffer. Returns nil for non-float or empty buffers
    /// (AVAudioEngine's input node delivers 32-bit float).
    static func copyChannelZero(of buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let frames = Int(buffer.frameLength)
        if buffer.format.isInterleaved, buffer.format.channelCount > 1 {
            let stride = buffer.stride
            return (0 ..< frames).map { channels[0][$0 * stride] }
        }
        return Array(UnsafeBufferPointer(start: channels[0], count: frames))
    }

    static func levels(of samples: [Float]) -> (rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        return (vDSP.rootMeanSquare(samples), vDSP.maximumMagnitude(samples))
    }
}

/// Assigns monotonic positions to incoming buffers.
///
/// - Session audio clock: seconds of input since the listening session began (see
///   `AudioTimeRange`). It advances by every buffer, including buffers dropped under backlog,
///   and by input gaps detected from `AVAudioTime.sampleTime`, so timestamps track real input.
/// - Segments: a new analyzer segment (frame position restarting at 0) begins after a capture
///   restart or a sample-rate change, because `SNAudioStreamAnalyzer` is bound to one format.
struct StreamClock: Sendable {
    struct Placement: Sendable, Hashable {
        var generation: Int
        var segmentID: Int
        var segmentStart: TimeInterval
        var sampleRate: Double
        /// Frame position within the segment, passed to `analyze(_:atAudioFramePosition:)`.
        var framePosition: Int64

        var startTime: TimeInterval { segmentStart + Double(framePosition) / sampleRate }
    }

    private(set) var generation = 0
    private(set) var segmentID = 0
    private(set) var gapFrames: Int64 = 0
    private var segmentStart: TimeInterval = 0
    private var segmentFrames: Int64 = 0
    private var sampleRate: Double = 0
    private var nextSampleTime: Int64?
    private var needsNewSegment = true

    /// Session audio clock position after the last placed buffer.
    var currentTime: TimeInterval {
        sampleRate > 0 ? segmentStart + Double(segmentFrames) / sampleRate : segmentStart
    }

    /// Next buffer starts a new analyzer segment (capture started, stopped or restarted).
    mutating func markDiscontinuity() {
        needsNewSegment = true
    }

    /// Starts a new listening session: clock back to 0, results of older sessions become stale.
    mutating func resetSession() {
        generation += 1
        gapFrames = 0
        segmentStart = 0
        segmentFrames = 0
        sampleRate = 0
        nextSampleTime = nil
        needsNewSegment = true
    }

    /// - Parameter sampleTime: the buffer's `AVAudioTime.sampleTime` if valid.
    mutating func place(frameCount: Int, sampleRate rate: Double, sampleTime: Int64?) -> Placement {
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
