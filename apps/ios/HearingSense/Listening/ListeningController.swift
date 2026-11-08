import Attention
import HearingSenseAudio
import HearingSenseDomain
import IslandPresentation
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
/// Window 4 attaches no audio consumer at all: the attention engine (owned by `attention`) only
/// receives the confirmed sound events and speech results the two pipelines already publish.
/// Window 5 adds the presentation outside the app (owned by `liveActivity`): it gets the same
/// confirmed sound events for its icon-only channel and the attention engine's intents for the
/// important one.
///
/// Window 7: one listening session at a time, switched by `ListeningSessionMachine`. The buttons
/// in the app, the "Toggle Hearing Sense" intent (Action Button) and the debug arguments all go
/// through `start`, `stop` and `toggle`; a request that arrives while a start is in progress is
/// refused. Whether a session was open is stored after every change, so a relaunch knows that
/// the previous process ended while listening (it never restarts the microphone by itself).
@Observable
final class ListeningController {
    static let historyLength = 120  // about 10 s of level history at ~12 buffers/s
    private static let sessionRecordKey = "listening.session.v1"

    /// The one controller of the process. App Intents run without a scene and without the SwiftUI
    /// environment, so the app and its intents share this instance.
    static let shared = ListeningController()

    /// What a toggle did, for the intent's short answer.
    enum ToggleOutcome: Equatable {
        case turnedOn
        case turnedOff
        /// A start is still in progress; nothing changed.
        case busy
        case failed(String)

        var dialog: String {
            switch self {
            case .turnedOn: "Hearing Sense is on."
            case .turnedOff: "Hearing Sense is off."
            case .busy: "Hearing Sense is still starting."
            case .failed(let message): "Hearing Sense could not start. \(message)"
            }
        }
    }

    private(set) var state: ListeningState = .idle
    /// The ON/OFF switch. `state` says what the microphone is doing; this says whether a session is open.
    private(set) var session = ListeningSessionMachine()
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
    /// Window 4: decides which sound events and speech results deserve attention.
    let attention = AttentionController()
    /// Window 5: the Live Activity (Dynamic Island and Lock Screen) of the listening session.
    let liveActivity = LiveActivityController()
    /// Window 7: the acoustic scene, from the same confirmed sound events.
    let scene = SceneAwarenessController()
    /// Conversation summaries on request, continued understanding with live captions, saved summaries.
    let conversation: ConversationIntelligenceController

    @ObservationIgnored private var capture = MicrophoneCapture()
    @ObservationIgnored private let audioSession = AudioSessionController()
    @ObservationIgnored private var sessionObserver: AudioSessionObserver?
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private let defaults: UserDefaults
    /// Hybrid classifier experiment: tells the switching backend which classifier should run.
    /// Unused (and harmless) with a single classifier.
    @ObservationIgnored private let backendSelection = ClassifierBackendSelection()
    @ObservationIgnored private var backgroundCheckpoint: CaptureThroughput.Checkpoint?
    /// A hard end for this launch's listening (timed device tests): see `limitListening(to:)`.
    private(set) var timeLimit: SessionTimeLimit?
    @ObservationIgnored private var timeLimitTask: Task<Void, Never>?
    /// Called right after the time limit switched the microphone off (the debug export writes
    /// its file at once, so the stop can be read from the Mac).
    @ObservationIgnored var onTimeLimitStop: (() -> Void)?
    #if DEBUG
    /// Window 8: the device test mode as the app's screen shows it (`DeviceTestMode` holds it).
    private(set) var testConfiguration = DeviceTestMode.configuration
    /// The open session runs without the microphone (see `captureDecision(for:)`).
    private(set) var sessionIsSynthetic = false
    /// When the device test mode ends the open session.
    private(set) var testSessionDeadline: Date?
    @ObservationIgnored private var testSessionTask: Task<Void, Never>?
    /// The metadata export; started with the controller, so it also runs in a process that iOS
    /// launched for an intent.
    @ObservationIgnored private(set) var diagnosticsExporter: DebugDiagnosticsExporter?
    @ObservationIgnored private var testSceneTask: Task<Void, Never>?
    @ObservationIgnored private var testSceneBackgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        route = AudioRouteSnapshot.capture()
        var backendNote: (DiagnosticEventLog.Kind, String)?
        var experimental: (RecognitionController, SpeechIntelligenceController)?
        #if DEBUG
        // Research switch: a converted third-party classifier on the CPU instead of Apple's.
        if let choice = ExperimentalClassifier.requested, DeviceTestMode.configuration.prohibitsModelInference {
            backendNote = (.lifecycle, "Experimental classifier \(choice.model.rawValue) not loaded: model inference is "
                + "prohibited by the device test mode")
        } else if let choice = ExperimentalClassifier.requested {
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
        #if DEBUG
        // While model inference is prohibited the language model is not reachable at all.
        conversation = DeviceTestMode.configuration.prohibitsModelInference
            ? ConversationIntelligenceController(summarizer: ProhibitedSummarizer()) : ConversationIntelligenceController()
        #else
        conversation = ConversationIntelligenceController()
        #endif
        recognition = experimental?.0 ?? RecognitionController()
        speech = experimental?.1 ?? SpeechIntelligenceController()
        if let backendNote { log.append(backendNote.0, backendNote.1) }
        connect(capture)
        recognition.setLogger { [weak self] kind, message in self?.log.append(kind, message) }
        speech.setLogger { [weak self] kind, message in self?.log.append(kind, message) }
        attention.setLogger { [weak self] kind, message in self?.log.append(kind, message) }
        liveActivity.setLogger { [weak self] kind, message in self?.log.append(kind, message) }
        recognition.setForwarding(frame: { [engine = speech.engine] in engine.process($0) },
                                  event: { [engine = speech.engine, attention, liveActivity, scene] update in
                                      engine.process(update)
                                      attention.receive(update)
                                      // Every confirmed event, whatever the attention engine decides.
                                      liveActivity.receive(update)
                                      scene.receive(update)
                                  })
        scene.setLogger { [weak self] kind, message in self?.log.append(kind, message) }
        scene.onChange = { [liveActivity] in liveActivity.receive(sceneTitle: $0?.scene.title) }
        attention.onIntent = { [liveActivity] in liveActivity.receive($0) }
        attention.onInjectedSound = { [liveActivity, scene] in
            liveActivity.receive($0)
            scene.receive($0)
        }
        speech.setForwarding(result: { [attention, conversation] in
                                 attention.receive($0)
                                 conversation.receive($0)
                             },
                             cleared: { [attention, conversation, liveActivity] in
                                 attention.speechDataCleared()
                                 conversation.speechDataCleared()
                                 liveActivity.speechDataCleared()
                             })
        // The state of a requested summary goes to the Live Activity, whose expanded
        // presentation offers the controls for it. The conversation controller follows the attention controller's session, which starts and ends with capture.
        conversation.setLogger { [weak self] kind, message in self?.log.append(kind, message) }
        conversation.onIslandState = { [liveActivity] in liveActivity.receive(conversation: $0) }
        // The buttons of the expanded Dynamic Island (Live Activity intents) arrive here.
        HearingSenseActionCenter.handler = { [weak self] action in self?.perform(action) }
        conversation.transcriptionProvider = { [speech] in speech.isTranscriptionEnabled }
        attention.onSessionChange = { [conversation, speech] isActive in
            if isActive {
                conversation.sessionWillStart(isTranscriptionOn: speech.isTranscriptionEnabled)
            } else {
                conversation.sessionDidEnd()
            }
        }
        sessionObserver = AudioSessionObserver { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
        log.append(.lifecycle, "App launched on \(DeviceInfo.summary). Microphone permission: \(MicrophonePermission.current.rawValue)")
        // A process launched for an intent (Action Button) starts without a scene.
        isInBackground = UIApplication.shared.applicationState == .background
        conversation.foregroundChanged(UIApplication.shared.applicationState == .active)
        let stored = defaults.data(forKey: Self.sessionRecordKey)
            .flatMap { try? JSONDecoder().decode(ListeningSessionRecord.self, from: $0) }
        if let stored { report(.restored(stored, at: .now)) }
        #if DEBUG
        for line in DeviceTestMode.reportLines() { log.append(.lifecycle, line.trimmingCharacters(in: .whitespaces)) }
        if testConfiguration.isHalted {
            // Whatever an earlier process left on the island goes; nothing starts.
            liveActivity.endLeftoverActivities()
        }
        if (testConfiguration.isEnabled && testConfiguration.exportsDiagnostics) || DebugDiagnosticsExporter.isExportRequested {
            startDiagnosticsExport()
        }
        #endif
    }

    var assessment: RouteAssessment { RouteAssessment.evaluate(route) }

    // MARK: - User actions

    /// Turns listening on. Refused (and logged) while a session is open or a start is in progress.
    func start(source: ListeningRequestSource = .app) async {
        await request(.start(source, at: .now))
    }

    /// Turns listening off: the microphone, sound recognition, the temporary speech text, a
    /// followed conversation and the Live Activity all end. Saved summaries stay.
    func stop(source: ListeningRequestSource = .app) async {
        await request(.stop(source, at: .now))
    }

    /// For an intent that may leave the microphone on (`AudioRecordingIntent`): waits for the
    /// Live Activity and, when there is none, switches listening off again, because App Intents
    /// ends the process when such an intent returns with an active audio session and no Live
    /// Activity. Returns what to tell the user, or nil when all is well.
    func requireLiveActivityForIntent() async -> String? {
        guard session.isOn || state.isCapturing || audioSession.isActive else { return nil }
        if await liveActivity.ensureRunning() { return nil }
        let reason = !liveActivity.settings.isEnabled
            ? "Turn on “Show in Dynamic Island” in Hearing Sense settings to use this."
            : liveActivity.status == .notAllowed
                ? "Allow Live Activities for Hearing Sense in Settings to use this."
                : "Open Hearing Sense to start listening."
        log.append(.error, "Intent: no Live Activity for the listening session (\(liveActivity.status)); listening switched off")
        await stop(source: .intent)
        return "Hearing Sense could not start. " + reason
    }

    /// ON when off, OFF when on (the Action Button's intent). Never anything else.
    @discardableResult
    func toggle(source: ListeningRequestSource) async -> ToggleOutcome {
        #if DEBUG
        // A session whose time was over while the process was suspended: this press ends it.
        if enforceTestSessionLimit(trigger: "request") { return .turnedOff }
        if !session.isOn, Self.captureDecision(for: source) == .refused {
            log.append(.lifecycle, "Listening request refused: the device test mode's emergency stop is set")
            return .failed("The test mode's emergency stop is set.")
        }
        #endif
        let wasOn = session.isOn
        let effects = await request(.toggle(source, at: .now))
        if effects.contains(where: { if case .refused = $0 { true } else { false } }) { return .busy }
        if wasOn { return .turnedOff }
        switch state {
        case .listening: return .turnedOn
        case .permissionDenied: return .failed("Microphone access is off in Settings.")
        case .failed(let message): return .failed(message)
        default: return session.isOn ? .turnedOn : .failed("Open the app and try again.")
        }
    }

    /// A control of the expanded Dynamic Island was pressed. Each one acts on the conversation
    /// only; none of them starts or stops listening.
    func perform(_ action: HearingSenseAction) {
        log.append(.lifecycle, "Live Activity control: \(action.rawValue)")
        switch action {
        case .summarize: conversation.summarize()
        case .continueUnderstanding: conversation.continueUnderstanding()
        case .stopUnderstanding: conversation.stopUnderstanding()
        }
    }

    /// A start would have to show the microphone permission prompt, which iOS only shows while
    /// the app is on screen.
    var needsForegroundToStart: Bool {
        #if DEBUG
        if Self.captureDecision(for: .intent) != .microphone { return false }
        #endif
        return !session.isOn && MicrophonePermission.current == .undetermined
    }

    #if DEBUG
    /// `--hs-synthetic-capture` (Debug builds): a listening session without the microphone. The
    /// audio session is not activated and the engine is not started; everything else — the
    /// switch, the Live Activity, the conversation controller — runs as usual and is fed with
    /// synthetic events. For checks on the Mac and in the Simulator, where the microphone would
    /// pick up real speech in the room.
    static let syntheticCaptureArgument = "--hs-synthetic-capture"
    static var launchRequestsSyntheticCapture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(syntheticCaptureArgument) || arguments.contains("--hs-w7-selftest")
            || arguments.contains("--hs-w9-selftest")
    }

    /// What a start asked for by `source` gets: the device test mode decides first (stored on
    /// the device, so it also holds for an intent's launch); the launch argument can only take
    /// the microphone away, never give it.
    static func captureDecision(for source: ListeningRequestSource) -> DeviceTestConfiguration.CaptureDecision {
        let decision = DeviceTestMode.configuration.capture(for: source)
        return decision == .microphone && launchRequestsSyntheticCapture ? .synthetic : decision
    }
    #endif

    @discardableResult
    private func request(_ input: ListeningSessionMachine.Input) async -> [ListeningSessionMachine.Effect] {
        let effects = session.process(input)
        persistSession()
        for effect in effects {
            switch effect {
            case .beginSession(let id):
                log.append(.lifecycle, "Listening session \(id.uuidString.prefix(8)) requested (\(session.requestedBy?.rawValue ?? "?"))")
                await startCapture()
            case .resumeSession:
                await startCapture()
            case .endSession(_, let reason):
                // Any other reason was reported by the code that already switched the microphone off.
                if reason == .userStopped { stopCapture() }
            case .refused(let reason):
                log.append(.lifecycle, "Listening request refused: \(reason.rawValue)")
            case .previousSessionLost:
                break
            }
        }
        return effects
    }

    /// Tells the switch what happened to the microphone. Its effects are not carried out: the
    /// caller already did what they describe.
    private func report(_ input: ListeningSessionMachine.Input) {
        for effect in session.process(input) {
            if case .previousSessionLost(let record) = effect {
                let since = record.startedAt.map { " (started \($0.formatted(.iso8601)))" } ?? ""
                log.append(.lifecycle, "The previous launch ended while a listening session was open\(since). "
                    + "Nothing was restarted; the microphone is off.")
            }
        }
        persistSession()
    }

    private func persistSession() {
        if let data = try? JSONEncoder().encode(session.record) { defaults.set(data, forKey: Self.sessionRecordKey) }
    }

    private func startCapture() async {
        guard state.canStart else {
            report(.captureEnded(.startFailed, at: .now))
            return
        }
        guard captureIsAllowed(context: "Start") else {
            report(.captureEnded(.timeLimit, at: .now))
            return
        }

        var permission = MicrophonePermission.current
        #if DEBUG
        let decision = Self.captureDecision(for: session.requestedBy ?? .automation)
        guard decision != .refused else {
            log.append(.lifecycle, "Start refused: the device test mode's emergency stop is set")
            report(.captureEnded(.startFailed, at: .now))
            return
        }
        sessionIsSynthetic = decision == .synthetic
        if sessionIsSynthetic { permission = .granted }
        #endif
        switch permission {
        case .granted:
            break
        case .denied:
            state = .permissionDenied
            log.append(.permission, "Start refused: microphone permission denied")
            report(.captureEnded(.startFailed, at: .now))
            return
        case .undetermined:
            state = .requestingPermission
            let result = await MicrophonePermission.request()
            log.append(.permission, "Permission prompt answered: \(result.rawValue)")
            guard result == .granted else {
                state = .permissionDenied
                report(.captureEnded(.startFailed, at: .now))
                return
            }
        }

        state = .starting
        if beginCapture() {
            log.append(.lifecycle, "Listening started with policy “\(policy.title)”")
            announce("Listening started")
        }
    }

    // MARK: - Time limit (timed tests end by themselves)

    /// From now on this launch listens for at most `seconds`: at the deadline the microphone is
    /// switched off, and nothing starts or resumes it afterwards (an interruption that ends after
    /// the deadline does not bring the microphone back). The stop does not depend on one timer:
    /// every audio buffer that still arrives after the deadline triggers it as well, so the
    /// microphone cannot keep delivering audio past the limit while the app is running.
    func limitListening(to seconds: TimeInterval) {
        let limit = SessionTimeLimit(armedAt: .now, duration: seconds)
        timeLimit = limit
        log.append(.lifecycle, "Time limit armed: the microphone is switched off "
            + "\(limit.duration.formatted(.number.precision(.fractionLength(0)))) s from now, at "
            + limit.deadline.formatted(.iso8601.time(includingFractionalSeconds: true)))
        timeLimitTask?.cancel()
        timeLimitTask = Task { [weak self] in
            // The continuous clock keeps counting while the app is in the background.
            try? await Task.sleep(for: .seconds(limit.duration), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.enforceTimeLimit(trigger: .timer)
        }
    }

    private func enforceTimeLimit(trigger: SessionTimeLimit.Trigger) {
        guard var limit = timeLimit, limit.isDue(at: .now) else { return }
        limit.fire(at: .now, trigger: trigger)
        timeLimit = limit
        let wasOn = state.canStop
        if wasOn {
            endCapture(keepSession: false)
            state = .idle
        }
        report(.captureEnded(.timeLimit, at: .now))
        log.append(.lifecycle, "Time limit reached (trigger: \(trigger.rawValue), "
            + "\((limit.lateness ?? 0).formatted(.number.precision(.fractionLength(2)))) s after the deadline): "
            + (wasOn ? "listening stopped; microphone released" : "the microphone was already off"))
        if wasOn { announce("Listening stopped") }
        onTimeLimitStop?()
    }

    /// False (and logged) once a time limit's deadline has passed.
    private func captureIsAllowed(context: String) -> Bool {
        guard let limit = timeLimit, !limit.allowsCapture(at: .now) else { return true }
        log.append(.lifecycle, "\(context) refused: this launch's listening time limit is over")
        enforceTimeLimit(trigger: .startRefused)
        return false
    }

    private func stopCapture() {
        guard state.canStop else {
            // The session was open without a microphone (start failed half-way): nothing to stop.
            if !state.canStart { state = .idle }
            return
        }
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
            try audioSession.setPreferredInput(uid: uid)
            log.append(.route, "Preferred input set to \(uid ?? "system default")")
        } catch {
            log.append(.error, "Could not set preferred input: \(error.localizedDescription)")
        }
        refreshRoute()
    }

    func setKeepsSessionActiveWhenStopped(_ value: Bool) {
        keepsSessionActiveWhenStopped = value
        log.append(.session, "Keep session active when stopped: \(value ? "on" : "off")")
        if !value, !state.isCapturing, audioSession.isActive {
            do {
                try audioSession.deactivate()
                log.append(.session, "Session deactivated (\(audioSession.lastTrace.summary))")
            } catch {
                log.append(.error, "Session deactivation failed: \(error.localizedDescription)")
            }
            refreshRoute()
        }
    }

    func refreshRoute() {
        route = audioSession.snapshot()
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
        conversation.foregroundChanged(phase == .active)
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
            liveActivity.appBecameActive()
            refreshRoute()
            #if DEBUG
            enforceTestSessionLimit(trigger: "app became active")
            #endif
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
            testModeReport,
            "Listening session: \(session.phase.rawValue) · started \(session.statistics.sessionsStarted), ended "
                + "\(session.statistics.sessionsEnded), toggles \(session.statistics.toggles), requests refused "
                + "\(session.statistics.requestsRefused) · last end: \(session.lastEndReason?.rawValue ?? "none")",
            captureFormat.map { "Capture format: \($0.summary)" } ?? "Capture format: not capturing",
            "",
            route.reportText(),
            "",
            recognition.reportText(),
            "",
            speech.reportText(),
            "",
            attention.reportText(),
            "",
            scene.reportText(),
            "",
            liveActivity.reportText(),
            "",
            conversation.reportText(),
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
        #if DEBUG
        if sessionIsSynthetic {
            log.append(.session, "Synthetic capture: the microphone stays off and the audio session is not activated")
            recognition.sessionWillStart()
            speech.sessionWillStart()
            attention.sessionWillStart()
            scene.sessionWillStart()
            liveActivity.sessionWillStart()
            state = .listening
            report(.captureStarted(at: .now))
            armTestSessionLimit()
            return true
        }
        // Second line: whatever led here, a prohibited microphone is not started.
        guard !DeviceTestMode.configuration.prohibitsMicrophone else {
            state = .failed("The microphone is prohibited by the device test mode.")
            report(.captureEnded(.startFailed, at: .now))
            log.append(.error, "Start refused: the microphone is prohibited by the device test mode")
            return false
        }
        #endif
        do {
            let input = try audioSession.activate(policy: policy)
            log.append(.session, "Session active (playAndRecord, \(policy.mode.rawValue), "
                + "\(policy.options.map(\.rawValue).joined(separator: ", "))); preferred input: \(describe(input))")
            log.append(.session, "Activation steps: \(audioSession.lastTrace.summary)")
            recognition.sessionWillStart()
            speech.sessionWillStart()
            attention.sessionWillStart()
            scene.sessionWillStart()
            liveActivity.sessionWillStart()
            let engineStart = ContinuousClock.now
            let format = try capture.start()
            log.append(.capture, "Engine start took \(milliseconds(since: engineStart))")
            captureFormat = format
            state = .listening
            report(.captureStarted(at: .now))
            #if DEBUG
            armTestSessionLimit()
            #endif
            log.append(.capture, "Capture running: \(format.summary)")
            refreshRoute()
            return true
        } catch {
            endCapture(keepSession: false)
            state = .failed(error.localizedDescription)
            report(.captureEnded(.startFailed, at: .now))
            log.append(.error, "Start failed: \(error.localizedDescription)")
            refreshRoute()
            return false
        }
    }

    /// Stops capture (microphone off) and, unless `keepSession`, deactivates the session so
    /// other apps can resume normally.
    private func endCapture(keepSession: Bool) {
        #if DEBUG
        testSessionTask?.cancel()
        testSessionTask = nil
        testSessionDeadline = nil
        #endif
        let engineStop = ContinuousClock.now
        capture.stop()
        log.append(.capture, "Engine stop took \(milliseconds(since: engineStop))")
        recognition.sessionDidEnd()
        speech.sessionDidEnd()
        attention.sessionDidEnd()
        scene.sessionDidEnd()
        liveActivity.sessionDidEnd()
        if keepSession {
            log.append(.session, "Session kept active (microphone off)")
        } else if audioSession.isActive {
            do {
                try audioSession.deactivate()
                log.append(.session, "Session deactivated (\(audioSession.lastTrace.summary))")
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
        // Second line of the time limit: audio is still arriving after the deadline.
        if let timeLimit, timeLimit.isDue(at: .now) {
            enforceTimeLimit(trigger: .captureTick)
            return
        }
        #if DEBUG
        if enforceTestSessionLimit(trigger: "capture tick") { return }
        #endif
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
            attention.sessionDidEnd()
            scene.sessionDidEnd()
            // The session is expected to resume: the activity stays and shows "paused".
            liveActivity.sessionPaused()
            audioSession.noteDeactivatedBySystem()
            captureFormat = nil
            level = .silence
            state = .interrupted
            report(.interrupted(at: .now))
            announce("Listening paused by the system")
        case .interruptionEnded(let shouldResume):
            guard state == .interrupted else { break }
            if shouldResume {
                guard captureIsAllowed(context: "Resume after the interruption") else {
                    state = .idle
                    report(.captureEnded(.timeLimit, at: .now))
                    break
                }
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
            attention.sessionDidEnd()
            scene.sessionDidEnd()
            liveActivity.sessionDidEnd()
            audioSession.noteDeactivatedBySystem()
            capture = MicrophoneCapture()
            connect(capture)
            captureFormat = nil
            level = .silence
            if wasActive {
                state = .failed("Audio services were reset by iOS. Tap Start Listening to continue.")
                report(.captureEnded(.captureFailed, at: .now))
            }
            refreshRoute()
        case .mediaServicesWereLost, .silenceSecondaryAudioHint:
            refreshRoute()
        }
    }

    private func handleEngineConfigurationChange() {
        log.append(.capture, "AVAudioEngine configuration changed (hardware format or route); engine stopped")
        guard state.isCapturing else { return }
        #if DEBUG
        // A synthetic session has no engine to bring back, and a prohibited microphone stays off.
        guard !sessionIsSynthetic, !DeviceTestMode.configuration.prohibitsMicrophone else {
            log.append(.capture, "Capture not restarted: this session runs without the microphone")
            return
        }
        #endif
        guard captureIsAllowed(context: "Capture restart") else { return }
        do {
            let format = try capture.restart()
            captureFormat = format
            log.append(.capture, "Capture restarted: \(format.summary)")
        } catch {
            endCapture(keepSession: false)
            state = .failed("Capture could not restart after an audio route change: \(error.localizedDescription)")
            report(.captureEnded(.captureFailed, at: .now))
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

    // MARK: - Device test mode (Debug builds, Window 8)

    /// The device test mode and what the microphone is doing, for the shared report. Release
    /// builds have no test mode.
    private var testModeReport: String {
        #if DEBUG
        (DeviceTestMode.reportLines() + ["Microphone right now: \(microphoneFacts)"]).joined(separator: "\n")
        #else
        "Device test mode: not part of this build"
        #endif
    }

    #if DEBUG
    /// What the microphone is doing, from the objects that would run it: this session's kind,
    /// whether this app activated its audio session, whether the audio engine is running.
    var microphoneFacts: String {
        "capture=\(state.isCapturing ? (sessionIsSynthetic ? "synthetic" : "microphone") : "none") "
            + "audioSession=\(audioSession.isActive ? "active" : "inactive") engine=\(capture.isRunning ? "running" : "stopped") "
            + "micPermission=\(MicrophonePermission.current.rawValue)"
    }

    @discardableResult
    func startDiagnosticsExport() -> DebugDiagnosticsExporter {
        if let diagnosticsExporter { return diagnosticsExporter }
        let exporter = DebugDiagnosticsExporter(controller: self)
        exporter.start()
        diagnosticsExporter = exporter
        // The stop of a timed test is in the file the moment it happens.
        onTimeLimitStop = { [exporter] in exporter.writeNow() }
        return exporter
    }

    /// Every session of the device test mode ends by itself: a timer, every audio buffer after
    /// the deadline, the next request and the app's return to the screen all carry it out. (A
    /// process that iOS suspended runs no timer; a synthetic session then ends when the process
    /// next runs. A session with the microphone is not suspended.)
    private func armTestSessionLimit() {
        guard testSessionDeadline == nil, let seconds = DeviceTestMode.configuration.effectiveSessionLimit else { return }
        let deadline = Date.now.addingTimeInterval(seconds)
        testSessionDeadline = deadline
        log.append(.lifecycle, "Device test mode: this session ends by itself in \(Int(seconds)) s, at "
            + deadline.formatted(.iso8601.time(includingFractionalSeconds: true)))
        testSessionTask?.cancel()
        testSessionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.enforceTestSessionLimit(trigger: "timer")
        }
    }

    /// Ends the open session if its test deadline has passed. Returns whether it did.
    @discardableResult
    private func enforceTestSessionLimit(trigger: String) -> Bool {
        guard let deadline = testSessionDeadline, Date.now >= deadline else { return false }
        let late = Date.now.timeIntervalSince(deadline)
        endCapture(keepSession: false)
        state = .idle
        report(.captureEnded(.timeLimit, at: .now))
        log.append(.lifecycle, "Device test mode: session ended automatically (trigger: \(trigger), "
            + "\(late.formatted(.number.precision(.fractionLength(1)))) s after its deadline); \(microphoneFacts)")
        announce("Listening stopped")
        diagnosticsExporter?.writeNow()
        return true
    }

    /// Emergency stop: everything off now, and nothing starts again until it is cleared. Does
    /// not go through the switch, which refuses a stop while a start is in progress.
    func emergencyStop(reason: String) {
        DeviceTestMode.halt()
        testConfiguration = DeviceTestMode.configuration
        testSceneTask?.cancel()
        attention.stopInjection()
        liveActivity.stopDemo(attention: attention)
        let wasOpen = session.isOn || state.canStop
        endCapture(keepSession: false)
        state = .idle
        report(.captureEnded(.userStopped, at: .now))
        liveActivity.endLeftoverActivities()
        log.append(.lifecycle, "EMERGENCY STOP (\(reason)): " + (wasOpen ? "session ended" : "no session was open")
            + "; nothing starts until it is cleared; \(microphoneFacts)")
        announce("Emergency stop")
        diagnosticsExporter?.writeNow()
    }

    func clearEmergencyStop() {
        DeviceTestMode.resume()
        testConfiguration = DeviceTestMode.configuration
        log.append(.lifecycle, "Emergency stop cleared. \(DeviceTestMode.summary)")
        diagnosticsExporter?.writeNow()
    }

    /// Plays a synthetic scene into the open session (`--hs-island-demo` together with a session):
    /// the events take the path real ones take, to the attention engine, the scene and the Live
    /// Activity. With `afterBackground` the scene starts when the app leaves the screen, which is
    /// when the island shows the activity; a background task keeps the process running for it
    /// (about 30 s; without the microphone iOS suspends the app after that).
    func playTestScene(_ demo: LiveActivityController.DemoScene, keyAt: TimeInterval, afterBackground: Bool) {
        testSceneTask?.cancel()
        let scenario = demo.scenario(keyAt: keyAt)
        log.append(.lifecycle, "Test scene “\(demo.title)” armed (synthetic events; main event at \(keyAt.formatted()) s"
            + (afterBackground ? " after the app leaves the screen)" : ")"))
        testSceneTask = Task { [weak self] in
            if afterBackground {
                let entered = NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification)
                    .map { _ in () }
                for await _ in entered { break }
            }
            guard !Task.isCancelled, let self, self.session.isOn else { return }
            self.testSceneBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "test-scene") { [weak self] in
                guard let self else { return }
                self.log.append(.lifecycle, "Test scene: background time is over; iOS suspends the app now")
                self.diagnosticsExporter?.writeNow()
                UIApplication.shared.endBackgroundTask(self.testSceneBackgroundTask)
                self.testSceneBackgroundTask = .invalid
            }
            self.attention.inject(scenario)
        }
    }
    #endif

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
