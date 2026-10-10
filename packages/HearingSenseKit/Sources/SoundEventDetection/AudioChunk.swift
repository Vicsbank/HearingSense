import AVFAudio
import Accelerate
import Foundation
import HearingSenseAudio

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

/// The session audio clock is shared with the speech pipeline (Window 3), so it lives in
/// HearingSenseAudio as `AudioStreamClock`.
typealias StreamClock = AudioStreamClock
