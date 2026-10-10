import AVFAudio
import Foundation
import HearingSenseAudio
import os

/// Feeds the pre-roll buffer from the shared microphone stream.
///
/// Attach with `MicrophoneCapture.addConsumer(_:)` next to the sound recognition engine: both
/// receive the same buffers from the single input tap, so speech processing never opens a second
/// capture session (which could disturb media playback).
///
/// The tap applies the same `AudioStreamClock` rules as `SoundRecognitionEngine` (channel 0,
/// float buffers only, new segment on capture start/stop, session reset on `resetSession()`), so
/// buffer positions match `ClassificationFrame.audioTime`.
public final class SpeechAudioTap: AudioStreamConsumer {
    public let buffer: PreRollAudioBuffer
    private let clock = OSAllocatedUnfairLock(initialState: AudioStreamClock())

    public init(buffer: PreRollAudioBuffer) {
        self.buffer = buffer
    }

    /// Starts a new listening session: audio clock back to 0. Call when the sound recognition
    /// engine's `endSession()` is called, after capture stopped.
    public func resetSession() {
        clock.withLock { $0.resetSession() }
    }

    /// Session audio clock position after the newest buffer.
    public var currentTime: TimeInterval { clock.withLock { $0.currentTime } }

    // MARK: - AudioStreamConsumer

    public func captureDidStart(format: AVAudioFormat) {
        clock.withLock { $0.markDiscontinuity() }
    }

    public func captureDidReceive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let sampleTime = time.isSampleTimeValid ? time.sampleTime : nil
        let sampleRate = buffer.format.sampleRate
        let placement = clock.withLock {
            $0.place(frameCount: frames, sampleRate: sampleRate, sampleTime: sampleTime)
        }
        if buffer.format.isInterleaved, buffer.format.channelCount > 1 {
            // Not produced by AVAudioEngine's input node; handled for completeness (allocates).
            let stride = buffer.stride
            let mono = (0 ..< frames).map { channels[0][$0 * stride] }
            mono.withUnsafeBufferPointer { self.buffer.append($0, placement: placement, capturedAt: .now) }
        } else {
            self.buffer.append(UnsafeBufferPointer(start: channels[0], count: frames), placement: placement,
                               capturedAt: .now)
        }
    }

    public func captureDidStop() {
        clock.withLock { $0.markDiscontinuity() }
    }
}
