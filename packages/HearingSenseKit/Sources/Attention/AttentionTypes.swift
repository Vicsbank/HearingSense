import Foundation
import HearingSenseDomain

/// Everything the engine reacts to. Each input carries its own time, so a recorded sequence can
/// be replayed and gives the same decisions; the engine never reads the system clock.
public enum AttentionInput: Hashable, Sendable {
    /// A new listening session: all episode state is discarded.
    case sessionStarted(at: Date)
    /// Listening stopped or was interrupted: every episode is resolved.
    case sessionEnded(at: Date)
    /// Window 2: a confirmed sound event started, changed or ended.
    case sound(AcousticEventUpdate)
    /// Window 3: the latest revision of a speech event.
    case speech(SpeechSemanticResult)
    /// The user changed the mode or a preference. Applies to the episodes that exist.
    case preferences(AttentionPreferences, at: Date)
    /// Window 6: the semantic engine accepted a statement as relevant for one of the user's goals.
    case semantic(SemanticAttentionSignal)
    /// The speech pipeline discarded its speech events (transcription was switched off): the
    /// engine drops every speech source and all speech-derived text.
    case speechDataCleared(at: Date)
    /// Time passed (the host calls this at `AttentionEngine.nextDeadline`): expirations, deferred
    /// presentations, stale sources.
    case tick(at: Date)

    /// The time this input happened.
    public var date: Date {
        switch self {
        case .sessionStarted(let date), .sessionEnded(let date), .tick(let date), .speechDataCleared(let date): date
        case .preferences(_, let date): date
        case .speech(let result): result.updatedDate
        case .semantic(let signal): signal.date
        case .sound(let update):
            switch update {
            case .started(let event): event.confirmedDate
            case .updated(let event): event.lastObservedDate
            case .ended(let event): event.endedDate ?? event.lastObservedDate
            }
        }
    }
}

/// A statement the semantic engine (Window 6) accepted as relevant for one of the user's goals.
/// The attention engine does not judge its meaning again; it decides whether and how it is
/// presented: preferences, repetition, the presentation budget and expiry stay here.
public struct SemanticAttentionSignal: Hashable, Sendable {
    public enum Urgency: String, Hashable, Sendable, Codable {
        case low, normal, high
    }

    public var id: UUID
    public var goalID: UUID
    /// A few words for the expanded presentation ("Exam moved to Friday"). Speech-derived:
    /// handled like a speech summary, never part of a title, a log or an export.
    public var headline: String
    /// The statement itself, used once to recognize a repetition and not kept.
    public var statement: String
    public var urgency: Urgency
    /// The personal relevance is not established: presented, but not worded as a fact.
    public var isUncertain: Bool
    public var date: Date

    public init(id: UUID = UUID(), goalID: UUID, headline: String, statement: String, urgency: Urgency = .normal,
                isUncertain: Bool = false, date: Date)
    {
        self.id = id
        self.goalID = goalID
        self.headline = headline
        self.statement = statement
        self.urgency = urgency
        self.isUncertain = isUncertain
        self.date = date
    }
}

/// What the scheduler decided for one episode.
public enum AttentionAction: String, Hashable, Sendable, Codable, CaseIterable {
    /// Present a new episode.
    case show = "SHOW"
    /// Change an episode that is presented.
    case update = "UPDATE"
    /// Do not present (ambient, muted, duplicate, cooling down, cosmetic change).
    case suppress = "SUPPRESS"
    /// Eligible, but not now: waiting for a condition, the presentation budget or the update interval.
    case `defer` = "DEFER"
    /// Every source ended; the presentation ends after a short linger.
    case resolve = "RESOLVE"
    /// The episode's presentation is over (timed out, dropped while deferred, session ended).
    case expire = "EXPIRE"
}

/// What caused a decision (metadata only).
public enum AttentionTrigger: Hashable, Sendable, Codable {
    case sound(kindID: String, phase: AcousticEventPhase)
    case speech(state: SpeechProcessingState, level: Int, summaryRevision: Int)
    case timer
    case preferences
    case session
    case semantic

    public var summary: String {
        switch self {
        case .sound(let kindID, let phase): "sound \(kindID) \(phase.rawValue)"
        case .speech(let state, let level, let revision): "speech \(state.rawValue) L\(level) summary r\(revision)"
        case .timer: "timer"
        case .semantic: "goal match"
        case .preferences: "preferences"
        case .session: "session"
        }
    }
}

/// One scheduler decision with its explanation. `event` is the episode after the decision.
public struct AttentionDecision: Identifiable, Hashable, Sendable, Codable {
    /// Position in the engine's decision sequence.
    public var id: Int
    public var action: AttentionAction
    public var event: AttentionEvent
    /// What Window 5 should do; nil when nothing that is shown changes.
    public var intent: AttentionPresentationIntent?
    public var reasons: [AttentionReason]
    public var decidedAt: Date
    public var trigger: AttentionTrigger

    /// One line of metadata for logs and reports. Contains no speech-derived text.
    public var summary: String {
        "\(action.rawValue) \(event.id) \(event.title) [\(event.priority)] "
            + reasons.map(\.rawValue).joined(separator: ",") + " ← \(trigger.summary)"
    }
}

/// A cooldown that is running.
public struct AttentionCooldown: Hashable, Sendable, Codable, Identifiable {
    /// Sound kind id, or `speech`.
    public var id: String
    public var until: Date
}

public struct AttentionStatistics: Hashable, Sendable, Codable {
    public var inputs = 0
    public var soundInputs = 0
    public var speechInputs = 0
    /// Speech revisions that changed nothing the engine uses (partial transcripts, timings).
    public var speechProgressIgnored = 0
    /// Goal matches received from the semantic engine, and those dropped as repetitions.
    public var semanticInputs = 0
    public var semanticRepeats = 0
    public var decisions: [AttentionAction: Int] = [:]
    public var episodesCreated = 0
    public var fusions = 0
    public var rejoins = 0
    public var escalations = 0
    public var evictions = 0
    public var staleSources = 0
    public var maximumEpisodes = 0
    public var maximumDeferred = 0

    public init() {}

    public func count(_ action: AttentionAction) -> Int { decisions[action] ?? 0 }
}

/// The engine's state for display and diagnostics (metadata; private text only inside `events`).
public struct AttentionSnapshot: Hashable, Sendable {
    public var date: Date
    public var mode: AttentionMode
    /// Presented episodes, most important first, then most recently changed.
    public var presented: [AttentionEvent]
    /// Episodes that are tracked but not shown (suppressed, deferred, timed out).
    public var tracked: [AttentionEvent]
    public var deferred: [AttentionEventID]
    public var cooldowns: [AttentionCooldown]
    /// Presentations below `high` counted against the budget right now, and the budget.
    public var budgetUsed: Int
    public var budgetLimit: Int
    public var statistics: AttentionStatistics
}
