#if DEBUG
import ConversationUnderstanding
import Foundation
import HearingSenseAudio
import HearingSenseDomain
import SoundEventDetection
import SpeechIntelligence
import UIKit

/// Debug-build test aid for physical-device tests. While the device test mode is on (Window 8,
/// `DeviceTestMode`; stored on the iPhone, so it also holds for a process started by the Action
/// Button's intent) or when the app is launched with `--hs-export-diagnostics`, it rewrites
/// `Documents/hearing-sense-diagnostics.txt` every few seconds, so a test run can be read from
/// the Mac (`xcrun devicectl device copy from --domain-type appDataContainer …`) instead of from
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

    /// `--hs-autostop-after <seconds>`: the app itself stops listening (microphone off) this long
    /// after launch, so a timed device test ends on time even if the Mac that started it does
    /// nothing more. Carried out by `ListeningController.limitListening(to:)`: a timer and every
    /// audio buffer after the deadline both trigger the stop, nothing resumes listening afterwards,
    /// and the export is written at the moment of the stop ("Time limit reached" in the event log,
    /// `timeLimit=fired…` in the heartbeat).
    static let autostopArgument = "--hs-autostop-after"
    static var autostopAfter: TimeInterval? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: autostopArgument), index + 1 < arguments.count,
              let seconds = TimeInterval(arguments[index + 1]), seconds > 0 else { return nil }
        return seconds
    }

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

    /// Writes the file now, outside the 5 s rhythm (an event that must not be missed).
    func writeNow() {
        tick()
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
            "session=\(controller.session.phase.rawValue)",
            controller.microphoneFacts,
            "transcription=\(controller.speech.isTranscriptionEnabled ? "on" : "off")"
                + (controller.speech.isTranscriptionLockedOff ? "(locked)" : ""),
            "testMode=\(DeviceTestMode.summary)",
            "testSessionEnds=\(controller.testSessionDeadline.map { "in\(max(Int($0.timeIntervalSinceNow.rounded(.up)), 0))s" } ?? "-")",
            "timeLimit=\(controller.timeLimit?.heartbeat(at: .now) ?? "off")",
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
            controller.attention.heartbeat,
            controller.liveActivity.heartbeat,
            "scene=\(controller.scene.estimate?.scene.rawValue ?? "-")",
            "conversation=\(controller.conversation.phase.rawValue)",
            "summaryRequests=\(controller.conversation.recapsMade)",
        ].joined(separator: " ") + " " + resourceFields().joined(separator: " ") + " " + extraHeartbeat()
    }

    private func report() -> String {
        var lines = [
            "Hearing Sense debug diagnostics (metadata only: no audio, no transcripts, no summaries)",
            "Device: \(DeviceInfo.summary)",
            "Build: \(Self.build)",
            "Launched \(Self.time(launchDate)), written \(Self.time(.now))",
            "Process arguments: \(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " ").isEmpty ? "none" : ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))",
        ]
        lines += DeviceTestMode.reportLines()
        lines += [
            "Microphone right now: \(controller.microphoneFacts)",
            "Listening session: \(controller.session.phase.rawValue) · started \(controller.session.statistics.sessionsStarted), ended "
                + "\(controller.session.statistics.sessionsEnded), toggles \(controller.session.statistics.toggles), requests refused "
                + "\(controller.session.statistics.requestsRefused) · last end: \(controller.session.lastEndReason?.rawValue ?? "none")",
            "",
            "== Heartbeats (every 5 s) ==",
        ]
        lines += heartbeats
        lines += ["", "== Event log =="]
        lines += controller.log.entries.map { "\(Self.time($0.date)) [\($0.kind.rawValue)] \($0.message)" }
        lines += ["", "== Reports ==", controller.recognition.reportText(), "", controller.speech.reportText(), "",
                  controller.attention.reportText(), "", controller.scene.reportText(), "", controller.liveActivity.reportText(), "",
                  controller.conversation.reportText(), "", extraReport()]
        return lines.joined(separator: "\n")
    }

    /// Version, build number and when this binary was built (the executable's modification date).
    private static let build: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let built = (Bundle.main.executableURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) })?
            .contentModificationDate.map { $0.formatted(.iso8601) } ?? "unknown"
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")), "
            + "Debug, binary of \(built), source \((info["HSSourceRevision"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "not recorded")"
    }()

    private static func time(_ date: Date) -> String {
        date.formatted(.iso8601.time(includingFractionalSeconds: true))
    }
}
#endif
