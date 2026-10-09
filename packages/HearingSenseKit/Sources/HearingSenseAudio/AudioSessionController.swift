#if os(iOS)
import AVFAudio

/// Applies an `AudioSessionPolicy` to the shared AVAudioSession and manages activation.
///
/// Order required by AVAudioSession: set category/mode → activate → set preferred input.
/// Start `MicrophoneCapture` only after `activate(policy:)` returns so the input node sees
/// the final route. Call from the main actor; these calls can block briefly.
public final class AudioSessionController {
    public enum PreferredInputResult: Sendable, Equatable {
        case selected(AudioPortInfo)
        case unavailable(AudioSessionPolicy.PreferredInput)
        case systemDefault
    }

    private let session: AVAudioSession

    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    /// Configures and activates the session, then applies the policy's preferred input.
    @discardableResult
    public func activate(policy: AudioSessionPolicy) throws -> PreferredInputResult {
        try session.setCategory(.playAndRecord, mode: policy.sessionMode, options: policy.categoryOptions)
        try session.setActive(true)
        return try applyPreferredInput(policy.preferredInput)
    }

    /// Deactivates the session and lets interrupted apps resume. Stop capture first.
    public func deactivate() throws {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    public func applyPreferredInput(_ preference: AudioSessionPolicy.PreferredInput) throws -> PreferredInputResult {
        let inputs = session.availableInputs ?? []
        let match: AVAudioSessionPortDescription?
        switch preference {
        case .systemDefault:
            try session.setPreferredInput(nil)
            return .systemDefault
        case .builtInMicrophone:
            match = inputs.first { $0.portType == .builtInMic }
        case .bluetoothMicrophone:
            match = inputs.first { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }
        }
        guard let match else { return .unavailable(preference) }
        try session.setPreferredInput(match)
        return .selected(AudioPortInfo(match))
    }

    /// Selects a specific available input by UID (nil restores the system default).
    public func setPreferredInput(uid: String?) throws {
        guard let uid else {
            try session.setPreferredInput(nil)
            return
        }
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else { return }
        try session.setPreferredInput(port)
    }

    public func snapshot() -> AudioRouteSnapshot {
        AudioRouteSnapshot.capture(from: session)
    }
}
#endif
