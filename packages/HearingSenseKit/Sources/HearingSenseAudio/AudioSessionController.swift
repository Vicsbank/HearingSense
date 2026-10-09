#if os(iOS)
import AVFAudio

/// Applies an `AudioSessionPolicy` to the shared AVAudioSession and manages activation.
///
/// Order required by AVAudioSession: set category/mode → activate → set preferred input.
/// Start `MicrophoneCapture` only after `activate(policy:)` returns so the input node sees
/// the final route. Call from the main actor; these calls can block briefly.
///
/// Window 2: steps whose target state already holds are skipped (same category/mode/options,
/// session already active, same preferred input), because each real reconfiguration can
/// renegotiate the hardware route and briefly stall other apps' playback. Every activation and
/// deactivation records which steps ran and how long they took (`lastTrace`).
public final class AudioSessionController {
    public enum PreferredInputResult: Sendable, Equatable {
        case selected(AudioPortInfo)
        case unavailable(AudioSessionPolicy.PreferredInput)
        case systemDefault
    }

    /// Which session calls an activation or deactivation actually made, with durations.
    public struct Trace: Sendable, Equatable {
        public struct Step: Sendable, Equatable {
            public var name: String
            public var performed: Bool
            public var seconds: Double
        }

        public var steps: [Step] = []

        public var summary: String {
            steps.map { step in
                step.performed
                    ? "\(step.name) \((step.seconds * 1000).formatted(.number.precision(.fractionLength(1)))) ms"
                    : "\(step.name) skipped"
            }.joined(separator: ", ")
        }
    }

    private let session: AVAudioSession
    /// Whether this controller activated the session and has not deactivated it since.
    public private(set) var isActive = false
    public private(set) var lastTrace = Trace()

    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    /// Configures and activates the session, then applies the policy's preferred input.
    @discardableResult
    public func activate(policy: AudioSessionPolicy) throws -> PreferredInputResult {
        var trace = Trace()
        defer { lastTrace = trace }
        let categoryMatches = session.category == .playAndRecord && session.mode == policy.sessionMode
            && session.categoryOptions == policy.categoryOptions
        try trace.measure("setCategory", perform: !categoryMatches) {
            try session.setCategory(.playAndRecord, mode: policy.sessionMode, options: policy.categoryOptions)
        }
        try trace.measure("setActive(true)", perform: !isActive) {
            try session.setActive(true)
        }
        isActive = true
        var result = PreferredInputResult.systemDefault
        try trace.measure("setPreferredInput", perform: true) {
            result = try applyPreferredInput(policy.preferredInput)
        }
        return result
    }

    /// Deactivates the session and lets interrupted apps resume. Stop capture first.
    public func deactivate() throws {
        var trace = Trace()
        defer { lastTrace = trace }
        try trace.measure("setActive(false)", perform: true) {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        isActive = false
    }

    /// Records that iOS deactivated the session (interruption, media-services reset), so the
    /// next `activate` calls `setActive(true)` again.
    public func noteDeactivatedBySystem() {
        isActive = false
    }

    /// Applies a preferred input; skips the call when that input is already preferred.
    public func applyPreferredInput(_ preference: AudioSessionPolicy.PreferredInput) throws -> PreferredInputResult {
        let inputs = session.availableInputs ?? []
        let match: AVAudioSessionPortDescription?
        switch preference {
        case .systemDefault:
            if session.preferredInput != nil { try session.setPreferredInput(nil) }
            return .systemDefault
        case .builtInMicrophone:
            match = inputs.first { $0.portType == .builtInMic }
        case .bluetoothMicrophone:
            match = inputs.first { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }
        }
        guard let match else { return .unavailable(preference) }
        if session.preferredInput?.uid != match.uid { try session.setPreferredInput(match) }
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

private extension AudioSessionController.Trace {
    mutating func measure(_ name: String, perform: Bool, _ body: () throws -> Void) throws {
        guard perform else {
            steps.append(Step(name: name, performed: false, seconds: 0))
            return
        }
        let start = ContinuousClock.now
        defer {
            let elapsed = (ContinuousClock.now - start).components
            steps.append(Step(name: name, performed: true,
                              seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18))
        }
        try body()
    }
}
#endif
