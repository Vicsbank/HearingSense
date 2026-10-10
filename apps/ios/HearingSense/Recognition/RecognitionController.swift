import HearingSenseAudio
import HearingSenseDomain
import Observation
import SoundEventDetection
import SwiftUI

/// Presentation state for live sound recognition. Every value shown comes from the real
/// classifier through `SoundRecognitionEngine.outputs`; nothing here invents predictions.
///
/// Main-actor isolated (app default). Keeps classification metadata only, never audio, and only
/// in memory (bounded history).
@Observable
final class RecognitionController {
    static let historyCapacity = 50

    private(set) var status: EnvironmentStatus = .warmingUp
    private(set) var latestFrame: ClassificationFrame?
    private(set) var activeEvents: [ConfirmedAcousticEvent] = []
    private(set) var candidates: [AcousticEventCandidate] = []
    /// Confirmed events, newest first (active ones are updated in place, ended ones stay).
    private(set) var history: [ConfirmedAcousticEvent] = []
    private(set) var diagnostics = SoundAnalysisDiagnostics()
    private(set) var detectorStatistics = SoundEventDetector.Statistics()
    private(set) var analyzerDescription: String?
    private(set) var lastFailure: String?
    private(set) var isSessionActive = false
    private(set) var resources: ResourceReading?
    private(set) var configuration: ClassifierConfiguration = .standard

    @ObservationIgnored let engine: SoundRecognitionEngine
    @ObservationIgnored private var log: (DiagnosticEventLog.Kind, String) -> Void = { _, _ in }
    @ObservationIgnored private var backgroundStart: (date: Date, windows: Int, events: Int)?
    @ObservationIgnored private var resourceBaseline: ProcessResourceUsage?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    /// Window 3: the engine's output stream has a single consumer (this controller), so classifier
    /// windows and event updates are forwarded from here to the speech pipeline.
    @ObservationIgnored private var forwardFrame: (ClassificationFrame) -> Void = { _ in }
    @ObservationIgnored private var forwardEvent: (AcousticEventUpdate) -> Void = { _ in }

    struct ResourceReading: Equatable {
        var cpuUtilization: Double?
        var memoryMB: Double?
        var thermal: String
        var sampledAt: Date
    }

    var taxonomy: SoundTaxonomy { engine.taxonomy }

    init(engine: SoundRecognitionEngine = SoundRecognitionEngine()) {
        self.engine = engine
        listenTask = Task { [weak self, outputs = engine.outputs] in
            for await output in outputs {
                guard let self else { return }
                self.handle(output)
            }
        }
    }

    deinit {
        listenTask?.cancel()
    }

    /// Where pipeline lifecycle messages go (the app's diagnostic log).
    func setLogger(_ logger: @escaping (DiagnosticEventLog.Kind, String) -> Void) {
        log = logger
    }

    /// Receives every classifier window and every confirmed-event update, in order.
    func setForwarding(frame: @escaping (ClassificationFrame) -> Void, event: @escaping (AcousticEventUpdate) -> Void) {
        forwardFrame = frame
        forwardEvent = event
    }

    // MARK: - Lifecycle (called by ListeningController)

    func sessionWillStart() {
        status = .warmingUp
        latestFrame = nil
        candidates = []
        activeEvents = []
        lastFailure = nil
        isSessionActive = true
        resourceBaseline = ProcessResourceUsage.sample()
        resources = nil
    }

    /// Capture stopped (user, interruption or failure): end every event.
    func sessionDidEnd() {
        guard isSessionActive else { return }
        isSessionActive = false
        engine.endSession()
    }

    func select(windowDuration: TimeInterval) {
        guard !isSessionActive else { return }
        configuration.windowDuration = windowDuration
        engine.setConfiguration(configuration)
        log(.recognition, "Classifier window set to \(windowDuration.formatted()) s (applies at next start)")
    }

    func enteredBackground() {
        guard isSessionActive else { return }
        backgroundStart = (.now, diagnostics.results, detectorStatistics.eventsConfirmed)
    }

    func becameActive() {
        guard let start = backgroundStart else { return }
        backgroundStart = nil
        let seconds = Date.now.timeIntervalSince(start.date)
        let windows = diagnostics.results - start.windows
        let expected = seconds / max(configuration.hop, 0.01)
        log(.recognition, "Background interval \(seconds.formatted(.number.precision(.fractionLength(1)))) s: "
            + "\(windows) classifier windows (≈ \(Int(expected.rounded())) expected), "
            + "\(detectorStatistics.eventsConfirmed - start.events) events confirmed")
    }

    // MARK: - Engine outputs

    private func handle(_ output: SoundRecognitionOutput) {
        switch output {
        case .analyzerStarted(let sampleRate, let window, let overlap):
            analyzerDescription = "SNClassifySoundRequest(.version1), window \(window.formatted()) s, "
                + "overlap \(overlap.formatted(.percent)), input \(Int(sampleRate)) Hz → mono channel 0"
            log(.recognition, "Sound analyzer started: \(analyzerDescription ?? "")")
        case .event(let update):
            apply(update)
            forwardEvent(update)
        case .frame(let report):
            guard isSessionActive else { return }
            forwardFrame(report.frame)
            latestFrame = report.frame
            status = report.status
            candidates = report.candidates
            activeEvents = report.activeEvents
            diagnostics = report.diagnostics
            detectorStatistics = report.detectorStatistics
            if report.frame.sequence % 8 == 0 { sampleResources() }
        case .sessionEnded(let final):
            diagnostics = final
            activeEvents = []
            candidates = []
            status = .warmingUp
            log(.recognition, "Recognition session ended: \(final.results) windows, "
                + "\(detectorStatistics.eventsConfirmed) events confirmed, \(final.chunksDropped) buffers dropped")
        case .failure(let message):
            lastFailure = message
            log(.error, "Sound analysis: \(message)")
        }
    }

    private func apply(_ update: AcousticEventUpdate) {
        let event = update.event
        if let index = history.firstIndex(where: { $0.id == event.id }) {
            history[index] = event
        } else {
            history.insert(event, at: 0)
            if history.count > Self.historyCapacity { history.removeLast(history.count - Self.historyCapacity) }
        }
        switch update {
        case .started(let event):
            log(.recognition, "Event confirmed: \(event.kind.displayName) [\(event.primaryLabel)] peak "
                + "\(event.evidence.peakScore), \(event.evidence.supportingWindows) windows, latency "
                + "\(event.confirmationLatency.formatted(.number.precision(.fractionLength(2)))) s audio")
        case .ended(let event):
            log(.recognition, "Event ended: \(event.kind.displayName), observed "
                + "\(event.observedDuration.formatted(.number.precision(.fractionLength(1)))) s")
        case .updated:
            break
        }
    }

    private func sampleResources() {
        let now = ProcessResourceUsage.sample()
        let utilization = resourceBaseline.flatMap { now.cpuUtilization(since: $0) }
        resources = ResourceReading(cpuUtilization: utilization, memoryMB: now.memoryFootprintMB,
                                    thermal: now.thermalDescription, sampledAt: now.date)
        resourceBaseline = now
    }

    func clearHistory() {
        history.removeAll { !$0.isActive }
    }

    /// Text for sharing test results: configuration, diagnostics and event metadata (no audio).
    func reportText() -> String {
        var lines = ["Sound recognition", analyzerDescription ?? "Analyzer: not started", ""]
        lines += diagnostics.reportLines()
        let stats = detectorStatistics
        lines.append("Detector: \(stats.windows) windows, \(stats.candidatesStarted) candidates, "
            + "\(stats.candidatesRejected) rejected, \(stats.eventsConfirmed) confirmed, \(stats.eventsEnded) ended")
        if let resources {
            lines.append("Process: CPU \(resources.cpuUtilization.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "–"), "
                + "memory \(resources.memoryMB.map { "\(Int($0)) MB" } ?? "–"), thermal \(resources.thermal)")
        }
        lines.append("")
        lines.append("Confirmed events (newest first):")
        for event in history {
            lines.append("\(event.confirmedDate.formatted(.iso8601.time(includingFractionalSeconds: true))) "
                + "\(event.kind.id) [\(event.primaryLabel)] \(event.phase.rawValue) peak \(event.evidence.peakScore) "
                + "windows \(event.evidence.supportingWindows) quality \(event.quality) "
                + "latency \(event.confirmationLatency.formatted(.number.precision(.fractionLength(2)))) s "
                + "duration \(event.observedDuration.formatted(.number.precision(.fractionLength(1)))) s "
                + "labels \(event.evidence.labels.map { "\($0.label)×\($0.windowCount)" }.joined(separator: ","))")
        }
        return lines.joined(separator: "\n")
    }
}
