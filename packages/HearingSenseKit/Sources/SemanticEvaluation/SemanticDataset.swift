import Foundation
import SemanticAttention

/// The labelled, synthetic utterances used to evaluate semantic attention (Window 6).
///
/// Two files with separate roles: the development set, on which prompts and thresholds may be
/// tuned, and the held-out set, which is only run to report. Every utterance was written for
/// this project; none is a real conversation.
public struct SemanticDataset: Sendable {
    public enum Split: String, Sendable, CaseIterable {
        /// Window 6: the first development set and the held-out set that has since been read
        /// (a historical benchmark). Window 6.1: a second development set and a sealed set.
        /// Window 6.2: a third development set and a second sealed set by another author.
        /// Window 6.3: a fourth development set and a third sealed set by another author, both
        /// about whether a sentence applies to the listener.
        case dev, heldout, dev2, sealed, dev3, sealed2, dev4, sealed3

        /// Report only: run once with a frozen configuration, never as a subset.
        public var isSealed: Bool { self == .sealed || self == .sealed2 || self == .sealed3 }

        var resource: String {
            switch self {
            case .dev: "semantic_dev"
            case .heldout: "semantic_heldout"
            case .dev2: "semantic_dev2"
            case .sealed: "semantic_sealed"
            case .dev3: "semantic_dev3"
            case .sealed2: "semantic_sealed2"
            case .dev4: "semantic_dev4"
            case .sealed3: "semantic_sealed3"
            }
        }
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
        /// A short instruction to act now.
        public var isUrgent = false
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
        // Window 6.1, development set 2.
        "student2": [
            ("grades", "Notify me about anything that could affect my grades."),
            ("schedule", "Tell me if my class schedule or a room changes."),
            ("attention", "Tell me if someone is talking to me or wants my attention."),
            ("danger", "Warn me if someone says something dangerous is happening near me."),
        ],
        "office": [
            ("project", "Tell me about changes to my project's deadlines or meetings."),
            ("tasks", "Let me know when someone asks me to do something."),
            ("danger", "Warn me about anything dangerous happening nearby."),
        ],
        "home": [
            ("kids", "Tell me about anything that changes when or where I pick up my kids."),
            ("door", "Let me know if someone is at the door or a delivery arrives."),
            ("danger", "Warn me about anything dangerous happening nearby."),
        ],
        // Window 6.1, sealed set. Three of the four profiles use goals that occur nowhere else.
        "pupil": [
            ("grades", "Notify me about anything that could affect my grades."),
            ("attention", "Tell me if someone is talking to me or wants my attention."),
            ("danger", "Warn me if someone says something dangerous is happening near me."),
        ],
        "commuter": [
            ("transit", "Tell me about anything that changes my train or bus ride."),
            ("danger", "Warn me if I need to move or get out of the way."),
            ("attention", "Let me know if a stranger is speaking to me."),
        ],
        "clinic": [
            ("turn", "Tell me when it is my turn or my appointment changes."),
            ("medicine", "Let me know about anything that changes how I should take my medicine."),
            ("danger", "Warn me about anything dangerous happening nearby."),
        ],
        "shop": [
            ("customers", "Tell me when a customer needs me or an order is ready to hand out."),
            ("hours", "Tell me about anything that changes my hours or my pay."),
            ("attention", "Notify me if someone is trying to get my attention."),
        ],
    ]

    /// Profiles that a dataset file defines itself (`@profile | name | key | goal text`), so a
    /// set written by another author needs no change here.
    static let fileProfiles: [String: [(key: String, text: String)]] = {
        var found: [String: [(key: String, text: String)]] = [:]
        for split in Split.allCases {
            guard let url = Bundle.module.url(forResource: split.resource, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("@profile") {
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard fields.count == 4 else { continue }
                found[fields[1], default: []].append((fields[2], fields[3]))
            }
        }
        return found
    }()

    /// What the listener of a profile wrote about themselves (`@about | name | text`), if anything.
    static let fileAbouts: [String: String] = {
        var found: [String: String] = [:]
        for split in Split.allCases {
            guard let url = Bundle.module.url(forResource: split.resource, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("@about") {
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard fields.count == 3 else { continue }
                found[fields[1]] = fields[2]
            }
        }
        return found
    }()

    /// The optional "about me" line of a profile; empty when the listener wrote none.
    public static func about(for profile: String) -> String { fileAbouts[profile] ?? "" }

    /// Stable goal identifiers, so a run is reproducible.
    public static func goals(for profile: String) -> [(key: String, goal: AttentionGoal)] {
        (profiles[profile] ?? fileProfiles[profile] ?? []).enumerated().map { index, entry in
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

    /// The sealed set without the items whose sentence also occurs, word for word, in a set
    /// that was used for tuning (Window 6.2: the second sealed set has another author, and one
    /// of its everyday sentences is also in the first development set). Returns the set and
    /// the identifiers that were left out, so that a report can account for them.
    public func independent(of tuning: [Split] = [.dev, .dev2, .dev3, .dev4, .heldout, .sealed, .sealed2]) throws
        -> (dataset: SemanticDataset, excluded: [String])
    {
        let seen = Set(try tuning.filter { $0 != split }.flatMap { try SemanticDataset.load($0).items }.map { $0.text.lowercased() })
        var result = self
        result.items = items.filter { !seen.contains($0.text.lowercased()) }
        return (result, items.filter { seen.contains($0.text.lowercased()) }.map(\.id))
    }

    static func parse(_ text: String, split: Split) throws -> SemanticDataset {
        var items: [Item] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.hasPrefix("@") {
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
                } else if flag == "urgent" {
                    item.isUrgent = true
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
