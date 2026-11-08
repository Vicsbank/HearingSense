import Foundation

/// A hard end for a listening session: "the microphone is off at `deadline`, whatever else
/// happens". Used for timed device tests, which must end by themselves.
///
/// A value type without a clock, so the rule is testable: the host asks `isDue(at:)` from more
/// than one place (a timer, and every audio buffer that still arrives) and reports the stop with
/// `fire(at:trigger:)`. Once the deadline has passed nothing may start capturing again under this
/// limit — `allowsCapture(at:)` — so a session that was interrupted before the deadline cannot
/// resume after it.
public struct SessionTimeLimit: Hashable, Sendable {
    public enum Trigger: String, Hashable, Sendable {
        /// The host's timer for the deadline.
        case timer
        /// An audio buffer arrived at or after the deadline (the timer did not run in time).
        case captureTick = "capture tick"
        /// Capture was about to start or resume after the deadline.
        case startRefused = "start refused"
    }

    public let armedAt: Date
    public let deadline: Date
    public private(set) var firedAt: Date?
    public private(set) var trigger: Trigger?

    public init(armedAt: Date, duration: TimeInterval) {
        self.armedAt = armedAt
        deadline = armedAt.addingTimeInterval(max(duration, 0))
    }

    public var duration: TimeInterval { deadline.timeIntervalSince(armedAt) }
    public var hasFired: Bool { firedAt != nil }

    /// The stop is owed: the deadline has passed and it was not carried out yet.
    public func isDue(at date: Date) -> Bool { !hasFired && date >= deadline }

    /// Capture may run (start, resume or continue) at `date`.
    public func allowsCapture(at date: Date) -> Bool { date < deadline }

    /// Records the stop. Only the first call counts.
    public mutating func fire(at date: Date, trigger: Trigger) {
        guard firedAt == nil else { return }
        firedAt = date
        self.trigger = trigger
    }

    /// How late the stop was (0 when on time or early).
    public var lateness: TimeInterval? { firedAt.map { max($0.timeIntervalSince(deadline), 0) } }

    /// One field for diagnostics: `off`, `in 42s`, `due`, `fired+0.0s(timer)`.
    public func heartbeat(at date: Date) -> String {
        if let lateness, let trigger {
            return "fired+\(lateness.formatted(.number.precision(.fractionLength(1))))s(\(trigger.rawValue))"
        }
        let remaining = deadline.timeIntervalSince(date)
        return remaining > 0 ? "in \(Int(remaining.rounded(.up)))s" : "due"
    }
}
