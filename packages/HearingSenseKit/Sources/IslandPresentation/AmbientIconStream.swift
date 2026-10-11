import Foundation
import HearingSenseDomain

/// The icon of one ordinary sound, for the icon-only presentation. Carries no text to draw:
/// `spokenName` exists for VoiceOver only.
public struct AmbientIcon: Hashable, Sendable, Codable {
    /// SF Symbol name, or a `CustomSoundGlyph` raw value.
    public var symbolName: String
    /// `SoundEventKind.id` of the sound.
    public var kindID: String
    public var category: SoundCategory
    /// The sound's name ("Rain", "Coughing"), as an accessibility label.
    public var spokenName: String

    public init(symbolName: String, kindID: String, category: SoundCategory, spokenName: String) {
        self.symbolName = symbolName
        self.kindID = kindID
        self.category = category
        self.spokenName = spokenName
    }
}

/// Rules of the ambient icon stream. Provisional defaults: none of them has been tuned on a
/// device.
public struct AmbientIconPolicy: Hashable, Sendable {
    /// Evidence quality an event needs before its icon may be shown. An event that starts weak
    /// becomes eligible when a later update raises its quality.
    public var minimumQuality: EventQuality
    /// An icon that is shown stays at least this long before another icon (or none) replaces it.
    public var minimumDisplay: TimeInterval
    /// How long an icon stays after its sound ended.
    public var linger: TimeInterval
    /// A sound that was just confirmed takes the icon, whatever is shown, for this long: the
    /// newest sound wins. 0: only rank decides (the first version of Window 5, in which a sound
    /// that kept going — speech in a room — hid every lower-ranked sound; the student saw a strong
    /// sneeze not appear on the iPhone).
    public var freshFor: TimeInterval
    /// A fresh sound gets the icon only if that can happen within this time of its confirmation;
    /// otherwise it is not shown as a newcomer at all. No late jumps.
    public var timelyWithin: TimeInterval
    /// A fresh sound that ranks below the shown icon may replace it only after the shown icon had
    /// this long (a higher or equal rank needs `minimumDisplay` only). The switch cooldown.
    public var lowerRankCooldown: TimeInterval
    /// A kind whose icon was on display within this time does not get the icon as a newcomer
    /// again (it can still be shown as the highest-ranked ongoing sound). Same-kind de-duplication:
    /// in a room, laughter or coughing every few seconds would otherwise keep flipping the icon.
    public var sameKindCooldown: TimeInterval
    /// A sound with at least this peak score ignores `sameKindCooldown`. (Retest on the iPhone: a
    /// sneeze at 0.99 was not shown because a cough had used the same icon 18 s earlier.)
    public var strongPeak: Double
    /// Extra time the last icon stays before the island goes back to the plain listening glyph.
    /// A sound that starts meanwhile replaces it directly, which saves the update in between.
    /// (iPhone, 35 minutes in a lived-in room: the island went "icon → glyph → icon" within
    /// 2–6 s again and again.)
    public var idleHold: TimeInterval
    /// Whether a sound that has already ended may still get the island from a higher-ranked icon
    /// once that one is gone. False: an ended sound keeps the island if it has it, but does not
    /// get it afterwards. (iPhone: a drawer that had closed 5 s earlier appeared for 4 s when the
    /// speech icon above it went away.)
    public var showsEndedSoundsLate: Bool
    /// Icon changes allowed in any 60 s. Further changes wait.
    public var maximumChangesPerMinute: Int
    /// An active event without an update for this long is dropped (the detector publishes at
    /// least every `DetectionPolicy.updateInterval` while an event is alive; the same bound the
    /// attention engine uses).
    public var staleAfter: TimeInterval
    /// Kinds that never get an icon.
    public var excludedKindIDs: Set<String>
    /// Which icon wins while several sounds are present: the higher rank. Not an importance
    /// judgement for alerting (that is the attention engine's job), only "which one icon".
    public var categoryRank: [SoundCategory: Int]
    public var kindRank: [String: Int]

    public init(minimumQuality: EventQuality, minimumDisplay: TimeInterval, linger: TimeInterval,
                freshFor: TimeInterval, timelyWithin: TimeInterval, lowerRankCooldown: TimeInterval,
                sameKindCooldown: TimeInterval, strongPeak: Double, idleHold: TimeInterval, showsEndedSoundsLate: Bool,
                maximumChangesPerMinute: Int, staleAfter: TimeInterval, excludedKindIDs: Set<String>,
                categoryRank: [SoundCategory: Int], kindRank: [String: Int])
    {
        self.minimumQuality = minimumQuality
        self.minimumDisplay = minimumDisplay
        self.linger = linger
        self.freshFor = freshFor
        self.timelyWithin = timelyWithin
        self.lowerRankCooldown = lowerRankCooldown
        self.sameKindCooldown = sameKindCooldown
        self.strongPeak = strongPeak
        self.idleHold = idleHold
        self.showsEndedSoundsLate = showsEndedSoundsLate
        self.maximumChangesPerMinute = maximumChangesPerMinute
        self.staleAfter = staleAfter
        self.excludedKindIDs = excludedKindIDs
        self.categoryRank = categoryRank
        self.kindRank = kindRank
    }

    /// "Newest sound first" without the cooldowns (the rules of the first device retest plan),
    /// for comparisons on recorded device traces.
    public static var newestFirstWithoutCooldowns: AmbientIconPolicy {
        var policy = standard
        policy.minimumDisplay = 2
        policy.timelyWithin = .infinity
        policy.lowerRankCooldown = 2
        policy.sameKindCooldown = 0
        return policy
    }

    /// The rules as first shipped in Window 5, kept for before/after comparisons on recorded
    /// device traces (`hs-attention-eval island-device-trace`).
    public static var firstVersion: AmbientIconPolicy {
        var policy = standard
        policy.minimumDisplay = 4
        policy.freshFor = 0
        policy.idleHold = 0
        policy.showsEndedSoundsLate = true
        policy.maximumChangesPerMinute = 10
        return policy
    }

    public static let standard = AmbientIconPolicy(
        minimumQuality: .moderate,
        minimumDisplay: 3.5,
        linger: 5,
        freshFor: 5,
        timelyWithin: 2.5,
        lowerRankCooldown: 6,
        sameKindCooldown: 15,
        strongPeak: 0.9,
        idleHold: 5,
        showsEndedSoundsLate: false,
        maximumChangesPerMinute: 12,
        staleAfter: 20,
        // Wind on the microphone is a recording artifact, not a sound around the user.
        excludedKindIDs: ["mic_wind_noise"],
        categoryRank: [.alerts: 100, .impacts: 90, .speech: 80, .household: 60, .animals: 55, .transportation: 50,
                       .humanActivity: 45, .crowd: 40, .weatherNature: 30, .music: 20, .other: 10],
        kindRank: ["door": 85, "phone": 85, "beep": 70, "screaming": 90, "crying": 70,
                   "clock": 15, "small_objects": 15, "typing_writing": 15, "body_sounds": 15, "insect": 15])

    public func rank(kindID: String, category: SoundCategory) -> Int {
        kindRank[kindID] ?? categoryRank[category] ?? 0
    }
}

public enum AmbientIconInput: Hashable, Sendable {
    /// A new listening session: everything is forgotten.
    case sessionStarted(at: Date)
    /// Listening stopped or paused: no icon.
    case sessionEnded(at: Date)
    /// Window 2: a confirmed sound event started, changed or ended.
    case sound(AcousticEventUpdate)
    /// Time passed (the host calls this at `nextDeadline`).
    case tick(at: Date)

    public var date: Date {
        switch self {
        case .sessionStarted(let date), .sessionEnded(let date), .tick(let date): date
        case .sound(let update):
            switch update {
            case .started(let event): event.confirmedDate
            case .updated(let event): event.lastObservedDate
            case .ended(let event): event.endedDate ?? event.lastObservedDate
            }
        }
    }
}

public struct AmbientIconStatistics: Hashable, Sendable, Codable {
    public var soundInputs = 0
    /// Icon changes published (including "no icon").
    public var changes = 0
    /// Events that never reached the quality an icon needs.
    public var belowQuality = 0
    public var excluded = 0
    /// Times a change had to wait for the minimum display time or the rate limit.
    public var heldBack = 0
    public var staleEvents = 0

    public init() {}
}

/// Turns the confirmed sound events of Window 2 into at most one calm icon (Window 5, the
/// "ambient awareness" channel).
///
/// It reads the same `AcousticEventUpdate`s the attention engine reads, but it is separate from
/// it: nothing here decides what deserves attention, sends a notification or shows text. An
/// event the attention engine suppresses as ambient (rain, music, a dog) can still be an icon.
///
/// Which icon: the sound that was confirmed most recently, for `freshFor` seconds; after that the
/// highest-ranked sound that is still going on (a sneeze shows at once and the speech around it
/// comes back). Against flicker: only confirmed events count (the detector's k-of-n confirmation
/// is the temporal smoothing of the classifier), the evidence quality must be at least
/// `minimumQuality`, a shown icon stays for `minimumDisplay`, an ended sound lingers, the plain
/// glyph waits for `idleHold`, and changes are limited per minute.
///
/// A value type without a clock, like the attention engine: every input carries its time and
/// the host sends one `.tick` at `nextDeadline`, so a recorded sequence replays identically.
public struct AmbientIconStream: Sendable {
    public struct Change: Hashable, Sendable {
        /// The icon to show now; nil for none.
        public var icon: AmbientIcon?
        public var date: Date

        public init(icon: AmbientIcon?, date: Date) {
            self.icon = icon
            self.date = date
        }
    }

    public let policy: AmbientIconPolicy
    /// The icon currently shown.
    public private(set) var current: AmbientIcon?
    /// When the host should send `.tick` next; nil when nothing is pending.
    public private(set) var nextDeadline: Date?
    public private(set) var statistics = AmbientIconStatistics()

    private struct Tracked {
        var icon: AmbientIcon
        var rank: Int
        var confirmed: Date
        var lastObserved: Date
        var ended: Date?
        var isEligible: Bool
        /// When the event became eligible for an icon (confirmed, or its evidence improved).
        var eligibleSince: Date?
        var peak: Double = 0
    }

    private var tracked: [AcousticEventID: Tracked] = [:]
    private var currentID: AcousticEventID?
    /// Rank of the icon that is shown (kept after its event is gone).
    private var currentRank = 0
    /// Since when nothing wants the island although an icon is still shown.
    private var idleSince: Date?
    /// When each kind's icon was last taken off the display.
    private var lastShown: [String: Date] = [:]
    private var lastChange: Date?
    private var recentChanges: [Date] = []

    public init(policy: AmbientIconPolicy = .standard) {
        self.policy = policy
    }

    /// Number of sound events being followed (shown or not).
    public var trackedCount: Int { tracked.count }

    /// Returns the change to publish, if the icon changed.
    @discardableResult
    public mutating func process(_ input: AmbientIconInput) -> Change? {
        let now = input.date
        switch input {
        case .sessionStarted, .sessionEnded:
            tracked.removeAll()
            currentID = nil
            idleSince = nil
            lastShown.removeAll()
            nextDeadline = nil
            // Session boundaries are not rate-limited: the icon of a session that ended must go.
            guard current != nil else { return nil }
            return publish(nil, at: now)
        case .sound(let update):
            statistics.soundInputs += 1
            track(update)
        case .tick:
            break
        }
        return resolve(at: now)
    }

    private mutating func track(_ update: AcousticEventUpdate) {
        let event = update.event
        guard !policy.excludedKindIDs.contains(event.kind.id) else {
            if case .started = update { statistics.excluded += 1 }
            return
        }
        let symbol = SoundSymbolCatalog.symbol(for: event)
        let icon = AmbientIcon(symbolName: symbol.name, kindID: event.kind.id, category: event.category,
                               spokenName: SoundSymbolCatalog.spokenName(for: event))
        var entry = tracked[event.id] ?? Tracked(
            icon: icon, rank: policy.rank(kindID: event.kind.id, category: event.category),
            confirmed: event.confirmedDate, lastObserved: event.lastObservedDate, ended: nil, isEligible: false,
            eligibleSince: nil)
        // The primary label can change while an event is ongoing (dog → dog_bark): the icon follows.
        entry.icon = icon
        entry.lastObserved = max(entry.lastObserved, event.lastObservedDate)
        entry.peak = max(entry.peak, event.evidence.peakScore.rawValue)
        if !entry.isEligible, event.quality >= policy.minimumQuality {
            entry.isEligible = true
            entry.eligibleSince = AmbientIconInput.sound(update).date
        }
        if case .ended = update {
            entry.ended = event.endedDate ?? event.lastObservedDate
            if !entry.isEligible {
                statistics.belowQuality += 1
                tracked[event.id] = nil
                return
            }
        }
        tracked[event.id] = entry
    }

    private mutating func resolve(at now: Date) -> Change? {
        // Drop what is over: ended and lingered, or silent for too long.
        for (id, entry) in tracked {
            if let ended = entry.ended {
                if ended.addingTimeInterval(policy.linger) <= now { tracked[id] = nil }
            } else if entry.lastObserved.addingTimeInterval(policy.staleAfter) <= now {
                statistics.staleEvents += 1
                tracked[id] = nil
            }
        }

        let shownRank = current == nil ? Int.min : currentRank
        let best = tracked.filter { id, entry in
            guard entry.isEligible else { return false }
            // A sound that is over does not get the island late from something that outranked it.
            return policy.showsEndedSoundsLate || entry.ended == nil || id == currentID || entry.rank >= shownRank
        }.max { lhs, rhs in
            if lhs.value.rank != rhs.value.rank { return lhs.value.rank < rhs.value.rank }
            if lhs.value.confirmed != rhs.value.confirmed { return lhs.value.confirmed < rhs.value.confirmed }
            return lhs.key.description < rhs.key.description
        }

        // Keep the shown sound while it is present, unless something of a higher rank appeared.
        var wantedID = best?.key
        if let currentID, let shown = tracked[currentID], let best, best.value.rank <= shown.rank {
            wantedID = currentID
        }
        // The newest sound wins while it is fresh, whatever its rank — if it can be shown in time
        // (`timelyWithin`), and not when its kind was on display a moment ago (`sameKindCooldown`).
        // The shown icon must have had `minimumDisplay`, or `lowerRankCooldown` when the newcomer
        // ranks below it. A newcomer that would only get the icon late does not get it at all.
        var freshUntil: Date?
        var freshEarliest: Date?
        let shownSince = lastChange ?? now
        let newest = tracked.compactMap { id, entry -> (id: AcousticEventID, since: Date, rank: Int, earliest: Date)? in
            guard entry.isEligible, let since = entry.eligibleSince, since.addingTimeInterval(policy.freshFor) > now
            else { return nil }
            if id == currentID || entry.icon == current { return (id, since, entry.rank, now) }
            if entry.peak < policy.strongPeak, let last = lastShown[entry.icon.kindID],
               last.addingTimeInterval(policy.sameKindCooldown) > now
            {
                return nil
            }
            var earliest = since
            if current != nil {
                let needed = entry.rank < currentRank ? policy.lowerRankCooldown : policy.minimumDisplay
                earliest = max(since, shownSince.addingTimeInterval(needed))
            }
            guard earliest <= since.addingTimeInterval(policy.timelyWithin) else { return nil }
            return (id, since, entry.rank, earliest)
        }.max { lhs, rhs in
            if lhs.since != rhs.since { return lhs.since < rhs.since }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.id.description < rhs.id.description
        }
        if let newest {
            wantedID = newest.id
            freshUntil = newest.since.addingTimeInterval(policy.freshFor)
            freshEarliest = newest.earliest
        }
        let wanted = wantedID.flatMap { tracked[$0]?.icon }

        var pendingChange: Date?
        var change: Change?
        if wanted == current {
            currentID = wantedID
            idleSince = nil
        } else {
            var allowed = earliestChange(after: now)
            if let freshEarliest { allowed = max(allowed, freshEarliest) }
            if wanted == nil {
                // Going back to the plain glyph waits a little: the next sound may come first.
                let since = idleSince ?? now
                idleSince = since
                allowed = max(allowed, since.addingTimeInterval(policy.idleHold))
            } else {
                idleSince = nil
            }
            if allowed <= now {
                currentID = wantedID
                if let wantedID, let entry = tracked[wantedID] { currentRank = entry.rank }
                idleSince = nil
                change = publish(wanted, at: now)
            } else {
                statistics.heldBack += 1
                pendingChange = allowed
            }
        }

        var deadlines: [Date] = pendingChange.map { [$0] } ?? []
        if let freshUntil { deadlines.append(freshUntil) }
        for entry in tracked.values {
            deadlines.append(entry.ended.map { $0.addingTimeInterval(policy.linger) }
                ?? entry.lastObserved.addingTimeInterval(policy.staleAfter))
        }
        nextDeadline = deadlines.min()
        return change
    }

    /// The earliest time the icon may change again.
    private mutating func earliestChange(after now: Date) -> Date {
        var allowed = now
        if current != nil, let lastChange {
            allowed = max(allowed, lastChange.addingTimeInterval(policy.minimumDisplay))
        }
        recentChanges.removeAll { $0.addingTimeInterval(60) <= now }
        if recentChanges.count >= policy.maximumChangesPerMinute, let oldest = recentChanges.first {
            allowed = max(allowed, oldest.addingTimeInterval(60))
        }
        return allowed
    }

    private mutating func publish(_ icon: AmbientIcon?, at now: Date) -> Change {
        if let previous = current { lastShown[previous.kindID] = now }
        current = icon
        lastChange = now
        recentChanges.append(now)
        statistics.changes += 1
        return Change(icon: icon, date: now)
    }
}
