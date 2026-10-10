import Foundation

/// Stable identifier of one *speech event*: a stretch of nearby speech that the speech pipeline
/// treats as one conversation (one or more utterances separated by short pauses). Every
/// `SpeechSemanticResult` update for that conversation carries the same id, so consumers
/// (Attention Priority Engine, presentation) can tell "new speech" from "more of the same".
public struct SpeechEventID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public var description: String { rawValue.uuidString }
}

/// Lifecycle of a speech event.
///
/// ```
/// detected ─▶ transcribing ─▶ processing ─▶ summarized ─▶ completed
///     │            │              │              ▲  │
///     │            │              └──────────────┘  │   (more utterances in the same conversation)
///     └────────────┴──────────────▶ completed / failed
/// ```
public enum SpeechProcessingState: String, Hashable, Sendable, Codable, CaseIterable {
    /// Speech-like sound was noticed; nothing has been transcribed (yet).
    case detected
    /// On-device transcription is running for the current utterance.
    case transcribing
    /// A final transcript exists; semantic interpretation is running.
    case processing
    /// An interpretation (summary and/or category) is available; the conversation may continue.
    case summarized
    /// The speech ended. Final: no further updates for this id.
    case completed
    /// Transcription or interpretation failed and nothing better than the current content will
    /// arrive for this id. `SpeechSemanticResult.failure` explains why.
    case failed

    public var isTerminal: Bool { self == .completed || self == .failed }

    public var displayName: String {
        switch self {
        case .detected: "Detected"
        case .transcribing: "Transcribing"
        case .processing: "Processing"
        case .summarized: "Summarized"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

/// How much the pipeline could tell about a speech event (layered fallback).
public enum SpeechOutputLevel: Int, Hashable, Comparable, Sendable, Codable {
    /// Level 1 — speech was detected, no transcript (transcription off, unavailable or empty).
    case detection = 1
    /// Level 2 — an on-device transcript is available, no validated summary.
    case transcript = 2
    /// Level 3 — a validated short summary from the on-device language model is available.
    case summary = 3

    public static func < (lhs: SpeechOutputLevel, rhs: SpeechOutputLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What kind of utterance it was. Advisory input for the Attention Priority Engine.
public enum SpeechSemanticCategory: String, Hashable, Sendable, Codable, CaseIterable {
    case question
    case request
    case reminder
    case announcement
    case warning
    case casualConversation
    case greeting
    case other
    /// Not interpreted (no transcript, unclear transcript, or interpretation failed).
    case unknown

    public var displayName: String {
        switch self {
        case .question: "Question"
        case .request: "Request"
        case .reminder: "Reminder"
        case .announcement: "Announcement"
        case .warning: "Warning"
        case .casualConversation: "Casual conversation"
        case .greeting: "Greeting"
        case .other: "Other"
        case .unknown: "Unknown"
        }
    }
}

/// Whether on-device speech transcription can run right now.
public enum TranscriptionAvailability: Hashable, Sendable, Codable {
    /// Not checked yet.
    case unknown
    case available
    /// The user switched speech transcription off (sound classification keeps running).
    case disabledByUser
    /// The device does not support Apple's on-device transcriber.
    case unsupportedDevice
    /// No on-device model exists for this language.
    case unsupportedLocale(String)
    /// The language is supported but its model is not installed; the user can download it.
    case modelNotInstalled(String)
    case modelDownloading(String)
    /// Transcription kept failing in this session; the pipeline fell back to detection only.
    case failed(String)

    public var isUsable: Bool { self == .available }

    public var displayName: String {
        switch self {
        case .unknown: "Not checked"
        case .available: "Available (on device)"
        case .disabledByUser: "Off"
        case .unsupportedDevice: "Not supported on this device"
        case .unsupportedLocale(let locale): "Language \(locale) not supported"
        case .modelNotInstalled(let locale): "Speech model for \(locale) not installed"
        case .modelDownloading(let locale): "Downloading speech model for \(locale)…"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

/// Whether the on-device language model (Apple Foundation Models) can interpret transcripts.
public enum SemanticModelAvailability: Hashable, Sendable, Codable {
    /// Not checked yet.
    case unknown
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    /// The model is downloading or otherwise not ready yet.
    case modelNotReady
    case unsupportedLanguage(String)
    case unavailable(String)

    public var isUsable: Bool { self == .available }

    public var displayName: String {
        switch self {
        case .unknown: "Not checked"
        case .available: "Available (on device)"
        case .deviceNotEligible: "Device not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is turned off"
        case .modelNotReady: "Model not ready (downloading or preparing)"
        case .unsupportedLanguage(let language): "Language \(language) not supported by the model"
        case .unavailable(let reason): "Unavailable: \(reason)"
        }
    }
}

/// Speech **recognition** quality of a transcript. This describes how sure the recognizer was
/// about the words; it says nothing about whether a summary is right (`SummaryReliability`).
public struct TranscriptQuality: Hashable, Sendable, Codable {
    public enum Rating: String, Hashable, Sendable, Codable, Comparable {
        case unknown, poor, fair, good

        private var order: Int {
            switch self {
            case .unknown: 0
            case .poor: 1
            case .fair: 2
            case .good: 3
            }
        }

        public static func < (lhs: Rating, rhs: Rating) -> Bool { lhs.order < rhs.order }
    }

    public var rating: Rating
    /// Mean and lowest per-run confidence reported by the recognizer (0...1). Uncalibrated:
    /// do not read them as probabilities of correctness.
    public var meanConfidence: Double?
    public var minimumConfidence: Double?
    public var wordCount: Int

    public init(rating: Rating, meanConfidence: Double?, minimumConfidence: Double?, wordCount: Int) {
        self.rating = rating
        self.meanConfidence = meanConfidence
        self.minimumConfidence = minimumConfidence
        self.wordCount = wordCount
    }

    public static let unknown = TranscriptQuality(rating: .unknown, meanConfidence: nil, minimumConfidence: nil,
                                                  wordCount: 0)

    /// Rule-based rating: good ≥ 0.80 mean confidence, fair ≥ 0.50, otherwise poor; unknown
    /// when the recognizer reported no confidence.
    public static func assess(meanConfidence: Double?, minimumConfidence: Double?, wordCount: Int) -> TranscriptQuality {
        let rating: Rating = switch meanConfidence {
        case .none: .unknown
        case .some(let mean) where mean >= 0.80: .good
        case .some(let mean) where mean >= 0.50: .fair
        default: .poor
        }
        return TranscriptQuality(rating: rating, meanConfidence: meanConfidence,
                                 minimumConfidence: minimumConfidence, wordCount: wordCount)
    }
}

/// Transcribed speech. Sensitive: kept in memory only, never logged or persisted by default.
public struct SpeechTranscript: Hashable, Sendable, Codable {
    public var text: String
    /// BCP-47 identifier of the recognizer's language, e.g. `en-US`.
    public var language: String
    /// False while the recognizer may still revise the text.
    public var isFinal: Bool
    public var quality: TranscriptQuality
    /// Session audio clock span of the transcribed speech.
    public var audioTime: AudioTimeRange

    public init(text: String, language: String, isFinal: Bool, quality: TranscriptQuality, audioTime: AudioTimeRange) {
        self.text = text
        self.language = language
        self.isFinal = isFinal
        self.quality = quality
        self.audioTime = audioTime
    }
}

/// How far a summary was checked. **Semantic interpretation** quality, separate from
/// `TranscriptQuality`. Rule-based, not a probability: `validated` means the deterministic
/// faithfulness checks found nothing wrong, not that the summary is guaranteed correct.
public enum SummaryReliability: String, Hashable, Sendable, Codable {
    /// Passed every deterministic check (grounding, negation, time, length) as generated.
    case validated
    /// Passed after a deterministic repair (e.g. a dropped time was appended from the transcript).
    case repaired
    /// Passed the critical checks but has warnings (e.g. a number from the transcript is missing).
    case validatedWithWarnings
}

/// A short headline for a speech event, e.g. "Biology Test Tomorrow".
public struct SpeechSummary: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        /// Apple Foundation Models (`SystemLanguageModel`), on device.
        case onDeviceLanguageModel
    }

    public var text: String
    public var wordCount: Int
    public var source: Source
    public var reliability: SummaryReliability
    /// Human-readable notes from validation (warnings, repairs). No transcript text.
    public var notes: [String]

    public init(text: String, wordCount: Int, source: Source, reliability: SummaryReliability, notes: [String] = []) {
        self.text = text
        self.wordCount = wordCount
        self.source = source
        self.reliability = reliability
        self.notes = notes
    }
}

/// Machine-readable details extracted from the transcript (advisory).
public struct SpeechSemanticDetails: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        case onDeviceLanguageModel
        /// Deterministic keyword rules (fallback when the language model is unavailable).
        case rules
    }

    public var source: Source
    /// Main subject, only if its words occur in the transcript.
    public var subject: String?
    /// Time, date or number mentioned, only if it occurs in the transcript.
    public var timeOrNumber: String?
    /// The utterance negates something ("has not arrived", "don't open"). Determined by rules.
    public var isNegated: Bool
    public var isQuestion: Bool

    public init(source: Source, subject: String? = nil, timeOrNumber: String? = nil, isNegated: Bool = false,
                isQuestion: Bool = false)
    {
        self.source = source
        self.subject = subject
        self.timeOrNumber = timeOrNumber
        self.isNegated = isNegated
        self.isQuestion = isQuestion
    }
}

/// Wall-clock latencies measured for one speech event (seconds). Nil = not measured.
public struct SpeechLatency: Hashable, Sendable, Codable {
    /// From the classifier result that triggered activation to transcription running.
    public var activationToTranscription: TimeInterval?
    /// Audio already in the pre-roll buffer that was handed to the transcriber at activation
    /// (seconds of audio before the trigger, not a delay).
    public var preRollUsed: TimeInterval?
    /// From the end of the last transcribed word to the final transcript.
    public var speechEndToFinalTranscript: TimeInterval?
    /// Duration of the language-model interpretation (all attempts).
    public var semanticProcessing: TimeInterval?
    /// From the end of the last transcribed word to the summary (or fallback) being available.
    public var speechEndToSummary: TimeInterval?

    public init(activationToTranscription: TimeInterval? = nil, preRollUsed: TimeInterval? = nil,
                speechEndToFinalTranscript: TimeInterval? = nil, semanticProcessing: TimeInterval? = nil,
                speechEndToSummary: TimeInterval? = nil)
    {
        self.activationToTranscription = activationToTranscription
        self.preRollUsed = preRollUsed
        self.speechEndToFinalTranscript = speechEndToFinalTranscript
        self.semanticProcessing = semanticProcessing
        self.speechEndToSummary = speechEndToSummary
    }
}

/// Everything the speech intelligence pipeline knows about one speech event. This is the
/// contract the Attention Priority Engine (Window 4) consumes.
///
/// Updates: the pipeline publishes the same `id` repeatedly while a conversation develops.
/// `revision` increases with every published change; `summaryRevision` increases only when the
/// summary text changes, so a consumer that notifies on summaries can ignore everything else.
/// A result in a terminal `state` is never updated again.
///
/// Privacy: `transcript` is sensitive. Keep results in memory; do not log or persist the
/// transcript unless the user explicitly opted in.
public struct SpeechSemanticResult: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeechEventID
    public var revision: Int
    public var summaryRevision: Int
    /// Window 2 `speech`/`shouting` events that overlap this speech event (may be empty for
    /// speech too short to be confirmed by the sound detector).
    public var sourceEventIDs: [AcousticEventID]
    public var state: SpeechProcessingState
    /// Session audio clock span from the start of the transcribed audio to the latest speech.
    public var audioTime: AudioTimeRange
    public var startDate: Date
    public var updatedDate: Date

    /// Most recent utterance(s) of the conversation (bounded) plus the partial text of the
    /// utterance in progress; nil at level 1.
    public var transcript: SpeechTranscript?
    /// Number of finalized utterances (recognizer sentences) in this conversation so far.
    public var utteranceCount: Int
    public var summary: SpeechSummary?
    public var category: SpeechSemanticCategory
    public var details: SpeechSemanticDetails?
    /// The final transcript is too unreliable or fragmentary to interpret (poor recognition
    /// quality, only filler words). No summary is attempted for unclear speech.
    public var isUnclear: Bool

    public var transcriptionAvailability: TranscriptionAvailability
    public var modelAvailability: SemanticModelAvailability
    public var latency: SpeechLatency
    /// Why transcription or interpretation failed or fell back. Never contains transcript text.
    public var failure: String?

    public init(id: SpeechEventID = SpeechEventID(), revision: Int = 0, summaryRevision: Int = 0,
                sourceEventIDs: [AcousticEventID] = [], state: SpeechProcessingState, audioTime: AudioTimeRange,
                startDate: Date, updatedDate: Date, transcript: SpeechTranscript? = nil, utteranceCount: Int = 0,
                summary: SpeechSummary? = nil, category: SpeechSemanticCategory = .unknown,
                details: SpeechSemanticDetails? = nil, isUnclear: Bool = false, transcriptionAvailability: TranscriptionAvailability,
                modelAvailability: SemanticModelAvailability, latency: SpeechLatency = SpeechLatency(),
                failure: String? = nil)
    {
        self.id = id
        self.revision = revision
        self.summaryRevision = summaryRevision
        self.sourceEventIDs = sourceEventIDs
        self.state = state
        self.audioTime = audioTime
        self.startDate = startDate
        self.updatedDate = updatedDate
        self.transcript = transcript
        self.utteranceCount = utteranceCount
        self.summary = summary
        self.category = category
        self.details = details
        self.isUnclear = isUnclear
        self.transcriptionAvailability = transcriptionAvailability
        self.modelAvailability = modelAvailability
        self.latency = latency
        self.failure = failure
    }

    public var level: SpeechOutputLevel {
        if summary != nil { return .summary }
        if utteranceCount > 0, let transcript, !transcript.text.isEmpty { return .transcript }
        return .detection
    }

    /// Short text for compact presentation (Dynamic Island in Window 5). Never invents content:
    /// the validated summary if there is one, otherwise a neutral label.
    public var headline: String {
        if let summary { return summary.text }
        if level == .transcript { return isUnclear ? Self.unclearHeadline : Self.transcriptHeadline }
        return Self.detectionHeadline
    }

    /// Level 1 label: speech-like sound without a transcript.
    public static let detectionHeadline = "Nearby Speech"
    /// Level 2 label: a transcript exists but no validated summary.
    public static let transcriptHeadline = "Speech Detected"
    /// The transcript is unreliable; no summary is attempted.
    public static let unclearHeadline = "Speech Unclear"
}
