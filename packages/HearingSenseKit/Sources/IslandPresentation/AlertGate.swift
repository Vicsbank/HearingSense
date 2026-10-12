import Foundation

/// What the app can tell about the lock state while it runs in the background.
///
/// iOS gives an app no direct "is the device locked" query. The estimate rests on data
/// protection: with a passcode set, protected data becomes unavailable some seconds after the
/// device locks and available again when it is unlocked. It is not reliable:
/// - without a passcode nothing can be told (`unknown`);
/// - where the signal does not exist it always reads "available". The iOS Simulator is such a
///   place (measured in Window 5: a locked Simulator reported a passcode and available data).
///   The estimate is therefore `unknown` until this installation has seen protected data become
///   unavailable at least once (`lockSignalObserved`);
/// - protected data stays available for some seconds after locking (measured on the iPhone 18
///   Pro, iOS 27.2: unavailable 4–12 s after the lock button). iOS posts "protected data will
///   become unavailable" earlier: in the two instrumented runs it arrived at the moment of
///   locking, about 1.4 s before the app entered the background. While that notice is pending
///   (`lockNoticePending`) the estimate is `locked`. Two observations are not a guarantee: an
///   alert in the first seconds after locking can still reach a locked screen. The settings
///   screen says so, and the device plan of Window 8 measures it.
public enum DeviceLockEstimate: String, Hashable, Sendable, Codable {
    case unlocked
    case locked
    case unknown

    /// - Parameters:
    ///   - passcodeSet: whether the device has a passcode; nil when that could not be determined.
    ///   - protectedDataAvailable: `UIApplication.isProtectedDataAvailable`.
    ///   - lockSignalObserved: this installation has seen protected data become unavailable
    ///     before, so "available" carries information on this device.
    ///   - lockNoticePending: "protected data will become unavailable" arrived and neither
    ///     "did become available" nor the app coming to the front has followed.
    public static func estimate(passcodeSet: Bool?, protectedDataAvailable: Bool, lockSignalObserved: Bool,
                                lockNoticePending: Bool = false) -> DeviceLockEstimate
    {
        guard passcodeSet == true else { return .unknown }
        guard protectedDataAvailable, !lockNoticePending else { return .locked }
        return lockSignalObserved ? .unlocked : .unknown
    }
}

/// Decides whether an update may carry an ActivityKit alert configuration.
///
/// An alert is the only way an app can ask iOS to present a Live Activity update prominently
/// (to expand the Dynamic Island). On a locked iPhone the same alert lights up the screen and
/// may play a sound. The rule (decision of 2026-10-11):
/// - "Prominent alerts" on (the default) and the iPhone judged `unlocked`: the request is made.
/// - `locked` or `unknown`: a silent update, unless the user opted in to alerts on the locked
///   iPhone (`IslandSettings.alertsWhileLocked`, off by default).
/// - A summary the user asked for follows its own switch and is never announced on a locked
///   iPhone: its text is not shown there anyway.
///
/// Passing the gate is a request, not a result: iOS decides whether the island expands or the
/// screen lights up, and reports nothing back.
public enum AlertGate {
    public enum BlockReason: String, Hashable, Sendable, Codable, CaseIterable {
        case disabledInSettings = "disabled_in_settings"
        case deviceLocked = "device_locked"
        case lockStateUnknown = "lock_state_unknown"
        /// The app is on screen: its own activity is not shown in the island.
        case appInForeground = "app_in_foreground"
    }

    public enum Outcome: Hashable, Sendable {
        case send
        case blocked(BlockReason)
    }

    /// - Parameter isUserRequested: the request announces a summary the user asked for; it
    ///   follows "Show the summary when it is ready" instead of "Prominent alerts", and the
    ///   opt-in for the locked iPhone does not apply to it.
    public static func evaluate(settings: IslandSettings, lock: DeviceLockEstimate, appIsActive: Bool,
                                isUserRequested: Bool = false) -> Outcome
    {
        guard isUserRequested ? settings.expandsForSummaries : settings.expandsForImportantEvents else {
            return .blocked(.disabledInSettings)
        }
        if appIsActive { return .blocked(.appInForeground) }
        let mayWakeLockedScreen = !isUserRequested && settings.alertsWhileLocked
        switch lock {
        case .locked: return mayWakeLockedScreen ? .send : .blocked(.deviceLocked)
        case .unknown: return mayWakeLockedScreen ? .send : .blocked(.lockStateUnknown)
        case .unlocked: return .send
        }
    }
}
