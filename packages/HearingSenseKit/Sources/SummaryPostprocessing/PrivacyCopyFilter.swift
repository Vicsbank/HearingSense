import Foundation

/// Keeps a saved summary from becoming a saved transcript. Only about copying: whether a
/// statement is true is the grounder's question, and a short true sentence is never removed
/// here merely because it matches what was said.
///
/// The rule is the one approved in Windows 7 and 8, unchanged:
/// - a statement of at least `copiedMinimumWords` words that is, word for word, a whole spoken
///   sentence or utterance is a copy;
/// - a copy of at most `keptCopyMaximumWords` words may stay as it was said, at most
///   `maximumKeptCopies` of them per recap (each sentence once), never two next to each other;
/// - every other copy is restated by the model (in memory) or left out;
/// - the whole text may repeat the transcript word for word up to `maximumVerbatimShare`.
public struct PrivacyCopyFilter: Hashable, Sendable {
    public var configuration: PostprocessingConfiguration

    public init(configuration: PostprocessingConfiguration = .standard) {
        self.configuration = configuration
    }

    /// Every utterance and every sentence of one, as words.
    public static func spokenSentences(lines: [String]) -> Set<[String]> {
        var spoken: Set<[String]> = []
        for line in lines.flatMap({ $0.split(whereSeparator: \.isNewline).map(String.init) }) {
            spoken.insert(SummaryText.words(in: line))
            for sentence in SummaryText.sentences(in: line) { spoken.insert(SummaryText.words(in: sentence)) }
        }
        return spoken
    }

    /// Every run of `run` consecutive words of one utterance.
    public static func spokenRuns(lines: [String], run: Int) -> Set<[String]> {
        var runs: Set<[String]> = []
        for line in lines.flatMap({ $0.split(whereSeparator: \.isNewline).map(String.init) }) {
            let words = SummaryText.words(in: line)
            guard words.count >= run else { continue }
            for start in 0 ... (words.count - run) { runs.insert(Array(words[start ..< start + run])) }
        }
        return runs
    }

    /// The statement is, word for word, a whole spoken sentence or utterance.
    public func isCopy(_ statement: String, spoken: Set<[String]>) -> Bool {
        let words = SummaryText.words(in: statement)
        return words.count >= configuration.copiedMinimumWords && spoken.contains(words)
    }

    /// A copy short enough to be kept as it was said (before the count and adjacency limits).
    public func isShortCopy(_ statement: String) -> Bool {
        SummaryText.words(in: statement).count <= configuration.keptCopyMaximumWords
    }

    /// Words of one statement, and how many lie in a run of `verbatimRun` words of one utterance.
    func verbatimCount(of statement: String, runs: Set<[String]>) -> VerbatimCount {
        let run = max(configuration.verbatimRun, 2)
        var total = 0, covered = 0
        // Sentence by sentence: a run never spans two sentences.
        for sentence in statement.split(whereSeparator: \.isNewline).flatMap({ SummaryText.sentences(in: String($0)) }) {
            let words = SummaryText.words(in: sentence)
            total += words.count
            guard words.count >= run else { continue }
            var isCovered = [Bool](repeating: false, count: words.count)
            for start in 0 ... (words.count - run) where runs.contains(Array(words[start ..< start + run])) {
                for index in start ..< start + run { isCovered[index] = true }
            }
            covered += isCovered.count(where: { $0 })
        }
        return VerbatimCount(total: total, covered: covered)
    }

    /// How much of `text` repeats the transcript word for word: the share of its words that lie
    /// in a run of at least `verbatimRun` consecutive words of one utterance. Identical to the
    /// Window 7 measure (`RecapValidator.verbatimShare`).
    public func verbatimShare(of text: String, transcriptLines: [String]) -> Double {
        let runs = Self.spokenRuns(lines: transcriptLines, run: max(configuration.verbatimRun, 2))
        let count = verbatimCount(of: text, runs: runs)
        return count.total == 0 ? 0 : Double(count.covered) / Double(count.total)
    }

    /// Why `restated` cannot stand in for the spoken sentence `original`; nil when it can. It has
    /// to carry the same facts and nothing else: the same values (compared as values, so "6 a.m."
    /// and "six a.m." agree), the same negations, no new name, most of the content words, one
    /// sentence, not much more text, and not the sentence again.
    public func restatementProblem(_ restated: String, of original: String, normalizer: EnglishNormalizer = EnglishNormalizer()) -> ReasonCode? {
        let words = SummaryText.words(in: restated), originalWords = SummaryText.words(in: original)
        guard !words.isEmpty, words != originalWords else { return .restatementUnchanged }
        if SummaryText.sentences(in: restated).count > 1 { return .restatementNotOneSentence }
        if words.count > originalWords.count + configuration.restatementExtraWords { return .restatementTooLong }
        let newValues = normalizer.values(in: restated), oldValues = normalizer.values(in: original)
        let sameValues = newValues.allSatisfy { value in oldValues.contains { $0.isCompatible(with: value) } }
            && oldValues.allSatisfy { value in newValues.contains { $0.isCompatible(with: value) } }
        if !sameValues { return .restatementChangedNumberOrTime }
        if negationCount(restated, normalizer) != negationCount(original, normalizer) { return .restatementChangedNegation }
        let known = Set(originalWords)
        for token in normalizer.tokens(in: restated) where token.kind == .word && token.isCapitalized && token.original.count > 1 {
            let lowered = token.original.lowercased()
            let plain = lowered.hasSuffix("'s") ? String(lowered.dropLast(2)) : lowered
            if !known.contains(lowered), !known.contains(plain), !Lexicon.stopWords.contains(lowered), !Self.reportingOpeners.contains(lowered) {
                return .restatementAddedName
            }
        }
        let content = Set(originalWords.filter { !Lexicon.stopWords.contains($0) }.map(Lexicon.stem))
        if !content.isEmpty {
            let kept = Set(words.map(Lexicon.stem))
            if Double(content.count(where: kept.contains)) / Double(content.count) < configuration.restatementKeeps {
                return .restatementLostContent
            }
        }
        return nil
    }

    /// Capitalized first words of reported speech that are not names.
    static let reportingOpeners: Set<String> = ["somebody", "everyone", "everybody", "anyone", "nobody", "apparently", "reportedly", "someone", "it", "they", "people"]

    private func negationCount(_ text: String, _ normalizer: EnglishNormalizer) -> Int {
        normalizer.tokens(in: text).count { $0.kind == .word && Lexicon.negators.contains($0.text) }
    }
}

/// The short copies kept so far in one recap (each sentence once).
struct KeptCopyLedger: Hashable, Sendable {
    var kept: [String] = []

    /// Whether `statement` (a short copy) may be kept: the same sentence again, or room for one more.
    func mayKeep(_ statement: String, maximum: Int) -> Bool {
        kept.contains(statement) || kept.count < maximum
    }

    /// Records it; true when it is a sentence not kept before.
    mutating func record(_ statement: String) -> Bool {
        guard !kept.contains(statement) else { return false }
        kept.append(statement)
        return true
    }
}
