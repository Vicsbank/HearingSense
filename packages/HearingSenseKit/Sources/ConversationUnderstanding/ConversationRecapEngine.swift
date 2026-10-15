import Foundation
import NaturalLanguage
import SummaryPostprocessing

/// A recap as the language model wrote it, before checking. Untrusted.
public struct RecapDraft: Hashable, Sendable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    /// Window 9: the engine that wrote it (set by `SummarizationCoordinator`). nil: not known.
    public var engine: SummarizationEngineIdentity?
    /// Window 9: why the preferred engine was not used (a code), when this draft is the fallback's.
    public var fallbackReason: String?
    /// Window 9, updates only: sentences of the earlier recap that the model says the new speech
    /// made wrong (copied from the earlier recap). Checked against the earlier recap and the new
    /// transcript before anything is replaced.
    public var outdated: [String]

    public init(title: String, summary: String, keyPoints: [String] = [], engine: SummarizationEngineIdentity? = nil,
                fallbackReason: String? = nil, outdated: [String] = [])
    {
        self.outdated = outdated
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.engine = engine
        self.fallbackReason = fallbackReason
    }
}

/// A language model that writes recaps. Production: `FoundationModelRecapSummarizer`.
public protocol ConversationSummarizing: Sendable {
    /// Whether the transcript says what `statement` says (Window 8): the reading check that the
    /// lexical checks cannot make. nil: this summarizer cannot judge, and the statement is kept.
    /// The transcript is given in memory, like for the recap itself; nothing of it is kept.
    func isGrounded(_ statement: String, in transcript: String) async throws -> Bool?
    /// Window 8: for each statement, the lines of the transcript that say it (indices into
    /// `lines`) and the model's own verdict, in one request. nil: this summarizer cannot do it.
    func evidence(for statements: [String], in lines: [String]) async throws -> [StatementEvidence]?
    func isAvailable() async -> Bool
    func prewarm() async
    /// A recap of the excerpt.
    func recap(transcript: String, notes: [String]) async throws -> RecapDraft
    /// The earlier recap, extended by what was said since. Earlier details must be kept.
    func update(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft
    /// One sentence that was said, rewritten as one sentence of a recap (reported speech) with
    /// the same facts. Used when a draft repeats a spoken sentence word for word; the result is
    /// checked like every other statement.
    func restate(_ statement: String) async throws -> String
    /// Window 9: the complete updated recap (earlier details that are still true, what is new,
    /// and corrections applied: an outdated value is not stated as current). Used only when the
    /// new speech changed something the earlier recap says; the result is checked like a first recap.
    func rewrite(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft
}

extension ConversationSummarizing {
    /// A summarizer that cannot restate: the copied sentence is then left out.
    public func restate(_ statement: String) async throws -> String { throw RecapError.restatementUnsupported }
    /// A summarizer that cannot rewrite: the merged addition stands, the outdated statement stays marked.
    public func rewrite(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft { throw RecapError.restatementUnsupported }
}

/// A checked recap, ready to show and to save.
extension ConversationSummarizing {
    public func isGrounded(_ statement: String, in transcript: String) async throws -> Bool? { nil }
    public func evidence(for statements: [String], in lines: [String]) async throws -> [StatementEvidence]? { nil }
}

/// Where the transcript says what a statement of a recap says, according to the model.
public struct StatementEvidence: Hashable, Sendable {
    /// Indices of transcript lines. Empty: the model found no line that says it.
    public var lines: [Int]
    /// The model's own reading: the cited lines say what the statement says.
    public var isSupported: Bool

    public init(lines: [Int], isSupported: Bool) {
        self.lines = lines
        self.isSupported = isSupported
    }
}

extension RecapValidator {
    /// Window 8: the model read the statement against the transcript. It stands when the model
    /// calls it supported and can name a line of the transcript that says it. (Holding the
    /// statement against the cited line word by word as well was measured and dropped: it
    /// rejected true statements whose line says "she" for a name or "call us" for "by phone".)
    public func groundingProblem(_ statement: String, evidence: StatementEvidence, lines: [String]) -> String? {
        guard evidence.isSupported, evidence.lines.contains(where: lines.indices.contains) else { return "ungrounded_statement" }
        return nil
    }
}

public struct ConversationRecap: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable, Codable {
        /// Written by the on-device language model and checked.
        case languageModel
        /// The model was unavailable or its text failed the checks: no summary was written.
        case unavailable
        /// Too little was said to summarize.
        case insufficientContext
    }

    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var source: Source
    /// What the reader should know about the recap's limits ("the beginning may be missing").
    public var caveats: [String]
    /// Statements the checks removed or flagged (names only, for diagnostics).
    public var corrections: [String]
    /// The time span of the speech it covers.
    public var coveredFrom: Date?
    public var coveredTo: Date?
    public var utteranceCount: Int
    public var modelSeconds: TimeInterval
    /// Share of the text that repeats an utterance word for word (`RecapValidator.verbatimShare`),
    /// measured when it was checked. A number only; for diagnostics and the evaluation.
    public var verbatimShare = 0.0
    /// Window 9: the engines that wrote this recap, first the one that wrote the first version;
    /// later updates by a different engine add theirs. Empty: unknown (older records).
    public var engines: [SummarizationEngineIdentity] = []
    /// Window 9: why the preferred engine was not used for this recap (a code), if it was not.
    public var fallbackReason: String?
    /// Window 9: statements kept although the checks could not confirm them (and no model
    /// verification confirmed them either). A count, for diagnostics.
    public var unverifiedStatements = 0

    public init(title: String, summary: String, keyPoints: [String] = [], source: Source, caveats: [String] = [],
                corrections: [String] = [], coveredFrom: Date? = nil, coveredTo: Date? = nil, utteranceCount: Int = 0,
                modelSeconds: TimeInterval = 0)
    {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.source = source
        self.caveats = caveats
        self.corrections = corrections
        self.coveredFrom = coveredFrom
        self.coveredTo = coveredTo
        self.utteranceCount = utteranceCount
        self.modelSeconds = modelSeconds
    }

    public var isSummary: Bool { source == .languageModel }

    /// The engines' names, joined ("Qwen (Qwen3.5-4B-MLX-4bit)"); nil when unknown.
    public var engineLabel: String? {
        var labels: [String] = []
        for engine in engines where !labels.contains(engine.label) { labels.append(engine.label) }
        return labels.isEmpty ? nil : labels.joined(separator: " + ")
    }

    /// Title, summary, key points and caveats as one text (for copying and for search).
    public var fullText: String {
        var parts = [summary]
        if !keyPoints.isEmpty { parts.append(keyPoints.map { "• " + $0 }.joined(separator: "\n")) }
        if !caveats.isEmpty { parts.append(caveats.map { "Note: " + $0 }.joined(separator: "\n")) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// Deterministic checks on a recap: what it says must be in the transcript.
///
/// The checks are lexical. They catch a number, a day or a name that was never said, and a
/// sentence whose content words are mostly not from the transcript. They cannot judge whether a
/// sentence combines true words into a false statement.
public struct RecapValidator: Hashable, Sendable {
    /// Share of a sentence's content words that must occur in the transcript.
    public var minimumSupport: Double
    /// Window 7: a statement of at least this many words that is, word for word, a whole
    /// sentence of the transcript is a copy, not a summary, and is never kept as it is — a saved
    /// summary must never turn into a saved transcript. (Found in the Simulator: asked to extend
    /// a recap, the on-device model appended the three new utterances unchanged, and every other
    /// check passed them, because a copy is fully supported by its source.)
    ///
    /// A copy is not simply deleted, because a short spoken sentence is often a fact the reader
    /// needs ("The lot reopens on Friday."): the engine asks the model to restate it, in memory,
    /// and `validate` puts the restatement in its place when it passes `restatementProblem`.
    /// Only when no acceptable restatement exists is the statement left out.
    public var copiedMinimumWords: Int
    /// Words in a row, taken from one utterance, that count as repeated word for word when the
    /// whole text is measured (`verbatimShare`).
    public var verbatimRun: Int
    /// A restatement may be this many words longer than the sentence it restates.
    public var restatementExtraWords: Int
    /// Share of the original's content words a restatement must keep.
    public var restatementKeeps: Double
    /// Window 8 (approved by the student on 2026-10-12: completeness and accuracy come first,
    /// and a summary the user asked for may hold a short exact quotation): a statement that
    /// repeats a spoken sentence of at most this many words stays as it is — "The lot reopens on
    /// Friday." is the fact, and rewording it only to avoid the match risks changing it. Words
    /// are counted by `RecapText.words`, which also segments Chinese and other text written
    /// without spaces. 0: the rule of Window 7 (restate, or leave out).
    ///
    /// What still keeps a saved summary from becoming a saved transcript: a longer copy is
    /// restated or left out as before; no two kept copies stand next to each other
    /// and at most `maximumKeptCopies` are kept in one recap; and the summary as a whole may
    /// not be mostly transcript (`ConversationRecapEngine.Policy.maximumVerbatimShare`).
    public var keptCopyMaximumWords: Int
    /// Short copies kept in one recap (summary and key points together, each sentence once).
    public var maximumKeptCopies: Int
    /// 2026-10-11: the supporting words of a statement have to stand near each other in the
    /// transcript, within this many words. A sentence put together from words that were said
    /// minutes apart ("Vic", "student", "family") reads like a fact and is none; every word of
    /// it passes the ordinary support test. The window is wide (about half a minute of speech),
    /// so a sentence that sums up one exchange is never affected.
    public var proximityWindow: Int

    public init(minimumSupport: Double = 0.5, copiedMinimumWords: Int = 5, verbatimRun: Int = 6,
                restatementExtraWords: Int = 10, restatementKeeps: Double = 0.75, proximityWindow: Int = 80,
                keptCopyMaximumWords: Int = 12, maximumKeptCopies: Int = 3)
    {
        self.proximityWindow = proximityWindow
        self.keptCopyMaximumWords = keptCopyMaximumWords
        self.maximumKeptCopies = maximumKeptCopies
        self.minimumSupport = minimumSupport
        self.copiedMinimumWords = copiedMinimumWords
        self.verbatimRun = verbatimRun
        self.restatementExtraWords = restatementExtraWords
        self.restatementKeeps = restatementKeeps
    }

    public struct Result: Hashable, Sendable {
        public var summary: String
        public var keyPoints: [String]
        public var title: String
        public var corrections: [String]
        /// Sentences and key points checked, and how many were removed.
        public var statements: Int
        public var removed: Int
        /// Statements that repeated a spoken sentence word for word and are not in the result as
        /// they were (each once). Speech-derived: for the engine's restating only, never logged.
        public var copied: [String]
        /// How many statements were replaced by a checked restatement.
        public var restated: Int
        /// Share of the kept text's words that repeat an utterance word for word (see `verbatimShare`).
        public var verbatimShare: Double
    }

    /// The name of the correction recorded when a copied statement was replaced by a restatement.
    public static let restatedCorrection = "restated_copy"
    /// A short copied statement that was kept as it was said (`keptCopyMaximumWords`).
    public static let keptCopyCorrection = "kept_short_copy"

    /// How much of `text` repeats the transcript word for word: the share of its words that lie
    /// in a run of at least `verbatimRun` consecutive words of one utterance. A summary of plain
    /// facts shares runs with its source (0.2–0.4 is ordinary); a text that is mostly transcript
    /// is close to 1.
    public func verbatimShare(of text: String, transcript: String) -> Double {
        let run = max(verbatimRun, 2)
        var spokenRuns: Set<[String]> = []
        for line in transcript.split(whereSeparator: \.isNewline) {
            let words = RecapText.words(in: String(line))
            guard words.count >= run else { continue }
            for start in 0...(words.count - run) { spokenRuns.insert(Array(words[start ..< start + run])) }
        }
        var total = 0, covered = 0
        // Statement by statement: a run never spans two sentences of the text.
        for statement in text.split(whereSeparator: \.isNewline).flatMap({ RecapText.sentences(in: String($0)) }) {
            let words = RecapText.words(in: statement)
            total += words.count
            guard words.count >= run else { continue }
            var isCovered = [Bool](repeating: false, count: words.count)
            for start in 0...(words.count - run) where spokenRuns.contains(Array(words[start ..< start + run])) {
                for index in start ..< start + run { isCovered[index] = true }
            }
            covered += isCovered.count(where: { $0 })
        }
        return total == 0 ? 0 : Double(covered) / Double(total)
    }

    /// Why `restated` cannot stand in for the spoken sentence `original`; nil when it can. It
    /// has to carry the same facts and nothing else: the same numbers, days and times, the same
    /// negations, most of the content words, no new name, and not much more text.
    public func restatementProblem(_ restated: String, of original: String) -> String? {
        let words = RecapText.words(in: restated), originalWords = RecapText.words(in: original)
        guard !words.isEmpty, words != originalWords else { return "restatement_unchanged" }
        if RecapText.sentences(in: restated).count > 1 { return "restatement_not_one_sentence" }
        if words.count > originalWords.count + restatementExtraWords { return "restatement_too_long" }
        if RecapText.quantities(in: restated) != RecapText.quantities(in: original) { return "restatement_changed_number_or_time" }
        if RecapText.negations(in: restated) != RecapText.negations(in: original) { return "restatement_changed_negation" }
        // Stricter than the ordinary name test, which cannot judge a sentence's first word: every
        // capitalized word has to be a word of the original or an ordinary opening ("Someone").
        let known = Set(originalWords)
        for word in RecapText.capitalizedWords(in: restated)
            where !known.contains(word) && !RecapText.stopWords.contains(word) && !RecapText.reportingOpeners.contains(word)
        {
            return "restatement_added_name"
        }
        let content = Set(RecapText.contentWords(in: original).map(RecapText.stem))
        if !content.isEmpty {
            let kept = Set(RecapText.words(in: restated).map(RecapText.stem))
            if Double(content.count(where: kept.contains)) / Double(content.count) < restatementKeeps { return "restatement_lost_content" }
        }
        return nil
    }

    /// - Parameter restatements: for statements that repeat a spoken sentence, what the model
    ///   wrote when asked to restate them (keyed by the statement). Used only where it passes
    ///   the checks.
    public func validate(_ draft: RecapDraft, transcript: String, earlierText: String = "",
                         restatements: [String: String] = [:]) -> Result
    {
        let source = transcript + " " + earlierText
        let sourceStems = Set(RecapText.words(in: source).map(RecapText.stem))
        let sourceQuantities = RecapText.quantities(in: source)
        let sourceNames = RecapText.names(in: source)
        var corrections: [String] = []
        var statements = 0, removed = 0
        // Every spoken sentence and every whole utterance, as words (the earlier recap is not
        // part of it: restating it is fine).
        var spoken: Set<[String]> = []
        for line in transcript.split(whereSeparator: \.isNewline) {
            spoken.insert(RecapText.words(in: String(line)))
            for sentence in RecapText.sentences(in: String(line)) { spoken.insert(RecapText.words(in: sentence)) }
        }

        // Overlapping stretches of the source, for the proximity test. A source shorter than
        // the window is one stretch, and the test then adds nothing.
        let stems = RecapText.words(in: source).map(RecapText.stem)
        var stretches: [Set<String>] = []
        if proximityWindow > 0, stems.count > proximityWindow {
            let step = max(proximityWindow / 4, 1)
            var start = 0
            while start < stems.count {
                stretches.append(Set(stems[start ..< min(start + proximityWindow, stems.count)]))
                if start + proximityWindow >= stems.count { break }
                start += step
            }
        }

        func isCopy(_ statement: String) -> Bool {
            let words = RecapText.words(in: statement)
            return words.count >= copiedMinimumWords && spoken.contains(words)
        }

        func problem(in statement: String, allowsCopy: Bool = false) -> String? {
            if !allowsCopy, isCopy(statement) { return "copied_from_transcript" }
            let quantities = RecapText.quantities(in: statement)
            if !quantities.isSubset(of: sourceQuantities) { return "unsupported_number_or_time" }
            if !RecapText.names(in: statement).isSubset(of: sourceNames) { return "unsupported_name" }
            let content = RecapText.contentWords(in: statement).map(RecapText.stem)
            if content.count >= 3 {
                let supported = content.count(where: sourceStems.contains)
                if Double(supported) / Double(content.count) < minimumSupport { return "unsupported_statement" }
                if !stretches.isEmpty {
                    let together = stretches.map { stretch in content.count(where: stretch.contains) }.max() ?? 0
                    if Double(together) / Double(content.count) < minimumSupport { return "unsupported_combination" }
                }
            }
            return nil
        }

        var copied: [String] = []
        var restated = 0

        // Short copies that stay as they were said (each sentence once, however often it occurs).
        var keptCopies: Set<String> = []

        /// The statement as it may be kept: itself, a short copy as it was said, a checked
        /// restatement of a copy, or nil. `afterKeptCopy`: the statement before it in the same
        /// list is a kept copy — two in a row would be a piece of transcript.
        func resolved(_ statement: String, afterKeptCopy: Bool) -> String? {
            statements += 1
            if isCopy(statement) {
                if RecapText.words(in: statement).count <= keptCopyMaximumWords, !afterKeptCopy,
                   keptCopies.contains(statement) || keptCopies.count < maximumKeptCopies,
                   problem(in: statement, allowsCopy: true) == nil
                {
                    if keptCopies.insert(statement).inserted { corrections.append(Self.keptCopyCorrection) }
                    return statement
                }
                if !copied.contains(statement) { copied.append(statement) }
                if let candidate = restatements[statement]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   restatementProblem(candidate, of: statement) == nil, problem(in: candidate) == nil
                {
                    restated += 1
                    corrections.append(Self.restatedCorrection)
                    return candidate
                }
            }
            if let issue = problem(in: statement) {
                removed += 1
                corrections.append(issue)
                return nil
            }
            return statement
        }

        var kept: [String] = []
        for sentence in RecapText.sentences(in: draft.summary) {
            if let statement = resolved(sentence, afterKeptCopy: kept.last.map(keptCopies.contains) ?? false) { kept.append(statement) }
        }
        var points: [String] = []
        for point in draft.keyPoints.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !point.isEmpty {
            if let statement = resolved(point, afterKeptCopy: points.last.map(keptCopies.contains) ?? false),
               !points.contains(statement)
            {
                points.append(statement)
            }
        }
        var title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A title names the topic in words of its own ("Medication instructions"), so only its
        // numbers, days and times are checked.
        if title.isEmpty || !RecapText.quantities(in: title).isSubset(of: sourceQuantities)
            || title.split(separator: " ").count > 10
        {
            if !title.isEmpty { corrections.append("title_replaced") }
            title = ""
        }
        let share = verbatimShare(of: (kept + points).joined(separator: "\n"), transcript: transcript)
        return Result(summary: kept.joined(separator: " "), keyPoints: points, title: title, corrections: corrections,
                      statements: statements, removed: removed, copied: copied, restated: restated, verbatimShare: share)
    }
}

/// Writes recaps of the recent conversation and extends them while the user keeps following.
public struct ConversationRecapEngine: Sendable {
    public struct Policy: Hashable, Sendable {
        /// Which postprocessing checks a draft goes through. `.window9` (default): normalization,
        /// claim-level grounding, privacy copy limits and quality editing (`SummaryPostprocessing`).
        /// `.legacy`: the Window 7/8 lexical validator, kept only to measure before/after.
        public enum Postprocessing: String, Hashable, Sendable { case legacy, window9 }
        public var postprocessing = Postprocessing.window9
        /// Window 9: what happens to statements the deterministic grounding cannot decide
        /// (`uncertain`: paraphrases, claims of absence). `.off`: they stay, listed as unverified.
        /// `.uncertainOnly`: one request to the model that wrote the draft covers just those
        /// statements; what it calls unsupported is removed, what it does not answer in time stays
        /// unverified (never reported as verified).
        public enum Verification: String, Hashable, Sendable { case off, uncertainOnly }
        public var verification = Verification.off
        public var verificationTimeout: TimeInterval = 8
        /// Window 9: when the new speech changed something the earlier recap still states as
        /// current, one request asks the model for the complete updated recap. 0 turns it off.
        public var rewriteTimeout: TimeInterval = 30
        public var timeout: TimeInterval = 25
        /// A recap from which the checks removed more than this share is not shown as a summary.
        public var maximumRemovedShare = 0.5
        /// Words of transcript sent to the model at most (the newest are kept).
        public var maximumTranscriptWords = 900
        /// Missing speech longer than this in total is mentioned in the recap.
        public var missingSpeechNotice: TimeInterval = 6
        /// Statements of one draft that repeat a spoken sentence and are given to the model to
        /// restate (one short request each). Further ones are left out.
        public var maximumRestatements = 3
        /// Time for all restatements of one draft together.
        public var restateTimeout: TimeInterval = 10
        /// A text of which more than this share repeats the transcript word for word is not a
        /// summary and is not shown or saved as one. Chosen on the development scenes, whose
        /// summaries measure 0.13–0.44 (`docs/testing/WINDOW7_ACCEPTANCE_REPORT.md`, section 4).
        public var maximumVerbatimShare = 0.65
        /// Window 8: after the lexical checks the model reads every statement against the
        /// transcript (`ConversationSummarizing.evidence`); what it cannot find there is left
        /// out. One request per recap, with this much time; no answer in time: nothing is removed.
        public var groundingTimeout: TimeInterval = 10
        /// A reading that rejects this share of the statements or more is not believed (the
        /// model answered beside the point); the statements then stay as the other checks left them.
        public var groundingDistrustShare = 0.67

        public init() {}
    }

    public let summarizer: any ConversationSummarizing
    public let validator: RecapValidator
    public let policy: Policy
    public let bufferPolicy: ConversationBufferPolicy

    public init(summarizer: any ConversationSummarizing, validator: RecapValidator = RecapValidator(),
                policy: Policy = Policy(), bufferPolicy: ConversationBufferPolicy = .standard)
    {
        self.summarizer = summarizer
        self.validator = validator
        self.policy = policy
        self.bufferPolicy = bufferPolicy
    }

    public static let untitled = "Conversation"

    /// The caveats that follow from the excerpt itself, whatever the model writes.
    public func caveats(for excerpt: ConversationExcerpt) -> [String] {
        var caveats: [String] = []
        if excerpt.isTruncatedAtStart { caveats.append("Listening began during this conversation; its beginning is missing.") }
        if excerpt.missingDuration >= policy.missingSpeechNotice {
            caveats.append("About \(Int(excerpt.missingDuration.rounded())) seconds of speech could not be transcribed.")
        }
        if excerpt.lowQualityShare >= 0.4 { caveats.append("Much of the speech was hard to recognize; details may be wrong.") }
        return caveats
    }

    /// The transcript as it is given to the model: one utterance per line, with a marker where
    /// speech is missing. No speaker labels: the app does not know who spoke.
    public func transcript(of excerpt: ConversationExcerpt) -> String {
        var lines: [(Date, String)] = excerpt.utterances.map { ($0.start, $0.text) }
        lines += excerpt.missing.filter { $0.duration >= 3 }.map { ($0.start, "[some speech here could not be transcribed]") }
        let text = lines.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        return words.count <= policy.maximumTranscriptWords ? text : words.suffix(policy.maximumTranscriptWords).joined(separator: " ")
    }

    public func recap(_ excerpt: ConversationExcerpt) async -> ConversationRecap {
        let caveats = caveats(for: excerpt)
        guard excerpt.wordCount >= bufferPolicy.minimumWords else {
            return ConversationRecap(
                title: Self.untitled,
                summary: excerpt.utterances.isEmpty
                    ? "Nothing was transcribed in the last \(Self.describe(excerpt.windowEnd.timeIntervalSince(excerpt.windowStart))), so there is nothing to summarize."
                    : "Only a few words were transcribed in the last \(Self.describe(excerpt.windowEnd.timeIntervalSince(excerpt.windowStart))), not enough for a summary.",
                source: .insufficientContext, caveats: caveats, coveredFrom: excerpt.start, coveredTo: excerpt.end,
                utteranceCount: excerpt.utterances.count)
        }
        let text = transcript(of: excerpt)
        let started = Date()
        guard await summarizer.isAvailable(), let draft = try? await withTimeout({ [summarizer] in
            try await summarizer.recap(transcript: text, notes: caveats)
        }) else {
            return unavailable(excerpt, caveats: caveats, seconds: Date().timeIntervalSince(started))
        }
        var rejected: [String] = []
        if policy.postprocessing == .window9 {
            let output = await postprocessed(draft, lines: text.split(whereSeparator: \.isNewline).map(String.init))
            if let recap = checked(output, draft: draft, excerpt: excerpt, caveats: caveats,
                                   seconds: Date().timeIntervalSince(started), rejected: &rejected)
            {
                return recap
            }
            var note = unavailable(excerpt, caveats: caveats, seconds: Date().timeIntervalSince(started),
                                   correction: "summary_failed_checks")
            note.corrections += rejected
            note.engines = draft.engine.map { [$0] } ?? []
            note.fallbackReason = draft.fallbackReason
            return note
        }
        let result = await grounded(await validated(draft, transcript: text, earlierText: ""), transcript: text, known: [])
        if let recap = checked(result, excerpt: excerpt, caveats: caveats, seconds: Date().timeIntervalSince(started),
                               rejected: &rejected)
        {
            return recap
        }
        // The names of the checks that failed travel with the note (for diagnostics; no text).
        var note = unavailable(excerpt, caveats: caveats, seconds: Date().timeIntervalSince(started),
                               correction: "summary_failed_checks")
        note.corrections += rejected
        return note
    }

    /// Extends `previous` with the utterances said since. Returns nil when there is nothing new
    /// worth a change or the update could not be made; the earlier recap then stays as it is.
    public func update(_ previous: ConversationRecap, earlierTranscript: String, new utterances: [BufferedUtterance]) async -> ConversationRecap? {
        let fresh = utterances.map(\.text).joined(separator: "\n")
        guard previous.isSummary, fresh.split(whereSeparator: \.isWhitespace).count >= 4 else { return nil }
        let started = Date()
        let earlier = RecapDraft(title: previous.title, summary: previous.summary, keyPoints: previous.keyPoints)
        guard await summarizer.isAvailable(), let written = try? await withTimeout({ [summarizer] in
            try await summarizer.update(previous: earlier, newTranscript: fresh)
        }) else { return nil }
        var draft = written
        if policy.postprocessing == .legacy, !draft.summary.hasPrefix(previous.summary) {
            // The Window 7/8 checks expect the whole recap: the earlier text, then the addition.
            draft.summary = draft.summary.isEmpty ? previous.summary : previous.summary + " " + draft.summary
        }
        if policy.postprocessing == .window9 {
            return await mergedUpdate(previous, addition: draft, newUtterances: utterances, earlierTranscript: earlierTranscript,
                                      started: started)
        }
        // Earlier text counts as support: the update may restate what the first recap said.
        // Only what the update added is read against the transcript; the earlier recap was.
        let known = Set(RecapText.sentences(in: previous.summary) + previous.keyPoints)
        let result = await grounded(await validated(draft, transcript: fresh + "\n" + earlierTranscript, earlierText: previous.fullText),
                                    transcript: fresh + "\n" + earlierTranscript, known: known)
        guard !result.summary.isEmpty,
              result.statements == 0 || Double(result.removed) / Double(result.statements) <= policy.maximumRemovedShare,
              result.verbatimShare <= policy.maximumVerbatimShare
        else { return nil }
        var updated = previous
        updated.summary = result.summary
        // Earlier verified key points are never lost: new ones are added to them.
        var points = previous.keyPoints
        for point in result.keyPoints where !points.contains(point) { points.append(point) }
        // Nothing but copies was added: the earlier recap stays, and the new utterances are
        // offered again with the next update.
        guard result.summary != previous.summary || points != previous.keyPoints else { return nil }
        updated.keyPoints = points
        if !result.title.isEmpty { updated.title = result.title }
        updated.corrections += result.corrections
        updated.coveredTo = utterances.last?.end ?? previous.coveredTo
        updated.utteranceCount += utterances.count
        updated.modelSeconds = Date().timeIntervalSince(started)
        updated.verbatimShare = result.verbatimShare
        return updated
    }

    // MARK: - Window 9 postprocessing

    private var processor: SummaryPostprocessor {
        var configuration = PostprocessingConfiguration.standard
        configuration.keptCopyMaximumWords = validator.keptCopyMaximumWords
        configuration.maximumKeptCopies = validator.maximumKeptCopies
        configuration.copiedMinimumWords = validator.copiedMinimumWords
        configuration.verbatimRun = validator.verbatimRun
        configuration.maximumVerbatimShare = policy.maximumVerbatimShare
        return SummaryPostprocessor(configuration: configuration)
    }

    /// The draft after the Window 9 checks (normalization, claim-level grounding, copy limits,
    /// quality editing), with the restating of copied statements and the optional verification
    /// of the statements the checks could not decide. In memory; nothing is stored here.
    private func postprocessed(_ draft: RecapDraft, lines: [String]) async -> PostprocessingOutput {
        let text = DraftText(title: draft.title, summary: draft.summary, keyPoints: draft.keyPoints)
        var output = processor.process(text, transcriptLines: lines)
        output = await restating(output) { restatements in processor.process(text, transcriptLines: lines, restatements: restatements) }
        return await verified(output, lines: lines)
    }

    /// Copies longer than the kept limit are restated by the model (a few, within a time limit)
    /// and the draft is checked again with the answers.
    private func restating(_ first: PostprocessingOutput, recheck: ([String: String]) -> PostprocessingOutput) async
        -> PostprocessingOutput
    {
        guard !first.copiedNeedingRestatement.isEmpty, policy.maximumRestatements > 0 else { return first }
        var restatements: [String: String] = [:]
        let deadline = Date().addingTimeInterval(policy.restateTimeout)
        for statement in first.copiedNeedingRestatement.prefix(policy.maximumRestatements) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.5, !Task.isCancelled else { break }
            if let restated = try? await withTimeout(seconds: remaining, { [summarizer] in try await summarizer.restate(statement) }) {
                restatements[statement] = restated
            }
        }
        return restatements.isEmpty ? first : recheck(restatements)
    }

    /// One model request for the statements the deterministic grounding left `uncertain`
    /// (when the policy asks for it). Statements without an answer stay unverified.
    private func verified(_ output: PostprocessingOutput, lines: [String]) async -> PostprocessingOutput {
        guard policy.verification == .uncertainOnly, !output.uncertainStatements.isEmpty, !lines.isEmpty else { return output }
        let statements = output.uncertainStatements
        guard let evidence = try? await withTimeout(seconds: policy.verificationTimeout, { [summarizer] in
            try await summarizer.evidence(for: statements, in: lines)
        }), evidence.count == statements.count else { return output }
        // A reading that rejects most statements is not believed (the model answered beside the point).
        var verdicts: [String: Bool] = [:]
        for (statement, item) in zip(statements, evidence) { verdicts[statement] = item.isSupported && item.lines.contains(where: lines.indices.contains) }
        let rejected = verdicts.values.count { !$0 }
        guard statements.count < 3 || Double(rejected) / Double(statements.count) < policy.groundingDistrustShare else { return output }
        return output.applying(verifierVerdicts: verdicts)
    }

    private func checked(_ output: PostprocessingOutput, draft: RecapDraft, excerpt: ConversationExcerpt, caveats: [String],
                         seconds: TimeInterval, rejected: inout [String]) -> ConversationRecap?
    {
        guard !output.exceedsPrivacyLimits else {
            rejected = output.corrections + ["too_much_verbatim"]
            return nil
        }
        let judged = output.statementCount - output.duplicateCount - output.fillerCount
        guard !output.summary.isEmpty,
              judged <= 0 || Double(output.removedCount) / Double(judged) <= policy.maximumRemovedShare
        else {
            rejected = output.corrections
            return nil
        }
        var recap = ConversationRecap(title: output.title.isEmpty ? Self.untitled : output.title, summary: output.summary,
                                      keyPoints: output.keyPoints, source: .languageModel, caveats: caveats,
                                      corrections: output.corrections, coveredFrom: excerpt.start, coveredTo: excerpt.end,
                                      utteranceCount: excerpt.utterances.count, modelSeconds: seconds)
        recap.verbatimShare = output.verbatimShare
        recap.engines = draft.engine.map { [$0] } ?? []
        recap.fallbackReason = draft.fallbackReason
        recap.unverifiedStatements = output.unverifiedStatements.count
        return recap
    }

    /// The model's complete updated recap, checked like a first recap against all the speech held,
    /// accepted only when it keeps what the earlier recap said (a value may disappear only where the
    /// new speech gave another value of the same kind).
    private func rewritten(_ previous: ConversationRecap, newLines: [String], earlierLines: [String]) async
        -> (output: PostprocessingOutput, engine: SummarizationEngineIdentity?)?
    {
        let earlier = RecapDraft(title: previous.title, summary: previous.summary, keyPoints: previous.keyPoints)
        let fresh = newLines.joined(separator: "\n")
        guard let draft = try? await withTimeout(seconds: policy.rewriteTimeout, { [summarizer] in
            try await summarizer.rewrite(previous: earlier, newTranscript: fresh)
        }) else { return nil }
        let lines = earlierLines + newLines
        let rewrittenText = DraftText(title: previous.title, summary: draft.summary, keyPoints: draft.keyPoints)
        var output = processor.process(rewrittenText, transcriptLines: lines)
        output = await restating(output) { restatements in
            processor.process(rewrittenText, transcriptLines: lines, restatements: restatements)
        }
        let judged = output.statementCount - output.duplicateCount - output.fillerCount
        guard !output.summary.isEmpty, !output.exceedsPrivacyLimits,
              judged <= 0 || Double(output.removedCount) / Double(judged) <= policy.maximumRemovedShare
        else { return nil }
        // Check each earlier statement's own slot and content. A new weekday elsewhere
        // cannot authorize dropping an unrelated deadline, person, location or task.
        let resolver = CorrectionResolver()
        let transcript = AnalyzedTranscript(lines: lines)
        let corrections = resolver.corrections(in: transcript)
        let after = (SummaryText.sentences(in: output.summary) + output.keyPoints).map { AnalyzedText($0) }
        for statement in SummaryText.sentences(in: previous.summary) + previous.keyPoints {
            let before = AnalyzedText(statement)
            let changed = resolver.supersededCorrection(for: before, corrections: corrections,
                                                       transcript: transcript, fromLine: earlierLines.count)
            let requiredValues = before.values.filter { value in
                guard let changed, let old = changed.oldValue else { return true }
                return !value.isCompatible(with: old)
            }
            let required = SummaryQualityEditor.signature(of: before)
            // Related rewritten statements may distribute the earlier facts, but words
            // from unrelated topics never provide retention evidence.
            let related = after.filter {
                !$0.contentStemSet.isDisjoint(with: before.contentStemSet)
                    && SummaryQualityEditor.signature(of: $0).isNegative == required.isNegative
            }
            let keptStems = related.reduce(into: Set<String>()) { $0.formUnion(SummaryQualityEditor.signature(of: $1).stems) }
            guard required.stems.isSubset(of: keptStems),
                  requiredValues.allSatisfy({ value in related.contains { $0.values.contains { $0.isCompatible(with: value) } } })
            else { return nil }
            if let changed {
                let current = resolver.finalValue(of: changed, in: corrections)
                guard related.contains(where: { $0.values.contains { $0.isCompatible(with: current) } }) else { return nil }
            }
        }
        output.title = previous.title
        return (output, draft.engine)
    }

    /// An update under Window 9: the model wrote only the addition; the postprocessor checks it
    /// against the new speech and merges it with the earlier recap (duplicates dropped, a value
    /// the new speech changed replaced, earlier facts never lost silently).
    private func mergedUpdate(_ previous: ConversationRecap, addition: RecapDraft, newUtterances: [BufferedUtterance],
                              earlierTranscript: String, started: Date) async -> ConversationRecap?
    {
        let newLines = newUtterances.map(\.text)
        let earlierLines = earlierTranscript.split(whereSeparator: \.isNewline).map(String.init)
        // Drafts of engines that still return the whole recap (earlier text first) are cut back to the addition.
        var addedSummary = addition.summary
        if addedSummary.hasPrefix(previous.summary) { addedSummary = String(addedSummary.dropFirst(previous.summary.count)) }
        let earlier = DraftText(title: previous.title, summary: previous.summary, keyPoints: previous.keyPoints)
        let added = DraftText(title: previous.title, summary: addedSummary.trimmingCharacters(in: .whitespacesAndNewlines),
                              keyPoints: addition.keyPoints)
        let processor = self.processor
        var output = processor.merge(earlier: earlier, addition: added, newLines: newLines, earlierLines: earlierLines)
        output = await restating(output) { restatements in
            processor.merge(earlier: earlier, addition: added, newLines: newLines, earlierLines: earlierLines, restatements: restatements)
        }
        var rewrittenBy: SummarizationEngineIdentity?
        if policy.rewriteTimeout > 0,
           output.corrections.contains(ReasonCode.earlierOutdatedKept.rawValue) || output.corrections.contains(ReasonCode.outdatedByNewSpeech.rawValue),
           let rewrite = await rewritten(previous, newLines: newLines, earlierLines: earlierLines)
        {
            output = rewrite.output
            output.corrections.append("rewritten_for_correction")
            rewrittenBy = rewrite.engine
        }
        output = await verified(output, lines: earlierLines + newLines)
        guard !output.summary.isEmpty, !output.exceedsPrivacyLimits else { return nil }
        let judged = output.statementCount - output.duplicateCount - output.fillerCount
        guard judged <= 0 || Double(output.removedCount) / Double(judged) <= policy.maximumRemovedShare else { return nil }
        // Nothing new was added: the earlier recap stays and the new utterances are offered again.
        guard output.summary != previous.summary || output.keyPoints != previous.keyPoints else { return nil }
        var updated = previous
        updated.summary = output.summary
        updated.keyPoints = output.keyPoints
        if !output.title.isEmpty { updated.title = output.title }
        updated.corrections += output.corrections
        updated.coveredTo = newUtterances.last?.end ?? previous.coveredTo
        updated.utteranceCount += newUtterances.count
        updated.modelSeconds = Date().timeIntervalSince(started)
        updated.verbatimShare = output.verbatimShare
        updated.unverifiedStatements = output.unverifiedStatements.count
        for engine in [addition.engine, rewrittenBy].compactMap(\.self) where !updated.engines.contains(engine) { updated.engines.append(engine) }
        if updated.fallbackReason == nil { updated.fallbackReason = addition.fallbackReason }
        return updated
    }

    /// The draft after the checks. A statement that repeats a spoken sentence word for word is
    /// given back to the model to be restated, and the draft is checked again with the answers.
    /// All of this happens in memory: nothing is shown or stored before the checks have passed.
    private func validated(_ draft: RecapDraft, transcript: String, earlierText: String) async -> RecapValidator.Result {
        // Before any check: the narration ("Someone said …") and the stutters of speech
        // ("tomorrow, tomorrow") are taken out, so that what is checked is what is kept.
        let draft = RecapDraft(title: draft.title,
                               summary: RecapText.sentences(in: draft.summary).map(RecapText.tidied).joined(separator: " "),
                               keyPoints: draft.keyPoints.map(RecapText.tidied))
        let first = validator.validate(draft, transcript: transcript, earlierText: earlierText)
        guard !first.copied.isEmpty, policy.maximumRestatements > 0 else { return first }
        var restatements: [String: String] = [:]
        let deadline = Date().addingTimeInterval(policy.restateTimeout)
        for statement in first.copied.prefix(policy.maximumRestatements) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.5, !Task.isCancelled else { break }
            if let restated = try? await withTimeout(seconds: remaining, { [summarizer] in try await summarizer.restate(statement) }) {
                // Tidied like the draft, unless that would turn it back into the spoken sentence:
                // then the narrated form stays, because a saved summary never repeats a sentence
                // as it was said.
                let tidy = RecapText.tidied(restated)
                if !RecapText.isRun(RecapText.words(in: tidy), in: RecapText.words(in: statement)) {
                    restatements[statement] = tidy
                } else if RecapText.words(in: statement).count > validator.keptCopyMaximumWords {
                    // A long sentence is not kept as it was said: the narrated form stands in.
                    restatements[statement] = restated
                }
                // (A short one is kept as it is by the validator: no "Someone said that …".)
            }
        }
        guard !restatements.isEmpty else { return first }
        return validator.validate(draft, transcript: transcript, earlierText: earlierText, restatements: restatements)
    }

    /// Window 8: the reading check. The lexical checks cannot tell a statement that was said
    /// from one whose words were said ("Vic is a student in their family."); here the model is
    /// asked, in one request, which line of the transcript says each statement, and a statement
    /// it finds nowhere is left out. In memory, like the recap itself.
    private func grounded(_ result: RecapValidator.Result, transcript: String, known: Set<String>) async -> RecapValidator.Result {
        let sentences = RecapText.sentences(in: result.summary)
        var unique: [String] = []
        for statement in sentences + result.keyPoints where !known.contains(statement) && !unique.contains(statement) {
            unique.append(statement)
        }
        let statements = unique
        let lines = transcript.split(whereSeparator: \.isNewline).map(String.init)
        guard !statements.isEmpty, !lines.isEmpty, policy.groundingTimeout > 0,
              let evidence = try? await withTimeout(seconds: policy.groundingTimeout, { [summarizer] in
                  try await summarizer.evidence(for: statements, in: lines)
              }), evidence.count == statements.count
        else { return result }
        var problems: [String: String] = [:]
        for (statement, item) in zip(statements, evidence) {
            if let problem = validator.groundingProblem(statement, evidence: item, lines: lines) { problems[statement] = problem }
        }
        guard !problems.isEmpty else { return result }
        var result = result
        guard Double(problems.count) / Double(statements.count) < policy.groundingDistrustShare else {
            result.corrections.append("grounding_not_believed")
            return result
        }
        result.summary = sentences.filter { problems[$0] == nil }.joined(separator: " ")
        result.keyPoints = result.keyPoints.filter { problems[$0] == nil }
        result.removed += problems.count
        result.corrections += problems.values.sorted()
        result.verbatimShare = validator.verbatimShare(of: (RecapText.sentences(in: result.summary) + result.keyPoints).joined(separator: "\n"),
                                                       transcript: transcript)
        return result
    }

    private func checked(_ result: RecapValidator.Result, excerpt: ConversationExcerpt, caveats: [String],
                         seconds: TimeInterval, rejected: inout [String]) -> ConversationRecap?
    {
        guard result.verbatimShare <= policy.maximumVerbatimShare else {
            rejected = result.corrections + ["too_much_verbatim"]
            return nil
        }
        guard !result.summary.isEmpty,
              result.statements == 0 || Double(result.removed) / Double(result.statements) <= policy.maximumRemovedShare
        else {
            rejected = result.corrections
            return nil
        }
        var recap = ConversationRecap(title: result.title.isEmpty ? Self.untitled : result.title, summary: result.summary,
                                      keyPoints: result.keyPoints, source: .languageModel, caveats: caveats,
                                      corrections: result.corrections, coveredFrom: excerpt.start, coveredTo: excerpt.end,
                                      utteranceCount: excerpt.utterances.count, modelSeconds: seconds)
        recap.verbatimShare = result.verbatimShare
        return recap
    }

    /// The last check before a recap is written to storage, independent of how it was made:
    /// false when it repeats too much of the words it was written from. `transcript` is what
    /// the app still holds in memory; without it nothing can be compared and the earlier checks stand.
    public func maySave(_ recap: ConversationRecap, transcript: String) -> Bool {
        guard recap.isSummary else { return false }
        guard !transcript.isEmpty else { return true }
        let text = recap.summary + "\n" + recap.keyPoints.joined(separator: "\n")
        let lines = transcript.split(whereSeparator: \.isNewline).map(String.init)
        return validator.verbatimShare(of: text, transcript: transcript) <= policy.maximumVerbatimShare
            && !PrivacyCopyFilter().hasOverlongSourceRun(in: text, transcriptLines: lines)
    }

    /// No summary could be written. The raw transcript is deliberately not put in its place:
    /// a saved recap must never turn into a saved transcript.
    private func unavailable(_ excerpt: ConversationExcerpt, caveats: [String], seconds: TimeInterval,
                             correction: String? = nil) -> ConversationRecap
    {
        ConversationRecap(
            title: Self.untitled,
            summary: "A summary could not be written on this device right now. \(excerpt.utterances.count) utterances "
                + "(about \(excerpt.wordCount) words) were heard; they are shown below while the temporary transcript lasts.",
            source: .unavailable, caveats: caveats, corrections: correction.map { [$0] } ?? [],
            coveredFrom: excerpt.start, coveredTo: excerpt.end, utteranceCount: excerpt.utterances.count, modelSeconds: seconds)
    }

    private func withTimeout<Value: Sendable>(seconds: TimeInterval? = nil,
                                              _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value
    {
        let timeout = seconds ?? policy.timeout
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return seconds % 60 == 0 ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" : "\(seconds) seconds"
    }
}

/// Text helpers of the recap checks.
enum RecapText {
    /// A statement of a draft without the two habits that make a recap read like a transcript:
    ///
    /// - narration: "Someone said that the lot reopens on Friday." → "The lot reopens on Friday."
    ///   Only openers that name no one ("someone", "a person", "the speaker"); "Maya said" and
    ///   "It was announced that" stay.
    /// - a word said twice in a row: "tomorrow, tomorrow, they meet" → "tomorrow, they meet".
    ///   Never numbers ("five five" can be part of a phone number), and without a comma only
    ///   ordinary lower-case words of four letters or more, so that "Walla Walla" and
    ///   "had had" stay as they are.
    ///
    /// Nothing else is changed, and no word is added.
    static func tidied(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.range(of: narrationOpener, options: [.regularExpression, .caseInsensitive]),
           match.lowerBound == text.startIndex
        {
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
                    guard word.count >= minimum, numberWords[lowered] == nil, lowered != "one", !keptDoubles.contains(lowered) else { continue }
                    text.replaceSubrange(range, with: word)
                    changed = true
                }
            }
            if !changed { break }
        }
        return text
    }

    /// `words` occur in `other` one after the other, without a gap.
    static func isRun(_ words: [String], in other: [String]) -> Bool {
        guard !words.isEmpty, words.count <= other.count else { return false }
        return (0...(other.count - words.count)).contains { Array(other[$0 ..< $0 + words.count]) == words }
    }

    private static let narrationOpener =
        #"^(someone|somebody|a person|one person|a speaker|one speaker|the speakers?|one of the speakers)\s+(also\s+)?"#
        + #"(said|says|mentioned|mentions|stated|states|noted|added|explained)\s+(that\s+)?"#

    /// Words that are doubled on purpose.
    private static let keptDoubles: Set<String> = ["that", "very", "really", "much", "many", "long", "more", "knock", "bye"]

    /// The words of a text, lower-cased. Text written without spaces between words (Chinese,
    /// Japanese, Thai …) is segmented by the system's tokenizer, so that "12 words", "a run of 6
    /// words" and "a sentence of 5 words" mean about the same in every language, also where a
    /// sentence mixes them ("明天和 Ms. Wang 开会").
    static func words(in text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
            .flatMap { $0.unicodeScalars.contains(where: isUnspaced) ? segmented($0) : [$0] }
    }

    /// Scripts that are written without spaces between words.
    static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80 ... 0x9FFF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2FA1F,  // Han, Kana, CJK symbols and radicals
             0xAC00 ... 0xD7AF,  // Hangul syllables
             0x0E00 ... 0x0EFF:  // Thai, Lao
            true
        default:
            false
        }
    }

    private static func segmented(_ run: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = run
        let tokens = tokenizer.tokens(for: run.startIndex ..< run.endIndex).map { String(run[$0]) }
        return tokens.isEmpty ? [run] : tokens
    }

    static func contentWords(in text: String) -> [String] { words(in: text).filter { !stopWords.contains($0) } }

    static func stem(_ word: String) -> String {
        var stem = word
        for suffix in ["ing", "ed", "es", "s"] where stem.count > suffix.count + 2 && stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        if stem.count > 3, stem.hasSuffix("e") { stem.removeLast() }
        return stem
    }

    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                // The system ends a sentence after "Ms." ("… the meeting with Ms." | "Wang takes
                // place …"); the two halves would be checked, and could be removed, separately.
                if let last = sentences.last, endsWithTitle(last) {
                    sentences[sentences.count - 1] = last + " " + sentence
                } else {
                    sentences.append(sentence)
                }
            }
        }
        return sentences
    }

    private static func endsWithTitle(_ text: String) -> Bool {
        guard let word = text.split(separator: " ").last else { return false }
        return titles.contains(word.lowercased())
    }

    private static let titles: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "mt.", "vs.", "jr.", "sr."]

    /// Numbers (digits or words), days and times of day, normalized so "3" and "three" agree.
    static func quantities(in text: String) -> Set<String> {
        Set(words(in: text).compactMap { word in
            if let value = numberWords[word] { return String(value) }
            if word.contains(where: \.isNumber) {
                let digits = word.filter { $0.isNumber || $0 == "." }
                // "三点" and "3点", "十二" and "12" are the same number.
                return hanNumber(digits).map(String.init) ?? digits
            }
            return quantityWords.contains(word) ? word : nil
        })
    }

    /// A number written with Chinese numerals, up to 99; nil for anything else.
    static func hanNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = ["〇": 0, "零": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7,
                                        "八": 8, "九": 9]
        let characters = Array(text)
        guard !characters.isEmpty, characters.allSatisfy({ digits[$0] != nil || $0 == "十" }) else { return nil }
        guard let ten = characters.firstIndex(of: "十") else {
            return characters.count == 1 ? digits[characters[0]] : nil
        }
        guard characters.filter({ $0 == "十" }).count == 1, ten <= 1, characters.count - ten <= 2 else { return nil }
        let tens = ten == 0 ? 1 : (digits[characters[0]] ?? 1)
        let ones = ten + 1 < characters.count ? (digits[characters[ten + 1]] ?? 0) : 0
        return tens * 10 + ones
    }

    /// Capitalized words that are not at the start of a sentence and not ordinary words: a
    /// rough test for names.
    static func names(in text: String) -> Set<String> {
        var names: Set<String> = []
        for sentence in sentences(in: text) {
            let tokens = sentence.split { !($0.isLetter || $0 == "'") }.map(String.init)
            for (index, token) in tokens.enumerated() where index > 0 {
                guard let first = token.first, first.isUppercase, token.count > 1 else { continue }
                let lowered = token.lowercased()
                if stopWords.contains(lowered) || quantityWords.contains(lowered) || lowered == "i" || lowered.hasPrefix("i'") { continue }
                names.insert(lowered)
            }
        }
        return names
    }

    /// How many denying words the text has.
    static func negations(in text: String) -> Int {
        words(in: text).count { word in
            negationWords.contains(word) || word.hasSuffix("n't")
                || (word.unicodeScalars.contains(where: isUnspaced) && word.contains(where: { "不没沒未别別无無非".contains($0) }))
        }
    }

    /// Every capitalized word, wherever it stands (lowercased).
    static func capitalizedWords(in text: String) -> [String] {
        text.split { !($0.isLetter || $0 == "'") }.filter { $0.first?.isUppercase == true && $0.count > 1 }.map { $0.lowercased() }
    }

    /// Capitalized first words of reported speech that are not names.
    static let reportingOpeners: Set<String> = ["somebody", "everyone", "everybody", "anyone", "nobody", "apparently", "reportedly"]

    static let negationWords: Set<String> = ["not", "no", "never", "cannot", "nobody", "nothing", "none", "neither", "nor", "without"]

    static let numberWords: [String: Int] = [
        "zero": 0, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1000,
    ]

    static let quantityWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tonight", "tomorrow",
        "yesterday", "noon", "midnight", "half", "twice", "double", "january", "february", "march", "april", "june",
        "july", "august", "september", "october", "november", "december",
        "今天", "明天", "后天", "後天", "昨天", "今晚", "明晚", "上午", "下午", "中午", "晚上", "早上", "周一", "周二", "周三", "周四", "周五",
        "周六", "周日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日", "星期天", "礼拜一", "礼拜二", "礼拜三", "礼拜四",
        "礼拜五", "礼拜六", "礼拜天",
    ]

    static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "am", "has", "have", "had", "will", "would",
        "do", "does", "did", "to", "of", "in", "on", "at", "for", "and", "or", "but", "it", "its", "it's", "this", "that",
        "these", "those", "there", "here", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my",
        "your", "our", "their", "his", "so", "as", "by", "with", "from", "about", "if", "then", "than", "can", "could",
        "should", "may", "might", "what", "who", "when", "where", "why", "how", "which", "not", "no", "also", "because",
        "after", "before", "into", "over", "up", "out", "one", "someone", "speaker", "speakers", "person", "people",
        "conversation", "said", "says", "say", "mentioned", "mentions", "discussed", "discuss", "talked", "asked",
        "explained", "noted", "added", "another", "other", "they're", "there's", "that's", "group", "plan", "plans",
    ]
}
