import Foundation

public enum GroundingVerdict: String, Hashable, Sendable {
    case supported
    case unsupported
    case uncertain
}

public struct GroundingResult: Hashable, Sendable {
    public var verdict: GroundingVerdict
    public var reason: ReasonCode
    /// Transcript lines that support the statement (for "supported"), or the line that
    /// contradicts it (for some "unsupported" reasons).
    public var evidenceLines: [Int]

    public init(verdict: GroundingVerdict, reason: ReasonCode, evidenceLines: [Int] = []) {
        self.verdict = verdict
        self.reason = reason
        self.evidenceLines = evidenceLines
    }
}

/// Checks a statement of a recap against the transcript, claim by claim, with local evidence.
///
/// A statement is split into clauses; each clause's claims (typed values, names, negation,
/// content words) must be found together in one utterance or a short run of adjacent ones
/// (`evidenceWindowLines`). Words spread over the whole transcript are not evidence.
///
/// - unsupported (removed) only when a claim is clearly not what was said: a value or a name
///   that was never said, a value that belongs to another matter, a value that was later
///   corrected, a "not" added or dropped, a "no" answer turned into a "yes", a hedged value made
///   exact, words put in the mouth of someone named nowhere near them;
/// - uncertain (kept, listed) when the checks cannot decide: a paraphrase with little word
///   overlap, a claim that something was not said, a hedge dropped, a name far from its evidence;
/// - supported otherwise, with the lines that support it.
public struct ClaimGrounder: Sendable {
    public let transcript: AnalyzedTranscript
    public let corrections: [Correction]
    public let configuration: PostprocessingConfiguration
    public let normalizer: EnglishNormalizer
    /// Corrections said in lines before this one are not held against statements (merge: only
    /// what the new speech changed counts for the earlier recap).
    public var correctionsFromLine: Int

    struct EvidenceWindow: Sendable {
        let range: Range<Int>
        let stems: Set<String>
        let values: [NormalizedValue]
    }

    let windows: [EvidenceWindow]
    let resolver: CorrectionResolver
    /// Sound keys of the words said (for names the recognizer may have misspelt).
    let phoneticKeys: Set<String>
    /// Values said that a summary could compute with (numbers, money, percentages, durations).
    let numericValueCount: Int

    public init(lines: [String], configuration: PostprocessingConfiguration = .standard, normalizer: EnglishNormalizer = EnglishNormalizer()) {
        self.init(transcript: AnalyzedTranscript(lines: lines, normalizer: normalizer), configuration: configuration, normalizer: normalizer)
    }

    public init(transcript: AnalyzedTranscript, configuration: PostprocessingConfiguration = .standard,
                normalizer: EnglishNormalizer = EnglishNormalizer(), correctionsFromLine: Int = 0)
    {
        self.transcript = transcript
        self.configuration = configuration
        self.normalizer = normalizer
        self.correctionsFromLine = correctionsFromLine
        let resolver = CorrectionResolver(lookback: configuration.correctionLookback)
        self.resolver = resolver
        corrections = resolver.corrections(in: transcript)
        var windows: [EvidenceWindow] = []
        let count = transcript.lines.count
        for length in 1 ... max(1, configuration.evidenceWindowLines) {
            for start in 0 ..< count where start + length <= count {
                var stems: Set<String> = []
                var values: [NormalizedValue] = []
                for index in start ..< start + length {
                    stems.formUnion(transcript.lines[index].contentStemSet)
                    values += transcript.lines[index].values
                }
                windows.append(EvidenceWindow(range: start ..< start + length, stems: stems, values: values))
            }
        }
        self.windows = windows
        var keys: Set<String> = []
        var numeric = 0
        for line in transcript.lines {
            for token in line.tokens where token.kind == .word && token.original.count >= 3 {
                let key = Lexicon.phoneticKey(token.original)
                if key.count >= 3 { keys.insert(key) }
            }
            numeric += line.values.count { value in value.kinds.isSubset(of: Self.derivableKinds) }
        }
        phoneticKeys = keys
        numericValueCount = numeric
    }

    static let derivableKinds: Set<ValueKind> = [.number, .money, .percent, .duration]
    static let derivationWords: Set<String> = [
        "calculated", "calculation", "computed", "density", "total", "totals", "totaling", "totalling", "sum", "average",
        "averages", "combined", "altogether", "overall", "resulting", "result", "results", "remaining", "leaving",
        "difference", "ratio", "net",
    ]
    static let arithmeticWords: Set<String> = ["by", "times", "x", "plus", "minus"]

    /// A value of a kind a summary can compute.
    private func isDerivable(_ value: NormalizedValue) -> Bool {
        value.kinds.isSubset(of: Self.derivableKinds)
    }

    /// The statement says it computed something ("calculated", "a total of") or puts two values
    /// together ("12 by 14").
    private func mentionsDerivation(_ statement: AnalyzedText) -> Bool {
        if statement.tokens.contains(where: { $0.kind == .word && Self.derivationWords.contains($0.text) }) { return true }
        for value in statement.values {
            let next = value.tokenRange.upperBound
            guard next < statement.tokens.count, Self.arithmeticWords.contains(statement.tokens[next].text) else { continue }
            if statement.values.contains(where: { $0.tokenRange.lowerBound == next + 1 }) { return true }
        }
        return false
    }

    // MARK: Statement

    public func ground(_ statement: String, draftNames: Set<String> = []) -> GroundingResult {
        ground(AnalyzedText(statement, normalizer: normalizer), draftNames: draftNames)
    }

    /// - Parameter draftNames: words the draft uses as names elsewhere (capitalized inside a
    ///   sentence); a sentence that starts with one of them is checked for it too.
    public func ground(_ statement: AnalyzedText, draftNames: Set<String> = []) -> GroundingResult {
        let lines = transcript.lines
        let isMeta = statement.containsWord(in: Lexicon.metaWords) || containsPhrase(statement, ["could", "not", "hear"])
            || containsPhrase(statement, ["hard", "of", "hearing"])
        // A statement about speech that could not be transcribed is about the recording (its
        // length comes from the app's own note, not from the words): never removed.
        if isMeta, mentionsMissingSpeech(statement) {
            if transcript.hasMissingSpeechMarker, statement.values.allSatisfy({ transcript.contains($0) }) {
                return GroundingResult(verdict: .supported, reason: .missingSpeechMarker,
                                       evidenceLines: lines.indices.filter { lines[$0].isMissingSpeechMarker })
            }
            return GroundingResult(verdict: .uncertain, reason: .metaStatement)
        }
        var uncertain: ReasonCode?
        // Values that were never said. A number worked out from numbers that were said ("a
        // density of 4.04", "168 square feet" for twelve by fourteen) cannot be checked by words:
        // kept as uncertain. Any other unsaid value is removed.
        let unsaid = statement.values.filter { !transcript.contains($0) }
        if !unsaid.isEmpty {
            guard unsaid.allSatisfy(isDerivable), mentionsDerivation(statement), numericValueCount >= 2 else {
                return GroundingResult(verdict: .unsupported, reason: .inventedValue)
            }
            uncertain = .derivedValue
        }
        // Names that were never said. Known as written ("Street") or as normalized ("st"); a
        // common abbreviation is no name; a name said with nearly the same sound ("Krebs" for the
        // recognizer's "crabs") is kept as uncertain.
        let names = nameTokens(in: statement, draftNames: draftNames)
        for name in names where !isKnownName(name.name) && !isKnownName(statement.tokens[name.index].text) {
            if Lexicon.knownAbbreviations.contains(name.name) { continue }
            let key = Lexicon.phoneticKey(name.name)
            if name.name.count >= 4, key.count >= 3, phoneticKeys.contains(key) {
                if uncertain == nil { uncertain = .nameSpellingDiffers }
                continue
            }
            return GroundingResult(verdict: .unsupported, reason: .inventedName)
        }
        // A value that a later correction replaced, presented as current.
        if let correction = resolver.supersededCorrection(for: statement, corrections: corrections, transcript: transcript,
                                                          fromLine: correctionsFromLine)
        {
            return GroundingResult(verdict: .unsupported, reason: .supersededValue, evidenceLines: [correction.newLine])
        }
        // Claims about the recording or about what was not said need reading.
        if isMeta || isAbsenceClaim(statement) {
            return GroundingResult(verdict: .uncertain, reason: isMeta ? .metaStatement : .absenceClaim)
        }
        guard !lines.isEmpty else { return GroundingResult(verdict: .uncertain, reason: .noTranscript) }

        var evidence: Set<Int> = []
        var claims = 0
        for clause in clauses(of: statement) {
            guard let result = groundClause(clause, of: statement, names: names) else { continue }
            claims += 1
            switch result.verdict {
            case .unsupported:
                return result
            case .uncertain:
                if uncertain == nil { uncertain = result.reason }
                evidence.formUnion(result.evidenceLines)
            case .supported:
                evidence.formUnion(result.evidenceLines)
            }
        }
        if claims == 0 { return GroundingResult(verdict: .uncertain, reason: .weakLocalSupport) }
        if let uncertain { return GroundingResult(verdict: .uncertain, reason: uncertain, evidenceLines: evidence.sorted()) }
        return GroundingResult(verdict: .supported, reason: .locallySupported, evidenceLines: evidence.sorted())
    }

    // MARK: Clause

    /// nil: the clause makes no claim of its own (no content word, no value).
    private func groundClause(_ clause: Range<Int>, of statement: AnalyzedText, names: [(name: String, index: Int)]) -> GroundingResult? {
        let lines = transcript.lines
        let content = statement.contentStems(in: clause)
        let values = statement.values.filter { clause.contains($0.tokenRange.lowerBound) }
        guard !content.isEmpty || !values.isEmpty else { return nil }

        // The best local evidence: most content words and values together; the shortest and
        // earliest window on a tie.
        var bestWindow = windows[0]
        var bestScore = -1.0
        for window in windows {
            let covered = content.count(where: window.stems.contains)
            let matched = values.count { value in window.values.contains { $0.isCompatible(with: value) } }
            let score = Double(covered + matched) / Double(content.count + values.count)
            if score > bestScore + 1e-9 {
                bestScore = score
                bestWindow = window
            }
        }
        let coverage = content.isEmpty ? 1.0 : Double(content.count(where: bestWindow.stems.contains)) / Double(content.count)
        let evidence = Array(bestWindow.range)
        var uncertain: ReasonCode?

        let clauseWords = statement.tokens[clause].filter { $0.kind == .word }.map(\.text)
        let hasExplicitNegation = clauseWords.contains { Lexicon.negators.contains($0) }
        let impliesNegative = clauseWords.contains { Lexicon.isNegativeImplying($0) }
        let hasNegation = hasExplicitNegation || impliesNegative
        let hasHedge = clauseWords.contains { Lexicon.hedgeWords.contains($0) }
        let reportsQuestion = clauseWords.contains { Lexicon.questionReportingWords.contains($0) }

        // A value whose own words point to another utterance, which holds a different value of
        // the same type: the value belongs to another matter ("the soccer game is on Tuesday"
        // when Tuesday was the dentist). Not for a value in a list ("on the 5th, 6th and 7th
        // respectively"): its own words are shared with the others.
        for value in values {
            let inList = values.contains { other in
                other != value && other.sharesKind(with: value) && abs(other.tokenRange.lowerBound - value.tokenRange.lowerBound) <= 3
            }
            if inList { continue }
            let context = segmentStems(around: value, in: clause, of: statement)
            guard context.count >= 2 else { continue }
            var bestLine = -1
            var bestCoverage = 0.0
            for (index, line) in lines.enumerated() where !line.isMissingSpeechMarker {
                let lineCoverage = Double(context.count(where: line.contentStemSet.contains)) / Double(context.count)
                if lineCoverage > bestCoverage + 1e-9 {
                    bestCoverage = lineCoverage
                    bestLine = index
                }
            }
            // The value's own utterance, with the one before it when it leans on it ("it's at
            // nine") and the one after it when that one comments on it ("that's the beta").
            var own = 0.0
            for index in transcript.lineIndices(with: value) {
                var stems = lines[index].contentStemSet
                if index > 0, isReferential(lines[index], previous: lines[index - 1]) { stems.formUnion(lines[index - 1].contentStemSet) }
                if index + 1 < lines.count, isReferential(lines[index + 1], previous: lines[index]) {
                    stems.formUnion(lines[index + 1].contentStemSet)
                }
                own = max(own, Double(context.count(where: stems.contains)) / Double(context.count))
            }
            guard bestLine >= 0, bestCoverage >= 0.67, own < 0.5, own <= bestCoverage - 0.34 else { continue }
            let conflicting = lines[bestLine].values.contains { $0.sharesKind(with: value) && !$0.isCompatible(with: value) }
            // The value is what that utterance's value was later changed to: the same slot.
            let correctedToIt = corrections.contains { correction in
                correction.oldLine == bestLine && resolver.finalValue(of: correction, in: corrections).isCompatible(with: value)
            }
            if correctedToIt { continue }
            if conflicting {
                return GroundingResult(verdict: .unsupported, reason: .valueMismatch, evidenceLines: [bestLine])
            }
            if uncertain == nil { uncertain = .valueNotLocal }
        }

        // Negation.
        if !hasNegation {
            for stem in content {
                let occurrences = lines.indices.filter { lines[$0].contentStemSet.contains(stem) }
                guard !occurrences.isEmpty else { continue }
                // Every time it was said, it was denied ("no cafeteria"), and the utterance that
                // denied it is about what the clause is about; the clause asserts it.
                let alwaysNegated = occurrences.allSatisfy { lines[$0].negatedStems.contains(stem) && !lines[$0].affirmedStems.contains(stem) }
                guard alwaysNegated else { continue }
                let others = content.filter { $0 != stem }
                let aligned = occurrences.contains { line in
                    guard bestWindow.range.contains(line) else { return false }
                    guard !others.isEmpty else { return true }
                    var stems = lines[line].contentStemSet
                    if line > 0, isReferential(lines[line], previous: lines[line - 1]) { stems.formUnion(lines[line - 1].contentStemSet) }
                    return Double(others.count(where: stems.contains)) / Double(others.count) > 0.5
                }
                if aligned { return GroundingResult(verdict: .unsupported, reason: .negationFlip, evidenceLines: occurrences) }
            }
        }
        // It was only ever asked about, and the answer was no ("can we email it" — "no"), yet the
        // clause asserts it. Not when the clause itself reports the "no" (it denies something of
        // that question), and not for a "no" about what the listener heard or knows.
        if !reportsQuestion, !impliesNegative {
            for stem in content where !statement.negatedStems.contains(stem) {
                let occurrences = lines.indices.filter { lines[$0].contentStemSet.contains(stem) }
                guard !occurrences.isEmpty, occurrences.allSatisfy({ isDeniedQuestion($0) }) else { continue }
                let reportsDenial = occurrences.contains { !lines[$0].contentStemSet.isDisjoint(with: statement.negatedStems) }
                if reportsDenial { continue }
                return GroundingResult(verdict: .unsupported, reason: .deniedQuestion, evidenceLines: occurrences)
            }
        }
        if hasExplicitNegation {
            // The clause denies something the evidence requires or allows only ("paper copies only").
            for stem in content where statement.negatedStems.contains(stem) {
                let nearby = max(0, bestWindow.range.lowerBound - 1) ..< min(lines.count, bestWindow.range.upperBound + 1)
                if nearby.contains(where: { lines[$0].markedStems.contains(stem) && !lines[$0].negatedStems.contains(stem) }) {
                    return GroundingResult(verdict: .unsupported, reason: .negationFlip, evidenceLines: Array(nearby))
                }
            }
        }

        // Hedges: a value said only with "around" / "maybe" must not become exact.
        for value in values {
            let occurrences = lines.flatMap { line in line.values.filter { $0.isCompatible(with: value) } }
            guard !occurrences.isEmpty, occurrences.allSatisfy(\.isHedged), !value.isHedged, !hasHedge else { continue }
            if value.isCertain || clauseWords.contains(where: { Lexicon.strongCertaintyWords.contains($0) }) {
                return GroundingResult(verdict: .unsupported, reason: .certaintyAdded, evidenceLines: evidence)
            }
            if uncertain == nil { uncertain = .hedgeDropped }
        }
        // An utterance that only said "maybe" / "could" / "I think" / "I'm not sure", reported as settled.
        if !hasHedge, let line = bestEvidenceLine(for: content, in: bestWindow),
           lines[line].containsWord(in: Lexicon.modalHedgeWords) || lines[line].hasEpistemicHedge
        {
            if clauseWords.contains(where: { Lexicon.strongCertaintyWords.contains($0) && $0 != "sharp" }) {
                return GroundingResult(verdict: .unsupported, reason: .certaintyAdded, evidenceLines: [line])
            }
            if clauseWords.contains(where: { Lexicon.settledWords.contains($0) }), uncertain == nil { uncertain = .certaintyUnclear }
        }

        // Names: words attributed to someone should have that name where the words were said. The
        // app has no speaker labels and people are often named elsewhere in the conversation
        // ("see you at one thirty, Mr. Mehta"), so a name said, but not there, is uncertain, not
        // removed (a name never said was removed above).
        for name in names where clause.contains(name.index) {
            let nameLines = lines.indices.filter { lines[$0].vocabulary.contains(name.name) }
            if nameLines.contains(where: bestWindow.range.contains) { continue }
            let distance = nameLines.map { line in
                line < bestWindow.range.lowerBound ? bestWindow.range.lowerBound - line : line - (bestWindow.range.upperBound - 1)
            }.min() ?? Int.max
            if isAttribution(at: name.index, in: statement) {
                if uncertain == nil { uncertain = .attributionUnclear }
            } else if distance > 3, uncertain == nil {
                uncertain = .nameNotLocal
            }
        }

        if !content.isEmpty, coverage < configuration.minimumLocalSupport, uncertain == nil { uncertain = .weakLocalSupport }

        // Supported only by a question that nobody answered with a yes.
        if uncertain == nil, !reportsQuestion, !content.isEmpty {
            let supporting = bestWindow.range.filter { !lines[$0].contentStemSet.isDisjoint(with: content) }
            if !supporting.isEmpty, supporting.allSatisfy({ lines[$0].isYesNoQuestion && !isAnsweredYes($0) }) { uncertain = .questionOnly }
        }

        if let uncertain { return GroundingResult(verdict: .uncertain, reason: uncertain, evidenceLines: evidence) }
        return GroundingResult(verdict: .supported, reason: .locallySupported, evidenceLines: evidence)
    }

    // MARK: Helpers

    /// Clauses: split at sentence ends, semicolons, colons, brackets and dashes, at a comma
    /// before a conjunction or relative word, and before "but". A part with fewer than two
    /// content words and no value joins the clause before it.
    func clauses(of statement: AnalyzedText) -> [Range<Int>] {
        let tokens = statement.tokens
        guard !tokens.isEmpty else { return [] }
        var starts: [Int] = [0]
        for (index, token) in tokens.enumerated() {
            if token.kind == .punctuation {
                if isAbbreviationPeriod(at: index, in: tokens) { continue }
                if ".!?;:()".contains(token.text) {
                    starts.append(index + 1)
                } else if token.text == ",", index + 1 < tokens.count, Self.clauseOpeners.contains(tokens[index + 1].text) {
                    starts.append(index + 1)
                }
            } else if token.kind == .word, token.text == "but", index > 0 {
                starts.append(index)
            }
        }
        var ranges: [Range<Int>] = []
        let ordered = Array(Set(starts)).sorted()
        for (position, start) in ordered.enumerated() {
            let end = position + 1 < ordered.count ? ordered[position + 1] : tokens.count
            if start < end { ranges.append(start ..< end) }
        }
        var merged: [Range<Int>] = []
        for range in ranges {
            let stems = statement.contentStems(in: range)
            let hasValue = statement.values.contains { range.contains($0.tokenRange.lowerBound) }
            if stems.count < 2, !hasValue, let last = merged.last {
                merged[merged.count - 1] = last.lowerBound ..< range.upperBound
            } else {
                merged.append(range)
            }
        }
        // A first part too small to stand alone joins the next one.
        if merged.count >= 2 {
            let first = merged[0]
            if statement.contentStems(in: first).count < 2, !statement.values.contains(where: { first.contains($0.tokenRange.lowerBound) }) {
                merged[1] = first.lowerBound ..< merged[1].upperBound
                merged.removeFirst()
            }
        }
        return merged
    }

    static let clauseOpeners: Set<String> = [
        "and", "but", "while", "with", "which", "though", "although", "so", "whereas", "as", "because", "since", "plus",
        "then", "where", "including", "who", "whose", "meaning", "after", "before", "until", "if", "or", "giving",
        "leaving", "making", "bringing", "when", "noting", "adding",
    ]
    static let segmentBreakers: Set<String> = ["and", "with", "while", "but", "or", "plus", "so", "because", "as", "since", "though", "although", "when", "where", "which", "who"]

    /// The content words of the part of the clause the value stands in (between commas and
    /// conjunctions): what the value is said about.
    func segmentStems(around value: NormalizedValue, in clause: Range<Int>, of statement: AnalyzedText) -> [String] {
        let tokens = statement.tokens
        let position = value.tokenRange.lowerBound
        var start = position
        while start > clause.lowerBound {
            let previous = tokens[start - 1]
            let isBoundary = (previous.kind == .punctuation && !isAbbreviationPeriod(at: start - 1, in: tokens))
                || (previous.kind == .word && Self.segmentBreakers.contains(previous.text))
            if isBoundary { break }
            start -= 1
        }
        var end = value.tokenRange.upperBound
        while end < clause.upperBound {
            let next = tokens[end]
            let isBoundary = (next.kind == .punctuation && !isAbbreviationPeriod(at: end, in: tokens))
                || (next.kind == .word && Self.segmentBreakers.contains(next.text))
            if isBoundary { break }
            end += 1
        }
        return statement.contentStems(in: start ..< end)
    }

    /// The period of "Ms." or of an initial, which ends no clause.
    private func isAbbreviationPeriod(at index: Int, in tokens: [NormalizedToken]) -> Bool {
        guard tokens[index].kind == .punctuation, tokens[index].text == ".", index > 0, index + 1 < tokens.count else { return false }
        let previous = tokens[index - 1]
        return previous.kind == .word && (Lexicon.titles.contains(previous.text) || previous.text.count == 1)
    }

    /// An utterance that leans on the one before it: a pronoun, a short reply, or an answer.
    private func isReferential(_ line: AnalyzedText, previous: AnalyzedText) -> Bool {
        let pronouns: Set<String> = ["it", "that", "this", "he", "she", "they", "them", "him", "her", "there", "then", "those", "these", "it's", "that's", "he's", "she's", "they're"]
        let words = line.tokens.filter { $0.kind == .word }
        return previous.isQuestion || words.count < 6 || words.contains { pronouns.contains($0.text) }
    }

    private func isDeniedQuestion(_ index: Int) -> Bool {
        let lines = transcript.lines
        guard lines[index].isYesNoQuestion, index + 1 < lines.count else { return false }
        // "Did you hear about the elevator?" — "no": the listener did not hear; nothing is denied.
        if lines[index].containsWord(in: Lexicon.perceptionVerbs) { return false }
        return lines[index + 1].startsWithDenial
    }

    private func isAnsweredYes(_ index: Int) -> Bool {
        let lines = transcript.lines
        guard index + 1 < lines.count else { return false }
        return lines[index + 1].startsWithAffirmation
    }

    private func bestEvidenceLine(for content: [String], in window: EvidenceWindow) -> Int? {
        guard !content.isEmpty else { return nil }
        var best: Int?
        var bestCount = 0
        for index in window.range {
            let count = content.count(where: transcript.lines[index].contentStemSet.contains)
            if count > bestCount {
                bestCount = count
                best = index
            }
        }
        return best
    }

    /// Capitalized words used as names: not the first word of a sentence (unless the draft uses
    /// it as a name elsewhere), not a stop word, title, month, weekday, number or "AM"/"PM".
    func nameTokens(in statement: AnalyzedText, draftNames: Set<String>) -> [(name: String, index: Int)] {
        var valueToken = Set<Int>()
        for value in statement.values { valueToken.formUnion(value.tokenRange) }
        var names: [(name: String, index: Int)] = []
        for (index, token) in statement.tokens.enumerated() where token.kind == .word && token.isCapitalized && token.original.count > 1 {
            let lowered = token.original.lowercased()
            let plain = lowered.hasSuffix("'s") ? String(lowered.dropLast(2)) : lowered
            if valueToken.contains(index) || Lexicon.stopWords.contains(lowered) || Lexicon.stopWords.contains(plain) { continue }
            if Lexicon.titles.contains(plain) || plain == "am" || plain == "pm" || plain == "i" || lowered.hasPrefix("i'") { continue }
            if EnglishNormalizer.weekdays[plain] != nil || EnglishNormalizer.months[plain] != nil { continue }
            if token.startsSentence, !draftNames.contains(plain) { continue }
            names.append((plain, index))
        }
        return names
    }

    /// Words of a draft that it uses as names (capitalized inside a sentence), lower-cased.
    public static func draftNames(in statements: [AnalyzedText]) -> Set<String> {
        var names: Set<String> = []
        for statement in statements {
            for token in statement.tokens where token.kind == .word && token.isCapitalized && !token.startsSentence && token.original.count > 1 {
                let lowered = token.original.lowercased()
                names.insert(lowered.hasSuffix("'s") ? String(lowered.dropLast(2)) : lowered)
            }
        }
        return names
    }

    private func isKnownName(_ name: String) -> Bool {
        transcript.vocabulary.contains(name) || transcript.vocabulary.contains(Lexicon.stem(name))
    }

    private func isAttribution(at index: Int, in statement: AnalyzedText) -> Bool {
        var position = index + 1
        let skippable: Set<String> = ["also", "then", "later", "first", "had", "has", "have", "already", "again", "just"]
        while position < statement.tokens.count, statement.tokens[position].kind == .word, skippable.contains(statement.tokens[position].text) {
            position += 1
        }
        guard position < statement.tokens.count, statement.tokens[position].kind == .word else { return false }
        return Lexicon.speechVerbs.contains(statement.tokens[position].text)
    }

    private func isAbsenceClaim(_ statement: AnalyzedText) -> Bool {
        if statement.containsWord(in: Lexicon.absenceWords) { return true }
        let words = statement.tokens.filter { $0.kind == .word }.map(\.text)
        for (index, word) in words.enumerated() where Lexicon.negators.contains(word) {
            let reach = words[(index + 1) ..< min(words.count, index + 5)]
            if reach.contains(where: { Lexicon.absenceParticiples.contains($0) }) { return true }
        }
        return false
    }

    private func mentionsMissingSpeech(_ statement: AnalyzedText) -> Bool {
        let gap: Set<String> = ["transcribed", "transcription", "inaudible", "garbled", "missing", "unintelligible", "heard", "unclear"]
        let speech: Set<String> = ["speech", "part", "parts", "portion", "section", "conversation", "words", "some", "recording", "transcript", "said"]
        return statement.containsWord(in: gap) && statement.containsWord(in: speech)
    }

    private func containsPhrase(_ statement: AnalyzedText, _ phrase: [String]) -> Bool {
        let words = statement.tokens.filter { $0.kind == .word }.map(\.text)
        guard words.count >= phrase.count, !phrase.isEmpty else { return false }
        return (0 ... (words.count - phrase.count)).contains { Array(words[$0 ..< $0 + phrase.count]) == phrase }
    }
}
