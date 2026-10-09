import HearingSenseAudio
import Observation
import SwiftUI

/// Coordinates permission, the audio session, microphone capture and diagnostics for the UI.
///
/// Main-actor isolated (app target default). Capture callbacks arrive on the audio thread
/// and hop to the main actor before touching any state here.
///
/// Later windows attach analysis by adding `AudioStreamConsumer`s to `capture`; this type
/// should stay an orchestrator and not grow classification or speech logic itself.
@Observable
final class ListeningController {
    static let historyLength = 120  // about 10 s of level history at ~12 buffers/s

    private(set) var state: ListeningState = .idle
    private(set) var level: AudioLevel = .silence
    private(set) var levelHistory: [Float] = []
    private(set) var captureFormat: CaptureFormat?
    private(set) var route: AudioRouteSnapshot
    private(set) var log = DiagnosticEventLog(capacity: 300)
    private(set) var policy: AudioSessionPolicy = .recommended

    @ObservationIgnored private var capture = MicrophoneCapture()
    @ObservationIgnored private let session = AudioSessionController()
    @ObservationIgnored private var sessionObserver: AudioSessionObserver?
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var backgroundCheckpoint: CaptureThroughput.Checkpoint?

    init() {
        route = AudioRouteSnapshot.capture()
        connect(capture)
        sessionObserver = AudioSessionObserver { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
        log.append(.lifecycle, "App launched on \(DeviceInfo.summary). Microphone permission: \(MicrophonePermission.current.rawValue)")
    }

    var assessment: RouteAssessment { RouteAssessment.evaluate(route) }

    // MARK: - User actions

    func start() async {
        guard state.canStart else { return }

        switch MicrophonePermission.current {
        case .granted:
            break
        case .denied:
            state = .permissionDenied
            log.append(.permission, "Start refused: microphone permission denied")
            return
        case .undetermined:
            state = .requestingPermission
            let result = await MicrophonePermission.request()
            log.append(.permission, "Permission prompt answered: \(result.rawValue)")
            guard result == .granted else {
                state = .permissionDenied
                return
            }
        }

        state = .starting
        if beginCapture() {
            log.append(.lifecycle, "Listening started with policy “\(policy.title)”")
            announce("Listening started")
        }
    }

    func stop() {
        guard state.canStop else { return }
        endCapture()
        state = .idle
        log.append(.lifecycle, "Listening stopped; microphone released")
        announce("Listening stopped")
    }

    func select(_ newPolicy: AudioSessionPolicy) {
        guard !state.isCapturing, newPolicy != policy else { return }
        policy = newPolicy
        log.append(.session, "Policy selected: \(newPolicy.title)")
    }

    /// Prefers a specific input (nil = system default). Applies to the active session.
    func selectInput(uid: String?) {
        do {
            try session.setPreferredInput(uid: uid)
            log.append(.route, "Preferred input set to \(uid ?? "system default")")
        } catch {
            log.append(.error, "Could not set preferred input: \(error.localizedDescription)")
        }
        refreshRoute()
    }

    func refreshRoute() {
        route = session.snapshot()
    }

    func clearLog() {
        log.removeAll()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isInBackground = true
            log.append(.lifecycle, "App entered background" + (state.isCapturing ? " while listening" : ""))
            if state.isCapturing { backgroundCheckpoint = capture.throughput.checkpoint(at: .now) }
        case .active:
            isInBackground = false
            if let checkpoint = backgroundCheckpoint {
                logBackgroundCoverage(since: checkpoint)
                backgroundCheckpoint = nil
            }
            refreshRoute()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Text for sharing device test results: device, route snapshot and event log.
    /// Contains no audio and no transcripts.
    func diagnosticsReport() -> String {
        [
            "Device: \(DeviceInfo.summary)",
            "App policy: \(policy.title) [\(policy.id)]",
            "State: \(state.title)",
            captureFormat.map { "Capture format: \($0.summary)" } ?? "Capture format: not capturing",
            "",
            route.reportText(),
            "",
            "Event log (oldest first):",
            log.exportText(),
        ].joined(separator: "\n")
    }

    // MARK: - Capture lifecycle

    /// Activates the session for the current policy and starts the engine.
    /// Sets `.listening` or `.failed` and returns whether capture is running.
    @discardableResult
    private func beginCapture() -> Bool {
        do {
            let input = try session.activate(policy: policy)
            log.append(.session, "Session active (playAndRecord, \(policy.mode.rawValue), "
                + "\(policy.options.map(\.rawValue).joined(separator: ", "))); preferred input: \(describe(input))")
            let format = try capture.start()
            captureFormat = format
            state = .listening
            log.append(.capture, "Capture running: \(format.summary)")
            refreshRoute()
            return true
        } catch {
            endCapture()
            state = .failed(error.localizedDescription)
            log.append(.error, "Start failed: \(error.localizedDescription)")
            refreshRoute()
            return false
        }
    }

    /// Stops capture and deactivates the session so other apps can resume normally.
    private func endCapture() {
        capture.stop()
        do {
            try session.deactivate()
        } catch {
            log.append(.error, "Session deactivation failed: \(error.localizedDescription)")
        }
        captureFormat = nil
        level = .silence
        levelHistory.removeAll()
        refreshRoute()
    }

    private func connect(_ capture: MicrophoneCapture) {
        capture.setTickHandler { [weak self] tick in
            guard let self else { return }
            Task { @MainActor in self.receive(tick) }
        }
        capture.setConfigurationChangeHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleEngineConfigurationChange() }
        }
    }

    private func receive(_ tick: CaptureTick) {
        // Buffers keep being counted on the audio thread; skip UI work while not visible.
        guard state.isCapturing, !isInBackground else { return }
        level = tick.level
        levelHistory.append(tick.level.rmsDBFS)
        if levelHistory.count > Self.historyLength {
            levelHistory.removeFirst(levelHistory.count - Self.historyLength)
        }
    }

    // MARK: - System events

    private func handle(_ event: AudioSessionEvent) {
        log.append(event.logKind, event.logDescription)
        switch event {
        case .interruptionBegan:
            guard state.isCapturing || state == .starting else { break }
            capture.stop()
            captureFormat = nil
            level = .silence
            state = .interrupted
            announce("Listening paused by the system")
        case .interruptionEnded(let shouldResume):
            guard state == .interrupted else { break }
            if shouldResume {
                if beginCapture() {
                    log.append(.lifecycle, "Listening resumed after interruption")
                    announce("Listening resumed")
                }
            } else {
                log.append(.lifecycle, "iOS did not suggest resuming; tap Start Listening to resume")
            }
        case .routeChanged:
            refreshRoute()
        case .mediaServicesWereReset:
            // All audio objects are invalid after a reset: rebuild the engine.
            let wasActive = state.isCapturing || state == .interrupted
            capture.setTickHandler(nil)
            capture.setConfigurationChangeHandler(nil)
            capture.stop()
            capture = MicrophoneCapture()
            connect(capture)
            captureFormat = nil
            level = .silence
            if wasActive {
                state = .failed("Audio services were reset by iOS. Tap Start Listening to continue.")
            }
            refreshRoute()
        case .mediaServicesWereLost, .silenceSecondaryAudioHint:
            refreshRoute()
        }
    }

    private func handleEngineConfigurationChange() {
        log.append(.capture, "AVAudioEngine configuration changed (hardware format or route); engine stopped")
        guard state.isCapturing else { return }
        do {
            let format = try capture.restart()
            captureFormat = format
            log.append(.capture, "Capture restarted: \(format.summary)")
        } catch {
            endCapture()
            state = .failed("Capture could not restart after an audio route change: \(error.localizedDescription)")
            log.append(.error, "Restart failed: \(error.localizedDescription)")
        }
        refreshRoute()
    }

    private func logBackgroundCoverage(since checkpoint: CaptureThroughput.Checkpoint) {
        guard let interval = capture.throughput.interval(since: checkpoint, now: .now) else {
            log.append(.capture, "Background interval: capture restarted or stopped; coverage unavailable")
            return
        }
        let seconds = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        log.append(.capture, "Background interval \(interval.wallClockSeconds.formatted(seconds)) s: "
            + "captured \(interval.capturedSeconds.formatted(seconds)) s of audio in \(interval.buffers) buffers "
            + "(coverage \(interval.coverage.formatted(.percent.precision(.fractionLength(0)))))")
    }

    private func describe(_ result: AudioSessionController.PreferredInputResult) -> String {
        switch result {
        case .selected(let port): "\(port.name) [\(port.rawType)]"
        case .unavailable(let preference): "\(preference.rawValue) not available, using system default"
        case .systemDefault: "system default"
        }
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}

private extension AudioSessionEvent {
    var logKind: DiagnosticEventLog.Kind {
        switch self {
        case .interruptionBegan, .interruptionEnded: .interruption
        case .routeChanged: .route
        case .mediaServicesWereLost, .mediaServicesWereReset, .silenceSecondaryAudioHint: .session
        }
    }
}
