import Foundation

/// A recap as the language model wrote it, before checking. Untrusted.
public struct RecapDraft: Hashable, Sendable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]

    public init(title: String, summary: String, keyPoints: [String] = []) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
    }
}

/// A language model that writes recaps. Production: `FoundationModelRecapSummarizer`.
public protocol ConversationSummarizing: Sendable {
    func isAvailable() async -> Bool
    func prewarm() async
    /// A recap of the excerpt.
    func recap(transcript: String, notes: [String]) async throws -> RecapDraft
    /// The earlier recap, extended by what was said since. Earlier details must be kept.
    func update(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft
}

/// A checked recap, ready to show and to save.
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
    /// sentence of the transcript is a copy, not a summary, and is removed — a saved summary
    /// must never turn into a saved transcript. (Found in the Simulator: asked to extend a
    /// recap, the on-device model appended the three new utterances unchanged, and every other
    /// check passed them, because a copy is fully supported by its source.) A summary still
    /// uses the speakers' words; this only stops whole sentences from being stored as they
    /// were said.
    public var copiedMinimumWords: Int

    public init(minimumSupport: Double = 0.5, copiedMinimumWords: Int = 5) {
        self.minimumSupport = minimumSupport
        self.copiedMinimumWords = copiedMinimumWords
    }

    public struct Result: Hashable, Sendable {
        public var summary: String
        public var keyPoints: [String]
        public var title: String
        public var corrections: [String]
        /// Sentences and key points checked, and how many were removed.
        public var statements: Int
        public var removed: Int
    }

    public func validate(_ draft: RecapDraft, transcript: String, earlierText: String = "") -> Result {
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

        func problem(in statement: String) -> String? {
            let words = RecapText.words(in: statement)
            if words.count >= copiedMinimumWords, spoken.contains(words) { return "copied_from_transcript" }
            let quantities = RecapText.quantities(in: statement)
            if !quantities.isSubset(of: sourceQuantities) { return "unsupported_number_or_time" }
            if !RecapText.names(in: statement).isSubset(of: sourceNames) { return "unsupported_name" }
            let content = RecapText.contentWords(in: statement).map(RecapText.stem)
            if content.count >= 3 {
                let supported = content.count(where: sourceStems.contains)
                if Double(supported) / Double(content.count) < minimumSupport { return "unsupported_statement" }
            }
            return nil
        }

        var kept: [String] = []
        for sentence in RecapText.sentences(in: draft.summary) {
            statements += 1
            if let issue = problem(in: sentence) {
                removed += 1
                corrections.append(issue)
            } else {
                kept.append(sentence)
            }
        }
        var points: [String] = []
        for point in draft.keyPoints.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !point.isEmpty {
            statements += 1
            if let issue = problem(in: point) {
                removed += 1
                corrections.append(issue)
            } else if !points.contains(point) {
                points.append(point)
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
        return Result(summary: kept.joined(separator: " "), keyPoints: points, title: title, corrections: corrections,
                      statements: statements, removed: removed)
    }
}

/// Writes recaps of the recent conversation and extends them while the user keeps following.
public struct ConversationRecapEngine: Sendable {
    public struct Policy: Hashable, Sendable {
        public var timeout: TimeInterval = 25
        /// A recap from which the checks removed more than this share is not shown as a summary.
        public var maximumRemovedShare = 0.5
        /// Words of transcript sent to the model at most (the newest are kept).
        public var maximumTranscriptWords = 900
        /// Missing speech longer than this in total is mentioned in the recap.
        public var missingSpeechNotice: TimeInterval = 6

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
        if let recap = checked(draft, transcript: text, earlier: "", excerpt: excerpt, caveats: caveats,
                               seconds: Date().timeIntervalSince(started), rejected: &rejected)
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
        guard await summarizer.isAvailable(), let draft = try? await withTimeout({ [summarizer] in
            try await summarizer.update(previous: earlier, newTranscript: fresh)
        }) else { return nil }
        // Earlier text counts as support: the update may restate what the first recap said.
        let result = validator.validate(draft, transcript: fresh + "\n" + earlierTranscript, earlierText: previous.fullText)
        guard !result.summary.isEmpty,
              result.statements == 0 || Double(result.removed) / Double(result.statements) <= policy.maximumRemovedShare
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
        return updated
    }

    private func checked(_ draft: RecapDraft, transcript: String, earlier: String, excerpt: ConversationExcerpt,
                         caveats: [String], seconds: TimeInterval, rejected: inout [String]) -> ConversationRecap?
    {
        let result = validator.validate(draft, transcript: transcript, earlierText: earlier)
        guard !result.summary.isEmpty,
              result.statements == 0 || Double(result.removed) / Double(result.statements) <= policy.maximumRemovedShare
        else {
            rejected = result.corrections
            return nil
        }
        return ConversationRecap(title: result.title.isEmpty ? Self.untitled : result.title, summary: result.summary,
                                 keyPoints: result.keyPoints, source: .languageModel, caveats: caveats,
                                 corrections: result.corrections, coveredFrom: excerpt.start, coveredTo: excerpt.end,
                                 utteranceCount: excerpt.utterances.count, modelSeconds: seconds)
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

    private func withTimeout<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let timeout = policy.timeout
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
    static func words(in text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
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
                sentences.append(sentence)
            }
        }
        return sentences
    }

    /// Numbers (digits or words), days and times of day, normalized so "3" and "three" agree.
    static func quantities(in text: String) -> Set<String> {
        Set(words(in: text).compactMap { word in
            if let value = numberWords[word] { return String(value) }
            if word.contains(where: \.isNumber) { return word.filter { $0.isNumber || $0 == "." } }
            return quantityWords.contains(word) ? word : nil
        })
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
