import Foundation
import HearingSenseDomain

public struct AcousticScenePolicy: Hashable, Sendable {
    /// Evidence older than this does not count.
    public var window: TimeInterval = 60
    /// A scene needs this many weighted seconds of its sounds inside the window.
    public var minimumEvidence: TimeInterval = 10
    /// …and this share of all evidence to take over,
    public var dominance = 0.55
    /// …but only this share to stay (hysteresis).
    public var stayDominance = 0.40
    /// Less evidence than this in the whole window is "quiet".
    public var quietBelow: TimeInterval = 4
    /// Nothing is called quiet before the session has listened this long.
    public var quietAfter: TimeInterval = 20
    /// A different scene must lead for this long without a break before it replaces the current one.
    public var switchDwell: TimeInterval = 10
    /// A scene stays at least this long.
    public var minimumHold: TimeInterval = 20
    /// A short sound (a horn, a knock) counts as at least this long.
    public var minimumEventCredit: TimeInterval = 2
    /// An event that is still open counts up to this long after its last published update (the
    /// detector republishes an ongoing event only every few seconds, and only when it changed).
    public var openEventGrace: TimeInterval = 20
    /// How often the estimate is looked at again while something can still change.
    public var step: TimeInterval = 5
    /// Hard bound on remembered events.
    public var maximumEvents = 96

    public init() {}

    public static let standard = AcousticScenePolicy()

    /// Which scene a kind of sound is evidence for; nil: none (it says nothing about the scene).
    public func scene(for kind: SoundEventKind) -> AcousticScene? {
        switch kind.id {
        case "silence", "unmapped", "mic_wind_noise", "whoosh": return nil
        // Warning devices on the road are traffic evidence; an alarm clock or a smoke detector is not.
        case "siren", "vehicle_horn", "reverse_beeps", "bicycle_bell": return .traffic
        case "alarm": return .indoor
        case "laughter": return .conversation
        case "footsteps", "body_sounds", "hands", "whistling", "crying", "screaming", "sports": return nil
        case "dog", "cat": return nil
        default: break
        }
        switch kind.category {
        case .speech, .crowd: return .conversation
        case .transportation: return .traffic
        case .weatherNature, .animals: return .nature
        case .music: return .music
        case .household: return .indoor
        case .alerts, .impacts, .humanActivity, .other: return nil
        }
    }

    public func weight(for quality: EventQuality) -> Double {
        switch quality {
        case .weak: 0.5
        case .moderate: 0.8
        case .strong: 1
        }
    }
}

public enum AcousticSceneInput: Hashable, Sendable {
    case sessionStarted(at: Date)
    case sessionEnded(at: Date)
    /// Window 2: a confirmed sound event started, changed or ended.
    case sound(AcousticEventUpdate)
    /// Time passed (the host calls this at `AcousticSceneTracker.nextDeadline`).
    case tick(at: Date)

    public var date: Date {
        switch self {
        case .sessionStarted(let date), .sessionEnded(let date), .tick(let date): date
        case .sound(.started(let event)): event.confirmedDate
        case .sound(.updated(let event)): event.lastObservedDate
        case .sound(.ended(let event)): event.endedDate ?? event.lastObservedDate
        }
    }
}

/// The acoustic scene layer (Window 7): which kind of surroundings the recognized sounds of the
/// last minute add up to.
///
/// ```
/// confirmed sound events ──▶ evidence per scene (weighted seconds in a rolling window)
///                          ──▶ candidate (dominant scene, "mixed", or "quiet")
///                          ──▶ dwell + minimum hold ──▶ scene
/// ```
///
/// It reads only what the sound classifier already confirmed: no audio, no language model, no
/// location. A value type without a clock: the same inputs give the same scenes, and the host
/// sends one `.tick` at `nextDeadline`.
public struct AcousticSceneTracker: Sendable {
    public struct Statistics: Hashable, Sendable, Codable {
        public var soundInputs = 0
        public var evaluations = 0
        public var changes = 0
        /// A candidate led for a while and lost the lead before the dwell time was over.
        public var candidatesAbandoned = 0

        public init() {}
    }

    private struct Evidence {
        var scene: AcousticScene
        var start: Date
        var lastObserved: Date
        var end: Date?
        var weight: Double
    }

    public let policy: AcousticScenePolicy
    public private(set) var current: AcousticSceneEstimate?
    public private(set) var statistics = Statistics()
    public private(set) var nextDeadline: Date?
    /// The scene that would take over if it keeps leading (for diagnostics).
    public private(set) var candidate: AcousticScene?

    private var isActive = false
    private var sessionStart: Date?
    private var events: [AcousticEventID: Evidence] = [:]
    private var candidateSince: Date?

    public init(policy: AcousticScenePolicy = .standard) {
        self.policy = policy
    }

    /// Returns the new estimate when the scene changed, nil otherwise.
    @discardableResult
    public mutating func process(_ input: AcousticSceneInput) -> AcousticSceneEstimate? {
        let now = input.date
        switch input {
        case .sessionStarted:
            guard !isActive else { break }
            reset()
            isActive = true
            sessionStart = now
        case .sessionEnded:
            reset()
            return nil
        case .sound(let update):
            guard isActive else { return nil }
            statistics.soundInputs += 1
            note(update)
        case .tick:
            guard isActive else { return nil }
        }
        return evaluate(at: now)
    }

    /// Weighted seconds of evidence per scene inside the window that ends at `now`.
    public func evidence(at now: Date) -> [AcousticScene: TimeInterval] {
        let windowStart = now.addingTimeInterval(-policy.window)
        var totals: [AcousticScene: TimeInterval] = [:]
        for item in events.values {
            let end = min(item.end ?? item.lastObserved.addingTimeInterval(policy.openEventGrace), now)
            let from = max(item.start, windowStart)
            var seconds = end.timeIntervalSince(from)
            // A short sound that lies inside the window counts as a little more than its length.
            if end > windowStart { seconds = max(seconds, min(policy.minimumEventCredit, now.timeIntervalSince(from))) }
            guard seconds > 0 else { continue }
            totals[item.scene, default: 0] += seconds * item.weight
        }
        return totals
    }

    private mutating func reset() {
        isActive = false
        sessionStart = nil
        events.removeAll()
        current = nil
        candidate = nil
        candidateSince = nil
        nextDeadline = nil
    }

    private mutating func note(_ update: AcousticEventUpdate) {
        let event = update.event
        guard let scene = policy.scene(for: event.kind) else { return }
        var item = events[event.id] ?? Evidence(scene: scene, start: event.startDate, lastObserved: event.lastObservedDate,
                                                end: nil, weight: policy.weight(for: event.quality))
        item.lastObserved = max(item.lastObserved, event.lastObservedDate)
        item.weight = max(item.weight, policy.weight(for: event.quality))
        if case .ended = update { item.end = event.endedDate ?? event.lastObservedDate }
        events[event.id] = item
        if events.count > policy.maximumEvents, let oldest = events.min(by: { $0.value.lastObserved < $1.value.lastObserved }) {
            events[oldest.key] = nil
        }
    }

    private mutating func evaluate(at now: Date) -> AcousticSceneEstimate? {
        statistics.evaluations += 1
        let windowStart = now.addingTimeInterval(-policy.window)
        for (id, item) in events {
            let end = item.end ?? item.lastObserved.addingTimeInterval(policy.openEventGrace)
            if end <= windowStart { events[id] = nil }
        }
        let totals = evidence(at: now)
        let total = totals.values.reduce(0, +)
        // Ties are broken by the order of the cases, so that the result does not depend on a dictionary.
        let leader = AcousticScene.allCases.compactMap { scene in totals[scene].map { (scene, $0) } }
            .max { $0.1 < $1.1 }

        var wanted: (scene: AcousticScene, confidence: Double)?
        if total < policy.quietBelow {
            if let sessionStart, now.timeIntervalSince(sessionStart) >= policy.quietAfter {
                wanted = (.quiet, 1 - total / policy.quietBelow)
            }
        } else if let leader {
            let share = leader.1 / total
            let needed = leader.0 == current?.scene ? policy.stayDominance : policy.dominance
            if leader.1 >= policy.minimumEvidence, share >= needed {
                wanted = (leader.0, share)
            } else if total >= policy.minimumEvidence * 1.5, totals.count >= 2, share < policy.stayDominance {
                wanted = (.mixed, 1 - share)
            }
        }

        var change: AcousticSceneEstimate?
        if let wanted {
            if wanted.scene == current?.scene {
                current?.confidence = wanted.confidence
                abandonCandidate()
            } else {
                if candidate != wanted.scene {
                    abandonCandidate()
                    candidate = wanted.scene
                    candidateSince = now
                }
                let dwelled = candidateSince.map { now.timeIntervalSince($0) >= policy.switchDwell } ?? false
                let held = current.map { now.timeIntervalSince($0.since) >= policy.minimumHold } ?? true
                if dwelled, held {
                    let estimate = AcousticSceneEstimate(scene: wanted.scene, confidence: wanted.confidence, since: now)
                    current = estimate
                    candidate = nil
                    candidateSince = nil
                    statistics.changes += 1
                    change = estimate
                }
            }
        } else {
            // Not enough to decide: the current scene stays.
            abandonCandidate()
        }

        // Look again while evidence is still inside the window or a decision is pending;
        // a settled quiet scene with no evidence needs no timer.
        let isSettledQuiet = events.isEmpty && current?.scene == .quiet && candidate == nil
        let isWaitingForQuiet = events.isEmpty && current == nil
        if isSettledQuiet {
            nextDeadline = nil
        } else if isWaitingForQuiet, let sessionStart {
            nextDeadline = max(sessionStart.addingTimeInterval(policy.quietAfter), now.addingTimeInterval(policy.step))
        } else {
            nextDeadline = now.addingTimeInterval(policy.step)
        }
        return change
    }

    private mutating func abandonCandidate() {
        if candidate != nil { statistics.candidatesAbandoned += 1 }
        candidate = nil
        candidateSince = nil
    }
}
