import Foundation

/// Stable identifier of one acoustic event occurrence. Later modules (speech, attention,
/// presentation) attach their own data keyed by this id instead of mutating the event.
public struct AcousticEventID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public var description: String { rawValue.uuidString }
}

/// Lifecycle of an acoustic event.
///
/// `candidate` exists only inside the detector (`AcousticEventCandidate`); published events
/// (`ConfirmedAcousticEvent`) are `confirmed` (first publication), `ongoing` (still observed)
/// or `ended` (final).
public enum AcousticEventPhase: String, Hashable, Sendable, Codable {
    case candidate, confirmed, ongoing, ended
}

/// Where an event came from. Window 3 is expected to add speech-derived sources.
public enum AcousticEventSource: Hashable, Sendable, Codable {
    case soundClassifier(SoundModelID)
}

/// How much classifier evidence one label contributed to an event.
public struct LabelEvidence: Hashable, Sendable, Codable {
    public var label: SoundLabel
    /// Windows in which this label reached the evidence threshold.
    public var windowCount: Int
    public var peakScore: ClassifierScore
    public var scoreSum: Double

    public init(label: SoundLabel, windowCount: Int, peakScore: ClassifierScore, scoreSum: Double) {
        self.label = label
        self.windowCount = windowCount
        self.peakScore = peakScore
        self.scoreSum = scoreSum
    }

    public var meanScore: ClassifierScore {
        ClassifierScore(windowCount > 0 ? scoreSum / Double(windowCount) : 0)
    }
}

/// Aggregated classifier evidence behind an event (metadata only, never audio).
public struct EventEvidence: Hashable, Sendable, Codable {
    /// Windows whose best score for this kind reached the evidence threshold.
    public var supportingWindows: Int
    /// All windows observed since the event's first evidence (supporting or not).
    public var observedWindows: Int
    public var peakScore: ClassifierScore
    public var scoreSum: Double
    /// Per-label evidence, strongest contribution first.
    public var labels: [LabelEvidence]

    public init(supportingWindows: Int = 0, observedWindows: Int = 0, peakScore: ClassifierScore = .zero,
                scoreSum: Double = 0, labels: [LabelEvidence] = [])
    {
        self.supportingWindows = supportingWindows
        self.observedWindows = observedWindows
        self.peakScore = peakScore
        self.scoreSum = scoreSum
        self.labels = labels
    }

    public var meanScore: ClassifierScore {
        ClassifierScore(supportingWindows > 0 ? scoreSum / Double(supportingWindows) : 0)
    }

    /// Fraction of observed windows that supported the event.
    public var supportRatio: Double {
        observedWindows > 0 ? Double(supportingWindows) / Double(observedWindows) : 0
    }
}

/// Rule-based evidence quality (see `EventQuality.assess`). An ordinal indicator, not a
/// probability of correctness.
public enum EventQuality: Int, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    case weak = 0, moderate = 1, strong = 2

    public static func < (lhs: EventQuality, rhs: EventQuality) -> Bool { lhs.rawValue < rhs.rawValue }

    /// strong: peak ≥ 0.7 and at least 3 supporting windows; moderate: peak ≥ 0.5 or at least
    /// 3 supporting windows; otherwise weak.
    public static func assess(_ evidence: EventEvidence) -> EventQuality {
        let peak = evidence.peakScore.rawValue
        if peak >= 0.7, evidence.supportingWindows >= 3 { return .strong }
        if peak >= 0.5 || evidence.supportingWindows >= 3 { return .moderate }
        return .weak
    }

    public var description: String {
        switch self {
        case .weak: "weak"
        case .moderate: "moderate"
        case .strong: "strong"
        }
    }
}

/// A possible event that has evidence but has not (yet) met its confirmation rule.
/// Exposed for diagnostics; consumers should act on `ConfirmedAcousticEvent` only.
public struct AcousticEventCandidate: Hashable, Sendable {
    public var kind: SoundEventKind
    public var primaryLabel: SoundLabel
    /// Audio-clock start of the first supporting window.
    public var firstDetected: TimeInterval
    /// Audio-clock end of the latest supporting window.
    public var lastDetected: TimeInterval
    public var evidence: EventEvidence
    /// Supporting windows inside the confirmation look-back, and how many the rule needs.
    public var recentHits: Int
    public var requiredHits: Int

    public init(kind: SoundEventKind, primaryLabel: SoundLabel, firstDetected: TimeInterval,
                lastDetected: TimeInterval, evidence: EventEvidence, recentHits: Int, requiredHits: Int)
    {
        self.kind = kind
        self.primaryLabel = primaryLabel
        self.firstDetected = firstDetected
        self.lastDetected = lastDetected
        self.evidence = evidence
        self.recentHits = recentHits
        self.requiredHits = requiredHits
    }

    public var phase: AcousticEventPhase { .candidate }
}

/// A sound event that passed temporal confirmation. This is the contract later windows consume:
/// Window 3 attaches transcripts/summaries, Window 4 priorities and notification decisions,
/// Window 5 presentation — all keyed by `id`, without changing this type's meaning.
public struct ConfirmedAcousticEvent: Identifiable, Hashable, Sendable, Codable {
    public let id: AcousticEventID
    public let kind: SoundEventKind
    public let source: AcousticEventSource
    /// The label with the most accumulated evidence so far (original identifier).
    public var primaryLabel: SoundLabel
    public var phase: AcousticEventPhase

    /// Audio-clock start of the first supporting window.
    public let audioStart: TimeInterval
    /// Audio-clock end of the window that confirmed the event.
    public let audioConfirmed: TimeInterval
    /// Audio-clock end of the latest supporting window.
    public var audioLastObserved: TimeInterval

    /// Estimated wall-clock time of `audioStart`.
    public let startDate: Date
    /// Wall-clock time at which the detector confirmed the event.
    public let confirmedDate: Date
    /// Wall-clock time of the latest supporting classifier result.
    public var lastObservedDate: Date
    /// Wall-clock time at which the event was ended (nil while active).
    public var endedDate: Date?

    public var evidence: EventEvidence
    public var quality: EventQuality

    public init(id: AcousticEventID = AcousticEventID(), kind: SoundEventKind, source: AcousticEventSource,
                primaryLabel: SoundLabel, phase: AcousticEventPhase, audioStart: TimeInterval,
                audioConfirmed: TimeInterval, audioLastObserved: TimeInterval, startDate: Date,
                confirmedDate: Date, lastObservedDate: Date, endedDate: Date? = nil,
                evidence: EventEvidence, quality: EventQuality)
    {
        self.id = id
        self.kind = kind
        self.source = source
        self.primaryLabel = primaryLabel
        self.phase = phase
        self.audioStart = audioStart
        self.audioConfirmed = audioConfirmed
        self.audioLastObserved = audioLastObserved
        self.startDate = startDate
        self.confirmedDate = confirmedDate
        self.lastObservedDate = lastObservedDate
        self.endedDate = endedDate
        self.evidence = evidence
        self.quality = quality
    }

    public var category: SoundCategory { kind.category }
    public var isActive: Bool { phase != .ended }

    /// Observed duration on the audio clock (first to latest supporting window).
    public var observedDuration: TimeInterval { audioLastObserved - audioStart }

    /// Audio-clock time from the start of the first supporting window to confirmation. Includes
    /// the classifier's window length, so it is never shorter than one window.
    public var confirmationLatency: TimeInterval { audioConfirmed - audioStart }
}

/// Changes to the set of confirmed events, in the order they happened.
public enum AcousticEventUpdate: Hashable, Sendable {
    /// The event just passed confirmation (phase `.confirmed`).
    case started(ConfirmedAcousticEvent)
    /// New evidence changed something worth publishing (phase `.ongoing`); rate-limited.
    case updated(ConfirmedAcousticEvent)
    /// No evidence for the kind's timeout, or the session ended (phase `.ended`). Final.
    case ended(ConfirmedAcousticEvent)

    public var event: ConfirmedAcousticEvent {
        switch self {
        case .started(let event), .updated(let event), .ended(let event): event
        }
    }
}
