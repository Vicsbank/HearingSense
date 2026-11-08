#if DEBUG
import Foundation

/// What a Debug build may do during a device test (Window 8). Stored on the device, so it also
/// applies to a process that iOS starts for an App Intent (the Action Button), where there are
/// no launch arguments.
///
/// A value type without a store and without a clock, so the rules are testable. The rule that
/// matters is fail-closed: anything that is not a readable record of the current version —
/// nothing stored, damaged data, an older or newer version — resolves to `locked`, in which the
/// microphone, speech transcription and model inference are all prohibited. Permissions are
/// only ever added by an explicit command (`applying(arguments:)`), never by default.
///
/// Compiled in Debug builds only: a Release build of the app contains none of it.
public struct DeviceTestConfiguration: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let defaultSessionLimit: TimeInterval = 180
    public static let sessionLimitRange: ClosedRange<TimeInterval> = 10 ... 600

    /// Where the configuration in use came from.
    public enum Origin: String, Hashable, Sendable {
        case stored
        /// Nothing was stored: the locked configuration.
        case missing
        /// The stored data could not be used: the locked configuration.
        case unreadable
    }

    /// What a start request gets.
    public enum CaptureDecision: String, Hashable, Sendable {
        case microphone
        /// A session without the microphone: the switch, the Live Activity and the controls run,
        /// the audio session is not activated and the engine is not started.
        case synthetic
        /// Nothing starts (emergency stop).
        case refused
    }

    public var version: Int
    /// False: the build behaves like the product, without any of the restrictions below. Only
    /// reached with the explicit command `off`.
    public var isEnabled: Bool
    public var allowsMicrophone: Bool
    public var allowsTranscription: Bool
    public var allowsModelInference: Bool
    /// Every session ends by itself after this many seconds.
    public var sessionLimit: TimeInterval
    public var exportsDiagnostics: Bool
    /// Emergency stop: nothing starts until it is cleared.
    public var isHalted: Bool

    public init(isEnabled: Bool = true, allowsMicrophone: Bool = false, allowsTranscription: Bool = false,
                allowsModelInference: Bool = false, sessionLimit: TimeInterval = DeviceTestConfiguration.defaultSessionLimit,
                exportsDiagnostics: Bool = true, isHalted: Bool = false)
    {
        version = Self.currentVersion
        self.isEnabled = isEnabled
        self.allowsMicrophone = allowsMicrophone
        self.allowsTranscription = allowsTranscription
        self.allowsModelInference = allowsModelInference
        self.sessionLimit = sessionLimit
        self.exportsDiagnostics = exportsDiagnostics
        self.isHalted = isHalted
    }

    /// Test mode on, everything prohibited, sessions end after three minutes.
    public static let locked = DeviceTestConfiguration()

    /// The configuration to use for stored data. Never throws and never returns more than was stored.
    public static func resolve(_ stored: Data?) -> (configuration: DeviceTestConfiguration, origin: Origin) {
        guard let stored else { return (.locked, .missing) }
        guard let decoded = try? JSONDecoder().decode(DeviceTestConfiguration.self, from: stored),
              decoded.version == currentVersion, decoded.sessionLimit.isFinite
        else { return (.locked, .unreadable) }
        return (decoded.normalized, .stored)
    }

    /// The same permissions with the session limit inside its range.
    public var normalized: DeviceTestConfiguration {
        var copy = self
        copy.sessionLimit = min(max(sessionLimit, Self.sessionLimitRange.lowerBound), Self.sessionLimitRange.upperBound)
        return copy
    }

    // MARK: - Rules

    public var prohibitsMicrophone: Bool { isEnabled && (!allowsMicrophone || isHalted) }
    /// Transcription needs the microphone: prohibiting one prohibits the other.
    public var prohibitsTranscription: Bool { isEnabled && (!allowsTranscription || prohibitsMicrophone) }
    public var prohibitsModelInference: Bool { isEnabled && (!allowsModelInference || isHalted) }
    /// How long a session may last; nil when the test mode is off.
    public var effectiveSessionLimit: TimeInterval? { isEnabled ? normalized.sessionLimit : nil }

    /// A start asked for by `source`. A start made by a launch argument or a script is never a
    /// recording: only something a person pressed (the app's button, the intent) can get the
    /// microphone, and only when it is allowed.
    public func capture(for source: ListeningRequestSource) -> CaptureDecision {
        guard isEnabled else { return .microphone }
        if isHalted { return .refused }
        return allowsMicrophone && source != .automation ? .microphone : .synthetic
    }

    // MARK: - Commands (launch arguments)

    public static let modeArgument = "--hs-test-mode"
    public static let allowArgument = "--hs-test-allow"
    public static let sessionLimitArgument = "--hs-test-session-limit"

    /// The configuration after the commands in a launch's arguments, and what was done, for the log.
    ///
    /// - `--hs-test-mode locked`: back to the locked configuration (also clears an emergency stop).
    /// - `--hs-test-mode stop`: emergency stop. `--hs-test-mode resume`: clears it.
    /// - `--hs-test-mode off`: no test mode.
    /// - `--hs-test-allow microphone,transcription,model`: adds permissions, in a later scope.
    /// - `--hs-test-session-limit <seconds>`.
    ///
    /// A command that is not understood changes nothing. A stop in the same launch wins over
    /// everything else.
    public func applying(arguments: [String]) -> (configuration: DeviceTestConfiguration, notes: [String]) {
        var result = self
        var notes: [String] = []
        func value(after argument: String) -> String? {
            guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let mode = value(after: Self.modeArgument)
        switch mode {
        case "locked":
            result = .locked
            notes.append("reset to locked")
        case "off":
            result.isEnabled = false
            notes.append("test mode switched off")
        case "resume":
            result.isHalted = false
            notes.append("emergency stop cleared")
        case "stop", nil:
            break
        case .some(let unknown):
            notes.append("unknown mode “\(unknown)” ignored")
        }
        if let list = value(after: Self.allowArgument) {
            for item in list.split(separator: ",") {
                switch item {
                case "microphone": result.allowsMicrophone = true
                case "transcription": result.allowsTranscription = true
                case "model": result.allowsModelInference = true
                default:
                    notes.append("unknown permission “\(item)” ignored")
                    continue
                }
                notes.append("\(item) allowed")
            }
        }
        if let text = value(after: Self.sessionLimitArgument) {
            if let seconds = TimeInterval(text), seconds.isFinite, seconds > 0 {
                result.sessionLimit = seconds
                result = result.normalized
                notes.append("session limit \(Int(result.sessionLimit)) s")
            } else {
                notes.append("session limit “\(text)” ignored")
            }
        }
        if mode == "stop" {
            result.isHalted = true
            notes.append("emergency stop set")
        }
        return (result, notes)
    }

    /// One field for diagnostics.
    public func summary(origin: Origin) -> String {
        guard isEnabled else { return "off" }
        func word(_ isProhibited: Bool) -> String { isProhibited ? "prohibited" : "allowed" }
        return "on(microphone=\(word(prohibitsMicrophone)),transcription=\(word(prohibitsTranscription)),"
            + "model=\(word(prohibitsModelInference)),sessionLimit=\(Int(normalized.sessionLimit))s,"
            + "halted=\(isHalted ? "yes" : "no"),origin=\(origin.rawValue))"
    }
}
#endif
