import Foundation
import HearingSenseDomain

/// Limits for summaries and for what is sent to the language model.
public struct SummaryPolicy: Hashable, Sendable {
    /// Preferred headline length in words.
    public var targetWords: ClosedRange<Int> = 2 ... 3
    /// Display limit. A headline may exceed `targetWords` up to this many words when that is
    /// needed to keep a negation, time, number, place or warning.
    public var maximumWords = 6
    /// Only the newest words of a long transcript are interpreted.
    public var maximumTranscriptWords = 60
    public var maximumContextWords = 40
    /// Model attempts per request (the second attempt carries the validator's feedback).
    public var maximumAttempts = 2
    /// Seconds before a model request is abandoned and the transcript-level fallback is used.
    public var timeout: TimeInterval = 10

    public init() {}

    public static let standard = SummaryPolicy()
}

/// Text to interpret. Sensitive; lives only for the duration of the request.
public struct SemanticRequest: Hashable, Sendable {
    /// The utterance(s) to summarize.
    public var transcript: String
    /// Earlier utterances of the same conversation, oldest first (context only).
    public var context: [String]
    /// BCP-47 identifier of the transcript's language.
    public var languageIdentifier: String
    public var quality: TranscriptQuality

    public init(transcript: String, context: [String] = [], languageIdentifier: String = "en-US",
                quality: TranscriptQuality = .unknown)
    {
        self.transcript = transcript
        self.context = context
        self.languageIdentifier = languageIdentifier
        self.quality = quality
    }
}

/// What the language model returned, before validation. Untrusted: a model can drop a "not",
/// invent a detail, or follow instructions contained in the overheard speech.
public struct ModelInterpretation: Hashable, Sendable {
    public var headline: String
    public var category: SpeechSemanticCategory
    public var subject: String
    public var timeOrNumber: String

    public init(headline: String, category: SpeechSemanticCategory, subject: String = "", timeOrNumber: String = "") {
        self.headline = headline
        self.category = category
        self.subject = subject
        self.timeOrNumber = timeOrNumber
    }
}

/// A language model that interprets a transcript. Production: `FoundationModelInterpreter`
/// (Apple Foundation Models, on device). Tests use scripted implementations.
public protocol SemanticInterpreting: Sendable {
    /// Runtime availability for the given language. Must not trigger downloads.
    func availability(for languageIdentifier: String) async -> SemanticModelAvailability
    /// Loads the model ahead of the first request (optional optimization).
    func prewarm() async
    /// - Parameter feedback: why the previous attempt for this request was rejected, if any.
    func interpret(_ request: SemanticRequest, feedback: String?) async throws -> ModelInterpretation
}

public enum SemanticError: LocalizedError, Equatable {
    case unavailable(SemanticModelAvailability)
    case timedOut
    /// The model failed. The message names the error kind only, never the transcript.
    case modelFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let availability): "Language model unavailable: \(availability.displayName)"
        case .timedOut: "The language model did not answer in time"
        case .modelFailure(let kind): "Language model error: \(kind)"
        }
    }
}

/// Result of interpreting one request, after validation and fallback.
public struct SemanticOutcome: Hashable, Sendable {
    /// A validated headline, or nil when none could be produced faithfully.
    public var summary: SpeechSummary?
    public var category: SpeechSemanticCategory
    public var details: SpeechSemanticDetails?
    /// The transcript was too unreliable or fragmentary to interpret; no model call was made.
    public var isUnclear: Bool
    public var modelAvailability: SemanticModelAvailability
    /// Model calls made (0 when the model was not used).
    public var attempts: Int
    public var duration: TimeInterval
    /// Why model output was rejected, per attempt (issue names only).
    public var rejections: [String]
    /// Why no summary is available although the model was tried (no transcript text).
    public var failure: String?

    public init(summary: SpeechSummary? = nil, category: SpeechSemanticCategory = .unknown,
                details: SpeechSemanticDetails? = nil, isUnclear: Bool = false,
                modelAvailability: SemanticModelAvailability = .unknown, attempts: Int = 0, duration: TimeInterval = 0,
                rejections: [String] = [], failure: String? = nil)
    {
        self.summary = summary
        self.category = category
        self.details = details
        self.isUnclear = isUnclear
        self.modelAvailability = modelAvailability
        self.attempts = attempts
        self.duration = duration
        self.rejections = rejections
        self.failure = failure
    }
}
