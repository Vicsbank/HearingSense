#if DEBUG
import Foundation
import HearingSenseAudio
import HearingSenseDomain
import SoundEventDetection
import SpeechIntelligence
import UIKit

/// Debug-build test aid for physical-device tests. When the app is launched with
/// `--hs-export-diagnostics` it rewrites `Documents/hearing-sense-diagnostics.txt` every few
/// seconds, so a test run can be read from the Mac
/// (`xcrun devicectl device copy from --domain-type appDataContainer …`) instead of from
/// screenshots. `--hs-autostart` starts listening right after launch.
///
/// The file holds metadata only: app and lock state, counters, timings, the diagnostic event log
/// and the two metadata reports. No audio, no transcript text and no summary text is written.
/// Nothing is exported unless the launch argument is present; Release builds do not contain this.
final class DebugDiagnosticsExporter {
    static let exportArgument = "--hs-export-diagnostics"
    static let autostartArgument = "--hs-autostart"
    static let fileName = "hearing-sense-diagnostics.txt"
    static let interval: Duration = .seconds(5)
    static let maximumHeartbeats = 1_500

    static var isExportRequested: Bool { ProcessInfo.processInfo.arguments.contains(exportArgument) }
    static var isAutostartRequested: Bool { ProcessInfo.processInfo.arguments.contains(autostartArgument) }

    private let controller: ListeningController
    private var heartbeats: [String] = []
    private var task: Task<Void, Never>?
    private let launchDate = Date.now
    /// Experiments append their own heartbeat fields and report sections (metadata only).
    var extraHeartbeat: () -> String = { "" }
    var extraReport: () -> String = { "" }

    init(controller: ListeningController) {
        self.controller = controller
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func tick() {
        heartbeats.append(heartbeat())
        if heartbeats.count > Self.maximumHeartbeats { heartbeats.removeFirst(heartbeats.count - Self.maximumHeartbeats) }
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        // Written without file protection so the export keeps working while the iPhone is locked.
        try? Data(report().utf8).write(to: directory.appending(path: Self.fileName), options: [.atomic, .noFileProtection])
    }

    private var resourceBaseline = ProcessResourceUsage.sample()

    /// CPU since the previous heartbeat (100 % = one core), memory footprint, thermal state, battery.
    private func resourceFields() -> [String] {
        let now = ProcessResourceUsage.sample()
        let cpu = now.cpuUtilization(since: resourceBaseline).map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) } ?? "-"
        resourceBaseline = now
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let battery = device.batteryLevel >= 0 ? "\(Int((device.batteryLevel * 100).rounded()))" : "-"
        let charging = switch device.batteryState {
        case .charging, .full: "charging"
        case .unplugged: "unplugged"
        default: "unknown"
        }
        return ["cpu=\(cpu)%", "mem=\(now.memoryFootprintMB.map { "\(Int($0))" } ?? "-")MB", "thermal=\(now.thermalDescription)",
                "battery=\(battery)%(\(charging))"]
    }

    private func heartbeat() -> String {
        let application = UIApplication.shared
        let appState = switch application.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let sound = controller.recognition.diagnostics
        let speech = controller.speech.diagnostics
        return [
            Self.time(.now),
            "app=\(appState)",
            "unlocked=\(application.isProtectedDataAvailable)",
            "state=\(controller.state)",
            "windows=\(sound.results)",
            "segments=\(sound.segments)",
            "classifierFailures=\(sound.failures)",
            "speechWindows=\(speech.speechWindows)",
            "activations=\(speech.activations)",
            "utterances=\(speech.utterancesStarted)/\(speech.utterancesFinished)",
            "empty=\(speech.emptyUtterances)",
            "transcriptionFailures=\(speech.transcriptionFailures)",
            "startRetries=\(speech.recognizerStartRetries)",
            "segmentsFinal=\(speech.finalSegments)",
            "semantic=\(speech.semanticRequests)",
            "summaries=\(speech.summariesProduced)",
            "model=\(controller.recognition.latestFrame?.model.rawValue ?? "-")",
            "inferenceMs=\((sound.modelInference.mean * 1000).formatted(.number.precision(.fractionLength(2))))",
            "dropped=\(sound.chunksDropped)",
            "backlogMax=\(sound.maxBacklog)",
        ].joined(separator: " ") + " " + resourceFields().joined(separator: " ") + " " + extraHeartbeat()
    }

    private func report() -> String {
        var lines = [
            "Hearing Sense debug diagnostics (metadata only: no audio, no transcripts, no summaries)",
            "Device: \(DeviceInfo.summary)",
            "Launched \(Self.time(launchDate)), written \(Self.time(.now))",
            "",
            "== Heartbeats (every 5 s) ==",
        ]
        lines += heartbeats
        lines += ["", "== Event log =="]
        lines += controller.log.entries.map { "\(Self.time($0.date)) [\($0.kind.rawValue)] \($0.message)" }
        lines += ["", "== Reports ==", controller.recognition.reportText(), "", controller.speech.reportText(), "", extraReport()]
        return lines.joined(separator: "\n")
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.iso8601.time(includingFractionalSeconds: true))
    }
}
#endif
