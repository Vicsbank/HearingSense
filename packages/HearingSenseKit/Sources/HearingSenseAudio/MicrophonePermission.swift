import AVFAudio

/// Record-permission state, wrapping `AVAudioApplication` (iOS 17+ / macOS 14+).
public enum MicrophonePermission: String, Sendable, Equatable {
    case undetermined
    case denied
    case granted

    public static var current: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    /// Shows the system prompt if the user has not decided yet; otherwise returns immediately.
    public static func request() async -> MicrophonePermission {
        await AVAudioApplication.requestRecordPermission() ? .granted : .denied
    }
}
