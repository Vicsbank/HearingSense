import Foundation

/// Deterministic, rule-based facts about a piece of English text: negation, time expressions,
/// numbers and word stems. Used to check that a model-written headline stays faithful to the
/// transcript, and as the non-LLM fallback's source of details.
///
/// English only. The rules are heuristics (keyword lists and patterns), documented in
/// docs/research/SPEECH_INTELLIGENCE_ARCHITECTURE.md together with their known gaps.
public struct UtteranceAnalysis: Hashable, Sendable {
    /// Lowercased words, punctuation removed, inner apostrophes kept.
    public let words: [String]
    /// Negation words that remain after idioms without negative meaning were removed
    /// ("don't forget", "no problem", "can't wait").
    public let negations: [String]
    /// Normalized time expressions in order of appearance: clock times ("3 pm", "9:30") and
    /// day words ("tomorrow", "monday", "tonight").
    public let timeExpressions: [String]
    /// The subset of `timeExpressions` that names a clock time ("3 pm", "9:30", "five o'clock").
    public var clockTimes: [String] {
        timeExpressions.filter { $0.contains(where: \.isNumber) || $0.hasSuffix("o'clock") }
    }

    /// Numbers that are not part of a time expression, as written ("5", "five").
    public let numbers: [String]
    public let isQuestion: Bool

    public var isNegated: Bool { !negations.isEmpty }

    /// The statement itself is negated ("not", "n't", "never", "cannot"), as opposed to only
    /// containing "no", "nothing", "nobody" and the like.
    public var hasStatementNegation: Bool {
        negations.contains { !Self.quantifierNegations.contains($0) }
    }

    public init(_ text: String) {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        words = Self.tokenize(lowered)
        negations = Self.negationWords(in: Self.tokenize(Self.removingNeutralIdioms(from: lowered)))
        let times = Self.findTimeExpressions(in: lowered)
        timeExpressions = times.normalized
        numbers = Self.tokenize(times.remainder).filter { Self.isNumber($0) }
        isQuestion = text.contains("?") || Self.startsLikeQuestion(words)
    }

    // MARK: - Tokens

    static func tokenize(_ lowered: String) -> [String] {
        lowered.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == ":") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "':")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Negation

    static let negationWords: Set<String> = [
        "not", "no", "never", "none", "nobody", "nothing", "nowhere", "neither", "nor", "cannot", "without",
        "ain't", "can't", "couldn't", "didn't", "doesn't", "don't", "hadn't", "hasn't", "haven't", "isn't",
        "mustn't", "shouldn't", "wasn't", "weren't", "won't", "wouldn't", "aren't", "needn't", "shan't",
    ]

    /// Negation words that negate a thing or a quantity ("no milk", "nothing", "nobody") rather
    /// than the statement itself ("has not arrived", "don't open", "never").
    static let quantifierNegations: Set<String> = ["no", "none", "nobody", "nothing", "nowhere", "neither", "nor", "without"]

    /// Phrases that contain a negation word without negating the message.
    static let neutralIdioms = [
        "don't forget", "do not forget", "never forget", "not only", "why don't we", "why don't you",
        "can't wait", "cannot wait", "no problem", "no worries", "no doubt", "isn't it", "doesn't it",
        "aren't you", "don't you think", "won't you", "wouldn't it", "if not", "not bad", "no wonder",
    ]

    static func removingNeutralIdioms(from lowered: String) -> String {
        neutralIdioms.reduce(lowered) { $0.replacingOccurrences(of: $1, with: " ") }
    }

    static func negationWords(in words: [String]) -> [String] {
        words.filter { negationWords.contains($0) || $0.hasSuffix("n't") }
    }

    // MARK: - Time expressions and numbers

    static let dayWords: Set<String> = [
        "today", "tonight", "tomorrow", "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "noon", "midnight", "morning", "afternoon", "evening", "weekend",
    ]

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "half", "first",
        "second", "third",
    ]

    static func isNumber(_ word: String) -> Bool {
        numberWords.contains(word) || (word.first?.isNumber ?? false)
    }

    /// Finds clock times and day words. Returns them normalized, plus the text with clock times
    /// removed (so "3" in "3 PM" is not also counted as a plain number).
    static func findTimeExpressions(in lowered: String) -> (normalized: [String], remainder: String) {
        struct Found { var position: String.Index; var value: String }
        var found: [Found] = []
        var remainder = lowered
        // 3 pm, 3pm, 3:30 p.m., 15:30
        let clock = /\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\b\.?|p\.?m\b\.?)|\b(\d{1,2}):(\d{2})\b/
        for match in lowered.matches(of: clock) {
            let value: String
            if let hour = match.output.1, let meridiem = match.output.3 {
                let minutes = match.output.2.map { ":\($0)" } ?? ""
                value = "\(hour)\(minutes) \(meridiem.replacingOccurrences(of: ".", with: ""))"
            } else if let hour = match.output.4, let minutes = match.output.5 {
                value = "\(hour):\(minutes)"
            } else {
                continue
            }
            found.append(Found(position: match.range.lowerBound, value: value))
        }
        remainder = remainder.replacing(clock, with: " ")
        // five o'clock
        let oclock = /\b(\w+)\s+o'clock\b/
        for match in lowered.matches(of: oclock) {
            found.append(Found(position: match.range.lowerBound, value: "\(match.output.1) o'clock"))
        }
        remainder = remainder.replacing(oclock, with: " ")
        // day words
        var searchStart = lowered.startIndex
        for word in lowered.split(whereSeparator: { !$0.isLetter }) where dayWords.contains(String(word)) {
            if let range = lowered.range(of: word, range: searchStart ..< lowered.endIndex) {
                found.append(Found(position: range.lowerBound, value: String(word)))
                searchStart = range.upperBound
            }
        }
        var seen = Set<String>()
        let ordered = found.sorted { $0.position < $1.position }.map(\.value).filter { seen.insert($0).inserted }
        return (ordered, remainder)
    }

    // MARK: - Questions

    static let questionStarters: Set<String> = [
        "what", "where", "when", "who", "whose", "why", "how", "which", "is", "are", "was", "were", "do", "does",
        "did", "can", "could", "would", "will", "should", "have", "has", "may", "shall",
    ]

    static func startsLikeQuestion(_ words: [String]) -> Bool {
        let greetingsAndFillers: Set<String> = ["hey", "hi", "hello", "so", "um", "uh", "excuse", "me", "sorry", "okay", "ok"]
        guard let first = words.first(where: { !greetingsAndFillers.contains($0) }) else { return false }
        return questionStarters.contains(first)
    }

    // MARK: - Grounding

    /// Crude stem: possessive and common inflection endings removed ("arrived" → "arriv",
    /// "boxes" → "box"). Only for comparing a headline word with transcript words.
    static func stem(_ word: String) -> String {
        var stem = word
        if stem.hasSuffix("'s") { stem.removeLast(2) }
        for suffix in ["ing", "ed", "es", "ly", "s"] where stem.count - suffix.count >= 3 && stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        return stem
    }

    /// True if `word` is the same word as, or an inflection of, some word of this text.
    public func supports(_ word: String) -> Bool {
        let candidate = word.lowercased()
        let candidateStem = Self.stem(candidate)
        return words.contains { source in
            if source == candidate || Self.stem(source) == candidateStem { return true }
            // Short words and numbers must match exactly ("pm", "tv", "3").
            guard candidate.count > 3, source.count > 3, !Self.isNumber(candidate) else { return false }
            let shared = candidate.commonPrefix(with: source).count
            return shared >= 4 && shared * 2 >= max(candidate.count, source.count)
        }
    }
}
