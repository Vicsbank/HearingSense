import Foundation

/// A named AVAudioSession configuration. The app exposes these as presets so the routing
/// behaviour of each can be compared on a physical iPhone (docs/AUDIO_ROUTING_FEASIBILITY.md).
///
/// Every policy uses the `playAndRecord` category: it is the only category that both
/// records and accepts `mixWithOthers`, which keeps Spotify / Apple Music playing instead
/// of interrupting them. `duckOthers` is never set, so other apps' volume is not lowered.
public struct AudioSessionPolicy: Sendable, Hashable, Identifiable {
    public enum Mode: String, Sendable, Hashable {
        /// System default input processing (includes automatic gain control on iPhone).
        case `default`
        /// Minimal system input processing. Apple documents `mixWithOthers` as valid with the
        /// default mode, so whether this combination keeps other audio playing must be tested.
        case measurement
    }

    public enum Option: String, Sendable, Hashable, CaseIterable {
        case mixWithOthers
        case allowBluetoothA2DP
        case allowBluetoothHFP
        case defaultToSpeaker
        case bluetoothHighQualityRecording
    }

    public enum PreferredInput: String, Sendable, Hashable {
        case builtInMicrophone
        case bluetoothMicrophone
        case systemDefault
    }

    public let id: String
    public let title: String
    public let summary: String
    public let mode: Mode
    public let options: [Option]
    public let preferredInput: PreferredInput
    public let isExperimental: Bool

    public init(id: String, title: String, summary: String, mode: Mode, options: [Option],
                preferredInput: PreferredInput, isExperimental: Bool) {
        self.id = id
        self.title = title
        self.summary = summary
        self.mode = mode
        self.options = options
        self.preferredInput = preferredInput
        self.isExperimental = isExperimental
    }

    public var categoryName: String { "playAndRecord" }

    /// Recommended starting point: iPhone microphone for the environment, media keeps
    /// playing in high quality (A2DP) on AirPods. `defaultToSpeaker` only matters when no
    /// headphones are connected (it avoids routing other apps' audio to the earpiece).
    public static let builtInMicWithBluetoothMedia = AudioSessionPolicy(
        id: "builtin-mic-a2dp",
        title: "iPhone mic + AirPods media",
        summary: "Records from the iPhone's built-in microphone. Other apps keep playing; "
            + "Bluetooth output stays on the high-quality A2DP profile.",
        mode: .default,
        options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker],
        preferredInput: .builtInMicrophone,
        isExperimental: false)

    public static let builtInMicMeasurement = AudioSessionPolicy(
        id: "builtin-mic-measurement",
        title: "iPhone mic, measurement mode",
        summary: "Same routing as the recommended policy but with minimal input processing "
            + "(no automatic gain). Test whether other audio keeps playing.",
        mode: .measurement,
        options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker],
        preferredInput: .builtInMicrophone,
        isExperimental: true)

    public static let bluetoothHFP = AudioSessionPolicy(
        id: "bluetooth-hfp",
        title: "AirPods mic (HFP)",
        summary: "Uses the headset microphone over the Hands-Free Profile. Expected to switch "
            + "AirPods to call-quality audio for all output while active.",
        mode: .default,
        options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker],
        preferredInput: .bluetoothMicrophone,
        isExperimental: true)

    public static let bluetoothHighQuality = AudioSessionPolicy(
        id: "bluetooth-high-quality",
        title: "AirPods mic (high quality)",
        summary: "iOS 26 high-quality Bluetooth recording, falling back to HFP on routes that "
            + "do not support it. Supported only by certain AirPods models.",
        mode: .default,
        options: [.mixWithOthers, .bluetoothHighQualityRecording, .allowBluetoothHFP, .defaultToSpeaker],
        preferredInput: .bluetoothMicrophone,
        isExperimental: true)

    public static let recommended = builtInMicWithBluetoothMedia
    public static let all: [AudioSessionPolicy] = [
        builtInMicWithBluetoothMedia, builtInMicMeasurement, bluetoothHFP, bluetoothHighQuality,
    ]
}

#if os(iOS)
import AVFAudio

extension AudioSessionPolicy {
    var sessionMode: AVAudioSession.Mode {
        switch mode {
        case .default: .default
        case .measurement: .measurement
        }
    }

    var categoryOptions: AVAudioSession.CategoryOptions {
        var result: AVAudioSession.CategoryOptions = []
        for option in options {
            switch option {
            case .mixWithOthers: result.insert(.mixWithOthers)
            case .allowBluetoothA2DP: result.insert(.allowBluetoothA2DP)
            case .allowBluetoothHFP: result.insert(.allowBluetoothHFP)
            case .defaultToSpeaker: result.insert(.defaultToSpeaker)
            case .bluetoothHighQualityRecording:
                #if !targetEnvironment(macCatalyst)
                result.insert(.bluetoothHighQualityRecording)
                #endif
            }
        }
        return result
    }
}
#endif
