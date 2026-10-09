import Foundation

/// What the recognizer can say about the surroundings right now. These are deliberately
/// different situations; the recognizer never forces a category.
public enum EnvironmentStatus: Hashable, Sendable {
    /// Listening, but the first classifier window has not completed yet.
    case warmingUp
    /// The input level is below the quiet threshold (measured from samples), or the classifier's
    /// top label is `silence`. Not proof of perfect silence.
    case quiet
    /// Sound is present (level above the quiet threshold) but no label reached the display floor.
    case unclassified
    /// The best label is above the display floor but below its confirmation rule and nothing is
    /// confirmed: "maybe X". Shown as uncertain, never as an event.
    case uncertain(RawSoundPrediction)
    /// At least one confirmed event is active.
    case recognized([ConfirmedAcousticEvent])

    public var title: String {
        switch self {
        case .warmingUp: "Analyzing…"
        case .quiet: "Quiet"
        case .unclassified: "Sound, not recognized"
        case .uncertain: "No reliable classification"
        case .recognized: "Sound detected"
        }
    }
}
