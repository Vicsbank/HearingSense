import Foundation

/// A classifier's machine-readable label, preserved exactly as the model reports it
/// (for Apple's built-in classifier e.g. `dog_bark`, `car_horn`, `speech`).
///
/// Never rename or translate labels in this type; user-facing names live in the taxonomy
/// (`SoundTaxonomy` in SoundEventDetection) and in `SoundEventKind.displayName`.
public struct SoundLabel: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public var description: String { rawValue }
    public static func < (lhs: SoundLabel, rhs: SoundLabel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// `dog_bark` → `Dog bark`. Fallback only; curated names take precedence.
    public var generatedDisplayName: String {
        let words = rawValue.split(separator: "_").map(String.init)
        guard let first = words.first else { return rawValue }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

/// Identifies the model that produced a prediction, so stored metadata stays interpretable if
/// the classifier changes (Apple's `SNClassifierIdentifier.version1` today).
public struct SoundModelID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let appleSoundClassifierV1 = SoundModelID(rawValue: "apple.SoundAnalysis.version1")
    public var description: String { rawValue }
}

/// A classifier output score in 0...1.
///
/// Apple documents the value as a confidence "normalized to [0, 1]". It is **not** a calibrated
/// probability: a score of 0.9 does not mean the label is correct 90 % of the time, and the
/// built-in classifier is multi-label (scores of different labels do not sum to 1).
public struct ClassifierScore: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Double

    /// Clamps to 0...1; NaN becomes 0.
    public init(rawValue: Double) {
        self.rawValue = rawValue.isNaN ? 0 : min(max(rawValue, 0), 1)
    }

    public init(_ value: Double) { self.init(rawValue: value) }

    public static let zero = ClassifierScore(0)
    public static func < (lhs: ClassifierScore, rhs: ClassifierScore) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue.formatted(.number.precision(.fractionLength(2))) }
}

/// A span on the listening session's **audio clock**: seconds of captured audio since the
/// session started (frame position / sample rate). It is not wall-clock time: while capture is
/// stopped (e.g. during an engine restart) the audio clock does not advance. Frames that the
/// pipeline drops under backlog still advance it, so timestamps stay aligned with the input.
public struct AudioTimeRange: Hashable, Sendable, Codable, CustomStringConvertible {
    public var start: TimeInterval
    public var duration: TimeInterval

    public init(start: TimeInterval, duration: TimeInterval) {
        self.start = start
        self.duration = max(duration, 0)
    }

    public init(start: TimeInterval, end: TimeInterval) {
        self.init(start: start, duration: end - start)
    }

    public var end: TimeInterval { start + duration }

    public var description: String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        return "\(start.formatted(style))–\(end.formatted(style)) s"
    }
}
