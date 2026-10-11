import Foundation

/// One finalized utterance held for a possible recap. Speech-derived: temporary, in memory only.
public struct BufferedUtterance: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    /// When the utterance began and ended (wall clock).
    public var start: Date
    public var end: Date
    /// The recognizer rated its own output as poor.
    public var isLowQuality: Bool

    public init(id: UUID = UUID(), text: String, start: Date, end: Date, isLowQuality: Bool = false) {
        self.id = id
        self.text = text
        self.start = start
        self.end = max(end, start)
        self.isLowQuality = isLowQuality
    }

    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

/// A stretch of time inside the excerpt for which no speech text exists although speech was
/// probably going on (the recognizer failed, or speech was detected but not transcribed).
public struct MissingSpeech: Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// What a recap is made from: the recent conversation, cut at a meaningful boundary.
public struct ConversationExcerpt: Hashable, Sendable {
    /// Oldest first.
    public var utterances: [BufferedUtterance]
    public var missing: [MissingSpeech]
    /// The requested look-back window.
    public var windowStart: Date
    public var windowEnd: Date
    /// Older speech inside the window was left out because a pause separated it from this conversation.
    public var startsAtBoundary: Bool
    /// The buffer did not reach back to the start of the window (listening began later, or text
    /// had already expired): the recap may miss the beginning.
    public var isTruncatedAtStart: Bool

    public var wordCount: Int { utterances.reduce(0) { $0 + $1.wordCount } }
    public var start: Date? { utterances.first?.start }
    public var end: Date? { utterances.last?.end }
    public var lowQualityShare: Double {
        utterances.isEmpty ? 0 : Double(utterances.count(where: \.isLowQuality)) / Double(utterances.count)
    }

    public var missingDuration: TimeInterval { missing.reduce(0) { $0 + $1.duration } }
}

/// Rules of the rolling buffer.
public struct ConversationBufferPolicy: Hashable, Sendable {
    /// How far back a recap looks. The user's setting; two minutes by default.
    public var lookBack: TimeInterval
    /// Text older than this is deleted. A little longer than `lookBack`, so that a recap asked
    /// for at the end of a sentence still reaches back the full window.
    public var retention: TimeInterval
    /// A pause this long between utterances separates two conversations.
    public var boundaryGap: TimeInterval
    /// A recap needs at least this many words; below it the app says that there is not enough.
    public var minimumWords: Int
    /// Hard bounds, whatever the timing.
    public var maximumUtterances: Int
    public var maximumCharacters: Int

    public init(lookBack: TimeInterval = 120, retention: TimeInterval? = nil, boundaryGap: TimeInterval = 25,
                minimumWords: Int = 8, maximumUtterances: Int = 80, maximumCharacters: Int = 6000)
    {
        self.lookBack = lookBack
        self.retention = retention ?? lookBack + 15
        self.boundaryGap = boundaryGap
        self.minimumWords = minimumWords
        self.maximumUtterances = maximumUtterances
        self.maximumCharacters = maximumCharacters
    }

    public static let standard = ConversationBufferPolicy()
    public static let lookBackChoices: [TimeInterval] = [60, 120, 180, 300]
}

/// The temporary speech context behind "what was just said?" (Window 6).
///
/// A value type without a clock: every call carries its time. It holds finalized utterances of
/// an authorized transcription session, bounded in age, count and size. It is filled only while
/// the user has allowed the app to keep temporary speech context; `clear` empties it when that
/// permission is withdrawn, when listening stops and when a continued session ends. Nothing
/// here is written to disk.
public struct RollingConversationBuffer: Sendable {
    public private(set) var policy: ConversationBufferPolicy
    public private(set) var utterances: [BufferedUtterance] = []
    public private(set) var missing: [MissingSpeech] = []
    /// When the buffer started collecting (the session start, or the last `clear`).
    public private(set) var collectingSince: Date?
    /// The newest words that are not final yet (live captions only; never part of a recap).
    public private(set) var tentative: String?
    public private(set) var expiredUtterances = 0

    public init(policy: ConversationBufferPolicy = .standard) {
        self.policy = policy
    }

    public var isEmpty: Bool { utterances.isEmpty && tentative == nil }
    public var characterCount: Int { utterances.reduce(0) { $0 + $1.text.count } }

    public mutating func setPolicy(_ policy: ConversationBufferPolicy, now: Date) {
        self.policy = policy
        prune(now: now)
    }

    /// Collection begins (a listening session with temporary speech context allowed).
    public mutating func begin(at date: Date) {
        clear()
        collectingSince = date
    }

    public mutating func append(_ utterance: BufferedUtterance, now: Date) {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collectingSince != nil, !text.isEmpty else { return }
        // The recognizer can deliver the same final text twice.
        if let last = utterances.last, last.text == text, utterance.start.timeIntervalSince(last.end) < 2 { return }
        var stored = utterance
        stored.text = text
        utterances.append(stored)
        utterances.sort { $0.start < $1.start }
        tentative = nil
        prune(now: now)
    }

    public mutating func setTentative(_ text: String?) {
        guard collectingSince != nil else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        tentative = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Speech was going on but produced no text (recognizer failure, speech judged unclear).
    public mutating func noteMissingSpeech(from start: Date, to end: Date, now: Date) {
        guard collectingSince != nil, end > start else { return }
        if var last = missing.last, start.timeIntervalSince(last.end) < 1 {
            last.end = max(last.end, end)
            missing[missing.count - 1] = last
        } else {
            missing.append(MissingSpeech(start: start, end: end))
        }
        prune(now: now)
    }

    /// Deletes what is older than the retention time or beyond the bounds. Call it with every
    /// input and on a timer, so text expires even when nobody speaks.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.retention)
        let before = utterances.count
        utterances.removeAll { $0.end < cutoff }
        missing.removeAll { $0.end < cutoff }
        while utterances.count > policy.maximumUtterances { utterances.removeFirst() }
        while characterCount > policy.maximumCharacters, utterances.count > 1 { utterances.removeFirst() }
        expiredUtterances += before - utterances.count
    }

    /// The next time `prune` would delete something.
    public var nextExpiry: Date? {
        ([utterances.first?.end, missing.first?.end].compactMap(\.self).min()).map { $0.addingTimeInterval(policy.retention) }
    }

    /// Deletes everything.
    public mutating func clear() {
        utterances.removeAll()
        missing.removeAll()
        tentative = nil
        collectingSince = nil
    }

    /// The conversation that is going on now, or that ended last, within the look-back window.
    ///
    /// Boundaries are pauses: walking back from the newest utterance, the excerpt stops at the
    /// first pause of `boundaryGap` or more. An older conversation in the same two minutes is
    /// left out, because a recap that mixes two conversations misleads.
    public func excerpt(now: Date, lookBack: TimeInterval? = nil) -> ConversationExcerpt {
        let windowStart = now.addingTimeInterval(-(lookBack ?? policy.lookBack))
        let inWindow = utterances.filter { $0.end >= windowStart && $0.start <= now }
        var selected: [BufferedUtterance] = []
        var startsAtBoundary = false
        for utterance in inWindow.reversed() {
            if let next = selected.first, next.start.timeIntervalSince(utterance.end) >= policy.boundaryGap {
                startsAtBoundary = true
                break
            }
            selected.insert(utterance, at: 0)
        }
        let from = selected.first?.start ?? windowStart
        let gaps = missing.filter { $0.end >= from && $0.start <= now }
        // Truncated: collection began inside the window and the first utterance starts right
        // then, so the conversation was probably already going on.
        let isTruncated: Bool = {
            guard !startsAtBoundary, let first = selected.first, let since = collectingSince else { return false }
            return since > windowStart && first.start.timeIntervalSince(since) < 3
        }()
        return ConversationExcerpt(utterances: selected, missing: gaps, windowStart: windowStart, windowEnd: now,
                                   startsAtBoundary: startsAtBoundary, isTruncatedAtStart: isTruncated)
    }

    /// Whether an excerpt is enough for a recap.
    public func isSufficient(_ excerpt: ConversationExcerpt) -> Bool {
        excerpt.wordCount >= policy.minimumWords
    }

    /// Final utterances that ended after `date` (for incremental summaries).
    public func utterances(after date: Date) -> [BufferedUtterance] {
        utterances.filter { $0.end > date }
    }

    /// Every place where one conversation ends and the next begins, by the pause rule.
    public func boundaries() -> [Date] {
        zip(utterances, utterances.dropFirst()).compactMap { earlier, later in
            later.start.timeIntervalSince(earlier.end) >= policy.boundaryGap ? later.start : nil
        }
    }
}
