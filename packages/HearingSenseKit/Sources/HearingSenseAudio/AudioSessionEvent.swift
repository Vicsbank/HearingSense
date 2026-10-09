import Foundation

/// Audio-session notifications reduced to Sendable values the app can log and react to.
public enum AudioSessionEvent: Sendable, Equatable {
    case interruptionBegan(reason: String)
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(reason: RouteChangeReason, previousInputs: [String], previousOutputs: [String])
    case mediaServicesWereLost
    case mediaServicesWereReset
    /// Another app's primary audio started (`begin`) or stopped. Useful to see whether
    /// Spotify / Apple Music playback is detected while listening.
    case silenceSecondaryAudioHint(begin: Bool)

    public enum RouteChangeReason: String, Sendable, Equatable {
        case unknown, newDeviceAvailable, oldDeviceUnavailable, categoryChange, override
        case wakeFromSleep, noSuitableRouteForCategory, routeConfigurationChange
    }

    public var logDescription: String {
        switch self {
        case .interruptionBegan(let reason):
            "Interruption began (reason: \(reason))"
        case .interruptionEnded(let shouldResume):
            "Interruption ended (shouldResume: \(shouldResume))"
        case .routeChanged(let reason, let inputs, let outputs):
            "Route changed: \(reason.rawValue); previous in [\(inputs.joined(separator: ", "))] "
                + "out [\(outputs.joined(separator: ", "))]"
        case .mediaServicesWereLost:
            "Media services were lost"
        case .mediaServicesWereReset:
            "Media services were reset"
        case .silenceSecondaryAudioHint(let begin):
            begin ? "Other app's primary audio started (silence-secondary hint: begin)"
                : "Other app's primary audio stopped (silence-secondary hint: end)"
        }
    }
}

#if os(iOS)
import AVFAudio

extension AudioSessionEvent {
    /// Parses an `AVAudioSession.interruptionNotification`.
    init?(interruption notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return nil }
        switch type {
        case .began:
            let rawReason = info[AVAudioSessionInterruptionReasonKey] as? UInt
            self = .interruptionBegan(reason: Self.interruptionReasonName(rawReason))
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            self = .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    /// Parses an `AVAudioSession.routeChangeNotification`.
    init?(routeChange notification: Notification) {
        guard let info = notification.userInfo,
              let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return nil }
        let previous = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        self = .routeChanged(reason: RouteChangeReason(reason),
                             previousInputs: previous?.inputs.map(\.portName) ?? [],
                             previousOutputs: previous?.outputs.map(\.portName) ?? [])
    }

    /// Parses an `AVAudioSession.silenceSecondaryAudioHintNotification`.
    init?(silenceSecondaryAudioHint notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) else { return nil }
        self = .silenceSecondaryAudioHint(begin: type == .begin)
    }

    // Raw values from AVAudioSessionInterruptionReason (iOS 27 SDK). Matching on raw values
    // avoids deprecation warnings for appWasSuspended and keeps unknown future values readable.
    static func interruptionReasonName(_ raw: UInt?) -> String {
        switch raw {
        case nil, 0: "default"
        case 1: "appWasSuspended"
        case 2: "builtInMicMuted"
        case 3: "sceneWasBackgrounded"
        case 4: "routeDisconnected"
        case 5: "deviceUnauthenticated"
        case let value?: "unknown(\(value))"
        }
    }
}

extension AudioSessionEvent.RouteChangeReason {
    init(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .unknown: self = .unknown
        case .newDeviceAvailable: self = .newDeviceAvailable
        case .oldDeviceUnavailable: self = .oldDeviceUnavailable
        case .categoryChange: self = .categoryChange
        case .override: self = .override
        case .wakeFromSleep: self = .wakeFromSleep
        case .noSuitableRouteForCategory: self = .noSuitableRouteForCategory
        case .routeConfigurationChange: self = .routeConfigurationChange
        @unknown default: self = .unknown
        }
    }
}

/// Observes AVAudioSession notifications for as long as the instance is alive.
/// The handler is called on the thread that posted the notification.
public final class AudioSessionObserver {
    private var tokens: [any NSObjectProtocol] = []

    public init(session: AVAudioSession = .sharedInstance(),
                handler: @escaping @Sendable (AudioSessionEvent) -> Void) {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ parse: @escaping @Sendable (Notification) -> AudioSessionEvent?) {
            tokens.append(center.addObserver(forName: name, object: session, queue: nil) { notification in
                if let event = parse(notification) { handler(event) }
            })
        }
        observe(AVAudioSession.interruptionNotification) { AudioSessionEvent(interruption: $0) }
        observe(AVAudioSession.routeChangeNotification) { AudioSessionEvent(routeChange: $0) }
        observe(AVAudioSession.silenceSecondaryAudioHintNotification) { AudioSessionEvent(silenceSecondaryAudioHint: $0) }
        observe(AVAudioSession.mediaServicesWereLostNotification) { _ in .mediaServicesWereLost }
        observe(AVAudioSession.mediaServicesWereResetNotification) { _ in .mediaServicesWereReset }
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
#endif
