import HearingSenseAudio
import Observation
import SoundEventDetection
import SpeechIntelligence
import SwiftUI

/// Coordinates permission, the audio session, microphone capture and diagnostics for the UI.
///
/// Main-actor isolated (app target default). Capture callbacks arrive on the audio thread
/// and hop to the main actor before touching any state here.
///
/// Later windows attach analysis by adding `AudioStreamConsumer`s to `capture`; this type
/// should stay an orchestrator and not grow classification or speech logic itself. Window 2
/// attaches `SoundRecognitionEngine` (owned by `recognition`), Window 3 the speech pipeline's
/// audio tap (owned by `speech`), which shares the same input tap instead of recording separately.
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
    /// Experiment for the start/stop media stall (AUDIO_ROUTING_FEASIBILITY §3): Stop removes the
    /// tap and stops the engine (microphone off) but leaves the audio session active.
    private(set) var keepsSessionActiveWhenStopped = false
    let recognition: RecognitionController
    /// Window 3: speech transcription and summaries, fed by the same capture and by `recognition`.
    let speech: SpeechIntelligenceController

    @ObservationIgnored private var capture = MicrophoneCapture()
    @ObservationIgnored private let session = AudioSessionController()
    @ObservationIgnored private var sessionObserver: AudioSessionObserver?
    @ObservationIgnored private var isInBackground = false
    /// Hybrid classifier experiment: tells the switching backend which classifier should run.
    /// Unused (and harmless) with a single classifier.
    @ObservationIgnored private let backendSelection = ClassifierBackendSelection()
    @ObservationIgnored private var backgroundCheckpoint: CaptureThroughput.Checkpoint?

    init() {
        route = AudioRouteSnapshot.capture()
        var backendNote: (DiagnosticEventLog.Kind, String)?
        var experimental: (RecognitionController, SpeechIntelligenceController)?
        #if DEBUG
        // Research switch: a converted third-party classifier on the CPU instead of Apple's.
        if let choice = ExperimentalClassifier.requested {
            do {
                var factory = try choice.model.factory()
                var policy = DetectionPolicy.standardAudioSet
                var vocalLabels = SoundTaxonomy.audioSetVocalMusicLabels
                if choice.isHybrid {
                    // Apple's classifier in the foreground, the CPU model while in the background.
                    factory = SwitchingClassifierBackend.factory(primary: AppleSoundAnalysisBackend.factory,
                                                                 secondary: factory, selection: backendSelection)
                    policy = .standardHybrid
                    vocalLabels.formUnion(SpeechActivationPolicy.standard.vocalMusicLabels)
                }
                experimental = (
                    RecognitionController(engine: SoundRecognitionEngine(policy: policy, backend: factory)),
                    SpeechIntelligenceController(taxonomy: factory.taxonomy, vocalMusicLabels: vocalLabels))
                backendNote = (.recognition, "Experimental classifier backend: \(factory.metadata.summary)")
            } catch {
                backendNote = (.error, "Experimental classifier \(choice.model.rawValue) unavailable "
                    + "(\(error.localizedDescription)); using Apple SoundAnalysis")
            }
        }
        #endif
        recognition = experimental?.0 ?? RecognitionController()
        speech = experimental?.1 ?? SpeechIntelligenceController()
        if let backendNote { log.append(backendNote.0, backendNote.1) }
        connect(capture)
        recognition.setLogger { [weak self] kind, message in self?.log.append(kind, message) }
        speech.setLogger { [weak self] kind, message in self?.log.append(kind, message) }
        recognition.setForwarding(frame: { [engine = speech.engine] in engine.process($0) },
                                  event: { [engine = speech.engine] in engine.process($0) })
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
        endCapture(keepSession: keepsSessionActiveWhenStopped)
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

    func setKeepsSessionActiveWhenStopped(_ value: Bool) {
        keepsSessionActiveWhenStopped = value
        log.append(.session, "Keep session active when stopped: \(value ? "on" : "off")")
        if !value, !state.isCapturing, session.isActive {
            do {
                try session.deactivate()
                log.append(.session, "Session deactivated (\(session.lastTrace.summary))")
            } catch {
                log.append(.error, "Session deactivation failed: \(error.localizedDescription)")
            }
            refreshRoute()
        }
    }

    func refreshRoute() {
        route = session.snapshot()
    }

    #if DEBUG
    /// Experiment seam (BackgroundInferenceProbe): an extra consumer of the same microphone tap.
    /// Not re-attached if iOS resets the media services.
    func attachExperimentConsumer(_ consumer: any AudioStreamConsumer) {
        capture.addConsumer(consumer)
    }
    #endif

    func clearLog() {
        log.removeAll()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isInBackground = true
            backendSelection.prefersSecondary = true
            log.append(.lifecycle, "App entered background" + (state.isCapturing ? " while listening" : ""))
            if state.isCapturing { backgroundCheckpoint = capture.throughput.checkpoint(at: .now) }
            recognition.enteredBackground()
        case .active:
            isInBackground = false
            backendSelection.prefersSecondary = false
            if let checkpoint = backgroundCheckpoint {
                logBackgroundCoverage(since: checkpoint)
                backgroundCheckpoint = nil
            }
            recognition.becameActive()
            refreshRoute()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Text for sharing device test results: device, route snapshot, recognition and speech
    /// pipeline metadata and the event log. Contains no audio, no transcripts and no summaries.
    func diagnosticsReport() -> String {
        [
            "Device: \(DeviceInfo.summary)",
            "App policy: \(policy.title) [\(policy.id)]",
            "State: \(state.title)",
            captureFormat.map { "Capture format: \($0.summary)" } ?? "Capture format: not capturing",
            "",
            route.reportText(),
            "",
            recognition.reportText(),
            "",
            speech.reportText(),
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
            log.append(.session, "Activation steps: \(session.lastTrace.summary)")
            recognition.sessionWillStart()
            speech.sessionWillStart()
            let engineStart = ContinuousClock.now
            let format = try capture.start()
            log.append(.capture, "Engine start took \(milliseconds(since: engineStart))")
            captureFormat = format
            state = .listening
            log.append(.capture, "Capture running: \(format.summary)")
            refreshRoute()
            return true
        } catch {
            endCapture(keepSession: false)
            state = .failed(error.localizedDescription)
            log.append(.error, "Start failed: \(error.localizedDescription)")
            refreshRoute()
            return false
        }
    }

    /// Stops capture (microphone off) and, unless `keepSession`, deactivates the session so
    /// other apps can resume normally.
    private func endCapture(keepSession: Bool) {
        let engineStop = ContinuousClock.now
        capture.stop()
        log.append(.capture, "Engine stop took \(milliseconds(since: engineStop))")
        recognition.sessionDidEnd()
        speech.sessionDidEnd()
        if keepSession {
            log.append(.session, "Session kept active (microphone off)")
        } else if session.isActive {
            do {
                try session.deactivate()
                log.append(.session, "Session deactivated (\(session.lastTrace.summary))")
            } catch {
                log.append(.error, "Session deactivation failed: \(error.localizedDescription)")
            }
        }
        captureFormat = nil
        level = .silence
        levelHistory.removeAll()
        refreshRoute()
    }

    private func connect(_ capture: MicrophoneCapture) {
        capture.addConsumer(recognition.engine)
        capture.addConsumer(speech.engine.audioTap)
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
            recognition.sessionDidEnd()
            speech.sessionDidEnd()
            session.noteDeactivatedBySystem()
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
            capture.removeAllConsumers()
            recognition.sessionDidEnd()
            speech.sessionDidEnd()
            session.noteDeactivatedBySystem()
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
            endCapture(keepSession: false)
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

    private func milliseconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = (ContinuousClock.now - start).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        return ms.formatted(.number.precision(.fractionLength(1))) + " ms"
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
