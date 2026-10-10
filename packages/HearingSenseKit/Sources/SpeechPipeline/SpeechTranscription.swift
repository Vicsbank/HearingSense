import Foundation
import HearingSenseDomain

/// One recognition result for the utterance being transcribed.
public struct TranscriptionUpdate: Hashable, Sendable {
    public var text: String
    /// Span of the recognized speech on the session audio clock.
    public var audioTime: AudioTimeRange
    /// False for volatile (partial) results that later results replace.
    public var isFinal: Bool
    /// Recognizer confidence over the result's runs (uncalibrated), when reported.
    public var meanConfidence: Double?
    public var minimumConfidence: Double?
    public var producedAt: Date

    public init(text: String, audioTime: AudioTimeRange, isFinal: Bool, meanConfidence: Double? = nil,
                minimumConfidence: Double? = nil, producedAt: Date = .now)
    {
        self.text = text
        self.audioTime = audioTime
        self.isFinal = isFinal
        self.meanConfidence = meanConfidence
        self.minimumConfidence = minimumConfidence
        self.producedAt = producedAt
    }
}

public enum TranscriptionEvent: Sendable {
    case update(TranscriptionUpdate)
    /// All audio given before `finish()` has been recognized; no further events follow.
    case finished
    /// The recognizer failed; no further events follow.
    case failed(String)
}

public enum TranscriptionError: LocalizedError, Equatable {
    case unavailable(TranscriptionAvailability)
    case unsupportedAudioFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let availability): "Speech transcription is unavailable: \(availability.displayName)"
        case .unsupportedAudioFormat(let detail): "Unsupported audio format for transcription: \(detail)"
        }
    }
}

/// Receives the events of one utterance transcription, in order.
public typealias TranscriptionEventHandler = @Sendable (TranscriptionEvent) async -> Void

/// On-device speech-to-text. The production implementation is `AppleSpeechTranscriber`; tests
/// use scripted implementations.
public protocol SpeechTranscribing: Sendable {
    /// BCP-47 identifier of the language this transcriber recognizes.
    var languageIdentifier: String { get }

    /// Checks device support and model installation. Must not download anything.
    func availability() async -> TranscriptionAvailability

    /// Loads the recognition model so the first utterance does not pay the start-up cost.
    func prepare() async

    /// Starts transcribing one utterance.
    /// - Parameters:
    ///   - audioTime: session audio clock time of the first sample that will be appended.
    ///   - onEvent: called for every event, in order, from the transcription's own context.
    func beginUtterance(at audioTime: TimeInterval, onEvent: @escaping TranscriptionEventHandler) async throws
        -> any UtteranceTranscription

    /// Listening stopped or transcription was switched off: let the system unload the model.
    func releaseResources() async
}

public extension SpeechTranscribing {
    func prepare() async {}
    func releaseResources() async {}
}

/// One utterance being transcribed. Audio must be appended contiguously (no gaps): Apple's
/// analyzer produces corrupt results when its timeline has holes (measured, see
/// docs/research/SPEECH_INTELLIGENCE_ARCHITECTURE.md).
public protocol UtteranceTranscription: Sendable {
    /// Appends mono Float32 samples that directly follow the previously appended audio.
    func append(_ samples: [Float], sampleRate: Double) async
    /// No more audio: recognize what was given and end with `.finished` (or `.failed`).
    func finish() async
    /// Stops immediately and discards pending results. No further events are delivered.
    func cancel() async
}
