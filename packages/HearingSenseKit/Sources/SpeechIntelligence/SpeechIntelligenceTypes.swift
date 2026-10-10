import Foundation
import HearingSenseDomain
import SemanticSummary
import SoundEventDetection
import SpeechPipeline

/// Tunable behaviour of the speech intelligence pipeline. Times are seconds of audio unless
/// stated otherwise. Provisional values: chosen from Mac measurements, not yet validated on the
/// iPhone (docs/WINDOW3_SPEECH_INTELLIGENCE_REPORT.md).
public struct SpeechIntelligenceConfiguration: Hashable, Sendable {
    public var activation = SpeechActivationPolicy.standard
    /// Capacity of the pre-roll ring buffer.
    public var preRollSeconds: TimeInterval = 5
    /// The utterance is finished when its transcript has not changed for this much audio.
    public var endpointSilence: TimeInterval = 1.6
    /// A longer utterance is finished and a new one started (bounds recognizer state).
    public var maximumUtteranceDuration: TimeInterval = 30
    /// Speech that resumes within this gap continues the same conversation (same id).
    public var conversationGap: TimeInterval = 6
    /// A conversation running longer than this is completed; later speech starts a new one.
    public var maximumConversationDuration: TimeInterval = 120
    /// Minimum audio time between two language-model requests of one conversation.
    public var minimumSummaryInterval: TimeInterval = 3
    /// Final utterances kept per conversation (older text is dropped).
    public var maximumUtterancesKept = 6
    /// Utterances shown in `SpeechSemanticResult.transcript`.
    public var transcriptUtterances = 2
    /// Earlier utterances given to the language model as context.
    public var summaryContextUtterances = 2
    /// Wall-clock seconds to wait for the recognizer's final result before the partial text is
    /// used instead.
    public var finalizationTimeout: TimeInterval = 3
    /// After this many transcription failures in a row the session falls back to detection only.
    public var maximumConsecutiveFailures = 3
    /// Wall-clock interval at which live audio is handed to the recognizer.
    public var feedInterval: TimeInterval = 0.06
    public var summary = SummaryPolicy.standard

    public init() {}

    public static let standard = SpeechIntelligenceConfiguration()
}

/// What the pipeline can currently do (layered fallback).
public struct SpeechCapabilities: Hashable, Sendable {
    public var isTranscriptionEnabled: Bool
    public var transcription: TranscriptionAvailability
    public var model: SemanticModelAvailability
    /// BCP-47 identifier of the transcription language.
    public var language: String

    public init(isTranscriptionEnabled: Bool = false, transcription: TranscriptionAvailability = .unknown,
                model: SemanticModelAvailability = .unknown, language: String = "en-US")
    {
        self.isTranscriptionEnabled = isTranscriptionEnabled
        self.transcription = transcription
        self.model = model
        self.language = language
    }

    /// Best output level reachable with the current settings and model availability.
    public var level: SpeechOutputLevel {
        guard isTranscriptionEnabled, transcription.isUsable else { return .detection }
        return model.isUsable ? .summary : .transcript
    }
}

/// Counters and timings of one listening session. Metadata only: no audio, no transcript text.
public struct SpeechIntelligenceDiagnostics: Hashable, Sendable {
    public var windows = 0
    public var speechWindows = 0
    public var windowsSuppressedByMusic = 0
    public var activations = 0

    public var utterancesStarted = 0
    public var utterancesFinished = 0
    /// Utterances that ended without any recognized text (false activations, trailing silence).
    public var emptyUtterances = 0
    public var utterancesEndedByEndpoint = 0
    public var utterancesEndedByDuration = 0
    public var finalizationTimeouts = 0
    public var transcriptionFailures = 0
    public var lastTranscriptionFailure: String?
    public var audioSecondsTranscribed: TimeInterval = 0
    /// Activations for which the pre-roll buffer no longer held the estimated onset.
    public var preRollShortfalls = 0
    /// Frames overwritten in the ring buffer before the recognizer read them.
    public var overrunFrames: Int64 = 0

    public var finalSegments = 0
    public var duplicateTranscriptsDropped = 0
    public var conversationsStarted = 0
    public var conversationsCompleted = 0

    public var semanticRequests = 0
    public var summariesProduced = 0
    public var duplicateSummariesSuppressed = 0
    /// Requests that ended without a summary although the model was tried.
    public var summaryFallbacks = 0
    public var unclearTranscripts = 0
    public var modelAttempts = 0
    public var summaryRejections = 0
    public var staleResultsDropped = 0
    public var lastSemanticFailure: String?

    /// Wall-clock seconds.
    public var activationToTranscription = TimingStatistics()
    public var preRollUsed = TimingStatistics()
    public var speechEndToFinalTranscript = TimingStatistics()
    public var semanticProcessing = TimingStatistics()
    public var speechEndToSummary = TimingStatistics()

    public init() {}

    public func reportLines() -> [String] {
        let ms = { (s: Double) in (s * 1000).formatted(.number.precision(.fractionLength(0))) + " ms" }
        let sec = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        var lines = [
            "Classifier windows: \(windows); speech windows: \(speechWindows); suppressed by music: \(windowsSuppressedByMusic)",
            "Activations: \(activations); utterances started: \(utterancesStarted), finished: \(utterancesFinished), "
                + "empty: \(emptyUtterances), ended by endpoint: \(utterancesEndedByEndpoint), by duration: \(utterancesEndedByDuration)",
            "Audio transcribed: \(audioSecondsTranscribed.formatted(sec)) s; pre-roll shortfalls: \(preRollShortfalls); "
                + "overrun frames: \(overrunFrames)",
            "Transcription failures: \(transcriptionFailures); finalization timeouts: \(finalizationTimeouts)",
            "Final segments: \(finalSegments); duplicate transcripts dropped: \(duplicateTranscriptsDropped)",
            "Conversations: \(conversationsStarted) started, \(conversationsCompleted) completed",
            "Semantic requests: \(semanticRequests) (model attempts \(modelAttempts)); summaries: \(summariesProduced); "
                + "duplicates suppressed: \(duplicateSummariesSuppressed); fallbacks: \(summaryFallbacks); "
                + "unclear: \(unclearTranscripts); rejections: \(summaryRejections); stale dropped: \(staleResultsDropped)",
        ]
        func timing(_ name: String, _ stats: TimingStatistics) {
            guard stats.count > 0 else { return }
            lines.append("\(name): mean \(ms(stats.mean)), p95 \(ms(stats.p95)), max \(ms(stats.max)) (n = \(stats.count))")
        }
        timing("Activation → transcription running", activationToTranscription)
        timing("Pre-roll audio used per activation", preRollUsed)
        timing("End of speech → final transcript", speechEndToFinalTranscript)
        timing("Semantic processing", semanticProcessing)
        timing("End of speech → summary", speechEndToSummary)
        if let lastTranscriptionFailure { lines.append("Last transcription failure: \(lastTranscriptionFailure)") }
        if let lastSemanticFailure { lines.append("Last semantic failure: \(lastSemanticFailure)") }
        return lines
    }
}

/// The pipeline's view after one classifier window (for the debugging UI).
public struct SpeechActivityReport: Hashable, Sendable {
    public var audioTime: AudioTimeRange
    public var evidence: SpeechEvidence
    public var isSpeechActive: Bool
    public var isTranscribing: Bool
    public var preRoll: PreRollAudioBuffer.Status
    public var diagnostics: SpeechIntelligenceDiagnostics
}

/// Everything a consumer of the speech intelligence pipeline receives, in order.
public enum SpeechIntelligenceOutput: Sendable {
    case capabilities(SpeechCapabilities)
    /// A speech event was created or changed (same `id`, higher `revision`).
    case result(SpeechSemanticResult)
    case activity(SpeechActivityReport)
    /// Transcripts held by the pipeline were discarded (transcription switched off). Consumers
    /// should discard theirs.
    case speechDataCleared
    /// The listening session ended; all temporary speech data was discarded.
    case sessionEnded(SpeechIntelligenceDiagnostics)
}
