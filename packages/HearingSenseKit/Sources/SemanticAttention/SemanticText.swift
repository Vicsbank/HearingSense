import Foundation
import NaturalLanguage

/// Which earlier statements a new one could be a repetition of (Window 6.2).
///
/// A repetition in other words ("Again, no elevator on Wednesday" after "The elevator will be
/// out of service all day Wednesday") is beyond a word count, and asking the model about every
/// pair would be slow and would let it call new information old. So two keys are needed: the
/// statements must share words and name no other number, day or time (decided here), and the
/// second look must say that it is the same news (decided by the model).
public enum SemanticRepetition {
    /// Share of the shorter statement's content words that the other one has too (by stem).
    public static func overlap(_ first: String, _ second: String) -> Double {
        let one = SemanticText.stems(in: SemanticText.withoutRepetitionMarker(first))
        let other = SemanticText.stems(in: SemanticText.withoutRepetitionMarker(second))
        let smaller = min(one.count, other.count)
        return smaller == 0 ? 0 : Double(one.intersection(other).count) / Double(smaller)
    }

    /// The earlier statements, newest first, that `text` may repeat: enough shared words, and
    /// every number, day and time of `text` was in the earlier one.
    public static func candidates(for text: String, among earlier: [String], minimumOverlap: Double = 0.4,
                                  limit: Int = 3) -> [String]
    {
        let quantities = SemanticText.quantities(in: text)
        return Array(earlier.reversed().filter {
            overlap(text, $0) >= minimumOverlap && quantities.isSubset(of: SemanticText.quantities(in: $0))
        }.prefix(limit))
    }
}

/// Small deterministic text helpers shared by the gate, the baselines and the verifier.
enum SemanticText {
    /// Lower-cased words; apostrophes inside a word are kept ("don't").
    static func words(in text: String) -> [String] {
        let normalized = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return normalized.split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    static func contentWords(in text: String) -> [String] {
        words(in: text).filter { !stopWords.contains($0) }
    }

    /// A crude stem, enough to match "grades" with "grade" and "postponed" with "postpone".
    static func stem(_ word: String) -> String {
        var stem = word
        for suffix in ["ing", "ed", "es", "s"] where stem.count > suffix.count + 2 && stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        if stem.count > 3, stem.hasSuffix("e") { stem.removeLast() }
        return stem
    }

    static func stems(in text: String) -> Set<String> { Set(contentWords(in: text).map(stem)) }

    static func isNegated(_ text: String) -> Bool {
        words(in: text).contains { negations.contains($0) || $0.hasSuffix("n't") }
    }

    /// Numbers, days and times of day: details an alert must not change.
    static func quantities(in text: String) -> Set<String> {
        Set(words(in: text).filter { quantityWords.contains($0) || $0.contains(where: \.isNumber) })
    }

    /// Share of `part`'s content words that occur in `whole` (by stem). 1 when `part` has none.
    static func coverage(of part: String, in whole: String) -> Double {
        let wanted = stems(in: part)
        guard !wanted.isEmpty else { return 1 }
        let available = Set(words(in: whole).map(stem))
        return Double(wanted.intersection(available).count) / Double(wanted.count)
    }

    /// The statement without the words that only announce a repetition ("Again, ...",
    /// "One more time, ...", "Just a reminder, ..."), so that it compares equal to the first time.
    static func withoutRepetitionMarker(_ text: String) -> String {
        let lowered = text.lowercased()
        for marker in repetitionMarkers where lowered.hasPrefix(marker) {
            let rest = text.dropFirst(marker.count).drop { !($0.isLetter || $0.isNumber) }
            if !rest.isEmpty { return String(rest) }
        }
        return text
    }

    static let repetitionMarkers = ["one more time", "once more", "once again", "again", "just a reminder", "a reminder",
                                    "as a reminder", "reminder", "as i said", "like i said", "as i mentioned", "as mentioned",
                                    "remember", "don't forget", "do not forget", "i repeat", "to repeat", "in case you missed it"]

    /// The speaker says that this is not news ("Reminder, …", "Don't forget, …", "Again, …").
    static func hasRepetitionMarker(_ text: String) -> Bool {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return repetitionMarkers.contains { lowered.hasPrefix($0) }
    }

    /// The utterance's own words as a headline: all of it when it is short, otherwise its
    /// beginning, but only if nothing that must not be lost (a "not", a number, a day, a time)
    /// lies in the part that is cut. Empty when it cannot be shortened safely.
    static func extractiveHeadline(from text: String, maximumWords: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func trimmed(_ words: [String]) -> String {
            words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:."))
        }
        guard words.count > maximumWords else { return trimmed(words) }
        let head = trimmed(Array(words.prefix(maximumWords)))
        guard isNegated(head) == isNegated(text), quantities(in: head) == quantities(in: text) else { return "" }
        return head + "…"
    }

    static func jaccard(_ first: Set<String>, _ second: Set<String>) -> Double {
        let union = first.union(second).count
        return union == 0 ? 1 : Double(first.intersection(second).count) / Double(union)
    }

    static let negations: Set<String> = ["not", "no", "never", "none", "nothing", "nobody", "cannot", "without",
                                         "neither", "nor"]

    static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "am", "has", "have", "had", "will", "would",
        "do", "does", "did", "to", "of", "in", "on", "at", "for", "and", "or", "but", "it", "its", "it's", "this", "that",
        "these", "those", "there", "here", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my",
        "your", "our", "their", "his", "please", "just", "so", "um", "uh", "s", "t", "as", "by", "with", "from", "about",
        "if", "then", "than", "can", "could", "should", "may", "might", "shall", "what", "who", "when", "where", "why",
        "how", "which", "any", "some", "all", "up", "out", "now", "very", "really", "too", "also", "get", "got", "going",
        "go", "let", "know", "tell", "anything", "something", "someone", "somebody", "anyone", "thing", "things",
    ]

    /// Words that carry no statement on their own: an utterance made only of these is not evaluated.
    static let fillers: Set<String> = [
        "yeah", "yes", "yep", "no", "nope", "ok", "okay", "right", "sure", "uh", "um", "hmm", "mm", "mhm", "huh", "oh",
        "ah", "well", "so", "like", "thanks", "thank", "you", "cool", "nice", "great", "good", "fine", "alright", "wow",
        "really", "i", "see", "know", "mean", "and", "but", "the", "a", "it", "that", "is", "it's", "that's", "true",
        "exactly", "totally", "lol", "haha", "bye", "hi", "hello",
    ]

    static let quantityWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "twenty",
        "thirty", "forty", "fifty", "hundred", "half", "twice", "double", "today", "tonight", "tomorrow", "yesterday",
        "morning", "afternoon", "evening", "noon", "midnight", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday",
    ]
}

/// Stage 1: is this utterance worth evaluating at all? Recall first: it only removes utterances
/// that cannot carry a statement (fillers, backchannel). Everything else goes on.
public struct UtteranceGate: Hashable, Sendable {
    public var maximumWords: Int

    public init(maximumWords: Int = 80) {
        self.maximumWords = maximumWords
    }

    public func admits(_ text: String) -> Bool {
        let words = SemanticText.words(in: text)
        return words.contains { !SemanticText.fillers.contains($0) }
    }

    /// Only the newest words of a very long utterance are evaluated.
    public func clipped(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count <= maximumWords ? text : words.suffix(maximumWords).joined(separator: " ")
    }

    /// Whether a short utterance may be a warning: it is then evaluated first, in a lane of its
    /// own. This decides the order only. Whether it is a warning is the model's judgement, and
    /// an utterance this does not flag is judged all the same, in its turn. (The attention
    /// engine's own phrase rule reacts to "Watch out!" at once, without this module.)
    ///
    /// Three kinds of cue, so that it does not rest on a list of alarm words alone: a word of
    /// alarm; the form of a short command ("Don't ...", "Get ...", "Stay ...", an exclamation);
    /// a phrase that describes something happening to the listener ("about to", "behind you").
    public func isLikelyUrgent(_ text: String) -> Bool {
        let words = SemanticText.words(in: text)
        guard !words.isEmpty, words.count <= 20 else { return false }
        if words.contains(where: { Self.alarmWords.contains($0) }) { return true }
        let joined = " " + words.joined(separator: " ") + " "
        if Self.hazardPhrases.contains(where: { joined.contains(" " + $0 + " ") }) { return true }
        guard words.count <= 12 else { return false }
        if Self.commandStarters.contains(words[0]) { return true }
        return words.count <= 5 && text.trimmingCharacters(in: .whitespaces).hasSuffix("!")
    }

    static let alarmWords: Set<String> = ["fire", "evacuate", "evacuation", "emergency", "danger", "dangerous", "help",
                                          "exit", "exits", "immediately", "shelter", "lockdown", "ambulance", "police",
                                          "run", "careful", "hurry", "stop", "warning", "duck", "leaking", "smoke", "gas"]

    /// First words of a short command or call.
    static let commandStarters: Set<String> = ["don't", "do", "never", "get", "stay", "move", "watch", "look", "mind",
                                               "hold", "step", "stand", "keep", "back", "out", "behind", "heads",
                                               "everybody", "everyone", "nobody", "quick", "wait", "leave"]

    /// Something is happening to the listener or right beside them.
    static let hazardPhrases = ["about to", "behind you", "above you", "on you", "toward you", "towards you", "at you",
                                "near you", "coming through", "coming loose", "coming down", "is falling", "it's falling",
                                "going to fall", "watch out", "look out", "get out", "get back", "get away", "get down",
                                "stay away", "stay back", "keep away", "out of the way", "right there", "broken glass"]
}

/// Baseline 1: a goal matches when the utterance shares a content word with it. This is what the
/// semantic engine must beat; it is never used for a decision in the app.
public struct KeywordGoalScorer: GoalSimilarityScoring {
    public let name = "keyword"

    public init() {}

    /// Words of a goal that describe the request, not its subject.
    static let requestWords: Set<String> = ["notify", "warn", "mention", "mentions", "affect", "affects", "matter",
                                            "important", "clear", "nearby", "trying", "try", "happens", "happen",
                                            "change", "changes", "related", "regarding", "concerning", "hear", "say",
                                            "says", "said", "talk", "talks", "talking"]

    public func keywords(of goal: String) -> Set<String> {
        Set(SemanticText.contentWords(in: goal).filter { !Self.requestWords.contains($0) }.map(SemanticText.stem))
    }

    public func score(utterance: String, goal: String) -> Double {
        let keywords = keywords(of: goal)
        guard !keywords.isEmpty else { return 0 }
        let present = Set(SemanticText.words(in: utterance).map(SemanticText.stem))
        return Double(keywords.intersection(present).count) / Double(keywords.count)
    }
}

/// Baseline 2 and goal ordering: cosine similarity of Apple's sentence embeddings
/// (`NLEmbedding.sentenceEmbedding`). Similar wording scores high; an indirect consequence
/// ("the exam moved" for a goal about grades) often does not, which is why this is not the
/// decision either.
public final class SentenceEmbeddingScorer: GoalSimilarityScoring, @unchecked Sendable {
    public let name = "sentence-embedding"
    private let embedding: NLEmbedding?
    private let lock = NSLock()
    private var vectors: [String: [Double]] = [:]

    public init(language: NLLanguage = .english) {
        embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    public var isAvailable: Bool { embedding != nil }

    private func vector(for text: String) -> [Double]? {
        lock.lock()
        defer { lock.unlock() }
        if let known = vectors[text] { return known }
        guard let vector = embedding?.vector(for: text) else { return nil }
        if vectors.count > 512 { vectors.removeAll() }
        vectors[text] = vector
        return vector
    }

    /// Cosine similarity mapped to 0…1 (0.5 = orthogonal).
    public func score(utterance: String, goal: String) -> Double {
        guard let first = vector(for: utterance), let second = vector(for: goal), first.count == second.count else { return 0 }
        var dot = 0.0, normFirst = 0.0, normSecond = 0.0
        for index in first.indices {
            dot += first[index] * second[index]
            normFirst += first[index] * first[index]
            normSecond += second[index] * second[index]
        }
        guard normFirst > 0, normSecond > 0 else { return 0 }
        return (dot / (normFirst.squareRoot() * normSecond.squareRoot()) + 1) / 2
    }
}
