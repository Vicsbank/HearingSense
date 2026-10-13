import Foundation

/// Window 9: postprocessing of model-written recaps, between the summarizer's raw text and what
/// the user sees. Normalization (`EnglishNormalizer`), claim-level grounding (`ClaimGrounder`),
/// corrections (`CorrectionResolver`), transcript privacy (`PrivacyCopyFilter`) and conservative
/// cleanup (`SummaryQualityEditor`), joined by `SummaryPostprocessor`. Design note:
/// `docs/research/W9_POSTPROCESSING_DESIGN.md`.
public enum SummaryPostprocessingModule {
    public static let version = "w9.1"
}

/// A recap as a model wrote it, before any check. Untrusted.
public struct DraftText: Hashable, Sendable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]

    public init(title: String, summary: String, keyPoints: [String] = []) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
    }
}

public struct PostprocessingConfiguration: Hashable, Sendable {
    /// A statement that repeats a whole spoken sentence of at most this many words may stay as it
    /// is (approved 2026-10-12). 0: every copy is restated or left out (the Window 7 rule).
    public var keptCopyMaximumWords = 12
    /// Short copies kept in one recap (summary and key points together, each sentence once).
    public var maximumKeptCopies = 3
    /// A statement of at least this many words that is a whole spoken sentence is a copy.
    public var copiedMinimumWords = 5
    /// Words in a row from one utterance that count as repeated word for word in `verbatimShare`.
    public var verbatimRun = 6
    /// A text with a larger share of words repeated word for word is not a summary.
    public var maximumVerbatimShare = 0.65
    /// A restatement may be this many words longer than the sentence it restates.
    public var restatementExtraWords = 10
    /// Share of the original's content words a restatement must keep.
    public var restatementKeeps = 0.75
    /// Share of a claim's content words its local evidence must contain for "supported".
    public var minimumLocalSupport = 0.5
    /// Adjacent utterances that may together support one claim.
    public var evidenceWindowLines = 3
    /// A title longer than this is not used.
    public var titleMaximumWords = 10
    /// Utterances back that the value replaced by a correction may lie.
    public var correctionLookback = 8

    public init(keptCopyMaximumWords: Int = 12, maximumKeptCopies: Int = 3, copiedMinimumWords: Int = 5, verbatimRun: Int = 6,
                maximumVerbatimShare: Double = 0.65, restatementExtraWords: Int = 10, restatementKeeps: Double = 0.75,
                minimumLocalSupport: Double = 0.5, evidenceWindowLines: Int = 3, titleMaximumWords: Int = 10,
                correctionLookback: Int = 8)
    {
        self.keptCopyMaximumWords = keptCopyMaximumWords
        self.maximumKeptCopies = maximumKeptCopies
        self.copiedMinimumWords = copiedMinimumWords
        self.verbatimRun = verbatimRun
        self.maximumVerbatimShare = maximumVerbatimShare
        self.restatementExtraWords = restatementExtraWords
        self.restatementKeeps = restatementKeeps
        self.minimumLocalSupport = minimumLocalSupport
        self.evidenceWindowLines = evidenceWindowLines
        self.titleMaximumWords = titleMaximumWords
        self.correctionLookback = correctionLookback
    }

    public static let standard = PostprocessingConfiguration()
}

public enum StatementVerdict: String, Hashable, Sendable {
    /// Kept: local evidence supports every claim of it.
    case supported
    /// Removed: a claim is clearly not what was said (invented value or name, a flipped "not",
    /// a value of another slot, a superseded value).
    case unsupported
    /// Kept, and listed for an optional reading by a model: the checks cannot decide.
    case uncertain
    /// Kept as it was said: a short copy within the approved limits.
    case keptShortCopy
    /// Replaced by a checked restatement.
    case restated
    /// Removed: what it says is already in the recap.
    case duplicate
    /// Removed: says nothing (filler) or is an unfinished fragment.
    case filler
    /// Removed: repeats a spoken sentence and no acceptable restatement exists.
    case copied

    /// The statement is not in the result.
    public var removesStatement: Bool {
        switch self {
        case .unsupported, .duplicate, .filler, .copied: return true
        case .supported, .uncertain, .keptShortCopy, .restated: return false
        }
    }
}

/// Fixed reason codes. A report or a correction never holds text of the transcript or of the
/// recap: only one of these.
public enum ReasonCode: String, Hashable, Sendable, CaseIterable {
    case locallySupported = "locally_supported"
    case keptShortCopy = "kept_short_copy"
    case restatedCopy = "restated_copy"
    case earlierRecap = "earlier_recap"
    case missingSpeechMarker = "missing_speech_marker"
    case verifierConfirmed = "verifier_confirmed"
    case inventedValue = "invented_value"
    case valueMismatch = "value_mismatch"
    case supersededValue = "superseded_value"
    case inventedName = "invented_name"
    case attributionNotInEvidence = "attribution_not_in_evidence"
    case negationFlip = "negation_flip"
    case deniedQuestion = "denied_question"
    case certaintyAdded = "certainty_added"
    case copiedFromTranscript = "copied_from_transcript"
    case verifierRejected = "verifier_rejected"
    case copyAdjacentAfterRemoval = "copy_adjacent_after_removal"
    case weakLocalSupport = "weak_local_support"
    case valueNotLocal = "value_not_local"
    case hedgeDropped = "hedge_dropped"
    case certaintyUnclear = "certainty_unclear"
    /// The clock time is compatible, but its AM/PM half was not established by local evidence.
    case timeQualifierAdded = "time_qualifier_added"
    case nameNotLocal = "name_not_local"
    case attributionUnclear = "attribution_unclear"
    case absenceClaim = "absence_claim"
    case metaStatement = "meta_statement"
    case questionOnly = "question_only"
    case outdatedByNewSpeech = "outdated_by_new_speech"
    case noTranscript = "no_transcript"
    /// A number not said but plausibly worked out from numbers that were ("a density of 4.04").
    case derivedValue = "derived_value"
    /// A name not said as written, but said with nearly the same sound ("Krebs" for "crabs").
    case nameSpellingDiffers = "name_spelling_differs"
    case duplicateStatement = "duplicate_statement"
    case repeatsSummarySentence = "repeats_summary_sentence"
    case emptyFiller = "empty_filler"
    case incompleteFragment = "incomplete_fragment"
    case replacedOutdatedStatement = "replaced_outdated_statement"
    case earlierOutdatedKept = "earlier_outdated_kept"
    case titleReplaced = "title_replaced"
    case restatementUnchanged = "restatement_unchanged"
    case restatementNotOneSentence = "restatement_not_one_sentence"
    case restatementTooLong = "restatement_too_long"
    case restatementChangedNumberOrTime = "restatement_changed_number_or_time"
    case restatementChangedNegation = "restatement_changed_negation"
    case restatementAddedName = "restatement_added_name"
    case restatementLostContent = "restatement_lost_content"
}

/// What happened to one statement. `text` is the statement (speech-derived): in memory only,
/// never logged. `reason` is a `ReasonCode` raw value and nothing else.
public struct StatementReport: Hashable, Sendable {
    public var text: String
    public var isKeyPoint: Bool
    public var verdict: StatementVerdict
    public var reason: String
    /// Indices of the transcript lines that support it (see `SummaryPostprocessor` for what they index).
    public var evidenceLines: [Int]

    public init(text: String, isKeyPoint: Bool, verdict: StatementVerdict, reason: ReasonCode, evidenceLines: [Int] = []) {
        self.text = text
        self.isKeyPoint = isKeyPoint
        self.verdict = verdict
        self.reason = reason.rawValue
        self.evidenceLines = evidenceLines
    }
}

/// Words of a kept statement and how many of them repeat an utterance word for word. Counts only.
struct VerbatimCount: Hashable, Sendable {
    var total: Int
    var covered: Int
}

public struct PostprocessingOutput: Hashable, Sendable {
    public var title = ""
    public var summary = ""
    public var keyPoints: [String] = []
    /// The summary's statements in order (`summary` is them joined by spaces).
    public var summaryStatements: [String] = []
    /// One report per statement of the input, in order: summary sentences, then key points
    /// (for `merge`: the addition's statements, then any earlier statement that changed).
    public var reports: [StatementReport] = []
    /// Statements that repeat a spoken sentence and may not stay as they are, each once. In
    /// memory only, for the engine's restating step; never logged or stored.
    public var copiedNeedingRestatement: [String] = []
    /// Statements kept although the checks could not decide. For an optional model verifier.
    public var uncertainStatements: [String] = []
    /// Uncertain statements no verifier has confirmed: never to be reported as verified.
    public var unverifiedStatements: [String] = []
    /// Statements checked, statements removed for what they say (unsupported, or copies without
    /// a restatement), statements replaced by a restatement. Duplicates and filler are counted
    /// separately: removing them loses nothing.
    public var statementCount = 0
    public var removedCount = 0
    public var restatedCount = 0
    public var duplicateCount = 0
    public var fillerCount = 0
    /// Reason codes of what was removed, restated, kept as a copy or replaced. Codes only.
    public var corrections: [String] = []
    /// Share of the kept text's words that repeat an utterance word for word.
    public var verbatimShare = 0.0
    /// The limit `verbatimShare` is held against (from the configuration).
    public var verbatimLimit = 0.65

    var verbatimCounts: [String: VerbatimCount] = [:]

    public init() {}

    /// More of the text repeats the transcript than a summary may: not to be shown or saved as one.
    public var exceedsVerbatimShare: Bool { verbatimShare > verbatimLimit }

    /// How many statements ended with each reason (codes and counts only: safe to log).
    public var reasonCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for report in reports { counts[report.reason, default: 0] += 1 }
        return counts
    }

    /// Applies an optional model verifier's verdicts (statement text → supported?) to the
    /// uncertain statements: rejected ones are removed, confirmed ones become supported, and those
    /// it did not answer (a timeout) stay listed as unverified — never reported as verified.
    /// Verdicts about statements that were not uncertain are ignored: what the checks found
    /// supported stays, what they removed stays removed.
    public func applying(verifierVerdicts: [String: Bool]) -> PostprocessingOutput {
        var rejected: Set<String> = []
        var confirmed: Set<String> = []
        var open: [String] = []
        for statement in uncertainStatements {
            switch verifierVerdicts[statement] {
            case .some(false): rejected.insert(statement)
            case .some(true): confirmed.insert(statement)
            case .none: open.append(statement)
            }
        }
        guard !rejected.isEmpty || !confirmed.isEmpty else { return self }
        var output = self
        for index in output.reports.indices where output.reports[index].verdict == .uncertain {
            let text = output.reports[index].text
            if rejected.contains(text) {
                output.reports[index].verdict = .unsupported
                output.reports[index].reason = ReasonCode.verifierRejected.rawValue
                output.removedCount += 1
                output.corrections.append(ReasonCode.verifierRejected.rawValue)
            } else if confirmed.contains(text) {
                output.reports[index].verdict = .supported
                output.reports[index].reason = ReasonCode.verifierConfirmed.rawValue
            }
        }
        output.summaryStatements = output.summaryStatements.filter { !rejected.contains($0) }
        output.keyPoints = output.keyPoints.filter { !rejected.contains($0) }
        // Two kept copies that now stand next to each other would be a piece of transcript.
        output.summaryStatements = output.withoutAdjacentCopies(output.summaryStatements, isKeyPoint: false)
        output.keyPoints = output.withoutAdjacentCopies(output.keyPoints, isKeyPoint: true)
        output.summary = output.summaryStatements.joined(separator: " ")
        output.uncertainStatements = open
        output.unverifiedStatements = open
        output.verbatimShare = output.recomputedVerbatimShare()
        return output
    }

    private mutating func withoutAdjacentCopies(_ statements: [String], isKeyPoint: Bool) -> [String] {
        let copies = Set(reports.filter { $0.verdict == .keptShortCopy }.map(\.text))
        var kept: [String] = []
        for statement in statements {
            if copies.contains(statement), let last = kept.last, copies.contains(last) {
                if let index = reports.firstIndex(where: { $0.text == statement && $0.verdict == .keptShortCopy && $0.isKeyPoint == isKeyPoint }) {
                    reports[index].verdict = .copied
                    reports[index].reason = ReasonCode.copyAdjacentAfterRemoval.rawValue
                }
                removedCount += 1
                corrections.append(ReasonCode.copyAdjacentAfterRemoval.rawValue)
                if !copiedNeedingRestatement.contains(statement) { copiedNeedingRestatement.append(statement) }
                continue
            }
            kept.append(statement)
        }
        return kept
    }

    func recomputedVerbatimShare() -> Double {
        var total = 0, covered = 0
        for statement in summaryStatements + keyPoints {
            guard let count = verbatimCounts[statement] else { continue }
            total += count.total
            covered += count.covered
        }
        return total == 0 ? 0 : Double(covered) / Double(total)
    }
}
