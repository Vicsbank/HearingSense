import ConversationUnderstanding
import Foundation

/// Synthetic conversations with the facts a recap must contain (Window 6).
public struct ConversationDataset: Sendable {
    /// A fact, as groups of alternative words: every group needs one of its alternatives.
    public struct Fact: Sendable, Hashable {
        public var groups: [[String]]
        public var isNegation: Bool
        public var isLater: Bool
        public var text: String

        /// Matched by word stem; an alternative of several words must occur as a phrase.
        public func isPresent(in recap: String) -> Bool {
            let words = ConversationDataset.stems(recap)
            let joined = " " + words.joined(separator: " ") + " "
            return groups.allSatisfy { alternatives in
                alternatives.contains { alternative in
                    let wanted = ConversationDataset.stems(alternative)
                    return !wanted.isEmpty && joined.contains(" " + wanted.joined(separator: " ") + " ")
                }
            }
        }
    }

    public struct Scene: Sendable, Identifiable {
        public var id: String
        public var split: String
        public var description: String
        public var utterances: [(start: TimeInterval, end: TimeInterval, text: String, isLater: Bool)]
        public var missing: [(start: TimeInterval, end: TimeInterval)]
        public var facts: [Fact]

        public var hasLaterPart: Bool { utterances.contains(where: \.isLater) }
    }

    public var scenes: [Scene]

    public static let origin = Date(timeIntervalSince1970: 1_780_000_000)

    public static func load() throws -> ConversationDataset {
        guard let url = Bundle.module.url(forResource: "conversations", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    static func parse(_ text: String) throws -> ConversationDataset {
        var scenes: [Scene] = []
        var isLater = false
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            func bad() -> CocoaError {
                CocoaError(.fileReadCorruptFile, userInfo: [NSDebugDescriptionErrorKey: "bad line: \(line.prefix(40))"])
            }
            switch fields[0] {
            case "C":
                guard fields.count == 4 else { throw bad() }
                scenes.append(Scene(id: fields[1], split: fields[2], description: fields[3], utterances: [], missing: [], facts: []))
                isLater = false
            case "U":
                guard fields.count == 4, let start = Double(fields[1]), let end = Double(fields[2]), !scenes.isEmpty else { throw bad() }
                scenes[scenes.count - 1].utterances.append((start, end, fields[3], isLater))
            case "M":
                guard fields.count == 3, let start = Double(fields[1]), let end = Double(fields[2]), !scenes.isEmpty else { throw bad() }
                scenes[scenes.count - 1].missing.append((start, end))
            case "P":
                isLater = true
            case "F", "NEG":
                guard fields.count == 2, !scenes.isEmpty else { throw bad() }
                let groups = fields[1].split(separator: "+").map { $0.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) } }
                scenes[scenes.count - 1].facts.append(Fact(groups: groups, isNegation: fields[0] == "NEG", isLater: false, text: fields[1]))
            default:
                throw bad()
            }
        }
        // A fact belongs to the later part when the first part of the conversation does not support it.
        for index in scenes.indices where scenes[index].hasLaterPart {
            let first = scenes[index].utterances.filter { !$0.isLater }.map(\.text).joined(separator: " ")
            for factIndex in scenes[index].facts.indices {
                scenes[index].facts[factIndex].isLater = !scenes[index].facts[factIndex].isPresent(in: first)
            }
        }
        return ConversationDataset(scenes: scenes)
    }

    static func stems(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == ":") }
            .map { word -> String in
                var stem = String(word)
                for suffix in ["ing", "ed", "es", "s"] where stem.count > suffix.count + 2 && stem.hasSuffix(suffix) {
                    stem.removeLast(suffix.count)
                    break
                }
                return stem
            }
    }
}

extension ConversationDataset.Scene {
    /// The scene as buffered utterances, as the app would hold them.
    public func buffer(includingLater: Bool, policy: ConversationBufferPolicy = .standard) -> (buffer: RollingConversationBuffer, now: Date) {
        var buffer = RollingConversationBuffer(policy: policy)
        let origin = ConversationDataset.origin
        buffer.begin(at: origin.addingTimeInterval(-60))
        let kept = utterances.filter { includingLater || !$0.isLater }
        let end = kept.map(\.end).max() ?? 0
        let now = origin.addingTimeInterval(end + 1)
        for utterance in kept {
            buffer.append(BufferedUtterance(text: utterance.text, start: origin.addingTimeInterval(utterance.start),
                                            end: origin.addingTimeInterval(utterance.end)), now: now)
        }
        for gap in missing where gap.end <= end {
            buffer.noteMissingSpeech(from: origin.addingTimeInterval(gap.start), to: origin.addingTimeInterval(gap.end), now: now)
        }
        return (buffer, now)
    }
}

/// What the recap engine did with one scene.
public struct RecapSceneResult: Sendable, Codable {
    public var id: String
    public var split: String
    public var source: String
    public var factsFound: Int
    public var factsTotal: Int
    public var negationsKept: Int
    public var negationsTotal: Int
    public var statements: Int
    /// Statements the lexical checks removed from the model's text (a number, day or name that
    /// was not said, or a sentence mostly made of other words).
    public var statementsRemoved: Int
    public var corrections: [String]
    public var mentionsMissingSpeech: Bool?
    public var seconds: Double
    public var words: Int
    /// Continued session: facts of the first part still present after the update, and facts of
    /// the later part that the update added.
    public var earlierFactsKept: Int?
    public var earlierFactsTotal: Int?
    public var laterFactsFound: Int?
    public var laterFactsTotal: Int?
    public var updateSeconds: Double?
    public var missedFacts: [String]
    /// The texts, for a manual read. Synthetic: not private.
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var updatedSummary: String?
}

public enum RecapEvaluator {
    /// Recap of the first part of each scene; for scenes with a later part, an update as well.
    public static func run(_ dataset: ConversationDataset, split: String?, summarizer: any ConversationSummarizing,
                           progress: (@Sendable (String) -> Void)? = nil) async -> [RecapSceneResult]
    {
        let engine = ConversationRecapEngine(summarizer: summarizer)
        var results: [RecapSceneResult] = []
        for scene in dataset.scenes where split == nil || scene.split == split {
            let (buffer, now) = scene.buffer(includingLater: false)
            let excerpt = buffer.excerpt(now: now)
            let recap = await engine.recap(excerpt)
            let text = recap.fullText + " " + recap.title
            let firstFacts = scene.facts.filter { !$0.isLater }
            let found = firstFacts.filter { $0.isPresent(in: text) }
            let negations = firstFacts.filter(\.isNegation)
            let transcript = engine.transcript(of: excerpt)
            // Statements counted on the model's own text are not available after the check, so
            // the engine's corrections are the removed ones; the kept ones are counted here.
            let kept = RecapSentences.count(in: recap.summary) + recap.keyPoints.count
            let removed = recap.corrections.count { $0 != "title_replaced" }
            var result = RecapSceneResult(
                id: scene.id, split: scene.split, source: recap.source.rawValue, factsFound: found.count,
                factsTotal: firstFacts.count, negationsKept: negations.count { $0.isPresent(in: text) },
                negationsTotal: negations.count, statements: kept + removed, statementsRemoved: removed,
                corrections: recap.corrections,
                mentionsMissingSpeech: scene.missing.isEmpty ? nil : recap.caveats.contains { $0.contains("could not be transcribed") },
                seconds: recap.modelSeconds, words: text.split(whereSeparator: \.isWhitespace).count,
                missedFacts: firstFacts.filter { !$0.isPresent(in: text) }.map(\.text), title: recap.title,
                summary: recap.summary, keyPoints: recap.keyPoints)
            if scene.hasLaterPart, recap.isSummary {
                let origin = ConversationDataset.origin
                let later = scene.utterances.filter(\.isLater).map {
                    BufferedUtterance(text: $0.text, start: origin.addingTimeInterval($0.start), end: origin.addingTimeInterval($0.end))
                }
                let updated = await engine.update(recap, earlierTranscript: transcript, new: later)
                let after = (updated ?? recap).fullText
                let laterFacts = scene.facts.filter(\.isLater)
                // A fact of the first part that the later part corrects may rightly change; only
                // facts the first recap had are expected to survive.
                result.earlierFactsTotal = found.count
                result.earlierFactsKept = found.count { $0.isPresent(in: after) }
                result.laterFactsTotal = laterFacts.count
                result.laterFactsFound = laterFacts.count { $0.isPresent(in: after) }
                result.updateSeconds = updated?.modelSeconds
                result.updatedSummary = updated.map { $0.summary + ($0.keyPoints.isEmpty ? "" : " • " + $0.keyPoints.joined(separator: " • ")) }
            }
            results.append(result)
            progress?(scene.id)
        }
        return results
    }

    public static func report(_ results: [RecapSceneResult]) -> String {
        func sum(_ value: (RecapSceneResult) -> Int) -> Int { results.reduce(0) { $0 + value($1) } }
        func share(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "–" : "\(part)/\(whole) (\((Double(part) / Double(whole) * 100).formatted(.number.precision(.fractionLength(0)))) %)"
        }
        let seconds = results.map(\.seconds).sorted()
        var lines = [
            "  scenes                \(results.count); summaries written \(results.count { $0.source == "languageModel" })",
            "  facts recalled        \(share(sum(\.factsFound), sum(\.factsTotal)))",
            "  negations kept        \(share(sum(\.negationsKept), sum(\.negationsTotal)))",
            "  statements removed    \(share(sum(\.statementsRemoved), sum(\.statements))) by the lexical checks",
            "  continued: earlier facts kept \(share(sum { $0.earlierFactsKept ?? 0 }, sum { $0.earlierFactsTotal ?? 0 })), "
                + "later facts added \(share(sum { $0.laterFactsFound ?? 0 }, sum { $0.laterFactsTotal ?? 0 }))",
            "  missing speech stated \(share(results.count { $0.mentionsMissingSpeech == true }, results.count { $0.mentionsMissingSpeech != nil }))",
            "  model time            median \(seconds.isEmpty ? "–" : seconds[seconds.count / 2].formatted(.number.precision(.fractionLength(1)))) s, "
                + "max \((seconds.last ?? 0).formatted(.number.precision(.fractionLength(1)))) s",
        ]
        for result in results where !result.missedFacts.isEmpty {
            lines.append("  \(result.id): missed \(result.missedFacts.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }
}

enum RecapSentences {
    static func count(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if substring?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { count += 1 }
        }
        return count
    }
}
