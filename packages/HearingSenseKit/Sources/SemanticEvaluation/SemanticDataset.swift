import Foundation
import SemanticAttention

/// The labelled, synthetic utterances used to evaluate semantic attention (Window 6).
///
/// Two files with separate roles: the development set, on which prompts and thresholds may be
/// tuned, and the held-out set, which is only run to report. Every utterance was written for
/// this project; none is a real conversation.
public struct SemanticDataset: Sendable {
    public enum Split: String, Sendable, CaseIterable {
        case dev, heldout

        var resource: String { self == .dev ? "semantic_dev" : "semantic_heldout" }
    }

    public enum Expected: String, Sendable, CaseIterable {
        /// An alert is wanted.
        case relevant
        /// No alert.
        case irrelevant
        /// Either is defensible; reported separately and not scored.
        case ambiguous
        /// A repetition of an earlier item: no second alert.
        case `repeat`
    }

    public struct Item: Sendable, Identifiable {
        public var id: String
        public var profile: String
        public var category: String
        public var expected: Expected
        /// Keys of the goals a match may name.
        public var acceptableGoals: [String]
        public var isImportant: Bool
        public var repeatOf: String?
        public var context: [String]
        public var text: String
        public var why: String
    }

    public var split: Split
    public var items: [Item]

    /// The goals of each profile, in the words a user would type. `key` is used by the labels only.
    public static let profiles: [String: [(key: String, text: String)]] = [
        "student": [
            ("grades", "Tell me anything that could affect my grades."),
            ("schedule", "Let me know if somebody mentions a change to my schedule."),
            ("attention", "Notify me if someone is trying to get my attention."),
            ("class", "Tell me if there are important announcements about my class."),
            ("emergency", "Warn me about clear emergency instructions nearby."),
        ],
        "traveler": [
            ("flight", "Tell me anything about my flight to Denver or its gate."),
            ("bags", "Let me know about anything that affects my luggage or what I can carry on."),
            ("emergency", "Warn me about clear emergency instructions nearby."),
        ],
        "worker": [
            ("shift", "Tell me about anything that changes my work shift or my hours."),
            ("order", "Notify me when a customer order is ready or a customer needs help."),
            ("attention", "Notify me if someone is trying to get my attention."),
        ],
    ]

    /// Stable goal identifiers, so a run is reproducible.
    public static func goals(for profile: String) -> [(key: String, goal: AttentionGoal)] {
        (profiles[profile] ?? []).enumerated().map { index, entry in
            let seed = abs(profile.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 1_000_000 })
            let id = UUID(uuidString: String(format: "00000000-0000-4000-9000-%06d%06d", seed, index)) ?? UUID()
            return (entry.key, AttentionGoal(id: id, text: entry.text, createdAt: Date(timeIntervalSince1970: 0)))
        }
    }

    public static func load(_ split: Split) throws -> SemanticDataset {
        guard let url = Bundle.module.url(forResource: split.resource, withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try parse(String(contentsOf: url, encoding: .utf8), split: split)
    }

    static func parse(_ text: String, split: Split) throws -> SemanticDataset {
        var items: [Item] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 8, let expected = Expected(rawValue: fields[3]) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSDebugDescriptionErrorKey: "bad line: \(line.prefix(40))"])
            }
            var item = Item(id: fields[0], profile: fields[1], category: fields[2], expected: expected,
                            acceptableGoals: fields[4].split(separator: ",").map(String.init), isImportant: false,
                            repeatOf: nil, context: [], text: fields[6], why: fields[7])
            for flag in fields[5].split(separator: ",").map(String.init) {
                if flag == "important" {
                    item.isImportant = true
                } else if flag.hasPrefix("repeat_of=") {
                    item.repeatOf = String(flag.dropFirst("repeat_of=".count))
                } else if flag.hasPrefix("context=") {
                    item.context.append(String(flag.dropFirst("context=".count)))
                }
            }
            items.append(item)
        }
        return SemanticDataset(split: split, items: items)
    }
}
