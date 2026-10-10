import Foundation
import HearingSenseDomain

/// Confirmation and hysteresis rule for one kind of sound.
///
/// Scores are classifier scores, not calibrated probabilities (see `ClassifierScore`); the
/// thresholds below are empirical operating points, documented with their evaluation in
/// docs/WINDOW2_SOUND_ANALYSIS_REPORT.md.
public struct ConfirmationRule: Hashable, Sendable, Codable {
    /// A window whose best score for the kind reaches this counts as a hit for a candidate.
    public var enterScore: Double
    /// An active event stays alive while windows reach this score (hysteresis: ≤ `enterScore`).
    public var sustainScore: Double
    /// Hits needed inside `confirmWithin` to confirm a candidate (k of the last windows).
    public var requiredHits: Int
    /// Look-back on the audio clock, measured between window end times, for counting hits.
    public var confirmWithin: TimeInterval
    /// A single window at or above this score confirms at once (for brief sounds). nil = never.
    public var instantConfirmScore: Double?
    /// An active event ends after this much audio without a window at `sustainScore`.
    public var endAfter: TimeInterval

    public init(enterScore: Double, sustainScore: Double, requiredHits: Int, confirmWithin: TimeInterval,
                instantConfirmScore: Double?, endAfter: TimeInterval)
    {
        precondition(sustainScore <= enterScore, "Hysteresis requires sustainScore <= enterScore")
        precondition(requiredHits >= 1)
        self.enterScore = enterScore
        self.sustainScore = sustainScore
        self.requiredHits = requiredHits
        self.confirmWithin = confirmWithin
        self.instantConfirmScore = instantConfirmScore
        self.endAfter = endAfter
    }
}

/// Competing-classification rule: a label's score is ignored in a window where another kind is
/// at least this strong, because the two are known to be confused (measured, see the report).
public struct LabelSuppression: Hashable, Sendable, Codable {
    public var label: SoundLabel
    public var competingKind: String
    public var minimumCompetingScore: Double

    public init(label: SoundLabel, competingKind: String, minimumCompetingScore: Double) {
        self.label = label
        self.competingKind = competingKind
        self.minimumCompetingScore = minimumCompetingScore
    }
}

/// All tunable detection parameters in one value, so tests and the offline evaluator use the
/// exact configuration the app uses.
public struct DetectionPolicy: Hashable, Sendable {
    public var profileRules: [TemporalProfile: ConfirmationRule]
    /// Per-kind rules (by `SoundEventKind.id`) that replace the profile rule.
    public var kindOverrides: [String: ConfirmationRule]
    public var suppressions: [LabelSuppression]
    /// Labels below this score are not shown, even as "uncertain".
    public var displayFloor: Double
    /// Windows whose mean input RMS is below this level are reported as quiet.
    public var quietThresholdDBFS: Float
    /// Minimum audio time between `.updated` publications of one event (unless the primary
    /// label or quality changes).
    public var updateInterval: TimeInterval

    public init(profileRules: [TemporalProfile: ConfirmationRule], kindOverrides: [String: ConfirmationRule],
                suppressions: [LabelSuppression] = [], displayFloor: Double, quietThresholdDBFS: Float,
                updateInterval: TimeInterval)
    {
        self.suppressions = suppressions
        precondition(TemporalProfile.allCases.allSatisfy { profileRules[$0] != nil }, "Every profile needs a rule")
        self.profileRules = profileRules
        self.kindOverrides = kindOverrides
        self.displayFloor = displayFloor
        self.quietThresholdDBFS = quietThresholdDBFS
        self.updateInterval = updateInterval
    }

    public func rule(for definition: SoundKindDefinition) -> ConfirmationRule {
        kindOverrides[definition.kind.id] ?? profileRules[definition.profile]!
    }

    /// The configuration shipped in Window 2. Provisional: derived from the offline evaluation
    /// on LibriSpeech / GTZAN / DEMAND and the first device tests, not optimized on a labeled
    /// environmental-event dataset (none is available locally).
    public static let standard = DetectionPolicy(
        profileRules: [
            .continuous: ConfirmationRule(enterScore: 0.5, sustainScore: 0.3, requiredHits: 2, confirmWithin: 2.0,
                                          instantConfirmScore: nil, endAfter: 3.0),
            .intermittent: ConfirmationRule(enterScore: 0.45, sustainScore: 0.3, requiredHits: 2, confirmWithin: 3.0,
                                            instantConfirmScore: 0.8, endAfter: 5.0),
            .transient: ConfirmationRule(enterScore: 0.4, sustainScore: 0.3, requiredHits: 2, confirmWithin: 2.0,
                                         instantConfirmScore: 0.65, endAfter: 2.0),
        ],
        kindOverrides: [
            // Warning signals: the 1 s-window probe on DEMAND street noise produced air_horn up to
            // 0.67 and emergency_vehicle 0.44 from ordinary traffic, so these need two windows
            // or a very strong single window.
            "vehicle_horn": ConfirmationRule(enterScore: 0.5, sustainScore: 0.35, requiredHits: 2, confirmWithin: 2.0,
                                             instantConfirmScore: 0.85, endAfter: 2.0),
            "siren": ConfirmationRule(enterScore: 0.5, sustainScore: 0.35, requiredHits: 2, confirmWithin: 3.0,
                                      instantConfirmScore: 0.85, endAfter: 5.0),
            "alarm": ConfirmationRule(enterScore: 0.5, sustainScore: 0.35, requiredHits: 2, confirmWithin: 3.0,
                                      instantConfirmScore: 0.85, endAfter: 5.0),
            "bang": ConfirmationRule(enterScore: 0.5, sustainScore: 0.35, requiredHits: 2, confirmWithin: 2.0,
                                     instantConfirmScore: 0.85, endAfter: 2.0),
            // Window 5 device session (iPhone, lived-in room): one `screaming` window at 0.90 among
            // laughter became a high-priority alert. Like the other warning signals it now needs
            // two windows or one very strong window. One observation; provisional.
            "screaming": ConfirmationRule(enterScore: 0.5, sustainScore: 0.35, requiredHits: 2, confirmWithin: 2.0,
                                          instantConfirmScore: 0.95, endAfter: 2.0),
            // A door moving is an ordinary sound (an icon, never an alert): no single-window
            // confirmation. On the iPhone 4 of 12 `door` events came from one window (0.66–0.91).
            "door_movement": ConfirmationRule(enterScore: 0.45, sustainScore: 0.3, requiredHits: 2, confirmWithin: 2.0,
                                              instantConfirmScore: nil, endAfter: 2.0),
        ],
        suppressions: [
            // Offline evaluation (1.5 s windows): 20 of 22 vehicle_horn events on 300 GTZAN music
            // clips were `foghorn` in classical/jazz/country (peak 0.61–0.98) — low brass and bass
            // notes. car_horn / air_horn / train_horn are not suppressed.
            LabelSuppression(label: "foghorn", competingKind: "music", minimumCompetingScore: 0.5),
        ],
        displayFloor: 0.3,
        quietThresholdDBFS: -60,
        updateInterval: 5
    )
}
