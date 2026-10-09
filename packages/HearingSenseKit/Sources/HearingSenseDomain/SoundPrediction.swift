import Foundation

/// One label's score for one classifier analysis window, exactly as the model reported it.
/// A raw prediction is evidence, not an event; see `ConfirmedAcousticEvent`.
public struct RawSoundPrediction: Hashable, Sendable, Codable {
    /// Original classifier identifier (never renamed).
    public var label: SoundLabel
    public var score: ClassifierScore
    /// The analyzed audio span on the session audio clock.
    public var audioTime: AudioTimeRange
    /// Wall-clock time at which the classifier delivered the result.
    public var producedAt: Date
    public var model: SoundModelID

    public init(label: SoundLabel, score: ClassifierScore, audioTime: AudioTimeRange,
                producedAt: Date, model: SoundModelID)
    {
        self.label = label
        self.score = score
        self.audioTime = audioTime
        self.producedAt = producedAt
        self.model = model
    }
}

/// Signal level of the input over one analysis window, measured from the real samples.
/// Lets consumers tell "quiet" from "sound present but unclassified".
public struct WindowInputLevel: Hashable, Sendable, Codable {
    /// Mean of the per-buffer RMS levels in the window, in dBFS.
    public var rmsDBFS: Float
    /// Highest per-buffer peak in the window, in dBFS.
    public var peakDBFS: Float

    public init(rmsDBFS: Float, peakDBFS: Float) {
        self.rmsDBFS = rmsDBFS
        self.peakDBFS = peakDBFS
    }
}

/// Everything the classifier reported for one analysis window.
public struct ClassificationFrame: Hashable, Sendable, Codable {
    /// Increments per window within a listening session, starting at 0.
    public var sequence: Int
    public var audioTime: AudioTimeRange
    public var producedAt: Date
    /// Wall-clock time at which the window's last sample was captured, when known (live
    /// capture). `producedAt - capturedAt` is the classifier's result delay.
    public var capturedAt: Date?
    public var model: SoundModelID
    /// Sorted by score, highest first. Only labels at or above the pipeline's reporting floor
    /// are kept; a label's absence means "below the floor", not "score 0".
    public var predictions: [RawSoundPrediction]
    public var inputLevel: WindowInputLevel?

    public init(sequence: Int, audioTime: AudioTimeRange, producedAt: Date, capturedAt: Date?,
                model: SoundModelID, predictions: [RawSoundPrediction], inputLevel: WindowInputLevel?)
    {
        self.sequence = sequence
        self.audioTime = audioTime
        self.producedAt = producedAt
        self.capturedAt = capturedAt
        self.model = model
        self.predictions = predictions.sorted { $0.score > $1.score }
        self.inputLevel = inputLevel
    }

    public var top: RawSoundPrediction? { predictions.first }

    public func score(for label: SoundLabel) -> ClassifierScore? {
        predictions.first { $0.label == label }?.score
    }

    /// Seconds between the end of the analyzed audio and the classifier result, if known.
    public var resultDelay: TimeInterval? {
        capturedAt.map { producedAt.timeIntervalSince($0) }
    }
}
