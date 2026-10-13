import Foundation

/// A statement or an utterance read once for all checks: its tokens, values, content words and
/// negations. Built in memory and never logged.
public struct AnalyzedText: Hashable, Sendable {
    public let text: String
    public let tokens: [NormalizedToken]
    public let values: [NormalizedValue]
    /// The canonical stem of each token that carries content; "" for the others (stop words,
    /// value words, punctuation).
    public let contentStemAt: [String]
    /// Content stems in order of first appearance.
    public let contentStems: [String]
    public let contentStemSet: Set<String>
    /// Lower-cased words, possessive-free words and stems: what a name is looked up in.
    public let vocabulary: Set<String>
    /// Content stems inside the reach of a "not", "no", "never", "without" ….
    public let negatedStems: Set<String>
    /// Content stems outside every negation.
    public let affirmedStems: Set<String>
    /// Content stems next to "only", "must", "need", "required", "always".
    public let markedStems: Set<String>
    /// The text has a negation (a leading answer "no" excluded; a question denies nothing).
    public let hasNegation: Bool
    /// "I'm not sure", "I don't know", "no idea": the speaker hedges.
    public let hasEpistemicHedge: Bool
    public let isYesNoQuestion: Bool
    /// Any question, also "what time do we get back".
    public let isQuestion: Bool
    public let startsWithDenial: Bool
    public let startsWithAffirmation: Bool
    public let isMissingSpeechMarker: Bool

    /// - Parameters:
    ///   - followsQuestion: the utterance before this one was a question, so a leading "no" or
    ///     "yes" answers it and does not negate what follows ("is it okay if we email it" — "no
    ///     paper copies only")…
    ///   - questionStems: …unless the word after it repeats what was asked about ("any
    ///     allergies?" — "no allergies"): then it is the answer and a negation at once.
    public init(_ text: String, normalizer: EnglishNormalizer = EnglishNormalizer(), followsQuestion: Bool = false,
                questionStems: Set<String> = [])
    {
        self.text = text
        let marker = SummaryText.isMissingSpeechMarker(text)
        isMissingSpeechMarker = marker
        let tokens: [NormalizedToken] = marker ? [] : normalizer.tokens(in: text)
        self.tokens = tokens
        let values = normalizer.values(in: tokens)
        self.values = values

        var valueToken = [Bool](repeating: false, count: tokens.count)
        // Venue nouns still participate in lexical support and negation ("no cafeteria",
        // "Nina's house has a pool"); unlike number words, they carry relational meaning.
        for value in values where !value.kinds.contains(.place) {
            for index in value.tokenRange where index < tokens.count { valueToken[index] = true }
        }
        var stems = [String](repeating: "", count: tokens.count)
        var ordered: [String] = []
        var vocabulary: Set<String> = []
        for (index, token) in tokens.enumerated() where token.kind == .word {
            let plain = token.text.hasSuffix("'s") ? String(token.text.dropLast(2)) : token.text
            let written = token.original.lowercased()
            vocabulary.insert(token.text)
            vocabulary.insert(plain)
            vocabulary.insert(written.hasSuffix("'s") ? String(written.dropLast(2)) : written)
            vocabulary.insert(Lexicon.stem(token.text))
            guard !valueToken[index], !Lexicon.stopWords.contains(token.text), plain.count >= 2,
                  plain.allSatisfy({ $0.isLetter || $0 == "'" })
            else { continue }
            let stem = Lexicon.canonicalStem(plain)
            stems[index] = stem
            if !ordered.contains(stem) { ordered.append(stem) }
        }
        // Letters said one by one are a word too ("K R seven nine two" → "kr", "the k p eye
        // review" → "kpi"), and so are two words said apart ("red wood" → "redwood").
        var letters: [String] = []
        var hasLetter = false
        var spoken: [String] = []
        for token in tokens {
            guard token.kind == .word else {
                Self.addLetterRun(letters, hasLetter: hasLetter, to: &vocabulary)
                letters = []
                hasLetter = false
                continue
            }
            let written = token.original.lowercased()
            spoken.append(written)
            if written.count == 1, written.first?.isLetter == true {
                letters.append(written)
                hasLetter = true
            } else if !letters.isEmpty, let letter = Lexicon.letterNames[written] {
                letters.append(letter)
            } else {
                Self.addLetterRun(letters, hasLetter: hasLetter, to: &vocabulary)
                letters = []
                hasLetter = false
            }
        }
        Self.addLetterRun(letters, hasLetter: hasLetter, to: &vocabulary)
        for position in spoken.indices.dropLast() {
            let first = spoken[position], second = spoken[position + 1]
            if first.count >= 2, second.count >= 2, first.allSatisfy(\.isLetter), second.allSatisfy(\.isLetter) {
                vocabulary.insert(first + second)
            }
        }
        contentStemAt = stems
        contentStems = ordered
        contentStemSet = Set(ordered)
        self.vocabulary = vocabulary

        // The first word after fillers ("um", "so", "okay" …).
        let words = tokens.indices.filter { tokens[$0].kind == .word }
        let firstIndex = words.first { !Lexicon.leadingFillers.contains(tokens[$0].text) }
        let firstWord = firstIndex.map { tokens[$0].text } ?? ""
        let endsWithQuestionMark = tokens.last.map { $0.kind == .punctuation && $0.text == "?" } ?? false
        let secondWord = firstIndex.map { $0 + 1 < tokens.count ? tokens[$0 + 1].text : "" } ?? ""
        // "Do not bring phones" is an instruction, "isn't it Sunday" a question.
        let isInstruction = ["do", "does", "did"].contains(firstWord) && secondWord == "not"
        let opensQuestion = (Lexicon.questionOpeners.contains(firstWord) && !isInstruction)
            || ((firstWord == "what" || firstWord == "how") && secondWord == "about")
        isYesNoQuestion = opensQuestion || endsWithQuestionMark
        isQuestion = isYesNoQuestion || ["what", "when", "where", "who", "why", "how", "which", "whose"].contains(firstWord)
        startsWithDenial = Lexicon.denialAnswers.contains(firstWord)
        startsWithAffirmation = Lexicon.affirmativeAnswers.contains(firstWord)

        // A leading "no" / "yes" is an answer when it follows a question or a comma follows it.
        var particle: Int?
        if let firstIndex, startsWithDenial || startsWithAffirmation {
            let commaAfter = firstIndex + 1 < tokens.count && tokens[firstIndex + 1].kind == .punctuation
            let repeatsQuestion = firstIndex + 1 < tokens.count && !stems[firstIndex + 1].isEmpty && questionStems.contains(stems[firstIndex + 1])
            if commaAfter || (followsQuestion && !repeatsQuestion) { particle = firstIndex }
        }

        // The reach of a negation. "no" / "without" deny the words that follow ("no paper copies");
        // "not" / "never" deny one word, and a verb after "to" ("does not need to skip"). It ends
        // at punctuation, a conjunction, a new subject ("she can't she works"), and at a word of
        // knowing ("I'm not sure someone said …": a hedge, not a denial). A question denies nothing.
        var negated = [Bool](repeating: false, count: tokens.count)
        var foundNegation = false
        var epistemic = false
        let negatorIndices: [Int] = isYesNoQuestion ? [] : tokens.indices.filter {
            tokens[$0].kind == .word && Lexicon.negators.contains(tokens[$0].text) && $0 != particle
        }
        for index in negatorIndices {
            foundNegation = true
            let phrasal = tokens[index].text != "not" && tokens[index].text != "never"
            var position = index + 1
            var steps = 0
            var inHead = false
            var afterTo = false
            while position < tokens.count, steps < 4 {
                let current = tokens[position]
                if current.kind == .punctuation { break }
                if current.kind == .word {
                    let text = current.text
                    let base = text.split(separator: "'").first.map(String.init) ?? text
                    if Lexicon.scopeBreakers.contains(text) { break }
                    if text.contains("'"), Lexicon.subjectPronouns.contains(base) || ["what", "here", "i", "we", "you", "they", "he", "she"].contains(base) { break }
                    if Lexicon.subjectPronouns.contains(text), position > index + 1 || text != "that" { break }
                    if Lexicon.epistemicWords.contains(text) {
                        epistemic = true
                        break
                    }
                    if !stems[position].isEmpty {
                        if inHead, !phrasal, !afterTo { break }
                        negated[position] = true
                        inHead = true
                        afterTo = false
                    } else if inHead {
                        if text == "to" { afterTo = true } else { break }
                    }
                    steps += 1
                } else if inHead {
                    break
                }
                position += 1
            }
        }
        hasNegation = foundNegation
        hasEpistemicHedge = epistemic
        var negatedSet: Set<String> = [], affirmedSet: Set<String> = []
        for index in tokens.indices where !stems[index].isEmpty {
            if negated[index] { negatedSet.insert(stems[index]) } else { affirmedSet.insert(stems[index]) }
        }
        negatedStems = negatedSet
        affirmedStems = affirmedSet

        var marked: Set<String> = []
        for (index, token) in tokens.enumerated() where token.kind == .word {
            let isMarker = Lexicon.affirmationMarkers.contains(token.text)
                || ((token.text == "have" || token.text == "has") && index + 1 < tokens.count && tokens[index + 1].text == "to")
            guard isMarker else { continue }
            for offset in [-2, -1, 1, 2] {
                let position = index + offset
                guard position >= 0, position < tokens.count, !stems[position].isEmpty, !negated[position] else { continue }
                // Not across punctuation.
                let low = min(index, position), high = max(index, position)
                if (low ... high).contains(where: { tokens[$0].kind == .punctuation }) { continue }
                marked.insert(stems[position])
            }
        }
        markedStems = marked
    }

    /// Every run of two to six consecutive letters of `letters`, joined ("k", "p", "i" → "kp", "kpi", "pi").
    private static func addLetterRun(_ letters: [String], hasLetter: Bool, to vocabulary: inout Set<String>) {
        guard hasLetter, letters.count >= 2 else { return }
        for start in letters.indices {
            var joined = letters[start]
            for position in (start + 1) ..< min(letters.count, start + 6) {
                joined += letters[position]
                vocabulary.insert(joined)
            }
        }
    }

    /// The stems of tokens `range`.
    public func contentStems(in range: Range<Int>) -> [String] {
        var result: [String] = []
        for index in range where index >= 0 && index < contentStemAt.count {
            let stem = contentStemAt[index]
            if !stem.isEmpty, !result.contains(stem) { result.append(stem) }
        }
        return result
    }

    /// Whether some token of the text is one of `words` (lower-cased token text).
    public func containsWord(in words: Set<String>) -> Bool {
        tokens.contains { $0.kind == .word && words.contains($0.text) }
    }

    /// Whether some content stem of the text is one of `stems`.
    public func containsStem(in stems: Set<String>) -> Bool {
        tokens.indices.contains { stems.contains(Lexicon.stem(tokens[$0].text)) && tokens[$0].kind == .word }
    }
}

/// The lines of a transcript, read once.
public struct AnalyzedTranscript: Hashable, Sendable {
    public let lines: [AnalyzedText]
    /// Every word and stem said, for name checks.
    public let vocabulary: Set<String>
    public let hasMissingSpeechMarker: Bool

    public init(lines: [String], normalizer: EnglishNormalizer = EnglishNormalizer()) {
        var analyzed: [AnalyzedText] = []
        var vocabulary: Set<String> = []
        var previousWasQuestion = false
        var previousStems: Set<String> = []
        for line in lines {
            let text = AnalyzedText(line, normalizer: normalizer, followsQuestion: previousWasQuestion, questionStems: previousStems)
            analyzed.append(text)
            vocabulary.formUnion(text.vocabulary)
            if !text.isMissingSpeechMarker {
                previousWasQuestion = text.isYesNoQuestion
                previousStems = text.contentStemSet
            }
        }
        self.lines = analyzed
        self.vocabulary = vocabulary
        hasMissingSpeechMarker = analyzed.contains { $0.isMissingSpeechMarker }
    }

    public var count: Int { lines.count }

    /// Whether some line has a value compatible with `value`.
    public func contains(_ value: NormalizedValue) -> Bool {
        lines.contains { line in line.values.contains { $0.isCompatible(with: value) } }
    }

    /// Indices of the lines with a value compatible with `value`.
    public func lineIndices(with value: NormalizedValue) -> [Int] {
        lines.indices.filter { index in lines[index].values.contains { $0.isCompatible(with: value) } }
    }
}
