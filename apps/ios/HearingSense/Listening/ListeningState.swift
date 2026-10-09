import Foundation

/// User-visible listening state. Every state has a text title and a symbol so status is
/// never conveyed by color alone.
enum ListeningState: Equatable {
    case idle
    case requestingPermission
    case permissionDenied
    case starting
    case listening
    /// The system interrupted the session (phone call, Siri, another app's recording...).
    case interrupted
    case failed(String)

    var isCapturing: Bool { self == .listening }

    /// The Start button is offered in these states.
    var canStart: Bool {
        switch self {
        case .idle, .permissionDenied, .interrupted, .failed: true
        case .requestingPermission, .starting, .listening: false
        }
    }

    /// The Stop button is offered in these states.
    var canStop: Bool {
        self == .listening || self == .interrupted || self == .starting
    }

    var title: String {
        switch self {
        case .idle: "Not listening"
        case .requestingPermission: "Waiting for microphone permission"
        case .permissionDenied: "Microphone access is off"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .interrupted: "Paused by the system"
        case .failed: "Could not start listening"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "The microphone is off. Nothing is being captured."
        case .requestingPermission:
            "Allow microphone access so Hearing Sense can measure sound around you."
        case .permissionDenied:
            "Turn on microphone access for Hearing Sense in Settings to start listening."
        case .starting:
            "Configuring the audio session."
        case .listening:
            "The microphone is on. Audio is analyzed in memory only and is never recorded or uploaded."
        case .interrupted:
            "Another audio event took priority (for example a phone call). Listening resumes automatically if iOS allows it; otherwise tap Start Listening."
        case .failed(let message):
            message
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "mic.slash"
        case .requestingPermission: "hand.raised"
        case .permissionDenied: "mic.slash.circle"
        case .starting: "hourglass"
        case .listening: "waveform.circle.fill"
        case .interrupted: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
