import Foundation
import HearingSenseDomain

/// How readily the engine interrupts. A mode selects a column of the policy table and a set of
/// timings (`ModeTuning`); it does not change what is recognized.
public enum AttentionMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Fewest interruptions: warning signals and important new events only.
    case quiet
    /// Important sounds and clearly relevant speech; ambient and repetitive events stay quiet.
    case balanced
    /// More of what changes around the user, with shorter cooldowns.
    case sensitive

    public var displayName: String {
        switch self {
        case .quiet: "Quiet"
        case .balanced: "Balanced"
        case .sensitive: "Sensitive"
        }
    }

    public var summary: String {
        switch self {
        case .quiet: "Only warning signals and important new events."
        case .balanced: "Important sounds and clearly relevant speech."
        case .sensitive: "More changes around you, repeated sooner."
        }
    }
}

/// A value per attention mode.
public struct ModeValues<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    public var quiet: Value
    public var balanced: Value
    public var sensitive: Value

    public init(quiet: Value, balanced: Value, sensitive: Value) {
        self.quiet = quiet
        self.balanced = balanced
        self.sensitive = sensitive
    }

    public init(_ quiet: Value, _ balanced: Value, _ sensitive: Value) {
        self.init(quiet: quiet, balanced: balanced, sensitive: sensitive)
    }

    public init(all value: Value) {
        self.init(quiet: value, balanced: value, sensitive: value)
    }

    public subscript(mode: AttentionMode) -> Value {
        switch mode {
        case .quiet: quiet
        case .balanced: balanced
        case .sensitive: sensitive
        }
    }
}

/// The user's choice for one category.
public enum CategorySetting: String, Hashable, Sendable, Codable, CaseIterable {
    /// Follow the attention mode.
    case automatic
    /// Never present this category.
    case muted
    /// Fixed priority in every mode. `urgent` cannot be chosen: it stays a policy decision.
    case low, normal, high

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .muted: "Muted"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    var fixedPriority: AttentionPriority? {
        switch self {
        case .automatic, .muted: nil
        case .low: .low
        case .normal: .normal
        case .high: .high
        }
    }
}

/// How much nearby speech may ask for attention. Independent of the transcription switch: the
/// engine never turns transcription on, and without it speech is only ever "Nearby Speech".
public enum SpeechAttention: String, Hashable, Sendable, Codable, CaseIterable {
    /// Speech is never presented.
    case off
    /// Only speech that looks like a warning.
    case importantOnly
    /// Follow the attention mode.
    case standard
    /// Present ordinary nearby speech in every mode.
    case everything

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .importantOnly: "Important only"
        case .standard: "Automatic"
        case .everything: "All speech"
        }
    }
}

/// Everything the user can change. Stored locally as JSON by the app; contains no event data.
public struct AttentionPreferences: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var mode: AttentionMode
    /// Categories not listed follow the mode (`automatic`).
    public var categories: [AttentionCategory: CategorySetting]
    public var speech: SpeechAttention

    public init(mode: AttentionMode = .balanced, categories: [AttentionCategory: CategorySetting] = [:],
                speech: SpeechAttention = .standard)
    {
        schemaVersion = Self.currentSchemaVersion
        self.mode = mode
        self.categories = categories.filter { $0.value != .automatic }
        self.speech = speech
    }

    /// Balanced, every category automatic, speech following the mode.
    public static let `default` = AttentionPreferences()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mode, categories, speech
    }

    /// Tolerant: a missing or unknown value falls back to its default, so a stored file from
    /// another app version never blocks the engine.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = Self.currentSchemaVersion
        mode = (try? container.decodeIfPresent(AttentionMode.self, forKey: .mode)) ?? .balanced
        speech = (try? container.decodeIfPresent(SpeechAttention.self, forKey: .speech)) ?? .standard
        let stored = (try? container.decodeIfPresent([String: String].self, forKey: .categories)) ?? [:]
        var categories: [AttentionCategory: CategorySetting] = [:]
        for (key, value) in stored {
            guard let category = AttentionCategory(rawValue: key), let setting = CategorySetting(rawValue: value),
                  setting != .automatic else { continue }
            categories[category] = setting
        }
        self.categories = categories
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mode, forKey: .mode)
        try container.encode(speech, forKey: .speech)
        let stored = Dictionary(uniqueKeysWithValues: categories.map { ($0.key.rawValue, $0.value.rawValue) })
        try container.encode(stored, forKey: .categories)
    }

    public func setting(for category: AttentionCategory) -> CategorySetting {
        categories[category] ?? .automatic
    }

    public mutating func set(_ setting: CategorySetting, for category: AttentionCategory) {
        categories[category] = setting == .automatic ? nil : setting
    }

    public var isDefault: Bool { self == .default }
}
