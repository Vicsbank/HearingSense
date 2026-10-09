import AVFAudio
import Accelerate

/// Signal level of one block of microphone samples, in dB relative to digital full scale.
///
/// A full-scale sine wave measures about -3 dBFS RMS and 0 dBFS peak. Values are clamped
/// to `floorDBFS`, which also represents digital silence.
public struct AudioLevel: Sendable, Equatable {
    public static let floorDBFS: Float = -120
    public static let silence = AudioLevel(rmsDBFS: floorDBFS, peakDBFS: floorDBFS)

    public var rmsDBFS: Float
    public var peakDBFS: Float

    public init(rmsDBFS: Float, peakDBFS: Float) {
        self.rmsDBFS = rmsDBFS
        self.peakDBFS = peakDBFS
    }

    /// Position of the RMS level on a meter spanning `range` (dBFS), clamped to 0...1.
    public func normalizedRMS(range: ClosedRange<Float> = -80 ... 0) -> Float {
        Self.normalize(rmsDBFS, range: range)
    }

    /// Position of the peak level on a meter spanning `range` (dBFS), clamped to 0...1.
    public func normalizedPeak(range: ClosedRange<Float> = -80 ... 0) -> Float {
        Self.normalize(peakDBFS, range: range)
    }

    static func normalize(_ value: Float, range: ClosedRange<Float>) -> Float {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }
}

/// Measures real sample data. It never synthesizes or smooths values.
public enum LevelMeter {
    public static func measure(_ samples: UnsafeBufferPointer<Float>) -> AudioLevel {
        guard !samples.isEmpty else { return .silence }
        let rms = vDSP.rootMeanSquare(samples)
        let peak = vDSP.maximumMagnitude(samples)
        return AudioLevel(rmsDBFS: decibels(rms), peakDBFS: decibels(peak))
    }

    public static func measure(_ samples: [Float]) -> AudioLevel {
        samples.withUnsafeBufferPointer { measure($0) }
    }

    /// Measures a float PCM buffer. With several channels the loudest channel is reported.
    /// Returns nil when the buffer is not 32-bit float (the input node always delivers float).
    public static func measure(_ buffer: AVAudioPCMBuffer) -> AudioLevel? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        guard frames > 0 else { return .silence }

        var result = AudioLevel.silence
        if buffer.format.isInterleaved {
            // One buffer holding all channels; measure each channel with a strided copy.
            let count = Int(buffer.format.channelCount)
            for channel in 0 ..< count {
                var samples = [Float](repeating: 0, count: frames)
                for frame in 0 ..< frames { samples[frame] = channels[0][frame * stride + channel] }
                result = louder(result, measure(samples))
            }
        } else {
            for channel in 0 ..< Int(buffer.format.channelCount) {
                let level = measure(UnsafeBufferPointer(start: channels[channel], count: frames))
                result = louder(result, level)
            }
        }
        return result
    }

    static func decibels(_ amplitude: Float) -> Float {
        guard amplitude > 1e-6 else { return AudioLevel.floorDBFS }
        return max(20 * log10(amplitude), AudioLevel.floorDBFS)
    }

    private static func louder(_ a: AudioLevel, _ b: AudioLevel) -> AudioLevel {
        AudioLevel(rmsDBFS: max(a.rmsDBFS, b.rmsDBFS), peakDBFS: max(a.peakDBFS, b.peakDBFS))
    }
}
