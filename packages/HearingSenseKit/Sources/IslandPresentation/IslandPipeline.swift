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
    /// The host's estimate of the lock state changed. While locked, speech-derived text is taken
    /// out of the content (the Lock Screen view never draws it; this keeps it out of what iOS
    /// stores for the activity as well). "Cannot tell" counts as not locked here: without a
    /// passcode there is no lock to protect the text.
    case deviceLock(isLocked: Bool, at: Date)
    /// Every speech-derived text must go now (the user switched transcription off or deleted the
    /// speech data), whether or not an episode is presented.
    case speechTextCleared(at: Date)
    /// Window 7: where a summary the user asked for stands; nil when that is over.
    case conversation(IslandConversation?, at: Date)
    /// Window 7: the acoustic scene in generic words ("Traffic nearby"); nil when there is none.
    case scene(String?, at: Date)
    /// Time passed (the host calls this at `IslandPipeline.nextDeadline`).
    case tick(at: Date)

    public var date: Date {
        switch self {
        case .sessionStarted(let date), .sessionPaused(let date), .sessionEnded(let date), .tick(let date),
             .speechTextCleared(let date): date
        case .settings(_, let date), .deviceLock(_, let date), .conversation(_, let date), .scene(_, let date): date
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
    /// Window 7: not an event at all but the summary the user asked for a moment ago. It follows
    /// its own setting (`IslandSettings.expandsForSummaries`).
    public var isUserRequested: Bool

    public init(title: String, body: String, priority: AttentionPriority, isUserRequested: Bool = false) {
        self.title = title
        self.body = body
        self.priority = priority
        self.isUserRequested = isUserRequested
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
    /// How long after the engine last changed it a high-priority episode or a summary keeps that
    /// protection. Urgent episodes keep it throughout.
    public var protectedFor: TimeInterval
    /// A speech episode below `protectedPriority` is shown as an episode only when it has a
    /// validated summary; without one it stays an icon of the ambient channel.
    public var speechNeedsSummary: Bool
    /// Shortest time between two expansion requests; an urgent episode ignores it.
    public var alertMinimumInterval: TimeInterval
    /// Request an expansion when an episode first shows a speech summary (if the user allows
    /// summaries), although the attention engine suggests no interruption for a late summary.
    public var alertsOnFirstSummary: Bool
    /// How long the latest presented speech summary stays readable in the expanded island after
    /// its episode left the front (an ordinary sound took the icon, or the episode ended). After
    /// that the text is removed with one quiet update. 0 turns the recall off.
    public var summaryRecall: TimeInterval
    /// Without any change the content is re-sent after this long, so that the activity's stale
    /// date moves on while the app is alive.
    public var keepAliveInterval: TimeInterval
    /// The host sets the activity's stale date this long after each update. A stale activity is
    /// drawn as "not updating" (the app was terminated).
    public var staleAfter: TimeInterval
    public var maximumTextLength: Int
    /// Window 7: a requested summary may be longer than an event's text (the expanded
    /// presentation shows a few lines of it; the whole summary is in the app).
    public var maximumSummaryLength = 240
    /// Window 7: only acoustic events ask iOS for an expansion. A speech episode (including a
    /// possible spoken warning, which rests on recognized words) is presented without one.
    public var speechMayRequestExpansion = false
    /// Only an acoustic event of at least this priority asks for a prominent presentation
    /// (`high`: a signal made to be noticed; `urgent`: a siren, a persisting alarm). Everything
    /// below changes the icon silently, whatever interruption the attention engine suggests.
    public var alertMinimumPriority = AttentionPriority.high
    /// An event the attention engine marks as uncertain asks for nothing: a prominent alert
    /// needs a verified event.
    public var alertsNeedVerifiedEvent = true

    public init(ambient: AmbientIconPolicy, minimumUpdateInterval: TimeInterval, attentionMinimumHold: TimeInterval,
                protectedPriority: AttentionPriority = .high, protectedFor: TimeInterval = 20,
                speechNeedsSummary: Bool = true, alertMinimumInterval: TimeInterval, alertsOnFirstSummary: Bool,
                summaryRecall: TimeInterval = 120, keepAliveInterval: TimeInterval,
                staleAfter: TimeInterval, maximumTextLength: Int)
    {
        self.ambient = ambient
        self.minimumUpdateInterval = minimumUpdateInterval
        self.attentionMinimumHold = attentionMinimumHold
        self.protectedPriority = protectedPriority
        self.protectedFor = protectedFor
        self.speechNeedsSummary = speechNeedsSummary
        self.alertMinimumInterval = alertMinimumInterval
        self.alertsOnFirstSummary = alertsOnFirstSummary
        self.summaryRecall = summaryRecall
        self.keepAliveInterval = keepAliveInterval
        self.staleAfter = staleAfter
        self.maximumTextLength = maximumTextLength
    }

    public static let standard = IslandPolicy(ambient: .standard, minimumUpdateInterval: 1, attentionMinimumHold: 3,
                                              alertMinimumInterval: 6, alertsOnFirstSummary: true,
                                              keepAliveInterval: 600, staleAfter: 900, maximumTextLength: 120)

    /// The rules before Window 7, in which a speech episode could ask for an expansion (its first
    /// summary, a possible spoken warning). Kept for the replay tools and for comparison.
    public static var window5: IslandPolicy {
        var policy = IslandPolicy.standard
        policy.speechMayRequestExpansion = true
        return policy
    }
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
    /// Speech episodes of the attention engine that had no summary and stayed an icon.
    public var speechWithoutSummary = 0
    public var alertRequests = 0
    public var alertRequestsRateLimited = 0
    /// Expansion requests of episodes that never reached the front while their sound was still
    /// going (another episode held it), so they were not sent.
    public var alertsLostToLead = 0
    /// Speech summaries that were presented as (part of) an episode.
    public var summariesPresented = 0
    /// First summaries that did not ask for an expansion because the speech was ordinary
    /// conversation (they are readable with a touch and hold).
    public var summariesWithoutExpansion = 0
    /// Window 7: states of a requested summary that were put into the content, and the
    /// expansion requests made for a summary that became ready.
    public var conversationStates = 0
    public var summaryReadyRequests = 0
    /// Episodes that would have asked for an expansion but are speech: speech never does.
    public var speechAlertsWithheld = 0
    /// Acoustic events that asked for nothing because they were below the alert priority or
    /// marked uncertain.
    public var unverifiedAlertsWithheld = 0

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
    /// Expansion requests of episodes that are not in front yet. Each is sent when its episode
    /// reaches the front while still active, or counted in `alertsLostToLead`.
    private var pendingAlerts: [AttentionEventID: (request: IslandAlertRequest, isUrgent: Bool)] = [:]
    private var lastEvaluated: Date?
    private var isDeviceLocked = false
    /// The latest summary an episode showed: when it first appeared and when its episode was
    /// last held for presentation.
    private var recalled: (text: String, since: Date, lastPresented: Date)?
    private var conversation: IslandConversation?
    private var sceneTitle: String?

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
        lastEvaluated = now
        var alertCandidate: (id: AttentionEventID, request: IslandAlertRequest, isUrgent: Bool)?
        var summaryAlert: IslandAlertRequest?

        switch input {
        case .sessionStarted:
            if !sessionActive {
                sessionActive = true
                sessionStart = now
                items.removeAll()
                pendingAlerts.removeAll()
                leadID = nil
                recalled = nil
                conversation = nil
                sceneTitle = nil
            }
            pausedSince = nil
            noteAmbient(ambient.process(.sessionStarted(at: now)))
        case .sessionPaused:
            guard sessionActive else { break }
            pausedSince = now
            items.removeAll()
            pendingAlerts.removeAll()
            leadID = nil
            recalled = nil
            noteAmbient(ambient.process(.sessionEnded(at: now)))
        case .sessionEnded:
            sessionActive = false
            pausedSince = nil
            items.removeAll()
            pendingAlerts.removeAll()
            leadID = nil
            recalled = nil
            conversation = nil
            sceneTitle = nil
            noteAmbient(ambient.process(.sessionEnded(at: now)))
        case .sound(let update):
            guard sessionActive, pausedSince == nil else { break }
            noteAmbient(ambient.process(.sound(update)))
        case .intent(let intent):
            guard sessionActive else { break }
            alertCandidate = apply(intent, at: now)
        case .settings(let updated, _):
            settings = updated
            if !updated.showsSpeechSummaries { recalled = nil }
        case .deviceLock(let isLocked, _):
            isDeviceLocked = isLocked
        case .conversation(let state, _):
            guard sessionActive else { break }
            if let state, state.phase != conversation?.phase { statistics.conversationStates += 1 }
            // The summary the user asked for is ready: one request to show it.
            if let state, state.phase == .summaryReady, conversation?.phase == .summarizing {
                summaryAlert = IslandAlertRequest(title: state.title, body: "Hearing Sense", priority: .normal,
                                                  isUserRequested: true)
            }
            conversation = state
        case .scene(let title, _):
            guard sessionActive else { break }
            sceneTitle = title
        case .speechTextCleared:
            recalled = nil
            conversation = conversation?.withoutSpeechText
            for (id, item) in items where item.intent.hasPrivateDetail { items[id] = nil }
        case .tick:
            break
        }

        if case .sound = input {} else { noteAmbient(ambient.process(.tick(at: now))) }
        for (id, item) in items {
            if let removeAt = item.removeAt, removeAt <= now {
                keepRecall(of: item, until: now)
                items[id] = nil
            }
        }
        let holdDeadline = selectLead(at: now)
        noteSummary(at: now)
        if let alertCandidate { pendingAlerts[alertCandidate.id] = (alertCandidate.request, alertCandidate.isUrgent) }
        for (id, _) in pendingAlerts where items[id].map(\.isResolved) ?? true {
            pendingAlerts[id] = nil
            statistics.alertsLostToLead += 1
        }

        var commands: [IslandCommand] = []
        let wanted = sessionActive && settings.isEnabled
        let content = compose(at: now)
        if !isLive || !wanted {
            // No activity to expand: requests are not kept for later.
            pendingAlerts.removeAll()
        }
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
            if let leadID, let candidate = pendingAlerts.removeValue(forKey: leadID) {
                if !candidate.isUrgent, let lastAlertAt, lastAlertAt.addingTimeInterval(policy.alertMinimumInterval) > now {
                    statistics.alertRequestsRateLimited += 1
                } else {
                    alert = candidate.request
                    lastAlertAt = now
                    statistics.alertRequests += 1
                }
            }
            // An event's request has precedence; the summary is then one touch and hold away.
            if alert == nil, let summaryAlert, content.mode != .attention {
                alert = summaryAlert
                statistics.summaryReadyRequests += 1
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
            // The user switched transcription off: every speech-derived text goes at once.
            if intent.reasons.contains(.speechDataCleared) { recalled = nil }
            guard var item = items[intent.id] else { return nil }
            if let expires = intent.expiresAt, expires > now {
                // Resolved: shown a little longer, and an update may still bring it back.
                item.removeAt = expires
                item.isResolved = true
                items[intent.id] = item
            } else {
                keepRecall(of: item, until: now)
                items[intent.id] = nil
            }
            return nil
        case .present, .update:
            // Nearby speech with nothing to read (no summary) is an ordinary sound in every mode:
            // the icon channel shows it, it is never an episode in the island and never asks for
            // an expansion. A possible spoken warning (high priority) is not affected. Decided by
            // the student after the device session, where "Nearby Speech" without text was
            // presented 12 times in 17 minutes.
            if policy.speechNeedsSummary, intent.category == .speech, !intent.hasPrivateDetail,
               intent.priority < policy.protectedPriority
            {
                if items[intent.id] != nil {
                    items[intent.id] = nil
                } else if intent.action == .present {
                    statistics.speechWithoutSummary += 1
                }
                return nil
            }
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
            // Only for speech the engine rates as relevant or as a possible warning: the summary
            // of ordinary conversation is readable with a touch and hold but does not ask for
            // attention ("do not turn every conversation into an alert").
            if policy.alertsOnFirstSummary, settings.showsSpeechSummaries, intent.privateDetail != nil, !item.summaryAlerted {
                if intent.priority >= policy.protectedPriority
                    || intent.reasons.contains(.relevantSpeech) || intent.reasons.contains(.importantSpeech)
                {
                    wantsAlert = true
                } else {
                    item.summaryAlerted = true
                    statistics.summariesWithoutExpansion += 1
                }
            }
            if wantsAlert, intent.category != .speech,
               intent.priority < policy.alertMinimumPriority || (policy.alertsNeedVerifiedEvent && intent.isUncertain)
            {
                // Not marked as alerted: the same episode may still ask once it is verified or
                // its priority has risen.
                wantsAlert = false
                statistics.unverifiedAlertsWithheld += 1
            }
            if wantsAlert, !policy.speechMayRequestExpansion, intent.category == .speech {
                wantsAlert = false
                item.alertedPriority = max(item.alertedPriority ?? intent.priority, intent.priority)
                if intent.privateDetail != nil { item.summaryAlerted = true }
                statistics.speechAlertsWithheld += 1
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
        // An active episode of at least `protectedPriority` goes before one whose sound has ended,
        // whatever its priority. (Seen on the iPhone: a siren that had ended kept the front while
        // it lingered, and a car horn confirmed during that time got no expansion.)
        func isActiveWarning(_ item: Item) -> Bool {
            !item.isResolved && item.intent.priority >= policy.protectedPriority
        }
        let best = items.filter { !$0.value.isResolved || $0.key == leadID }.max { lhs, rhs in
            if isActiveWarning(lhs.value) != isActiveWarning(rhs.value) { return isActiveWarning(rhs.value) }
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
        if best.value.intent.priority == current.intent.priority, !(current.isResolved && isActiveWarning(best.value)),
           let leadSince
        {
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

    /// Remembers the summary of the episode in front, for `IslandPolicy.summaryRecall`.
    private mutating func noteSummary(at now: Date) {
        if let recalled, recalled.lastPresented.addingTimeInterval(policy.summaryRecall) <= now { self.recalled = nil }
        guard policy.summaryRecall > 0, settings.showsSpeechSummaries, let leadID, let item = items[leadID],
              let text = item.intent.privateDetail else { return }
        if let recalled, recalled.text == text {
            self.recalled?.lastPresented = now
        } else {
            statistics.summariesPresented += 1
            recalled = (text, now, now)
        }
    }

    /// An episode leaves: the recall time of its summary counts from now.
    private mutating func keepRecall(of item: Item, until now: Date) {
        if let recalled, recalled.text == item.intent.privateDetail { self.recalled?.lastPresented = now }
    }

    private var showsSpeechText: Bool { settings.showsSpeechSummaries && !isDeviceLocked }

    /// Content of the icon channel, with the recent summary for the expanded presentation.
    private func quiet(_ content: IslandContent) -> IslandContent {
        guard showsSpeechText, let recalled else { return content }
        var content = content
        content.recentSummary = clip(recalled.text)
        content.recentSummaryDate = recalled.since
        return content
    }

    /// The channels' content with the two Window 7 additions.
    private func compose(at now: Date) -> IslandContent {
        var content = composeChannels(at: now)
        guard content.mode != .paused else { return content }
        if var conversation {
            if !showsSpeechText { conversation = conversation.withoutSpeechText }
            conversation.detail = conversation.detail.map { text in
                text.count <= policy.maximumSummaryLength ? text : String(text.prefix(policy.maximumSummaryLength - 1)) + "…"
            }
            content.conversation = conversation
        }
        content.sceneTitle = sceneTitle
        return content
    }

    private func composeChannels(at now: Date) -> IslandContent {
        if let pausedSince { return .paused(since: pausedSince) }
        let ambientIcon = settings.showsAmbientIcons ? ambient.current : nil
        if let leadID, let item = items[leadID] {
            let intent = item.intent
            let summary = showsSpeechText ? intent.privateDetail : nil
            // Protected: a high-priority event or a speech summary. Anything else the engine
            // presents (a dog, "Nearby Speech" without text) gives way to an ordinary sound that
            // appeared after it, so the icon channel stays live. (On the iPhone, in a room with
            // people talking, "Nearby Speech" episodes held the island for most of 35 minutes and
            // a sneeze never showed.)
            // Urgent episodes are protected for as long as the engine presents them; high-priority
            // ones and summaries for `protectedFor` after the engine last changed them. (Retest
            // on the iPhone: a door episode joined by the room's speech held the island for 48 s
            // and hid a dog and footsteps.)
            let isRecent = item.lastChanged.addingTimeInterval(policy.protectedFor) > now
            let isProtected = intent.priority >= .urgent
                || ((intent.priority >= policy.protectedPriority || summary != nil) && isRecent)
            if !isProtected, let ambientIcon, let ambientSince, ambientSince > item.lastChanged {
                return quiet(IslandContent(mode: .ambient, symbolName: ambientIcon.symbolName,
                                           spokenLabel: ambientIcon.spokenName, since: ambientSince))
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
            return quiet(IslandContent(mode: .ambient, symbolName: ambientIcon.symbolName, spokenLabel: ambientIcon.spokenName,
                                       since: ambientSince ?? now))
        }
        return quiet(.listening(since: sessionStart ?? now))
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
        copy.sceneTitle = nil
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
        // A requested summary's state is the answer to something the user did: never held back.
        let isQuiet = alert == nil && !involvesAttention && content.conversation == shown.conversation
        // An icon that is on the island stays for the icon channel's minimum display time, also
        // when it only just took over from an episode (seen on the iPhone: 1.0 s).
        let quietInterval = shown.mode == .ambient ? max(policy.minimumUpdateInterval, policy.ambient.minimumDisplay)
            : policy.minimumUpdateInterval
        if isQuiet, lastSentAt.addingTimeInterval(quietInterval) > now {
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
        // Protection of a high-priority episode runs out: look again.
        deadlines += items.values.map { $0.lastChanged.addingTimeInterval(policy.protectedFor) }
            .filter { $0 > (lastEvaluated ?? .distantPast) }
        // The recalled summary runs out: one quiet update removes its text.
        if let recalled { deadlines.append(recalled.lastPresented.addingTimeInterval(policy.summaryRecall)) }
        if isLive, let lastSentAt {
            let quietInterval = shown?.mode == .ambient ? max(policy.minimumUpdateInterval, policy.ambient.minimumDisplay)
                : policy.minimumUpdateInterval
            deadlines.append(lastSentAt.addingTimeInterval(hasPendingChange ? quietInterval : policy.keepAliveInterval))
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
        if recentSummary != nil { parts.append("(recent <speech summary>)") }
        if let conversation { parts.append("[\(conversation.phase.rawValue)\(conversation.detail == nil ? "" : " <summary>")]") }
        if let sceneTitle { parts.append("{\(sceneTitle)}") }
        return parts.joined(separator: " ")
    }
}
