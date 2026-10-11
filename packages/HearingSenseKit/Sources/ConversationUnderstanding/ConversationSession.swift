import Foundation

/// Where a requested recap or a continued session stands.
public enum ConversationPhase: String, Hashable, Sendable, Codable {
    /// Nothing requested. Ordinary listening.
    case idle
    /// The Action Button was pressed: the recent conversation is being cut out of the buffer.
    case preparing
    /// The language model is writing the recap.
    case summarizing
    /// The recap is saved and shown; "Continue understanding" is on offer.
    case summaryAvailable
    /// The user chose to keep following: live captions and incremental summaries.
    case continuing
}

/// What the Dynamic Island can say about it. Generic words only: never speech-derived text.
public enum ConversationStatus: String, Hashable, Sendable, Codable, CaseIterable {
    case preparingRecap, summarizing, summaryAvailable, summarySaved, continuing, stopped, unavailable

    public var title: String {
        switch self {
        case .preparingRecap: "Preparing Recap"
        case .summarizing: "Summarizing"
        case .summaryAvailable: "Summary Available"
        case .summarySaved: "Summary Saved"
        case .continuing: "Following Conversation"
        case .stopped: "Stopped Following"
        case .unavailable: "Recap Unavailable"
        }
    }

    public var symbolName: String {
        switch self {
        case .preparingRecap: "clock.arrow.circlepath"
        case .summarizing: "ellipsis.bubble"
        case .summaryAvailable: "text.bubble"
        case .summarySaved: "checkmark.circle"
        case .continuing: "captions.bubble"
        case .stopped: "stop.circle"
        case .unavailable: "exclamationmark.bubble"
        }
    }
}

/// Why a recap cannot be made right now.
public enum RecapUnavailableReason: String, Hashable, Sendable, Codable {
    /// Hearing Sense is not listening.
    case notListening
    /// The user has not allowed temporary speech context (or transcription is off).
    case contextNotAllowed

    public var message: String {
        switch self {
        case .notListening: "Hearing Sense is not listening. Start listening first."
        case .contextNotAllowed: "Recaps need “Keep recent speech for recaps” to be on."
        }
    }
}

public enum ConversationInput: Hashable, Sendable {
    /// The Action Button shortcut (or the button in the app).
    case actionInvoked(at: Date)
    /// The excerpt was cut out; the model starts.
    case excerptReady(at: Date)
    case recapReady(ConversationRecap, at: Date)
    case continueSelected(at: Date)
    /// "Stop" in the app. Same as pressing the Action Button while continuing.
    case stopSelected(at: Date)
    /// A final utterance arrived (its text is not kept here: only its size and time).
    case utterance(meaningfulWords: Int, end: Date)
    /// An incremental summary finished; nil when nothing changed or it could not be made.
    case updateFinished(ConversationRecap?, at: Date)
    case listeningStopped(at: Date)
    /// The user switched temporary speech context or transcription off.
    case contextRevoked(at: Date)
    case tick(at: Date)

    public var date: Date {
        switch self {
        case .actionInvoked(let date), .excerptReady(let date), .continueSelected(let date), .stopSelected(let date),
             .listeningStopped(let date), .contextRevoked(let date), .tick(let date):
            date
        case .recapReady(_, let date), .updateFinished(_, let date): date
        case .utterance(_, let end): end
        }
    }
}

public enum ConversationEffect: Hashable, Sendable {
    /// Cut the excerpt out of the buffer and ask the recap engine.
    case generateRecap
    /// Abandon a recap or an update that is being written.
    case cancelWork
    /// Store the recap (insert, or replace the record of this session).
    case save(ConversationRecap, isContinuing: Bool)
    /// Ask the recap engine to extend the saved recap with what was said after `since`.
    case requestUpdate(since: Date)
    /// The continued session is over: mark the record completed.
    case finalize
    /// Delete the temporary speech context now (it starts collecting again while listening goes on).
    case clearTemporaryContext
    /// What to show; `until` nil means until the next status.
    case status(ConversationStatus?, until: Date?)
    case unavailable(RecapUnavailableReason)
}

public struct ConversationSessionPolicy: Hashable, Sendable {
    /// How long "Continue understanding" stays on offer; afterwards the next press is a new recap.
    public var continueOffer: TimeInterval = 90
    /// How long "Summary Saved" and "Stopped Following" are shown.
    public var notice: TimeInterval = 8
    /// While continuing: an update is asked for after a pause this long, when something new was said.
    public var quietBeforeUpdate: TimeInterval = 6
    /// Updates are at least this far apart.
    public var minimumUpdateInterval: TimeInterval = 20
    /// Fewer new meaningful words than this are not worth an update.
    public var minimumNewWords = 6
    /// New speech is summarized at the latest after this long, pause or not (it must happen
    /// before the buffer lets the text expire).
    public var maximumPendingAge: TimeInterval = 75
    /// A continued session ends by itself after this long.
    public var maximumContinuedDuration: TimeInterval = 30 * 60

    public init() {}

    public static let standard = ConversationSessionPolicy()
}

/// The state machine behind the Action Button (Window 6).
///
/// First press: recap of the recent conversation, saved, with "Continue understanding" on
/// offer. If the user continues: live captions in the app and incremental summaries, written
/// only when something new was said. Next press: stop, finalize the saved summary, delete the
/// temporary context.
///
/// A value type without a clock, a model or storage: inputs carry their time and the host
/// carries out the returned effects. The same inputs give the same effects.
public struct ConversationSessionMachine: Sendable {
    public let policy: ConversationSessionPolicy
    public private(set) var phase = ConversationPhase.idle
    public private(set) var isListening = false
    public private(set) var isContextAllowed = false
    /// The recap of the current session, as last saved.
    public private(set) var recap: ConversationRecap?
    public private(set) var continuedSince: Date?
    public private(set) var updatesMade = 0
    public private(set) var updatesSkipped = 0

    private var offerEnds: Date?
    private var noticeEnds: Date?
    private var pendingWords = 0
    private var firstPending: Date?
    private var lastUtterance: Date?
    private var lastUpdateRequest: Date?
    private var updateInFlight = false
    private var coveredTo: Date?

    public init(policy: ConversationSessionPolicy = .standard) {
        self.policy = policy
    }

    public mutating func setListening(_ isListening: Bool) { self.isListening = isListening }
    public mutating func setContextAllowed(_ isAllowed: Bool) { isContextAllowed = isAllowed }

    public var isUpdateInFlight: Bool { updateInFlight }

    @discardableResult
    public mutating func process(_ input: ConversationInput) -> [ConversationEffect] {
        let now = input.date
        switch input {
        case .actionInvoked:
            switch phase {
            case .continuing:
                return stop(at: now, status: .stopped)
            case .preparing, .summarizing:
                return []  // already working on it
            case .idle, .summaryAvailable:
                guard isListening else { return [.unavailable(.notListening), .status(.unavailable, until: now + policy.notice)] }
                guard isContextAllowed else { return [.unavailable(.contextNotAllowed), .status(.unavailable, until: now + policy.notice)] }
                phase = .preparing
                recap = nil
                offerEnds = nil
                noticeEnds = nil
                return [.status(.preparingRecap, until: nil), .generateRecap]
            }

        case .excerptReady:
            guard phase == .preparing else { return [] }
            phase = .summarizing
            return [.status(.summarizing, until: nil)]

        case .recapReady(let ready, _):
            guard phase == .preparing || phase == .summarizing else { return [] }
            phase = .summaryAvailable
            recap = ready
            coveredTo = ready.coveredTo ?? now
            offerEnds = now + policy.continueOffer
            noticeEnds = now + policy.notice
            // Saved at once, then on offer: the island says "saved" briefly and "available" after.
            return [.save(ready, isContinuing: false), .status(.summarySaved, until: noticeEnds)]

        case .continueSelected:
            guard phase == .summaryAvailable, let recap, isListening, isContextAllowed else { return [] }
            phase = .continuing
            continuedSince = now
            offerEnds = nil
            noticeEnds = nil
            pendingWords = 0
            firstPending = nil
            lastUpdateRequest = now
            updateInFlight = false
            return [.save(recap, isContinuing: true), .status(.continuing, until: nil)]

        case .stopSelected:
            guard phase == .continuing else { return [] }
            return stop(at: now, status: .stopped)

        case .utterance(let words, let end):
            guard phase == .continuing, words > 0 else { return [] }
            pendingWords += words
            if firstPending == nil { firstPending = end }
            lastUtterance = end
            return updateIfDue(at: now)

        case .updateFinished(let updated, _):
            guard phase == .continuing else { return [] }
            updateInFlight = false
            guard let updated else {
                updatesSkipped += 1
                return updateIfDue(at: now)
            }
            updatesMade += 1
            recap = updated
            coveredTo = updated.coveredTo ?? coveredTo
            return [.save(updated, isContinuing: true)] + updateIfDue(at: now)

        case .listeningStopped:
            isListening = false
            return interrupt(at: now)

        case .contextRevoked:
            isContextAllowed = false
            return interrupt(at: now)

        case .tick:
            var effects: [ConversationEffect] = []
            if phase == .continuing {
                if let since = continuedSince, now.timeIntervalSince(since) >= policy.maximumContinuedDuration {
                    return stop(at: now, status: .stopped)
                }
                effects += updateIfDue(at: now)
            }
            if phase == .summaryAvailable {
                if let ends = noticeEnds, now >= ends {
                    noticeEnds = nil
                    effects.append(.status(.summaryAvailable, until: offerEnds))
                }
                if let ends = offerEnds, now >= ends {
                    phase = .idle
                    offerEnds = nil
                    effects.append(.status(nil, until: nil))
                }
            } else if phase == .idle, let ends = noticeEnds, now >= ends {
                noticeEnds = nil
                effects.append(.status(nil, until: nil))
            }
            return effects
        }
    }

    /// The next time `.tick` changes something.
    public var nextDeadline: Date? {
        var deadlines = [noticeEnds, offerEnds].compactMap(\.self)
        if phase == .continuing {
            if let since = continuedSince { deadlines.append(since + policy.maximumContinuedDuration) }
            if pendingWords > 0, !updateInFlight {
                if let last = lastUtterance { deadlines.append(max(last + policy.quietBeforeUpdate, earliestUpdate)) }
                if let first = firstPending { deadlines.append(first + policy.maximumPendingAge) }
            }
        }
        return deadlines.min()
    }

    private var earliestUpdate: Date {
        (lastUpdateRequest ?? .distantPast) + policy.minimumUpdateInterval
    }

    /// Something new was said, the speakers paused (or the text is getting old), and the last
    /// update is long enough ago: ask for one. Nothing new: no update, however long it lasts.
    private mutating func updateIfDue(at now: Date) -> [ConversationEffect] {
        guard phase == .continuing, !updateInFlight, pendingWords > 0, let first = firstPending else { return [] }
        let isOld = now.timeIntervalSince(first) >= policy.maximumPendingAge
        let isPaused = lastUtterance.map { now.timeIntervalSince($0) >= policy.quietBeforeUpdate } ?? false
        guard isOld || (pendingWords >= policy.minimumNewWords && isPaused && now >= earliestUpdate) else { return [] }
        guard pendingWords >= policy.minimumNewWords || isOld else { return [] }
        if pendingWords < policy.minimumNewWords {
            // Too little to summarize even after waiting: drop it rather than ask the model.
            pendingWords = 0
            firstPending = nil
            return []
        }
        let since = coveredTo ?? first
        updateInFlight = true
        lastUpdateRequest = now
        pendingWords = 0
        firstPending = nil
        return [.requestUpdate(since: since)]
    }

    private mutating func stop(at now: Date, status: ConversationStatus) -> [ConversationEffect] {
        let wasWorking = updateInFlight
        phase = .idle
        continuedSince = nil
        updateInFlight = false
        pendingWords = 0
        firstPending = nil
        offerEnds = nil
        noticeEnds = now + policy.notice
        return (wasWorking ? [.cancelWork] : []) + [.finalize, .clearTemporaryContext, .status(status, until: noticeEnds)]
    }

    /// Listening stopped or the permission was withdrawn: whatever is in progress ends, and the
    /// temporary context goes.
    private mutating func interrupt(at now: Date) -> [ConversationEffect] {
        switch phase {
        case .continuing:
            return stop(at: now, status: .stopped)
        case .preparing, .summarizing:
            phase = .idle
            return [.cancelWork, .clearTemporaryContext, .status(nil, until: nil)]
        case .summaryAvailable:
            phase = .idle
            offerEnds = nil
            noticeEnds = nil
            return [.clearTemporaryContext, .status(nil, until: nil)]
        case .idle:
            return [.clearTemporaryContext]
        }
    }
}

/// How many words of an utterance say something (fillers and backchannel do not count), so that
/// "yeah", "okay", "mm-hm" never cause a new summary.
public enum MeaningfulWords {
    static let fillers: Set<String> = [
        "yeah", "yes", "yep", "no", "nope", "ok", "okay", "right", "sure", "uh", "um", "hmm", "mm", "mhm", "huh", "oh",
        "ah", "well", "so", "like", "thanks", "thank", "you", "cool", "nice", "great", "good", "fine", "alright", "wow",
        "really", "i", "see", "know", "mean", "and", "but", "the", "a", "it", "that", "is", "it's", "that's", "true",
        "exactly", "totally", "bye", "hi", "hello", "hm", "yup", "got", "gotcha",
    ]

    public static func count(in text: String) -> Int {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.count { !fillers.contains(String($0)) }
    }
}
