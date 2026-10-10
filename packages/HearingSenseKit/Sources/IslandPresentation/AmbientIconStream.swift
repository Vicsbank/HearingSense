import Foundation
import HearingSenseDomain

/// The icon of one ordinary sound, for the icon-only presentation. Carries no text to draw:
/// `spokenName` exists for VoiceOver only.
public struct AmbientIcon: Hashable, Sendable, Codable {
    /// SF Symbol name.
    public var symbolName: String
    /// `SoundEventKind.id` of the sound.
    public var kindID: String
    public var category: SoundCategory
    /// The kind's name ("Rain"), as an accessibility label.
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
                maximumChangesPerMinute: Int, staleAfter: TimeInterval, excludedKindIDs: Set<String>,
                categoryRank: [SoundCategory: Int], kindRank: [String: Int])
    {
        self.minimumQuality = minimumQuality
        self.minimumDisplay = minimumDisplay
        self.linger = linger
        self.maximumChangesPerMinute = maximumChangesPerMinute
        self.staleAfter = staleAfter
        self.excludedKindIDs = excludedKindIDs
        self.categoryRank = categoryRank
        self.kindRank = kindRank
    }

    public static let standard = AmbientIconPolicy(
        minimumQuality: .moderate,
        minimumDisplay: 4,
        linger: 5,
        maximumChangesPerMinute: 10,
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
/// Against flicker: only confirmed events count (the detector's k-of-n confirmation is the
/// temporal smoothing of the classifier), the evidence quality must be at least
/// `minimumQuality`, a shown icon stays for `minimumDisplay`, an ended sound lingers, a
/// lower-ranked sound never replaces a higher-ranked one that is still present, and changes are
/// limited per minute.
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
    }

    private var tracked: [AcousticEventID: Tracked] = [:]
    private var currentID: AcousticEventID?
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
                               spokenName: event.kind.displayName)
        var entry = tracked[event.id] ?? Tracked(
            icon: icon, rank: policy.rank(kindID: event.kind.id, category: event.category),
            confirmed: event.confirmedDate, lastObserved: event.lastObservedDate, ended: nil, isEligible: false)
        // The primary label can change while an event is ongoing (dog → dog_bark): the icon follows.
        entry.icon = icon
        entry.lastObserved = max(entry.lastObserved, event.lastObservedDate)
        entry.isEligible = entry.isEligible || event.quality >= policy.minimumQuality
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

        let best = tracked.filter(\.value.isEligible).max { lhs, rhs in
            if lhs.value.rank != rhs.value.rank { return lhs.value.rank < rhs.value.rank }
            if lhs.value.confirmed != rhs.value.confirmed { return lhs.value.confirmed < rhs.value.confirmed }
            return lhs.key.description < rhs.key.description
        }

        // Keep the shown sound while it is present, unless something of a higher rank appeared.
        var wantedID = best?.key
        if let currentID, let shown = tracked[currentID], let best, best.value.rank <= shown.rank {
            wantedID = currentID
        }
        let wanted = wantedID.flatMap { tracked[$0]?.icon }

        var pendingChange: Date?
        var change: Change?
        if wanted == current {
            currentID = wantedID
        } else {
            let allowed = earliestChange(after: now)
            if allowed <= now {
                currentID = wantedID
                change = publish(wanted, at: now)
            } else {
                statistics.heldBack += 1
                pendingChange = allowed
            }
        }

        var deadlines: [Date] = pendingChange.map { [$0] } ?? []
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
        current = icon
        lastChange = now
        recentChanges.append(now)
        statistics.changes += 1
        return Change(icon: icon, date: now)
    }
}
