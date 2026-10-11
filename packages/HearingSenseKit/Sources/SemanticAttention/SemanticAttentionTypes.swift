import Foundation

/// Something the user wants to hear about, in their own words ("anything that could affect my
/// grades"). No keywords: what counts as a match is decided by reasoning about meaning.
public struct AttentionGoal: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var text: String
    public var isEnabled: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, isEnabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    public static let maximumLength = 160
    /// More goals than this are not sent to the model in one request.
    public static let maximumActive = 6

    /// The text as it is stored: one line, trimmed, bounded.
    public static func normalized(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(line.prefix(maximumLength))
    }
}

/// One finalized utterance to evaluate. Sensitive: speech-derived text that lives only for the
/// evaluation.
public struct SemanticUtterance: Hashable, Sendable {
    public var id: UUID
    public var text: String
    /// Earlier utterances of the same conversation, oldest first (context only).
    public var context: [String]
    public var date: Date
    /// The recognizer rated its own output as poor: a match is at most uncertain.
    public var isLowQuality: Bool

    public init(id: UUID = UUID(), text: String, context: [String] = [], date: Date = Date(), isLowQuality: Bool = false) {
        self.id = id
        self.text = text
        self.context = context
        self.date = date
        self.isLowQuality = isLowQuality
    }
}

public enum SemanticVerdict: String, Hashable, Sendable, Codable, CaseIterable {
    case relevant, irrelevant, uncertain
}

public enum SemanticUrgency: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case low, normal, high

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// What the statement is, as far as it matters for an alert.
public enum StatementKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// Something is, was or will be the case; an instruction; an announcement.
    case statement
    /// A question: nothing is asserted.
    case question
    /// "If", "might", "what if", a wish, a plan that is not decided.
    case hypothetical
    /// Reported, quoted, a joke or sarcasm: the speaker does not assert it now.
    case reported
    /// It says that nothing changes or that something does not happen.
    case noChange
    /// Too fragmentary to tell.
    case unclear
}

/// Whom the statement concerns.
public enum StatementSubject: String, Hashable, Sendable, Codable, CaseIterable {
    /// The listener, or a group the listener plausibly belongs to (the class, everyone here).
    case listenerOrGroup
    /// Clearly another person or another group.
    case someoneElse
    case unclear
}

/// How far the engine would go in presenting a decision. Window 4 has the last word.
public enum SuggestedPresentation: String, Hashable, Sendable, Codable, CaseIterable {
    /// Nothing.
    case none
    /// Kept in the app's list only, no alert (an uncertain match).
    case listOnly
    /// An attention event of normal priority.
    case notify
    /// An attention event of high priority.
    case alert
}

/// Where in the staged pipeline a decision was made.
public enum SemanticStage: String, Hashable, Sendable, Codable, CaseIterable {
    /// No goals, or semantic attention is off.
    case inactive
    /// The utterance gate: too short or a filler; no model call.
    case gate
    /// An identical utterance was decided a moment ago.
    case cache
    /// The model's fast first pass said "everyday talk"; no full judgement.
    case triage
    /// The language model's reasoning, checked by the verifier.
    case model
    /// The model was unavailable or failed; nothing is presented.
    case fallback
    /// Dropped from a full queue or cancelled before it was evaluated.
    case dropped
}

/// The validated result for one utterance.
public struct SemanticAttentionDecision: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var utteranceID: UUID
    public var date: Date
    public var matchedGoalID: UUID?
    public var verdict: SemanticVerdict
    /// Why, in a short sentence written by the model ("An exam date changed, which affects
    /// preparation"). Speech-derived: private.
    public var reason: String
    /// The words of the utterance the verdict rests on, verified to occur in it. Private.
    public var evidence: String
    /// A few words for the expanded island ("Exam moved to Friday"). Private.
    public var headline: String
    public var urgency: SemanticUrgency
    /// False when the same statement was already accepted a short while ago.
    public var isNovel: Bool
    public var statementKind: StatementKind
    public var subject: StatementSubject
    /// The personal relevance is not established (subject unclear, poor recognition).
    public var isPersonalRelevanceUncertain: Bool
    public var presentation: SuggestedPresentation
    public var stage: SemanticStage
    /// Checks of the verifier that changed the model's answer (names only).
    public var corrections: [String]
    /// Seconds from submission to this decision, and the part spent in the model.
    public var latency: TimeInterval
    public var modelTime: TimeInterval

    public init(id: UUID = UUID(), utteranceID: UUID, date: Date, matchedGoalID: UUID? = nil, verdict: SemanticVerdict,
                reason: String = "", evidence: String = "", headline: String = "", urgency: SemanticUrgency = .normal,
                isNovel: Bool = true, statementKind: StatementKind = .unclear, subject: StatementSubject = .unclear,
                isPersonalRelevanceUncertain: Bool = false, presentation: SuggestedPresentation = .none,
                stage: SemanticStage, corrections: [String] = [], latency: TimeInterval = 0, modelTime: TimeInterval = 0)
    {
        self.id = id
        self.utteranceID = utteranceID
        self.date = date
        self.matchedGoalID = matchedGoalID
        self.verdict = verdict
        self.reason = reason
        self.evidence = evidence
        self.headline = headline
        self.urgency = urgency
        self.isNovel = isNovel
        self.statementKind = statementKind
        self.subject = subject
        self.isPersonalRelevanceUncertain = isPersonalRelevanceUncertain
        self.presentation = presentation
        self.stage = stage
        self.corrections = corrections
        self.latency = latency
        self.modelTime = modelTime
    }

    /// Accepted for Window 4: a verified, novel, relevant match.
    public var isAccepted: Bool { verdict == .relevant && isNovel && presentation >= .notify }

    /// One line of metadata for logs. No speech-derived text.
    public var redactedSummary: String {
        "\(verdict.rawValue) stage=\(stage.rawValue) kind=\(statementKind.rawValue) subject=\(subject.rawValue) "
            + "urgency=\(urgency.rawValue) novel=\(isNovel) presentation=\(presentation.rawValue)"
            + (corrections.isEmpty ? "" : " corrections=\(corrections.joined(separator: ","))")
    }
}

extension SuggestedPresentation: Comparable {
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// What the language model answered, before verification. Untrusted.
public struct RelevanceJudgement: Hashable, Sendable {
    /// 1-based index into the goals of the request; 0 for none.
    public var goalIndex: Int
    public var verdict: SemanticVerdict
    public var consequence: String
    public var evidence: String
    public var headline: String
    public var urgency: SemanticUrgency
    public var statementKind: StatementKind
    public var subject: StatementSubject

    public init(goalIndex: Int, verdict: SemanticVerdict, consequence: String = "", evidence: String = "",
                headline: String = "", urgency: SemanticUrgency = .normal, statementKind: StatementKind = .statement,
                subject: StatementSubject = .listenerOrGroup)
    {
        self.goalIndex = goalIndex
        self.verdict = verdict
        self.consequence = consequence
        self.evidence = evidence
        self.headline = headline
        self.urgency = urgency
        self.statementKind = statementKind
        self.subject = subject
    }

    public static let none = RelevanceJudgement(goalIndex: 0, verdict: .irrelevant)
}

public enum SemanticReasonerAvailability: Hashable, Sendable {
    case available
    case unavailable(String)

    public var isUsable: Bool { self == .available }
}

/// A language model that reasons about whether an utterance matters for one of the goals.
/// Production: `FoundationModelRelevanceReasoner` (on device). Tests use scripted ones.
public protocol SemanticRelevanceReasoning: Sendable {
    func availability() async -> SemanticReasonerAvailability
    func prewarm() async
    func judge(_ utterance: SemanticUtterance, goals: [AttentionGoal]) async throws -> RelevanceJudgement
    /// A fast, generous first pass: false means "certainly everyday talk", and the full
    /// judgement is skipped. The default lets everything through.
    func couldMatter(_ utterance: SemanticUtterance, goals: [AttentionGoal]) async throws -> Bool
}

extension SemanticRelevanceReasoning {
    public func couldMatter(_ utterance: SemanticUtterance, goals: [AttentionGoal]) async throws -> Bool { true }
}

/// A cheap score of how close an utterance is to a goal, in 0…1. Used to order goals and as a
/// baseline in the evaluation; never the final decision.
public protocol GoalSimilarityScoring: Sendable {
    var name: String { get }
    func score(utterance: String, goal: String) -> Double
}
