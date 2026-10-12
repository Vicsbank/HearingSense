import Foundation

/// How the one Live Activity of a listening session is kept within iOS's limits (Window 7).
///
/// Apple documents that a Live Activity is active for up to eight hours, after which the
/// system ends it. An app can request a new one only while it is on screen (or from an App
/// Intent made for it). So: when the app is on screen and the activity is old, it is replaced
/// by a fresh one before the system ends it; when the system ended it while the app was in the
/// background, listening goes on and a new activity is requested the next time the app is opened.
///
/// The limit of the activity says nothing about how long the microphone or the recognition can
/// run in the background: that has to be measured on a device.
public struct ActivityLifetimePolicy: Hashable, Sendable {
    /// The system's documented limit for an active Live Activity.
    public var systemLimit: TimeInterval = 8 * 3600
    /// From this age on the activity is replaced whenever the app is on screen.
    public var renewAfter: TimeInterval = 7 * 3600

    public init() {}

    public static let standard = ActivityLifetimePolicy()

    public enum Decision: String, Hashable, Sendable {
        /// Nothing to do.
        case keep
        /// A session is running without an activity and the app is on screen: request one.
        case start
        /// The activity is old and the app is on screen: end it and request a fresh one.
        case renew
        /// A session is running without an activity (or with one past the limit) and the app
        /// is not on screen: nothing can be requested now.
        case waitForForeground
    }

    /// - Parameters:
    ///   - sessionIsLive: a listening session wants an activity.
    ///   - activityStartedAt: when the current activity was requested; nil when there is none.
    public func decide(sessionIsLive: Bool, activityStartedAt: Date?, appIsActive: Bool, now: Date) -> Decision {
        guard sessionIsLive else { return .keep }
        guard let activityStartedAt else { return appIsActive ? .start : .waitForForeground }
        let age = now.timeIntervalSince(activityStartedAt)
        if age >= renewAfter { return appIsActive ? .renew : (age >= systemLimit ? .waitForForeground : .keep) }
        return .keep
    }

    /// When the system is expected to end an activity that started at `start`.
    public func expectedEnd(startedAt start: Date) -> Date { start.addingTimeInterval(systemLimit) }
}
