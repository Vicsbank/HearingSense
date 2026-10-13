import Foundation

/// The postprocessing of a model-written recap, from draft to what may be shown and saved.
///
/// Per statement, in order (summary sentences, then key points):
/// 1. cleanup (`SummaryQualityEditor`): narration and stutters out; filler and fragments dropped;
/// 2. grounding (`ClaimGrounder`, with `CorrectionResolver`): supported / unsupported / uncertain;
/// 3. duplicates: a statement that adds nothing to a kept one is dropped;
/// 4. privacy (`PrivacyCopyFilter`): a copy of a spoken sentence is kept (short, within limits),
///    restated (the engine's restatement, checked) or left out.
///
/// Invariants: no text is produced that was not in the input (statements, or restatements the
/// caller passes in) apart from deletions; only clearly unsupported statements are removed;
/// equivalent spellings of a value are equal; reports and corrections hold reason codes and
/// counts, never transcript text; the result depends only on the input.
public struct SummaryPostprocessor: Sendable {
    public let configuration: PostprocessingConfiguration
    public let normalizer: EnglishNormalizer

    public init(configuration: PostprocessingConfiguration = .standard) {
        self.configuration = configuration
        normalizer = EnglishNormalizer()
    }

    public var copyFilter: PrivacyCopyFilter { PrivacyCopyFilter(configuration: configuration) }

    /// A first recap. `transcriptLines`: one utterance per line (may contain the marker line
    /// "[some speech here could not be transcribed]"). Evidence lines index `transcriptLines`.
    public func process(_ draft: DraftText, transcriptLines: [String], restatements: [String: String] = [:]) -> PostprocessingOutput {
        let grounder = ClaimGrounder(lines: transcriptLines, configuration: configuration, normalizer: normalizer)
        let statements = SummaryText.statements(summary: draft.summary, keyPoints: draft.keyPoints)
        var pass = Pass(configuration: configuration, normalizer: normalizer, grounder: grounder, spokenLines: transcriptLines,
                        restatements: restatements, evidenceMap: Array(transcriptLines.indices).map { Optional($0) })
        let names = draftNames(statements.summary + statements.keyPoints)
        pass.run(summary: statements.summary, keyPoints: statements.keyPoints, draftNames: names)
        var output = pass.output(summary: pass.keptSummary, keyPoints: pass.keptKeyPoints)
        var corrections = output.corrections
        let title = checkedTitle(draft.title, grounder: grounder, corrections: &corrections)
        output.corrections = corrections
        output.title = title
        return output
    }

    /// An update. `addition` is what the model wrote about `newLines` only (summary: the new
    /// sentences; key points: new ones); `earlier` is the saved recap; `earlierLines` the earlier
    /// transcript still held (may be empty). Returns the merged recap: the earlier statements,
    /// then what the addition adds. A new statement that repeats an earlier one is dropped; an
    /// earlier statement that the new speech explicitly changed is replaced in place by the new
    /// statement that states the change (only when nothing else of it is lost), kept and marked
    /// when that cannot be done — never removed silently.
    ///
    /// Evidence lines index `earlierLines + newLines`. Counts (`statementCount`, `removedCount`
    /// …) are about the addition's statements.
    public func merge(earlier: DraftText, addition: DraftText, newLines: [String], earlierLines: [String],
                      restatements: [String: String] = [:]) -> PostprocessingOutput
    {
        let earlierSummary = SummaryText.sentences(in: earlier.summary)
        let earlierPoints = earlier.keyPoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var earlierStatements: [String] = []
        for statement in earlierSummary + earlierPoints where !earlierStatements.contains(statement) { earlierStatements.append(statement) }

        // The earlier recap stands between the earlier speech and the new speech: it supports what
        // the addition repeats of it, and a correction in the new speech can refer to it.
        let timeline = earlierLines + earlierStatements + newLines
        let recapStart = earlierLines.count, newStart = earlierLines.count + earlierStatements.count
        let transcript = AnalyzedTranscript(lines: timeline, normalizer: normalizer)
        let grounder = ClaimGrounder(transcript: transcript, configuration: configuration, normalizer: normalizer)
        let evidenceMap: [Int?] = timeline.indices.map { index in
            if index < recapStart { return index }
            if index >= newStart { return recapStart + (index - newStart) }
            return nil
        }
        let spokenLines = earlierLines + newLines
        var pass = Pass(configuration: configuration, normalizer: normalizer, grounder: grounder, spokenLines: spokenLines,
                        restatements: restatements, evidenceMap: evidenceMap)
        for statement in earlierSummary { pass.seed(statement, isKeyPoint: false) }
        for statement in earlierPoints { pass.seed(statement, isKeyPoint: true) }
        let added = SummaryText.statements(summary: addition.summary, keyPoints: addition.keyPoints)
        let names = draftNames(earlierStatements + added.summary + added.keyPoints)
        pass.run(summary: added.summary, keyPoints: added.keyPoints, draftNames: names)

        // Earlier statements the new speech made outdated.
        var mergedSummary = earlierSummary
        var mergedPoints = earlierPoints
        var newSummary = pass.keptSummary
        var newPoints = pass.keptKeyPoints
        var extraReports: [StatementReport] = []
        var extraUncertain: [String] = []
        var extraCorrections: [String] = []
        func markedSuperseded(_ statement: String) -> String {
            statement.hasPrefix("Superseded: ") ? statement : "Superseded: " + statement
        }
        let resolver = CorrectionResolver(lookback: configuration.correctionLookback)
        for statement in earlierStatements {
            let analyzed = AnalyzedText(statement, normalizer: normalizer)
            guard let correction = resolver.supersededCorrection(for: analyzed, corrections: grounder.corrections, transcript: transcript,
                                                                 fromLine: newStart),
                let old = correction.oldValue
            else { continue }
            let current = resolver.finalValue(of: correction, in: grounder.corrections)
            let states = { (text: String) -> Bool in
                let candidate = AnalyzedText(text, normalizer: self.normalizer)
                return candidate.values.contains { $0.isCompatible(with: current) }
                    && !candidate.contentStemSet.isDisjoint(with: correction.topic)
            }
            // Accepted replacements remain available after insertion into the summary: a
            // separate digest point about the same old slot must still see the corrected fact.
            let summaryReplacement = pass.keptSummary.first(where: states)
            let pointReplacement = pass.keptKeyPoints.first(where: states)
            let isInSummary = mergedSummary.contains(statement)
            let evidence = [correction.newLine].compactMap { evidenceMap[$0] }
            guard summaryReplacement != nil || pointReplacement != nil else {
                let marked = markedSuperseded(statement)
                mergedSummary = mergedSummary.map { $0 == statement ? marked : $0 }
                mergedPoints = mergedPoints.map { $0 == statement ? marked : $0 }
                extraUncertain.append(marked)
                extraReports.append(StatementReport(text: marked, isKeyPoint: !isInSummary, verdict: .uncertain,
                                                    reason: .outdatedByNewSpeech, evidenceLines: evidence))
                extraCorrections.append(ReasonCode.outdatedByNewSpeech.rawValue)
                continue
            }
            // Replaced only when every other value and content/relation word survives. A
            // corrected date alone must not silently delete a task or prohibition in its sentence.
            let others = analyzed.values.filter { !$0.isCompatible(with: old) }
            let rest = (mergedSummary + mergedPoints + newSummary + newPoints).filter { $0 != statement }
            let restValues = rest.flatMap { normalizer.values(in: $0) }
            let signature = SummaryQualityEditor.signature(of: analyzed)
            var retainedStems = signature.stems
            if old.kinds.contains(.place) {
                for value in analyzed.values where value.isCompatible(with: old) {
                    for reading in value.readings {
                        if case let .place(phrase) = reading {
                            retainedStems.subtract(phrase.split(separator: " ").map { Lexicon.canonicalStem(String($0)) })
                        }
                    }
                }
            }
            let zeroPrice = current.readings.contains { if case let .money(amount, _) = $0 { return amount == 0 }; return false }
            let isSimplePayment = old.kinds.contains(.money) && zeroPrice && others.isEmpty
                && !analyzed.tokens.contains { ["and", "but", ";"].contains($0.text) }
            if isSimplePayment {
                // A zero-price correction replaces the payment predicate itself. Only a simple
                // payment claim may omit it; other tasks in compound statements still survive.
                retainedStems.subtract(["request", "requested", "bring", "pay", "need", "price", "priced", "cost", "owed"]
                    .map(Lexicon.canonicalStem))
            }
            let restStems = rest.map { SummaryQualityEditor.signature(of: AnalyzedText($0, normalizer: normalizer)) }
                .filter { isSimplePayment || $0.isNegative == signature.isNegative }
                .reduce(into: Set<String>()) { $0.formUnion($1.stems) }
            guard others.allSatisfy({ value in restValues.contains { $0.isCompatible(with: value) } }),
                  retainedStems.isSubset(of: restStems)
            else {
                let marked = markedSuperseded(statement)
                mergedSummary = mergedSummary.map { $0 == statement ? marked : $0 }
                mergedPoints = mergedPoints.map { $0 == statement ? marked : $0 }
                extraUncertain.append(marked)
                extraReports.append(StatementReport(text: marked, isKeyPoint: !isInSummary, verdict: .uncertain,
                                                    reason: .earlierOutdatedKept, evidenceLines: evidence))
                extraCorrections.append(ReasonCode.earlierOutdatedKept.rawValue)
                continue
            }
            if let index = mergedSummary.firstIndex(of: statement) {
                if let replacement = summaryReplacement {
                    mergedSummary[index] = replacement
                    newSummary.removeAll { $0 == replacement }
                } else {
                    mergedSummary.remove(at: index)
                }
            }
            if let index = mergedPoints.firstIndex(of: statement) {
                if let replacement = pointReplacement {
                    mergedPoints[index] = replacement
                    newPoints.removeAll { $0 == replacement }
                } else {
                    mergedPoints.remove(at: index)
                }
            }
            extraReports.append(StatementReport(text: statement, isKeyPoint: !isInSummary, verdict: .unsupported,
                                                reason: .replacedOutdatedStatement, evidenceLines: evidence))
            extraCorrections.append(ReasonCode.replacedOutdatedStatement.rawValue)
        }

        for statement in mergedSummary + mergedPoints { pass.countVerbatim(statement) }
        var output = pass.output(summary: mergedSummary + newSummary, keyPoints: mergedPoints + newPoints)
        output.reports += extraReports
        output.corrections += extraCorrections
        for statement in extraUncertain where !output.uncertainStatements.contains(statement) { output.uncertainStatements.append(statement) }
        output.unverifiedStatements = output.uncertainStatements
        let earlierTitle = earlier.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if earlierTitle.isEmpty {
            var corrections = output.corrections
            let title = checkedTitle(addition.title, grounder: grounder, corrections: &corrections)
            output.corrections = corrections
            output.title = title
        } else {
            output.title = earlierTitle
        }
        return output
    }

    /// A title names the topic in words of its own, so only its values are checked (and its length).
    private func checkedTitle(_ title: String, grounder: ClaimGrounder, corrections: inout [String]) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let tooLong = trimmed.split(separator: " ").count > configuration.titleMaximumWords
        let invented = normalizer.values(in: trimmed).contains { !grounder.transcript.contains($0) }
        if tooLong || invented {
            corrections.append(ReasonCode.titleReplaced.rawValue)
            return ""
        }
        return trimmed
    }

    private func draftNames(_ statements: [String]) -> Set<String> {
        ClaimGrounder.draftNames(in: statements.map { AnalyzedText(SummaryQualityEditor.tidied($0), normalizer: normalizer) })
    }
}

/// One pass over the statements of a draft (or of an addition).
struct Pass {
    struct Cover {
        let signature: SummaryQualityEditor.Signature
        let isStrong: Bool
        let isKeyPoint: Bool
    }

    let configuration: PostprocessingConfiguration
    let normalizer: EnglishNormalizer
    let grounder: ClaimGrounder
    let filter: PrivacyCopyFilter
    let spoken: Set<[String]>
    let runs: Set<[String]>
    let restatements: [String: String]
    /// Grounder line index → index reported to the caller (nil: a line of the earlier recap).
    let evidenceMap: [Int?]

    var covers: [Cover] = []
    var ledger = KeptCopyLedger()
    var keptSummary: [String] = []
    var keptKeyPoints: [String] = []
    var lastSummaryIsCopy = false
    var lastKeyPointIsCopy = false
    var reports: [StatementReport] = []
    var copied: [String] = []
    var uncertain: [String] = []
    var corrections: [String] = []
    var statementCount = 0
    var removed = 0
    var restated = 0
    var duplicates = 0
    var fillers = 0
    var verbatimCounts: [String: VerbatimCount] = [:]

    init(configuration: PostprocessingConfiguration, normalizer: EnglishNormalizer, grounder: ClaimGrounder, spokenLines: [String],
         restatements: [String: String], evidenceMap: [Int?])
    {
        self.configuration = configuration
        self.normalizer = normalizer
        self.grounder = grounder
        filter = PrivacyCopyFilter(configuration: configuration)
        spoken = PrivacyCopyFilter.spokenSentences(lines: spokenLines)
        runs = PrivacyCopyFilter.spokenRuns(lines: spokenLines, run: max(configuration.verbatimRun, 2))
        self.restatements = restatements
        self.evidenceMap = evidenceMap
    }

    /// An earlier statement (merge): it covers what repeats it, counts toward the kept copies and
    /// decides whether the next kept copy would stand next to a copy.
    mutating func seed(_ statement: String, isKeyPoint: Bool) {
        let analyzed = AnalyzedText(statement, normalizer: normalizer)
        covers.append(Cover(signature: SummaryQualityEditor.signature(of: analyzed), isStrong: true, isKeyPoint: isKeyPoint))
        let isCopy = filter.isCopy(statement, spoken: spoken)
        if isCopy, filter.isShortCopy(statement) { _ = ledger.record(statement) }
        if isKeyPoint { lastKeyPointIsCopy = isCopy } else { lastSummaryIsCopy = isCopy }
    }

    mutating func run(summary: [String], keyPoints: [String], draftNames: Set<String>) {
        for statement in summary { handle(statement, isKeyPoint: false, draftNames: draftNames) }
        for statement in keyPoints { handle(statement, isKeyPoint: true, draftNames: draftNames) }
    }

    mutating func countVerbatim(_ statement: String) {
        verbatimCounts[statement] = filter.verbatimCount(of: statement, runs: runs)
    }

    private func mapped(_ lines: [Int]) -> [Int] {
        var result: [Int] = []
        for line in lines where line >= 0 && line < evidenceMap.count {
            if let index = evidenceMap[line], !result.contains(index) { result.append(index) }
        }
        return result.sorted()
    }

    private mutating func handle(_ raw: String, isKeyPoint: Bool, draftNames: Set<String>) {
        statementCount += 1
        let text = SummaryQualityEditor.tidied(raw)
        if text.isEmpty || SummaryQualityEditor.isIncompleteFragment(text) {
            fillers += 1
            reports.append(StatementReport(text: text, isKeyPoint: isKeyPoint, verdict: .filler, reason: .incompleteFragment))
            return
        }
        let analyzed = AnalyzedText(text, normalizer: normalizer)
        if SummaryQualityEditor.isFiller(analyzed) {
            fillers += 1
            reports.append(StatementReport(text: text, isKeyPoint: isKeyPoint, verdict: .filler, reason: .emptyFiller))
            return
        }
        let grounding = grounder.ground(analyzed, draftNames: draftNames)
        let evidence = mapped(grounding.evidenceLines)
        let signature = SummaryQualityEditor.signature(of: analyzed)

        if grounding.verdict != .unsupported, let cover = covering(signature, isKeyPoint: isKeyPoint, verdict: grounding.verdict) {
            duplicates += 1
            let reason: ReasonCode = isKeyPoint && !cover.isKeyPoint ? .repeatsSummarySentence : .duplicateStatement
            reports.append(StatementReport(text: text, isKeyPoint: isKeyPoint, verdict: .duplicate, reason: reason, evidenceLines: evidence))
            return
        }

        if filter.isCopy(text, spoken: spoken) {
            let afterCopy = isKeyPoint ? lastKeyPointIsCopy : lastSummaryIsCopy
            if configuration.keptCopyMaximumWords > 0, filter.isShortCopy(text), !afterCopy,
               ledger.mayKeep(text, maximum: configuration.maximumKeptCopies), grounding.verdict != .unsupported
            {
                if ledger.record(text) { corrections.append(ReasonCode.keptShortCopy.rawValue) }
                keep(text, isKeyPoint: isKeyPoint, isCopy: true, signature: signature, isStrong: true)
                if grounding.verdict == .uncertain { appendUncertain(text) }
                reports.append(StatementReport(text: text, isKeyPoint: isKeyPoint, verdict: .keptShortCopy, reason: .keptShortCopy,
                                               evidenceLines: evidence))
                return
            }
            if grounding.verdict == .unsupported {
                remove(text, isKeyPoint: isKeyPoint, reason: grounding.reason, evidence: evidence)
                return
            }
            if !copied.contains(text) { copied.append(text) }
            if let candidate = restatements[text]?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty,
               filter.restatementProblem(candidate, of: text, normalizer: normalizer) == nil, !filter.isCopy(candidate, spoken: spoken)
            {
                let restatedText = AnalyzedText(candidate, normalizer: normalizer)
                let check = grounder.ground(restatedText, draftNames: draftNames)
                if check.verdict != .unsupported {
                    restated += 1
                    corrections.append(ReasonCode.restatedCopy.rawValue)
                    keep(candidate, isKeyPoint: isKeyPoint, isCopy: false, signature: SummaryQualityEditor.signature(of: restatedText),
                         isStrong: check.verdict == .supported)
                    if check.verdict == .uncertain { appendUncertain(candidate) }
                    reports.append(StatementReport(text: candidate, isKeyPoint: isKeyPoint, verdict: .restated, reason: .restatedCopy,
                                                   evidenceLines: mapped(check.evidenceLines)))
                    return
                }
            }
            removed += 1
            corrections.append(ReasonCode.copiedFromTranscript.rawValue)
            reports.append(StatementReport(text: text, isKeyPoint: isKeyPoint, verdict: .copied, reason: .copiedFromTranscript))
            return
        }

        switch grounding.verdict {
        case .unsupported:
            remove(text, isKeyPoint: isKeyPoint, reason: grounding.reason, evidence: evidence)
        case .uncertain:
            keep(text, isKeyPoint: isKeyPoint, isCopy: false, signature: signature, isStrong: false)
            appendUncertain(text)
            reports.append(StatementReport(text: text, isKeyPoint: isKeyPoint, verdict: .uncertain, reason: grounding.reason, evidenceLines: evidence))
        case .supported:
            keep(text, isKeyPoint: isKeyPoint, isCopy: false, signature: signature, isStrong: true)
            reports.append(StatementReport(text: text, isKeyPoint: isKeyPoint, verdict: .supported, reason: grounding.reason, evidenceLines: evidence))
        }
    }

    /// A kept statement that already says everything `signature` says. A key point shorter than
    /// the summary sentence it repeats is kept (it is the digest); an uncertain statement only
    /// covers another uncertain one, so that a verifier's later rejection cannot take a fact with it.
    private func covering(_ signature: SummaryQualityEditor.Signature, isKeyPoint: Bool, verdict: GroundingVerdict) -> Cover? {
        for cover in covers where SummaryQualityEditor.isCovered(signature, by: cover.signature) {
            guard cover.isStrong || verdict == .uncertain else { continue }
            if !isKeyPoint, cover.isKeyPoint { continue }
            if isKeyPoint, !cover.isKeyPoint, signature.wordCount < cover.signature.wordCount { continue }
            return cover
        }
        return nil
    }

    private mutating func keep(_ text: String, isKeyPoint: Bool, isCopy: Bool, signature: SummaryQualityEditor.Signature, isStrong: Bool) {
        if isKeyPoint {
            keptKeyPoints.append(text)
            lastKeyPointIsCopy = isCopy
        } else {
            keptSummary.append(text)
            lastSummaryIsCopy = isCopy
        }
        covers.append(Cover(signature: signature, isStrong: isStrong, isKeyPoint: isKeyPoint))
        countVerbatim(text)
    }

    private mutating func remove(_ text: String, isKeyPoint: Bool, reason: ReasonCode, evidence: [Int]) {
        removed += 1
        corrections.append(reason.rawValue)
        reports.append(StatementReport(text: text, isKeyPoint: isKeyPoint, verdict: .unsupported, reason: reason, evidenceLines: evidence))
    }

    private mutating func appendUncertain(_ text: String) {
        if !uncertain.contains(text) { uncertain.append(text) }
    }

    func output(summary: [String], keyPoints: [String]) -> PostprocessingOutput {
        var output = PostprocessingOutput()
        output.summaryStatements = summary
        output.summary = summary.joined(separator: " ")
        output.keyPoints = keyPoints
        output.reports = reports
        output.copiedNeedingRestatement = copied
        output.uncertainStatements = uncertain
        output.unverifiedStatements = uncertain
        output.statementCount = statementCount
        output.removedCount = removed
        output.restatedCount = restated
        output.duplicateCount = duplicates
        output.fillerCount = fillers
        output.corrections = corrections
        output.verbatimCounts = verbatimCounts
        output.verbatimLimit = configuration.maximumVerbatimShare
        output.verbatimShare = output.recomputedVerbatimShare()
        return output
    }
}
