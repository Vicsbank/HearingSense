import Foundation
import HearingSenseDomain

/// Raises an episode's priority when its sound keeps going or keeps coming back.
public struct EscalationRule: Hashable, Sendable, Codable {
    /// Raise once the sound has been observed for this long. Nil = never.
    public var afterDuration: TimeInterval?
    /// Raise once this many separate occurrences fell inside `occurrenceWindow`. Nil = never.
    public var afterOccurrences: Int?
    public var occurrenceWindow: TimeInterval
    /// Never raised above this.
    public var limit: AttentionPriority

    public init(afterDuration: TimeInterval? = nil, afterOccurrences: Int? = nil, occurrenceWindow: TimeInterval = 60,
                limit: AttentionPriority)
    {
        self.afterDuration = afterDuration
        self.afterOccurrences = afterOccurrences
        self.occurrenceWindow = occurrenceWindow
        self.limit = limit
    }
}

/// Attention policy for a group of sound kinds: one row of the policy table.
///
/// The priorities are defaults chosen by the project, documented in
/// docs/research/ATTENTION_ENGINE_ARCHITECTURE.md. They express what may deserve a glance, not a
/// measured risk.
public struct SoundAttentionProfile: Hashable, Sendable, Codable {
    public var id: String
    /// Base priority per mode, before evidence, repetition and preferences.
    public var base: ModeValues<AttentionPriority>
    /// Modes in which a `low` base is raised to `normal` once the sound is sustained and its
    /// classification is at least moderate ("Conditional" in the policy table).
    public var conditional: ModeValues<Bool>
    /// The sound's purpose is to warn, or it often accompanies danger. Such sounds are never
    /// held back by cooldowns or the presentation budget.
    public var isSafetyRelevant: Bool
    /// A known source of spurious detections; kept ambient in every mode.
    public var isMinor: Bool
    /// The same kind starting again within this time after it ended continues the same episode.
    public var rejoinWindow: TimeInterval
    /// After an episode was presented, later independent episodes of the same kind below `high`
    /// are suppressed for this long (Balanced; scaled per mode by `ModeTuning.cooldownScale`).
    public var cooldown: TimeInterval
    public var escalation: EscalationRule?

    public init(id: String, base: ModeValues<AttentionPriority>, conditional: ModeValues<Bool> = .init(all: false),
                isSafetyRelevant: Bool = false, isMinor: Bool = false, rejoinWindow: TimeInterval,
                cooldown: TimeInterval, escalation: EscalationRule? = nil)
    {
        self.id = id
        self.base = base
        self.conditional = conditional
        self.isSafetyRelevant = isSafetyRelevant
        self.isMinor = isMinor
        self.rejoinWindow = rejoinWindow
        self.cooldown = cooldown
        self.escalation = escalation
    }
}

/// Which profile and which user-facing category a sound kind belongs to.
public struct KindAssignment: Hashable, Sendable, Codable {
    public var profile: String
    public var category: AttentionCategory

    public init(profile: String, category: AttentionCategory) {
        self.profile = profile
        self.category = category
    }
}

/// Timings and limits that differ between the three modes.
public struct ModeTuning: Hashable, Sendable, Codable {
    /// Episodes below this priority are tracked but not presented.
    public var surfaceThreshold: AttentionPriority
    /// Multiplier for every cooldown.
    public var cooldownScale: Double
    /// Presentations below `high` allowed per `budgetWindow`. Further ones are deferred.
    public var presentationBudget: Int
    public var budgetWindow: TimeInterval
    /// Minimum time between content updates of one presented episode (except critical ones).
    public var minimumUpdateInterval: TimeInterval

    public init(surfaceThreshold: AttentionPriority, cooldownScale: Double, presentationBudget: Int,
                budgetWindow: TimeInterval, minimumUpdateInterval: TimeInterval)
    {
        self.surfaceThreshold = surfaceThreshold
        self.cooldownScale = cooldownScale
        self.presentationBudget = presentationBudget
        self.budgetWindow = budgetWindow
        self.minimumUpdateInterval = minimumUpdateInterval
    }
}

/// Deterministic rules for speech (`SpeechSemanticResult`). No language-model call is made here:
/// the engine uses the summary, category and details that Window 3 already produced.
public struct SpeechAttentionPolicy: Hashable, Sendable, Codable {
    /// Phrases that may signal a warning when they occur anywhere in a finalized utterance.
    public var urgentPhrases: [String]
    /// Single words that count only in a very short utterance ("Stop!", "Help!"), because they
    /// are common in ordinary sentences.
    public var urgentShortUtteranceWords: [String]
    public var shortUtteranceMaximumWords: Int
    /// Ordinary speech must have been observed this long (or have one finalized utterance) before
    /// a conditional mode presents it.
    public var sustainedAfter: TimeInterval
    /// Cooldown after ordinary speech was presented (Balanced; scaled per mode).
    public var cooldown: TimeInterval
    /// A new conversation starting within this time after the previous one ended continues the
    /// same episode.
    public var rejoinWindow: TimeInterval
    /// Two headlines whose content words overlap at least this much (Jaccard), with the same
    /// polarity and the same numbers and times, count as the same statement.
    public var sameMeaningSimilarity: Double
    /// A speech source with no update for this long is treated as ended.
    public var staleAfter: TimeInterval

    public init(urgentPhrases: [String], urgentShortUtteranceWords: [String], shortUtteranceMaximumWords: Int,
                sustainedAfter: TimeInterval, cooldown: TimeInterval, rejoinWindow: TimeInterval,
                sameMeaningSimilarity: Double, staleAfter: TimeInterval)
    {
        self.urgentPhrases = urgentPhrases
        self.urgentShortUtteranceWords = urgentShortUtteranceWords
        self.shortUtteranceMaximumWords = shortUtteranceMaximumWords
        self.sustainedAfter = sustainedAfter
        self.cooldown = cooldown
        self.rejoinWindow = rejoinWindow
        self.sameMeaningSimilarity = sameMeaningSimilarity
        self.staleAfter = staleAfter
    }

    public static let standard = SpeechAttentionPolicy(
        urgentPhrases: ["watch out", "look out", "be careful", "heads up", "get out", "get down", "get back",
                        "call 911", "call nine one one", "call an ambulance", "call the police", "emergency",
                        "danger", "evacuate"],
        urgentShortUtteranceWords: ["stop", "help", "fire", "run", "careful", "move", "hurry", "duck"],
        shortUtteranceMaximumWords: 3,
        sustainedAfter: 2.5,
        cooldown: 90,
        rejoinWindow: 8,
        sameMeaningSimilarity: 0.8,
        staleAfter: 30)
}

/// Which later event may join an episode that is already presented.
public struct FusionAffinity: Hashable, Sendable, Codable {
    /// Category of the episode that is already there.
    public var anchor: AttentionCategory
    /// Category of the event that follows it.
    public var follower: AttentionCategory

    public init(anchor: AttentionCategory, follower: AttentionCategory) {
        self.anchor = anchor
        self.follower = follower
    }
}

/// The whole policy as data, so tests, the replay tool and the app use the same configuration.
public struct AttentionConfiguration: Hashable, Sendable, Codable {
    public var profiles: [String: SoundAttentionProfile]
    /// By `SoundEventKind.id`.
    public var kinds: [String: KindAssignment]
    /// Profile for a kind the table does not list (a kind added by a later app version).
    public var fallbackProfile: String
    public var tuning: ModeValues<ModeTuning>
    public var speech: SpeechAttentionPolicy

    /// A follower joins an anchor episode when it starts at most this long after the anchor was
    /// last observed.
    public var fusionWindow: TimeInterval
    /// The follower must not have been observed more than this long before the anchor began:
    /// speech that was already going on is not attributed to a later knock.
    public var fusionOnsetTolerance: TimeInterval
    public var fusionAffinities: [FusionAffinity]

    /// Shortest time a resolved episode stays presented (longer when the profile's rejoin window is).
    public var resolveLinger: TimeInterval
    /// Longest presentation of an episode whose source keeps going, by priority (seconds).
    public var presentationLifetime: [AttentionPriority: TimeInterval]
    /// A sound source with no update for this long is treated as ended (the detector publishes at
    /// least every `DetectionPolicy.updateInterval` + `endAfter` while an event is alive).
    public var soundStaleAfter: TimeInterval
    /// A deferred presentation older than this is dropped instead of shown late.
    public var maximumDeferral: TimeInterval
    /// A deferred episode whose sources ended longer ago than this is dropped.
    public var deferredGrace: TimeInterval

    // Bounds
    public var maximumEpisodes: Int
    public var maximumSourcesPerEpisode: Int
    public var maximumOccurrencesRemembered: Int

    public func assignment(for kind: SoundEventKind) -> KindAssignment {
        kinds[kind.id] ?? KindAssignment(profile: fallbackProfile, category: Self.fallbackCategory(for: kind.category))
    }

    public func profile(for kind: SoundEventKind) -> SoundAttentionProfile {
        profiles[assignment(for: kind).profile] ?? profiles[fallbackProfile]!
    }

    public func lifetime(for priority: AttentionPriority) -> TimeInterval {
        presentationLifetime[priority] ?? 30
    }

    static func fallbackCategory(for category: SoundCategory) -> AttentionCategory {
        switch category {
        case .speech: .speech
        case .alerts: .vehicleWarnings
        case .transportation: .transportation
        case .household: .household
        case .impacts: .impacts
        case .humanActivity: .humanActivity
        case .animals: .animals
        case .music: .music
        case .weatherNature: .weather
        case .crowd: .crowd
        case .other: .other
        }
    }
}

extension AttentionConfiguration {
    /// The id of the sound kind that the speech pipeline also reports on; handled as speech.
    public static let speechKindID = "speech"

    /// The configuration shipped in Window 4. Provisional defaults: chosen from the policy table
    /// in the Window 4 brief and from what Windows 2–3 measured (which kinds fire spuriously),
    /// not tuned on field data.
    public static let standard: AttentionConfiguration = {
        typealias P = AttentionPriority
        func row(_ id: String, _ quiet: P, _ balanced: P, _ sensitive: P, conditionalIn modes: [AttentionMode] = [],
                 safety: Bool = false, minor: Bool = false, rejoin: TimeInterval, cooldown: TimeInterval,
                 escalation: EscalationRule? = nil) -> SoundAttentionProfile
        {
            SoundAttentionProfile(
                id: id, base: ModeValues(quiet, balanced, sensitive),
                conditional: ModeValues(modes.contains(.quiet), modes.contains(.balanced), modes.contains(.sensitive)),
                isSafetyRelevant: safety, isMinor: minor, rejoinWindow: rejoin, cooldown: cooldown,
                escalation: escalation)
        }
        let rows = [
            // Warning signals
            row("emergency_siren", .urgent, .urgent, .urgent, safety: true, rejoin: 15, cooldown: 0),
            row("alarm", .high, .high, .high, safety: true, rejoin: 15, cooldown: 0,
                escalation: EscalationRule(afterDuration: 20, limit: .urgent)),
            row("vehicle_horn", .high, .high, .high, safety: true, rejoin: 8, cooldown: 0),
            row("vehicle_signal", .normal, .high, .high, safety: true, rejoin: 15, cooldown: 0),
            row("bicycle_bell", .normal, .normal, .high, safety: true, rejoin: 8, cooldown: 0),
            // Impacts and distress
            row("danger_impact", .high, .high, .high, safety: true, rejoin: 8, cooldown: 0),
            row("thud", .ambient, .low, .normal, rejoin: 8, cooldown: 60),
            row("scream", .high, .high, .high, safety: true, rejoin: 10, cooldown: 0),
            row("crying", .low, .low, .normal, conditionalIn: [.balanced], rejoin: 20, cooldown: 120,
                escalation: EscalationRule(afterDuration: 30, limit: .high)),
            row("shouting", .low, .low, .normal, conditionalIn: [.balanced], rejoin: 10, cooldown: 90),
            // Someone or something asking for attention
            row("door_knock", .normal, .high, .high, rejoin: 20, cooldown: 0,
                escalation: EscalationRule(afterOccurrences: 3, occurrenceWindow: 60, limit: .high)),
            row("phone", .normal, .normal, .high, rejoin: 12, cooldown: 30,
                escalation: EscalationRule(afterDuration: 15, limit: .high)),
            row("beep", .ambient, .low, .normal, conditionalIn: [.balanced], rejoin: 10, cooldown: 60),
            // Animals
            row("dog", .ambient, .low, .normal, conditionalIn: [.balanced], rejoin: 15, cooldown: 120),
            row("animal", .ambient, .ambient, .low, rejoin: 20, cooldown: 180),
            // Surroundings
            row("music", .ambient, .ambient, .ambient, rejoin: 60, cooldown: 0),
            row("chime", .ambient, .ambient, .low, rejoin: 20, cooldown: 180),
            row("weather", .ambient, .ambient, .low, rejoin: 60, cooldown: 600),
            row("thunder", .ambient, .low, .normal, conditionalIn: [.balanced], rejoin: 30, cooldown: 180),
            row("fire", .ambient, .low, .normal, conditionalIn: [.balanced], rejoin: 30, cooldown: 300),
            row("transport", .ambient, .ambient, .low, rejoin: 30, cooldown: 300),
            row("household", .ambient, .ambient, .low, rejoin: 30, cooldown: 300),
            row("human_activity", .ambient, .ambient, .low, rejoin: 20, cooldown: 180),
            row("crowd", .ambient, .ambient, .low, rejoin: 30, cooldown: 300),
            // Kinds that Window 2 saw firing on clean speech or on handling noise.
            row("minor", .ambient, .ambient, .ambient, minor: true, rejoin: 10, cooldown: 0),
        ]
        func assign(_ profile: String, _ category: AttentionCategory, _ kinds: [String]) -> [(String, KindAssignment)] {
            kinds.map { ($0, KindAssignment(profile: profile, category: category)) }
        }
        let assignments: [(String, KindAssignment)] =
            assign("emergency_siren", .emergencySignals, ["siren"])
            + assign("alarm", .emergencySignals, ["alarm"])
            + assign("vehicle_horn", .vehicleWarnings, ["vehicle_horn"])
            + assign("vehicle_signal", .vehicleWarnings, ["reverse_beeps"])
            + assign("bicycle_bell", .vehicleWarnings, ["bicycle_bell"])
            + assign("danger_impact", .impacts, ["glass_breaking", "bang"])
            + assign("thud", .impacts, ["impact"])
            + assign("scream", .distressSounds, ["screaming"])
            + assign("crying", .distressSounds, ["crying"])
            + assign("shouting", .distressSounds, ["shouting"])
            + assign("door_knock", .doorAndKnock, ["door"])
            + assign("phone", .deviceSignals, ["phone"])
            + assign("beep", .deviceSignals, ["beep"])
            + assign("dog", .animals, ["dog"])
            + assign("animal", .animals, ["cat", "bird", "farm_animal", "wild_animal"])
            + assign("minor", .animals, ["insect"])
            + assign("music", .music, ["music"])
            + assign("chime", .other, ["bell"])
            + assign("weather", .weather, ["wind", "rain", "water_body"])
            + assign("thunder", .weather, ["thunder"])
            + assign("fire", .weather, ["fire"])
            + assign("transport", .transportation, ["road_vehicle", "rail", "aircraft", "boat", "bicycle_skateboard"])
            + assign("household", .household, ["kitchen", "water_use", "appliance", "tools", "door_movement"])
            + assign("minor", .household, ["typing_writing", "clock", "small_objects"])
            + assign("human_activity", .humanActivity, ["laughter", "footsteps", "hands", "whistling", "sports"])
            + assign("minor", .humanActivity, ["body_sounds"])
            + assign("crowd", .crowd, ["crowd"])
            + assign("minor", .other, ["mic_wind_noise", "whoosh", "unmapped"])
            // Speech is assessed from SpeechSemanticResult; the row is only a fallback.
            + assign("minor", .speech, [speechKindID])
        return AttentionConfiguration(
            profiles: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }),
            kinds: Dictionary(uniqueKeysWithValues: assignments),
            fallbackProfile: "minor",
            tuning: ModeValues(
                quiet: ModeTuning(surfaceThreshold: .normal, cooldownScale: 2.0, presentationBudget: 2,
                                  budgetWindow: 60, minimumUpdateInterval: 15),
                balanced: ModeTuning(surfaceThreshold: .normal, cooldownScale: 1.0, presentationBudget: 4,
                                     budgetWindow: 60, minimumUpdateInterval: 8),
                sensitive: ModeTuning(surfaceThreshold: .low, cooldownScale: 0.5, presentationBudget: 8,
                                      budgetWindow: 60, minimumUpdateInterval: 4)),
            speech: .standard,
            fusionWindow: 8,
            fusionOnsetTolerance: 1,
            fusionAffinities: [FusionAffinity(anchor: .doorAndKnock, follower: .speech),
                               FusionAffinity(anchor: .deviceSignals, follower: .speech)],
            resolveLinger: 4,
            presentationLifetime: [.low: 20, .normal: 30, .high: 45, .urgent: 60],
            soundStaleAfter: 20,
            maximumDeferral: 15,
            deferredGrace: 3,
            maximumEpisodes: 48,
            maximumSourcesPerEpisode: 8,
            maximumOccurrencesRemembered: 8)
    }()
}
