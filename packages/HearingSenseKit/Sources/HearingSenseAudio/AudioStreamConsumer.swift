import AVFAudio

/// Format of the PCM stream delivered by `MicrophoneCapture` (the input node's hardware format).
public struct CaptureFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channelCount: Int
    public var isInterleaved: Bool

    public init(sampleRate: Double, channelCount: Int, isInterleaved: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isInterleaved = isInterleaved
    }

    public init(_ format: AVAudioFormat) {
        self.init(sampleRate: format.sampleRate,
                  channelCount: Int(format.channelCount),
                  isInterleaved: format.isInterleaved)
    }

    public var summary: String {
        let khz = (sampleRate / 1000).formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(khz) kHz · \(channelCount) ch"
    }
}

/// Receives raw microphone buffers from `MicrophoneCapture`.
///
/// This is the extension seam for later windows: Window 2 attaches `SoundRecognitionEngine`
/// (SoundEventDetection), Window 3 a speech detector.
///
/// Threading contract:
/// - `captureDidReceive` is called on the AVAudioEngine tap thread, never on the main thread.
///   `captureDidStart` / `captureDidStop` are called from the context that starts and stops
///   `MicrophoneCapture` (the app's main actor), and `captureDidStart` may arrive after the
///   first buffers. Implementations must be thread-safe.
/// - `captureDidReceive` must return quickly. Copy the buffer and hop to your own serial
///   queue for heavy work; the buffer is only guaranteed valid during the call.
/// - Consumers must not write audio to disk unless the user explicitly enabled recording.
public protocol AudioStreamConsumer: AnyObject, Sendable {
    /// The stream (re)started, possibly with a new format after a route change.
    func captureDidStart(format: AVAudioFormat)
    func captureDidReceive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
    func captureDidStop()
}
