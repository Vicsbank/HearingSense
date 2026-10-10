import Foundation
import HearingSenseDomain

/// Everything the Live Activity presentation reacts to. Each input carries its own time; the
/// pipeline never reads the system clock.
public enum IslandInput: Hashable, Sendable {
    /// Listening started or resumed.
    case sessionStarted(at: Date)
    /// The microphone is off for now (interruption). The activity stays and shows "paused".
    case sessionPaused(at: Date)
    /// Listening stopped: the activity ends.
    case sessionEnded(at: Date)
    /// Window 2: a confirmed sound event started, changed or ended (the ambient channel).
    case sound(AcousticEventUpdate)
    /// Window 4: the attention engine wants an episode presented, changed or removed.
    case intent(AttentionPresentationIntent)
    case settings(IslandSettings, at: Date)
    /// Time passed (the host calls this at `IslandPipeline.nextDeadline`).
    case tick(at: Date)

    public var date: Date {
        switch self {
        case .sessionStarted(let date), .sessionPaused(let date), .sessionEnded(let date), .tick(let date): date
        case .settings(_, let date): date
        case .intent(let intent): intent.timestamp
        case .sound(let update): AmbientIconInput.sound(update).date
        }
    }
}

/// A request to let iOS expand the Dynamic Island. Whether it is honoured is decided by
/// `AlertGate` (never on a locked iPhone) and then by iOS. The texts are generic titles: an
/// alert never carries speech-derived text.
public struct IslandAlertRequest: Hashable, Sendable {
    public var title: String
    public var body: String
    public var priority: AttentionPriority

    public init(title: String, body: String, priority: AttentionPriority) {
        self.title = title
        self.body = body
        self.priority = priority
    }
}

/// What the host does with the one Live Activity.
public enum IslandCommand: Hashable, Sendable {
    case start(IslandContent)
    /// Replace the content silently; `alert` is a request, see `IslandAlertRequest`.
    case update(IslandContent, alert: IslandAlertRequest?)
    case end(IslandContent)
}

public struct IslandPolicy: Hashable, Sendable {
    public var ambient: AmbientIconPolicy
    /// Shortest time between two quiet updates (icon changes). Changes inside it are coalesced
    /// into one. Attention episodes are not delayed.
    public var minimumUpdateInterval: TimeInterval
    /// A presented episode stays in front at least this long before a newer episode of the same
    /// priority replaces it. A higher priority replaces it at once.
    public var attentionMinimumHold: TimeInterval
    /// Episodes of at least this priority (and episodes showing a speech summary) cannot be
    /// replaced by an ordinary sound's icon. Lower ones give way to a newer ordinary sound.
    public var protectedPriority: AttentionPriority
    /// Shortest time between two expansion requests; an urgent episode ignores it.
    public var alertMinimumInterval: TimeInterval
    /// Request an expansion when an episode first shows a speech summary (if the user allows
    /// summaries), although the attention engine suggests no interruption for a late summary.
    public var alertsOnFirstSummary: Bool
    /// Without any change the content is re-sent after this long, so that the activity's stale
    /// date moves on while the app is alive.
    public var keepAliveInterval: TimeInterval
    /// The host sets the activity's stale date this long after each update. A stale activity is
    /// drawn as "not updating" (the app was terminated).
    public var staleAfter: TimeInterval
    public var maximumTextLength: Int

    public init(ambient: AmbientIconPolicy, minimumUpdateInterval: TimeInterval, attentionMinimumHold: TimeInterval,
                protectedPriority: AttentionPriority = .high, alertMinimumInterval: TimeInterval, alertsOnFirstSummary: Bool, keepAliveInterval: TimeInterval,
                staleAfter: TimeInterval, maximumTextLength: Int)
    {
        self.ambient = ambient
        self.minimumUpdateInterval = minimumUpdateInterval
        self.attentionMinimumHold = attentionMinimumHold
        self.protectedPriority = protectedPriority
        self.alertMinimumInterval = alertMinimumInterval
        self.alertsOnFirstSummary = alertsOnFirstSummary
        self.keepAliveInterval = keepAliveInterval
        self.staleAfter = staleAfter
        self.maximumTextLength = maximumTextLength
    }

    public static let standard = IslandPolicy(ambient: .standard, minimumUpdateInterval: 1, attentionMinimumHold: 3,
                                              alertMinimumInterval: 6, alertsOnFirstSummary: true,
                                              keepAliveInterval: 600, staleAfter: 900, maximumTextLength: 120)
}

public struct IslandStatistics: Hashable, Sendable, Codable {
    public var starts = 0
    public var updates = 0
    public var ends = 0
    /// Quiet changes that were replaced by a later one before they were sent.
    public var coalesced = 0
    public var keepAlives = 0
    /// Evaluations in which only a secondary detail differed (the small ambient icon or the
    /// "+N more" count of an attention episode) and no update was sent for it.
    public var secondaryChangesNotSent = 0
    public var attentionEpisodes = 0
    public var alertRequests = 0
    public var alertRequestsRateLimited = 0

    public init() {}
}

/// Decides what the one Live Activity shows (Window 5). It joins the two channels:
///
/// ```
/// Window 2 confirmed sound events ──▶ AmbientIconStream ──▶ icon ──┐
///                                                                  ├──▶ IslandContent ──▶ commands
/// Window 4 AttentionPresentationIntent ──▶ presented episodes ─────┘
/// ```
///
/// Rules:
/// - A high-priority episode and an episode showing a speech summary have precedence. While one
///   is presented the ambient icon keeps being tracked but cannot replace it; it appears again
///   when the episode is gone. A lower-priority episode gives way to an ordinary sound that
///   appeared after it.
/// - Text exists only for attention episodes. Ordinary sounds are an icon.
/// - Important alerts come only from the attention engine's intents; the ambient stream cannot
///   create one, and nothing here presents an episode the engine did not present.
/// - Speech-derived text enters the content only when the user's setting allows it, and alert
///   requests never contain it.
/// - Quiet updates are coalesced (`minimumUpdateInterval`); identical content is not re-sent, and
///   a change of a secondary detail alone (see `primary`) is not sent by itself.
///
/// A value type without a clock: the host sends one `.tick` at `nextDeadline`.
public struct IslandPipeline: Sendable {
    public let policy: IslandPolicy
    public private(set) var settings: IslandSettings
    public private(set) var statistics = IslandStatistics()
    /// The content of the latest command (what the activity shows); nil while there is none.
    public private(set) var shown: IslandContent?
    /// A Live Activity should currently exist.
    public private(set) var isLive = false
    public private(set) var nextDeadline: Date?

    private struct Item {
        var intent: AttentionPresentationIntent
        var firstShown: Date
        /// When the engine last presented or changed the episode.
        var lastChanged: Date
        var removeAt: Date?
        /// The engine dismissed the episode with a later expiry: it lingers, and an update can
        /// bring it back.
        var isResolved = false
        /// Highest priority an expansion was requested for.
        var alertedPriority: AttentionPriority?
        var summaryAlerted = false
    }

    private var ambient: AmbientIconStream
    private var sessionActive = false
    private var pausedSince: Date?
    private var sessionStart: Date?
    private var items: [AttentionEventID: Item] = [:]
    private var leadID: AttentionEventID?
    private var leadSince: Date?
    private var ambientSince: Date?
    private var lastSentAt: Date?
    private var hasPendingChange = false
    private var lastAlertAt: Date?

    public init(policy: IslandPolicy = .standard, settings: IslandSettings = .default) {
        self.policy = policy
        self.settings = settings
        ambient = AmbientIconStream(policy: policy.ambient)
    }

    public var ambientIcon: AmbientIcon? { ambient.current }
    public var ambientStatistics: AmbientIconStatistics { ambient.statistics }
    /// Attention episodes currently held for presentation.
    public var presentedCount: Int { items.count }

    public mutating func process(_ input: IslandInput) -> [IslandCommand] {
        let now = input.date
        var alertCandidate: (id: AttentionEventID, request: IslandAlertRequest, isUrgent: Bool)?

        switch input {
        case .sessionStarted:
            if !sessionActive {
                sessionActive = true
                sessionStart = now
                items.removeAll()
                leadID = nil
            }
            pausedSince = nil
            noteAmbient(ambient.process(.sessionStarted(at: now)))
        case .sessionPaused:
            guard sessionActive else { break }
            pausedSince = now
            items.removeAll()
            leadID = nil
            noteAmbient(ambient.process(.sessionEnded(at: now)))
        case .sessionEnded:
            sessionActive = false
            pausedSince = nil
            items.removeAll()
            leadID = nil
            noteAmbient(ambient.process(.sessionEnded(at: now)))
        case .sound(let update):
            guard sessionActive, pausedSince == nil else { break }
            noteAmbient(ambient.process(.sound(update)))
        case .intent(let intent):
            guard sessionActive else { break }
            alertCandidate = apply(intent, at: now)
        case .settings(let updated, _):
            settings = updated
        case .tick:
            break
        }

        if case .sound = input {} else { noteAmbient(ambient.process(.tick(at: now))) }
        for (id, item) in items {
            if let removeAt = item.removeAt, removeAt <= now { items[id] = nil }
        }
        let holdDeadline = selectLead(at: now)

        var commands: [IslandCommand] = []
        let wanted = sessionActive && settings.isEnabled
        let content = compose(at: now)
        if !isLive {
            if wanted {
                isLive = true
                statistics.starts += 1
                commands.append(.start(content))
                markSent(content, at: now)
            }
        } else if !wanted {
            isLive = false
            statistics.ends += 1
            commands.append(.end(content))
            shown = nil
            lastSentAt = nil
            hasPendingChange = false
        } else {
            var alert: IslandAlertRequest?
            if let candidate = alertCandidate, candidate.id == leadID {
                if !candidate.isUrgent, let lastAlertAt, lastAlertAt.addingTimeInterval(policy.alertMinimumInterval) > now {
                    statistics.alertRequestsRateLimited += 1
                } else {
                    alert = candidate.request
                    lastAlertAt = now
                    statistics.alertRequests += 1
                }
            }
            if let command = update(to: content, alert: alert, at: now) { commands.append(command) }
        }

        scheduleDeadline(holdDeadline: holdDeadline)
        return commands
    }

    // MARK: - Attention channel

    /// Stores what the attention engine decided and returns the expansion request it implies.
    private mutating func apply(_ intent: AttentionPresentationIntent, at now: Date)
        -> (id: AttentionEventID, request: IslandAlertRequest, isUrgent: Bool)?
    {
        switch intent.action {
        case .dismiss:
            guard var item = items[intent.id] else { return nil }
            if let expires = intent.expiresAt, expires > now {
                // Resolved: shown a little longer, and an update may still bring it back.
                item.removeAt = expires
                item.isResolved = true
                items[intent.id] = item
            } else {
                items[intent.id] = nil
            }
            return nil
        case .present, .update:
            var item = items[intent.id] ?? Item(intent: intent, firstShown: now, lastChanged: now)
            if items[intent.id] == nil { statistics.attentionEpisodes += 1 }
            item.intent = intent
            item.lastChanged = now
            item.removeAt = intent.expiresAt
            item.isResolved = false

            var wantsAlert = false
            switch intent.interruption {
            case .active, .timeSensitive:
                wantsAlert = item.alertedPriority.map { intent.priority > $0 } ?? true
            case .passive:
                break
            case .none:
                break
            }
            // The attention engine lets a late summary appear quietly (`.none`). Its text is only
            // readable in the expanded presentation, so the first summary of an episode the engine
            // presents asks for one expansion; later rewordings do not.
            if policy.alertsOnFirstSummary, settings.showsSpeechSummaries, intent.privateDetail != nil, !item.summaryAlerted {
                wantsAlert = true
            }
            if wantsAlert {
                item.alertedPriority = max(item.alertedPriority ?? intent.priority, intent.priority)
                if intent.privateDetail != nil { item.summaryAlerted = true }
            }
            items[intent.id] = item
            guard wantsAlert else { return nil }
            let request = IslandAlertRequest(title: intent.title, body: intent.subtitle ?? intent.category.displayName,
                                             priority: intent.priority)
            return (intent.id, request, intent.interruption == .timeSensitive)
        }
    }

    /// Picks the episode in front. Returns when to look again if a newer episode is waiting for
    /// the minimum hold of the current one.
    private mutating func selectLead(at now: Date) -> Date? {
        // A resolved episode keeps the island while it lingers, but it does not come back to the
        // front once something else was there. (Seen on the iPhone: a dog that had ended 10 s
        // earlier reappeared for 2 s when a later speech episode expired.)
        let best = items.filter { !$0.value.isResolved || $0.key == leadID }.max { lhs, rhs in
            if lhs.value.intent.priority != rhs.value.intent.priority {
                return lhs.value.intent.priority < rhs.value.intent.priority
            }
            if lhs.value.firstShown != rhs.value.firstShown { return lhs.value.firstShown < rhs.value.firstShown }
            return lhs.key < rhs.key
        }
        guard let best else {
            leadID = nil
            leadSince = nil
            return nil
        }
        guard let currentID = leadID, let current = items[currentID], best.key != currentID else {
            if leadID != best.key {
                leadID = best.key
                leadSince = now
            }
            return nil
        }
        if best.value.intent.priority == current.intent.priority, let leadSince {
            let holdEnds = leadSince.addingTimeInterval(policy.attentionMinimumHold)
            if holdEnds > now { return holdEnds }
        }
        leadID = best.key
        leadSince = now
        return nil
    }

    // MARK: - Content

    private mutating func noteAmbient(_ change: AmbientIconStream.Change?) {
        if let change { ambientSince = change.date }
    }

    private func compose(at now: Date) -> IslandContent {
        if let pausedSince { return .paused(since: pausedSince) }
        let ambientIcon = settings.showsAmbientIcons ? ambient.current : nil
        if let leadID, let item = items[leadID] {
            let intent = item.intent
            let summary = settings.showsSpeechSummaries ? intent.privateDetail : nil
            // Protected: a high-priority event or a speech summary. Anything else the engine
            // presents (a dog, "Nearby Speech" without text) gives way to an ordinary sound that
            // appeared after it, so the icon channel stays live. (On the iPhone, in a room with
            // people talking, "Nearby Speech" episodes held the island for most of 35 minutes and
            // a sneeze never showed.)
            let isProtected = intent.priority >= policy.protectedPriority || summary != nil
            if !isProtected, let ambientIcon, let ambientSince, ambientSince > item.lastChanged {
                return IslandContent(mode: .ambient, symbolName: ambientIcon.symbolName,
                                     spokenLabel: ambientIcon.spokenName, since: ambientSince)
            }
            let caption: String? = summary == nil ? intent.subtitle
                : [intent.title, intent.subtitle].compactMap { $0 }.joined(separator: " · ")
            return IslandContent(
                mode: .attention, symbolName: intent.symbolName, spokenLabel: intent.title,
                headline: clip(summary ?? intent.title), caption: caption.map(clip), headlineIsSpeech: summary != nil,
                priority: intent.priority, isUncertain: intent.isUncertain, since: item.firstShown,
                ambientSymbolName: ambientIcon.flatMap { $0.symbolName == intent.symbolName ? nil : $0.symbolName },
                additionalCount: items.count - 1)
        }
        if let ambientIcon {
            return IslandContent(mode: .ambient, symbolName: ambientIcon.symbolName, spokenLabel: ambientIcon.spokenName,
                                 since: ambientSince ?? now)
        }
        return .listening(since: sessionStart ?? now)
    }

    private func clip(_ text: String) -> String {
        text.count <= policy.maximumTextLength ? text : String(text.prefix(policy.maximumTextLength - 1)) + "…"
    }

    /// The content without its secondary details: the small ambient icon and the "+N more" count
    /// of an attention episode. They are drawn in the expanded presentation only, so a change of
    /// nothing else is not worth an update of its own; the current values travel with the next
    /// update that is sent anyway. (In the replay of the Window 4 scenes these changes were 26–34 %
    /// of all updates.)
    private static func primary(_ content: IslandContent) -> IslandContent {
        var copy = content
        copy.ambientSymbolName = nil
        copy.additionalCount = 0
        return copy
    }

    private mutating func update(to content: IslandContent, alert: IslandAlertRequest?, at now: Date) -> IslandCommand? {
        guard let shown, let lastSentAt else {
            markSent(content, at: now)
            statistics.updates += 1
            return .update(content, alert: alert)
        }
        if Self.primary(content) == Self.primary(shown), alert == nil {
            if content != shown { statistics.secondaryChangesNotSent += 1 }
            hasPendingChange = false
            guard lastSentAt.addingTimeInterval(policy.keepAliveInterval) <= now else { return nil }
            statistics.keepAlives += 1
            markSent(content, at: now)
            return .update(content, alert: nil)
        }
        let involvesAttention = content.mode == .attention || shown.mode == .attention
            || content.mode == .paused || shown.mode == .paused
        let isQuiet = alert == nil && !involvesAttention
        if isQuiet, lastSentAt.addingTimeInterval(policy.minimumUpdateInterval) > now {
            if hasPendingChange { statistics.coalesced += 1 }
            hasPendingChange = true
            return nil
        }
        markSent(content, at: now)
        statistics.updates += 1
        return .update(content, alert: alert)
    }

    private mutating func markSent(_ content: IslandContent, at now: Date) {
        shown = content
        lastSentAt = now
        hasPendingChange = false
    }

    private mutating func scheduleDeadline(holdDeadline: Date?) {
        var deadlines: [Date] = []
        if let deadline = ambient.nextDeadline { deadlines.append(deadline) }
        if let holdDeadline { deadlines.append(holdDeadline) }
        deadlines += items.values.compactMap(\.removeAt)
        if isLive, let lastSentAt {
            deadlines.append(lastSentAt.addingTimeInterval(hasPendingChange ? policy.minimumUpdateInterval
                    : policy.keepAliveInterval))
        }
        nextDeadline = deadlines.min()
    }
}

extension IslandContent {
    /// One line for logs and diagnostics. Never contains speech-derived text.
    public var redactedSummary: String {
        var parts = [mode.rawValue, symbolName]
        if let priority { parts.append(priority.description) }
        if let headline { parts.append(headlineIsSpeech ? "<speech summary>" : "“\(headline)”") }
        if additionalCount > 0 { parts.append("+\(additionalCount)") }
        return parts.joined(separator: " ")
    }
}
