import Foundation
import NaturalLanguage

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

    /// Short utterances with a word of alarm are evaluated before anything that is waiting. (The
    /// attention engine's own phrase rule reacts to "Watch out!" at once, without this module.)
    public func isLikelyUrgent(_ text: String) -> Bool {
        let words = SemanticText.words(in: text)
        return words.count <= 12 && words.contains { Self.alarmWords.contains($0) }
    }

    static let alarmWords: Set<String> = ["fire", "evacuate", "evacuation", "emergency", "danger", "help", "exit",
                                          "exits", "immediately", "shelter", "lockdown", "ambulance", "police", "run",
                                          "careful", "hurry", "stop", "warning"]
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
