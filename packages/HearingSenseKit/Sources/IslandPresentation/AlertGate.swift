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
/// - for a few seconds after locking the estimate can still say `unlocked`. Nothing here can
///   close that gap, which is why automatic expansion is off unless the user turns it on.
public enum DeviceLockEstimate: String, Hashable, Sendable, Codable {
    case unlocked
    case locked
    case unknown

    /// - Parameters:
    ///   - passcodeSet: whether the device has a passcode; nil when that could not be determined.
    ///   - protectedDataAvailable: `UIApplication.isProtectedDataAvailable`.
    ///   - lockSignalObserved: this installation has seen protected data become unavailable
    ///     before, so "available" carries information on this device.
    public static func estimate(passcodeSet: Bool?, protectedDataAvailable: Bool, lockSignalObserved: Bool)
        -> DeviceLockEstimate
    {
        guard passcodeSet == true else { return .unknown }
        guard protectedDataAvailable else { return .locked }
        return lockSignalObserved ? .unlocked : .unknown
    }
}

/// Decides whether an update may carry an ActivityKit alert configuration.
///
/// An alert is the only way an app can ask iOS to expand the Dynamic Island. On a locked iPhone
/// the same alert lights up the screen and may play a sound, which this app must never cause.
/// The rule is therefore one-sided: an alert is sent only when the device is judged `unlocked`;
/// `locked` and `unknown` both mean a silent update. Not waking the screen has precedence over
/// automatic expansion.
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

    public static func evaluate(settings: IslandSettings, lock: DeviceLockEstimate, appIsActive: Bool) -> Outcome {
        guard settings.expandsForImportantEvents else { return .blocked(.disabledInSettings) }
        switch lock {
        case .locked: return .blocked(.deviceLocked)
        case .unknown: return .blocked(.lockStateUnknown)
        case .unlocked: break
        }
        if appIsActive { return .blocked(.appInForeground) }
        return .send
    }
}
