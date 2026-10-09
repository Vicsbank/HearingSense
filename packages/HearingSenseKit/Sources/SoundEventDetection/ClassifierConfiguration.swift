import Foundation

/// Settings for Apple's streaming sound classifier.
public struct ClassifierConfiguration: Hashable, Sendable {
    /// Analysis window length. Apple's version-1 classifier accepts 0.5–15 s (default 3 s);
    /// unsupported values are rounded by the framework.
    public var windowDuration: TimeInterval
    /// Fraction of each window shared with the next (0 ≤ x < 1). Results arrive every
    /// `windowDuration × (1 − overlapFactor)` seconds of audio.
    public var overlapFactor: Double
    /// Labels below this score are dropped from frames (they never reach any detector rule,
    /// whose lowest threshold is far higher). Keeps frames small.
    public var reportingFloor: Double
    /// At most this many labels per frame, highest scores first.
    public var maxPredictionsPerFrame: Int
    /// Buffers waiting for the analysis queue before new ones are dropped (and counted) instead
    /// of growing memory and latency without bound. nil = never drop (offline evaluation).
    public var backlogLimit: Int?

    public init(windowDuration: TimeInterval, overlapFactor: Double, reportingFloor: Double = 0.05,
                maxPredictionsPerFrame: Int = 10, backlogLimit: Int? = 50)
    {
        self.windowDuration = windowDuration
        self.overlapFactor = overlapFactor
        self.reportingFloor = reportingFloor
        self.maxPredictionsPerFrame = maxPredictionsPerFrame
        self.backlogLimit = backlogLimit
    }

    /// Audio time between consecutive results.
    public var hop: TimeInterval { windowDuration * (1 - overlapFactor) }

    /// Window 2 default: 1.5 s windows, 50 % overlap → a result every 0.75 s of audio.
    /// Chosen from the offline comparison of 1.0 / 1.5 / 3.0 s windows
    /// (docs/WINDOW2_SOUND_ANALYSIS_REPORT.md §6).
    public static let standard = ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5)

    /// Window lengths offered in the debug UI.
    public static let selectableWindowDurations: [TimeInterval] = [1.0, 1.5, 3.0]
}
