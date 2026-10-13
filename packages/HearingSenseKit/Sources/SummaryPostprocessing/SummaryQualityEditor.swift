import Foundation

/// Conservative cleanup that cannot change what a recap says. It only deletes: the narration
/// around a fact, a word said twice in a row, a sentence that says nothing, an unfinished
/// fragment, and a statement whose every word and value is already in an earlier one. It never
/// adds or replaces a word (the first letter of a de-narrated sentence is capitalized).
public enum SummaryQualityEditor {
    // MARK: Narration and stutters (ported from `RecapText.tidied`, Window 8)

    /// A statement without the two habits that make a recap read like a transcript:
    ///
    /// - narration: "Someone said that the lot reopens on Friday." → "The lot reopens on Friday."
    ///   Only openers that name no one ("someone", "a person", "the speaker", "they"); "Maya said"
    ///   and "It was announced that" stay. Not when fewer than three words would remain.
    /// - a word said twice in a row: "tomorrow, tomorrow, they meet" → "tomorrow, they meet".
    ///   Never numbers ("five five" can be part of a phone number), and without a comma only
    ///   ordinary lower-case words of four letters or more ("Walla Walla" and "had had" stay).
    public static func tidied(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.range(of: narrationOpener, options: [.regularExpression, .caseInsensitive]), match.lowerBound == text.startIndex {
            let rest = text[match.upperBound...]
            if rest.split(separator: " ").count >= 3, let first = rest.first {
                // "Someone said X and that Y" → "X and Y".
                text = (first.uppercased() + rest.dropFirst()).replacingOccurrences(of: " and that ", with: " and ")
            }
        }
        for _ in 0 ..< 4 {
            var changed = false
            for (pattern, minimum) in [(#"\b([A-Za-z']+),\s+\1\b"#, 2), (#"\b([a-z']+)\s+\1\b"#, 4)] {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: pattern.contains("A-Z") ? [.caseInsensitive] : [])
                else { continue }
                let whole = NSRange(text.startIndex..., in: text)
                for match in expression.matches(in: text, range: whole).reversed() {
                    guard let range = Range(match.range, in: text), let wordRange = Range(match.range(at: 1), in: text) else { continue }
                    let word = String(text[wordRange])
                    let lowered = word.lowercased()
                    guard word.count >= minimum, !isNumberWord(lowered), lowered != "one", !keptDoubles.contains(lowered) else { continue }
                    text.replaceSubrange(range, with: word)
                    changed = true
                }
            }
            if !changed { break }
        }
        return text
    }

    private static let narrationOpener =
        #"^(someone|somebody|a person|one person|a speaker|one speaker|the speakers?|one of the speakers|they)\s+(also\s+)?"#
        + #"(said|says|mentioned|mentions|stated|states|noted|added|explained)\s+(that\s+)?"#

    /// Words that are doubled on purpose.
    private static let keptDoubles: Set<String> = ["that", "very", "really", "much", "many", "long", "more", "knock", "bye"]

    private static func isNumberWord(_ word: String) -> Bool {
        EnglishNormalizer.units[word] != nil || EnglishNormalizer.teens[word] != nil || EnglishNormalizer.tensWords[word] != nil
            || word == "hundred" || word == "thousand" || word == "oh"
    }

    // MARK: Filler and fragments

    /// A statement that says nothing about what was said: no value, no name, and every other word
    /// is a stop word or a word about talking ("A few announcements were made.", "They agreed to
    /// do this after this.").
    public static func isFiller(_ statement: AnalyzedText) -> Bool {
        guard statement.values.isEmpty else { return false }
        let words = statement.tokens.filter { $0.kind == .word }
        guard !words.isEmpty else { return true }
        let speechCommentary: Set<String> = ["transcript", "conversation", "mentioned", "provided", "stated", "given"]
        let commentaryVocabulary: Set<String> = [
            "specific", "detail", "details", "name", "names", "time", "times", "date", "dates", "task", "tasks",
            "information", "additional", "provided", "mentioned", "stated", "given", "transcript", "conversation",
            "remain", "remains", "unchanged", "confirmed", "confirmation", "plan", "plans", "modification", "modifications",
            "change", "changes", "addition", "additions", "no", "nothing", "none",
        ]
        if words.contains(where: { speechCommentary.contains($0.text) }),
           words.allSatisfy({ Lexicon.stopWords.contains($0.text) || commentaryVocabulary.contains($0.text) }) {
            return true
        }
        for token in words {
            if token.isCapitalized, !token.startsSentence, !Lexicon.stopWords.contains(token.text) { return false }
            if Lexicon.stopWords.contains(token.text) { continue }
            let stem = Lexicon.stem(token.text)
            if !Lexicon.fillerVocabulary.contains(token.text), !Lexicon.fillerVocabulary.contains(stem) { return false }
        }
        return true
    }

    /// An unfinished statement: fewer than two words, or one that stops on a word that cannot
    /// end a sentence ("The meeting is on the", "Bring the forms and").
    public static func isIncompleteFragment(_ statement: String) -> Bool {
        let words = SummaryText.words(in: statement)
        guard words.count >= 2, let last = words.last else { return true }
        return danglingEnds.contains(last)
    }

    private static let danglingEnds: Set<String> = ["and", "or", "but", "the", "a", "an", "of", "is", "are", "was", "were", "will", "would", "which", "whose", "because", "than"]

    // MARK: Duplicates

    /// What a statement claims, for duplicate tests: its content stems and relation words, its
    /// values, whether it denies something, and its length.
    public struct Signature: Hashable, Sendable {
        public let stems: Set<String>
        public let values: [NormalizedValue]
        public let isNegative: Bool
        public let wordCount: Int
    }

    static let relationWords: Set<String> = [
        "like", "likes", "liked", "love", "loves", "loved", "want", "wants", "wanted", "must", "should", "can", "could",
        "will", "may", "might", "before", "after", "until", "till", "only", "every", "each", "all", "both", "either", "or",
        "more", "less", "most", "least", "earlier", "later",
    ]

    public static func signature(of statement: AnalyzedText) -> Signature {
        var stems = statement.contentStemSet
        for token in statement.tokens where token.kind == .word && relationWords.contains(token.text) {
            stems.insert("~" + token.text)
        }
        let words = statement.tokens.filter { $0.kind == .word }.map(\.text)
        let negative = words.contains { Lexicon.negators.contains($0) } || words.contains { Lexicon.isNegativeImplying($0) }
        return Signature(stems: stems, values: statement.values, isNegative: negative, wordCount: SummaryText.words(in: statement.text).count)
    }

    /// `statement` adds nothing to `other`: every content word, relation word and value of it is
    /// in `other`, and both affirm or both deny.
    public static func isCovered(_ statement: Signature, by other: Signature) -> Bool {
        guard !statement.stems.isEmpty || !statement.values.isEmpty else { return false }
        guard statement.isNegative == other.isNegative else { return false }
        guard statement.values.allSatisfy({ value in other.values.contains { $0.isCompatible(with: value) } }) else { return false }
        return statement.stems.isSubset(of: other.stems)
    }
}
