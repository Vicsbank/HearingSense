import Foundation

/// Platform-independent classification of an `AVAudioSession.Port`.
public enum PortKind: String, Sendable, Hashable {
    case builtInMic, builtInReceiver, builtInSpeaker
    case headphones, headsetMic
    case bluetoothA2DP, bluetoothHFP, bluetoothLE
    case airPlay, carAudio, usbAudio, lineIn, lineOut, hdmi, continuityMicrophone
    case other

    public var isBluetooth: Bool {
        self == .bluetoothA2DP || self == .bluetoothHFP || self == .bluetoothLE
    }

    public var displayName: String {
        switch self {
        case .builtInMic: "Built-in microphone"
        case .builtInReceiver: "Receiver (earpiece)"
        case .builtInSpeaker: "Built-in speaker"
        case .headphones: "Wired headphones"
        case .headsetMic: "Wired headset microphone"
        case .bluetoothA2DP: "Bluetooth A2DP (high-quality output)"
        case .bluetoothHFP: "Bluetooth HFP (hands-free / call profile)"
        case .bluetoothLE: "Bluetooth LE audio"
        case .airPlay: "AirPlay"
        case .carAudio: "CarPlay audio"
        case .usbAudio: "USB audio"
        case .lineIn: "Line in"
        case .lineOut: "Line out"
        case .hdmi: "HDMI"
        case .continuityMicrophone: "Continuity microphone"
        case .other: "Other"
        }
    }
}

/// One audio port (input or output) as reported by AVAudioSession.
public struct AudioPortInfo: Sendable, Hashable, Identifiable {
    public var id: String { uid }
    public var name: String
    public var kind: PortKind
    /// Raw `AVAudioSession.Port` value, kept for port types this app does not know yet.
    public var rawType: String
    public var uid: String
    public var channelCount: Int
    public var selectedDataSource: String?
    public var dataSources: [String]
    /// iOS 26 Bluetooth microphone capabilities; nil when the port reports none.
    public var highQualityRecording: Capability?
    public var farFieldCapture: Capability?

    public struct Capability: Sendable, Hashable {
        public var isSupported: Bool
        public var isEnabled: Bool

        public init(isSupported: Bool, isEnabled: Bool) {
            self.isSupported = isSupported
            self.isEnabled = isEnabled
        }
    }

    public init(name: String, kind: PortKind, rawType: String, uid: String, channelCount: Int = 1,
                selectedDataSource: String? = nil, dataSources: [String] = [],
                highQualityRecording: Capability? = nil, farFieldCapture: Capability? = nil) {
        self.name = name
        self.kind = kind
        self.rawType = rawType
        self.uid = uid
        self.channelCount = channelCount
        self.selectedDataSource = selectedDataSource
        self.dataSources = dataSources
        self.highQualityRecording = highQualityRecording
        self.farFieldCapture = farFieldCapture
    }
}

/// Everything the diagnostics screen shows about the audio session at one moment.
/// Contains only configuration and routing metadata — never audio content.
public struct AudioRouteSnapshot: Sendable, Equatable {
    public var capturedAt: Date
    public var category: String
    public var mode: String
    public var categoryOptions: [String]
    public var sampleRate: Double
    public var preferredSampleRate: Double
    public var ioBufferDuration: TimeInterval
    public var inputLatency: TimeInterval
    public var outputLatency: TimeInterval
    public var inputChannelCount: Int
    public var outputChannelCount: Int
    public var isInputAvailable: Bool
    public var isOtherAudioPlaying: Bool
    public var secondaryAudioShouldBeSilencedHint: Bool
    public var inputGain: Float
    public var isInputGainSettable: Bool
    public var inputs: [AudioPortInfo]
    public var outputs: [AudioPortInfo]
    public var availableInputs: [AudioPortInfo]
    public var preferredInputUID: String?
    public var permission: MicrophonePermission

    public init(capturedAt: Date = .now, category: String = "", mode: String = "",
                categoryOptions: [String] = [], sampleRate: Double = 0, preferredSampleRate: Double = 0,
                ioBufferDuration: TimeInterval = 0, inputLatency: TimeInterval = 0,
                outputLatency: TimeInterval = 0, inputChannelCount: Int = 0, outputChannelCount: Int = 0,
                isInputAvailable: Bool = false, isOtherAudioPlaying: Bool = false,
                secondaryAudioShouldBeSilencedHint: Bool = false, inputGain: Float = 0,
                isInputGainSettable: Bool = false, inputs: [AudioPortInfo] = [],
                outputs: [AudioPortInfo] = [], availableInputs: [AudioPortInfo] = [],
                preferredInputUID: String? = nil, permission: MicrophonePermission = .undetermined) {
        self.capturedAt = capturedAt
        self.category = category
        self.mode = mode
        self.categoryOptions = categoryOptions
        self.sampleRate = sampleRate
        self.preferredSampleRate = preferredSampleRate
        self.ioBufferDuration = ioBufferDuration
        self.inputLatency = inputLatency
        self.outputLatency = outputLatency
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.isInputAvailable = isInputAvailable
        self.isOtherAudioPlaying = isOtherAudioPlaying
        self.secondaryAudioShouldBeSilencedHint = secondaryAudioShouldBeSilencedHint
        self.inputGain = inputGain
        self.isInputGainSettable = isInputGainSettable
        self.inputs = inputs
        self.outputs = outputs
        self.availableInputs = availableInputs
        self.preferredInputUID = preferredInputUID
        self.permission = permission
    }

    /// Plain-text report for sharing device test results (no audio, no transcripts).
    public func reportText() -> String {
        func ms(_ seconds: TimeInterval) -> String {
            (seconds * 1000).formatted(.number.precision(.fractionLength(1))) + " ms"
        }
        func port(_ p: AudioPortInfo) -> String {
            var line = "  - \(p.name) [\(p.rawType)] ch=\(p.channelCount)"
            if let source = p.selectedDataSource { line += " source=\(source)" }
            if let hq = p.highQualityRecording { line += " hqRecording(supported=\(hq.isSupported), enabled=\(hq.isEnabled))" }
            if let ff = p.farFieldCapture { line += " farField(supported=\(ff.isSupported), enabled=\(ff.isEnabled))" }
            return line
        }
        var lines = [
            "Hearing Sense audio route snapshot",
            "Captured: \(capturedAt.formatted(.iso8601))",
            "Microphone permission: \(permission.rawValue)",
            "Category: \(category)  Mode: \(mode)",
            "Options: \(categoryOptions.isEmpty ? "none" : categoryOptions.joined(separator: ", "))",
            "Sample rate: \(sampleRate) Hz (preferred \(preferredSampleRate) Hz)",
            "IO buffer: \(ms(ioBufferDuration))  Input latency: \(ms(inputLatency))  Output latency: \(ms(outputLatency))",
            "Channels: in \(inputChannelCount) / out \(outputChannelCount)",
            "Input available: \(isInputAvailable)  Input gain: \(inputGain) (settable \(isInputGainSettable))",
            "Other audio playing: \(isOtherAudioPlaying)  Secondary audio should be silenced: \(secondaryAudioShouldBeSilencedHint)",
            "Current inputs:",
        ]
        lines += inputs.isEmpty ? ["  (none)"] : inputs.map(port)
        lines.append("Current outputs:")
        lines += outputs.isEmpty ? ["  (none)"] : outputs.map(port)
        lines.append("Available inputs:")
        lines += availableInputs.isEmpty ? ["  (none)"] : availableInputs.map(port)
        lines.append("Preferred input UID: \(preferredInputUID ?? "none (system default)")")
        let assessment = RouteAssessment.evaluate(self)
        lines.append("Assessment: \(assessment.headline) — \(assessment.detail)")
        return lines.joined(separator: "\n")
    }
}

#if os(iOS)
import AVFAudio

extension PortKind {
    init(_ port: AVAudioSession.Port) {
        switch port {
        case .builtInMic: self = .builtInMic
        case .builtInReceiver: self = .builtInReceiver
        case .builtInSpeaker: self = .builtInSpeaker
        case .headphones: self = .headphones
        case .headsetMic: self = .headsetMic
        case .bluetoothA2DP: self = .bluetoothA2DP
        case .bluetoothHFP: self = .bluetoothHFP
        case .bluetoothLE: self = .bluetoothLE
        case .airPlay: self = .airPlay
        case .carAudio: self = .carAudio
        case .usbAudio: self = .usbAudio
        case .lineIn: self = .lineIn
        case .lineOut: self = .lineOut
        case .HDMI: self = .hdmi
        case .continuityMicrophone: self = .continuityMicrophone
        default: self = .other
        }
    }
}

extension AudioPortInfo {
    init(_ port: AVAudioSessionPortDescription) {
        let bluetooth = port.bluetoothMicrophoneExtension
        self.init(
            name: port.portName,
            kind: PortKind(port.portType),
            rawType: port.portType.rawValue,
            uid: port.uid,
            channelCount: port.channels?.count ?? 0,
            selectedDataSource: port.selectedDataSource?.dataSourceName,
            dataSources: port.dataSources?.map(\.dataSourceName) ?? [],
            highQualityRecording: bluetooth.map {
                Capability(isSupported: $0.highQualityRecording.isSupported,
                           isEnabled: $0.highQualityRecording.isEnabled)
            },
            farFieldCapture: bluetooth.map {
                Capability(isSupported: $0.farFieldCapture.isSupported,
                           isEnabled: $0.farFieldCapture.isEnabled)
            })
    }
}

extension AudioRouteSnapshot {
    /// Reads the current state of the shared audio session.
    public static func capture(from session: AVAudioSession = .sharedInstance()) -> AudioRouteSnapshot {
        AudioRouteSnapshot(
            capturedAt: .now,
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            categoryOptions: optionNames(session.categoryOptions),
            sampleRate: session.sampleRate,
            preferredSampleRate: session.preferredSampleRate,
            ioBufferDuration: session.ioBufferDuration,
            inputLatency: session.inputLatency,
            outputLatency: session.outputLatency,
            inputChannelCount: session.inputNumberOfChannels,
            outputChannelCount: session.outputNumberOfChannels,
            isInputAvailable: session.isInputAvailable,
            isOtherAudioPlaying: session.isOtherAudioPlaying,
            secondaryAudioShouldBeSilencedHint: session.secondaryAudioShouldBeSilencedHint,
            inputGain: session.inputGain,
            isInputGainSettable: session.isInputGainSettable,
            inputs: session.currentRoute.inputs.map(AudioPortInfo.init),
            outputs: session.currentRoute.outputs.map(AudioPortInfo.init),
            availableInputs: (session.availableInputs ?? []).map(AudioPortInfo.init),
            preferredInputUID: session.preferredInput?.uid,
            permission: .current)
    }

    static func optionNames(_ options: AVAudioSession.CategoryOptions) -> [String] {
        var known: [(AVAudioSession.CategoryOptions, String)] = [
            (.mixWithOthers, "mixWithOthers"),
            (.duckOthers, "duckOthers"),
            (.allowBluetoothHFP, "allowBluetoothHFP"),
            (.defaultToSpeaker, "defaultToSpeaker"),
            (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudioAndMixWithOthers"),
            (.allowBluetoothA2DP, "allowBluetoothA2DP"),
            (.allowAirPlay, "allowAirPlay"),
            (.overrideMutedMicrophoneInterruption, "overrideMutedMicrophoneInterruption"),
        ]
        #if !targetEnvironment(macCatalyst)
        known.append((.bluetoothHighQualityRecording, "bluetoothHighQualityRecording"))
        #endif
        // interruptSpokenAudioAndMixWithOthers (0x11) contains mixWithOthers (0x1); list it
        // only when its own bit is present.
        return known.filter { options.isSuperset(of: $0.0) }.map(\.1)
    }
}
#endif
