import Foundation

/// How the one Live Activity of a listening session relates to iOS's limits.
///
/// Apple documents that a Live Activity is active for up to eight hours, after which the system
/// ends it. The app does not work around that (decision of 2026-10-11): a running activity is
/// never replaced by a fresh one, and when the system has ended it at its limit no activity is
/// requested in its place for that session. Listening is not affected; the next listening
/// session gets its own activity.
///
/// What remains is ordinary lifecycle: an activity that could not be started (it was requested
/// while the app was not on screen) or that was removed before its time is shown again when the
/// user opens the app, and leftovers of an earlier launch are ended.
///
/// The limit of the activity says nothing about how long the microphone or the recognition can
/// run in the background: that has to be measured on a device.
public struct ActivityLifetimePolicy: Hashable, Sendable {
    /// The system's documented limit for an active Live Activity.
    public var systemLimit: TimeInterval = 8 * 3600
    /// An activity that ended this close to the limit (or after it) was ended by the limit.
    public var limitTolerance: TimeInterval = 10 * 60

    public init() {}

    public static let standard = ActivityLifetimePolicy()

    public enum Decision: String, Hashable, Sendable, CaseIterable {
        /// Nothing to do: no session, or the activity is there.
        case keep
        /// A session is running without an activity and the app is on screen: request one.
        case start
        /// A session is running without an activity and the app is not on screen: nothing can
        /// be requested now.
        case waitForForeground
        /// The system ended this session's activity at its limit: nothing is requested.
        case stayEnded
    }

    /// Whether an activity that was requested at `start` and ended at `end` ran into the limit.
    public func endedAtLimit(startedAt start: Date, endedAt end: Date) -> Bool {
        end.timeIntervalSince(start) >= systemLimit - limitTolerance
    }

    /// - Parameters:
    ///   - sessionIsLive: a listening session wants an activity.
    ///   - reachedLimit: this session's activity was ended by the system's limit.
    public func decide(sessionIsLive: Bool, hasActivity: Bool, reachedLimit: Bool, appIsActive: Bool) -> Decision {
        guard sessionIsLive, !hasActivity else { return .keep }
        if reachedLimit { return .stayEnded }
        return appIsActive ? .start : .waitForForeground
    }

    /// When the system is expected to end an activity that started at `start`.
    public func expectedEnd(startedAt start: Date) -> Date { start.addingTimeInterval(systemLimit) }
}
