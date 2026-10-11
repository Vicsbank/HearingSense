import Foundation

// Output contract of the Attention Priority Engine (Window 4), consumed by presentation
// (Window 5). Foundation only: no SwiftUI, no ActivityKit.
//
// What these types do not say: where a sound came from, how far away it is, who is speaking, or
// whether speech is addressed to the user. Priority is a deterministic policy decision about
// what may deserve a glance; it is not a probability of danger.

/// Stable identifier of one attention episode. Assigned in order by the engine, so a replay of
/// the same inputs produces the same ids. Unique within one engine instance (in memory only).
public struct AttentionEventID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static func < (lhs: AttentionEventID, rhs: AttentionEventID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "A\(rawValue)" }
}

/// How much attention an episode may deserve. Ordinal, set by policy; not derived from a
/// classifier score (a confident classification of rain is still ambient).
public enum AttentionPriority: Int, Hashable, Comparable, Sendable, Codable, CaseIterable, CustomStringConvertible {
    /// Background sound or irrelevant content. Never presented.
    case ambient = 0
    case low = 1
    case normal = 2
    case high = 3
    /// Reserved for signals whose purpose is to warn (sirens, a persisting alarm).
    case urgent = 4

    public static func < (lhs: AttentionPriority, rhs: AttentionPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .ambient: "ambient"
        case .low: "low"
        case .normal: "normal"
        case .high: "high"
        case .urgent: "urgent"
        }
    }

    public var displayName: String { description.prefix(1).uppercased() + description.dropFirst() }

    /// `steps` levels higher (or lower for a negative value), clamped to `ambient...limit`.
    public func shifted(by steps: Int, limit: AttentionPriority = .urgent) -> AttentionPriority {
        AttentionPriority(rawValue: min(max(rawValue + steps, 0), limit.rawValue)) ?? self
    }
}

/// User-facing grouping of what an episode is about. Preferences (mute, priority) are set per
/// category; the policy table works on the finer `SoundEventKind`s.
public enum AttentionCategory: String, Hashable, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    /// Sirens and alarms.
    case emergencySignals
    /// Horns, reversing beeps, bicycle bells.
    case vehicleWarnings
    /// Breaking glass, bangs, thuds.
    case impacts
    /// Screaming, crying, shouting.
    case distressSounds
    case doorAndKnock
    /// Phones ringing, beeps.
    case deviceSignals
    case speech
    case animals
    case music
    case weather
    case transportation
    case household
    case humanActivity
    case crowd
    case other

    public var displayName: String {
        switch self {
        case .emergencySignals: "Sirens & alarms"
        case .vehicleWarnings: "Horns & vehicle warnings"
        case .impacts: "Breaking glass & bangs"
        case .distressSounds: "Screaming, crying & shouting"
        case .doorAndKnock: "Doors & knocking"
        case .deviceSignals: "Phones & beeps"
        case .speech: "Speech"
        case .animals: "Animals"
        case .music: "Music"
        case .weather: "Weather & nature"
        case .transportation: "Traffic & vehicles"
        case .household: "Home & appliances"
        case .humanActivity: "Human sounds"
        case .crowd: "Crowd"
        case .other: "Other sounds"
        }
    }

    /// SF Symbol name for presentation layers.
    public var systemImage: String {
        switch self {
        case .emergencySignals: "light.beacon.max"
        case .vehicleWarnings: "car.side.rear.and.collision.and.car.side.front"
        case .impacts: "burst"
        case .distressSounds: "exclamationmark.bubble"
        case .doorAndKnock: "door.left.hand.closed"
        case .deviceSignals: "bell"
        case .speech: "person.wave.2"
        case .animals: "pawprint"
        case .music: "music.note"
        case .weather: "cloud.rain"
        case .transportation: "car"
        case .household: "house"
        case .humanActivity: "figure.walk"
        case .crowd: "person.3"
        case .other: "waveform"
        }
    }
}

/// Why the engine decided what it decided. Every decision carries at least one code; the raw
/// values are stable and appear in diagnostics and evaluation output.
public enum AttentionReason: String, Hashable, Sendable, Codable, CaseIterable {
    // What the event is
    case safetyRelevant = "safety_relevant"
    case urgentSignal = "urgent_signal"
    case categoryDefault = "category_default"
    case ambientSound = "ambient_sound"
    case minorSound = "minor_sound"
    case musicContext = "music_context"
    case lowRelevance = "low_relevance"
    // Evidence (ordinal quality of the classification, not a probability)
    case strongEvidence = "strong_evidence"
    case weakEvidence = "weak_evidence"
    // Novelty, repetition, duration
    case newEvent = "new_event"
    case recentlySeen = "recently_seen"
    case duplicate = "duplicate"
    case ongoingEvent = "ongoing_event"
    case continuationOfRecent = "continuation_of_recent"
    case repeatedEvent = "repeated_event"
    case persistentSound = "persistent_sound"
    case escalated = "escalated"
    // Mode and preferences
    case belowModeThreshold = "below_mode_threshold"
    case userMuted = "user_muted"
    case userPriorityOverride = "user_priority_override"
    case speechAttentionOff = "speech_attention_off"
    case speechImportantOnly = "speech_important_only"
    case preferencesChanged = "preferences_changed"
    // Conditions, cooldowns, scheduling
    case conditionPending = "condition_pending"
    case conditionMet = "condition_met"
    case cooldownActive = "cooldown_active"
    case cooldownBypassed = "cooldown_bypassed"
    case rateLimited = "rate_limited"
    case rateLimitBypassed = "rate_limit_bypassed"
    case updateRateLimited = "update_rate_limited"
    case deferredReleased = "deferred_released"
    case deferredExpired = "deferred_expired"
    // Speech
    case transcriptionOff = "transcription_off"
    case modelUnavailable = "model_unavailable"
    case ordinarySpeech = "ordinary_speech"
    case relevantSpeech = "relevant_speech"
    case importantSpeech = "important_speech"
    case urgentPhrase = "urgent_phrase"
    case mentionsTimeOrNumber = "mentions_time_or_number"
    case negatedStatement = "negated_statement"
    case question = "question"
    case musicAmbiguity = "music_ambiguity"
    case possiblyLyrics = "possibly_lyrics"
    case lowRecognitionQuality = "low_recognition_quality"
    case summaryAdded = "summary_added"
    case meaningChanged = "meaning_changed"
    case negationChanged = "negation_changed"
    case detailChanged = "detail_changed"
    case cosmeticRevision = "cosmetic_revision"
    // Fusion
    case temporalFusion = "temporal_fusion"
    case mergedIntoEpisode = "merged_into_episode"
    // Endings
    case sourceEnded = "source_ended"
    case sourceStale = "source_stale"
    case presentationTimeout = "presentation_timeout"
    case sessionEnded = "session_ended"
    case speechDataCleared = "speech_data_cleared"
    case capacityEvicted = "capacity_evicted"
    // Attention goals (Window 6)
    /// What was said matters for one of the user's own goals (decided by the semantic engine).
    case goalMatch = "goal_match"
    /// The same statement was presented for a goal a short while ago.
    case repeatedStatement = "repeated_statement"
}

/// Lifecycle of an attention episode.
///
/// ```
/// active ─▶ updated ─▶ resolved ─▶ expired
///    │         ▲  │        │
///    │         └──┘        └─▶ updated   (the same source resumes shortly after it ended)
///    └──────────────────────▶ expired    (presentation timed out, or never presented)
/// ```
public enum AttentionLifecycle: String, Hashable, Sendable, Codable {
    /// Created; its sources are still being observed.
    case active
    /// Active, and changed since it was created (new source, new summary, new priority).
    case updated
    /// Every source ended. May still be shown briefly and can resume.
    case resolved
    /// Final. No further updates for this id.
    case expired

    public var isFinal: Bool { self == .expired }
}

/// One source event behind an episode. Sources are kept with their own timestamps: an episode
/// groups events that were close in time, it does not claim that one caused the other.
public struct AttentionSourceRecord: Hashable, Sendable, Codable {
    public enum Source: Hashable, Sendable, Codable {
        case sound(id: AcousticEventID, kindID: String)
        case speech(id: SpeechEventID)
    }

    public var source: Source
    public var firstObserved: Date
    public var lastObserved: Date
    /// Nil while the source is still being observed.
    public var ended: Date?

    public init(source: Source, firstObserved: Date, lastObserved: Date, ended: Date? = nil) {
        self.source = source
        self.firstObserved = firstObserved
        self.lastObserved = lastObserved
        self.ended = ended
    }

    public var isActive: Bool { ended == nil }

    public var isSpeech: Bool {
        if case .speech = source { return true }
        return false
    }
}

/// Text derived from what people said. Sensitive: in memory only, never encoded (`AttentionEvent`
/// and `AttentionPresentationIntent` leave it out of their `Codable` form), never written to diagnostics,
/// and not for the lock screen unless the user opts in.
public struct AttentionPrivateContent: Hashable, Sendable {
    /// The validated summary headline, unchanged (negation and wording as the pipeline produced it).
    public var text: String
    /// `SpeechSemanticResult.summaryRevision` this text came from.
    public var summaryRevision: Int
    public var isNegated: Bool
    public var isQuestion: Bool

    public init(text: String, summaryRevision: Int, isNegated: Bool, isQuestion: Bool) {
        self.text = text
        self.summaryRevision = summaryRevision
        self.isNegated = isNegated
        self.isQuestion = isQuestion
    }
}

/// What the attention engine currently knows about one episode: one sound, one stretch of
/// speech, or a few events close in time.
public struct AttentionEvent: Identifiable, Hashable, Sendable, Codable {
    public let id: AttentionEventID
    /// Increases whenever a published property changes.
    public var revision: Int
    public var category: AttentionCategory
    /// `SoundEventKind.id` of the leading sound; nil when the episode is led by speech.
    public var kindID: String?
    /// Short and generic ("Horn", "Nearby Speech"). Never contains words that were spoken, so it
    /// may appear on the lock screen.
    public var title: String
    /// Generic context ("Nearby speech afterwards", "Repeated 3 times"). Lock-screen safe.
    public var subtitle: String?
    public var symbolName: String
    public var priority: AttentionPriority
    public var lifecycle: AttentionLifecycle
    public var createdAt: Date
    public var updatedAt: Date
    /// When the presentation should end at the latest; nil while not presented.
    public var expiresAt: Date?
    /// True while the scheduler wants this episode shown.
    public var isPresented: Bool
    /// The classification or the interpretation is uncertain (weak evidence, speech over music,
    /// a summary with warnings). Presentation should not word it as a fact.
    public var isUncertain: Bool
    /// Source events with their own timestamps, oldest first (bounded).
    public var sources: [AttentionSourceRecord]
    /// Reason codes of the latest priority assessment and decision.
    public var reasons: [AttentionReason]
    /// How many separate occurrences of the leading sound this episode holds.
    public var occurrences: Int
    /// Speech-derived text. Not encoded.
    public var privateContent: AttentionPrivateContent? = nil

    private enum CodingKeys: String, CodingKey {
        case id, revision, category, kindID, title, subtitle, symbolName, priority, lifecycle, createdAt, updatedAt
        case expiresAt, isPresented, isUncertain, sources, reasons, occurrences
    }

    public init(id: AttentionEventID, revision: Int = 1, category: AttentionCategory, kindID: String?, title: String,
                subtitle: String? = nil, symbolName: String, priority: AttentionPriority,
                lifecycle: AttentionLifecycle = .active, createdAt: Date, updatedAt: Date, expiresAt: Date? = nil,
                isPresented: Bool = false, isUncertain: Bool = false, sources: [AttentionSourceRecord] = [],
                reasons: [AttentionReason] = [], occurrences: Int = 1, privateContent: AttentionPrivateContent? = nil)
    {
        self.id = id
        self.revision = revision
        self.category = category
        self.kindID = kindID
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.priority = priority
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.isPresented = isPresented
        self.isUncertain = isUncertain
        self.sources = sources
        self.reasons = reasons
        self.occurrences = occurrences
        self.privateContent = privateContent
    }

    /// The episode groups a sound and speech that were close in time.
    public var isFused: Bool {
        sources.contains { $0.isSpeech } && sources.contains { !$0.isSpeech }
    }
}

/// What presentation should do with an episode.
public enum PresentationAction: String, Hashable, Sendable, Codable {
    /// Show a new episode.
    case present
    /// Replace the content of an episode that is already shown.
    case update
    /// Remove the episode at `AttentionPresentationIntent.expiresAt` (it may be updated before then).
    case dismiss
}

/// How strongly a presentation change may ask for the user's attention. A suggestion derived
/// from the priority; Window 5 maps it to what the platform allows.
public enum PresentationInterruption: String, Hashable, Sendable, Codable {
    /// Change the content quietly (no sound, no haptic, no expansion).
    case none
    case passive
    case active
    case timeSensitive
}

/// A structured instruction for Window 5 (the "PresentationIntent" of the Window 4 brief; named
/// with a prefix because Foundation already has a `PresentationIntent` for attributed strings).
/// The engine emits one whenever something that is shown (or should now be shown) changes; it
/// performs no presentation itself.
public struct AttentionPresentationIntent: Identifiable, Hashable, Sendable, Codable {
    public var id: AttentionEventID
    public var revision: Int
    public var action: PresentationAction
    public var interruption: PresentationInterruption
    public var priority: AttentionPriority
    public var category: AttentionCategory
    /// Lock-screen safe (see `AttentionEvent.title`).
    public var title: String
    /// Lock-screen safe.
    public var subtitle: String?
    public var symbolName: String
    public var timestamp: Date
    public var expiresAt: Date?
    public var isUncertain: Bool
    public var reasons: [AttentionReason]
    /// True when `privateDetail` holds speech-derived text.
    public var hasPrivateDetail: Bool
    /// Speech-derived text for display inside the app (or elsewhere only with the user's opt-in).
    /// Not encoded.
    public var privateDetail: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, revision, action, interruption, priority, category, title, subtitle, symbolName, timestamp
        case expiresAt, isUncertain, reasons, hasPrivateDetail
    }

    public init(event: AttentionEvent, action: PresentationAction, interruption: PresentationInterruption,
                timestamp: Date, expiresAt: Date?, reasons: [AttentionReason])
    {
        id = event.id
        revision = event.revision
        self.action = action
        self.interruption = interruption
        priority = event.priority
        category = event.category
        title = event.title
        subtitle = event.subtitle
        symbolName = event.symbolName
        self.timestamp = timestamp
        self.expiresAt = expiresAt
        isUncertain = event.isUncertain
        self.reasons = reasons
        hasPrivateDetail = event.privateContent != nil
        privateDetail = event.privateContent?.text
    }
}
