import ActivityKit
import HearingSenseAudio
import HearingSenseDomain
import IslandPresentation
import IslandViews
import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// Runs the Live Activity of a listening session (Window 5): the Dynamic Island and Lock Screen
/// presentation outside the app.
///
/// It feeds `IslandPipeline` with the two channels the pipelines already produce — confirmed
/// sound events (ordinary sounds as an icon) and the attention engine's presentation intents
/// (important events with text) — and carries out the pipeline's commands with ActivityKit.
/// It decides nothing about importance; that stays in Window 4.
///
/// One activity per session, never two: leftovers of an earlier launch are ended before a new
/// one is requested, and all ActivityKit calls go through one serial queue.
///
/// Quiet by construction:
/// - Updates are plain `Activity.update` calls without an alert configuration. They do not wake
///   the screen, play a sound or vibrate; a locked iPhone shows the new state the next time the
///   screen is on.
/// - An alert configuration (the only way to ask iOS to expand the island) is attached only when
///   the user turned "Expand for important events" on (off by default) and `AlertGate` judges
///   the iPhone unlocked. The lock state is an estimate (see `DeviceLockEstimate`), so "locked"
///   and "cannot tell" both mean a silent update.
/// - No notification is ever scheduled.
///
/// Main-actor isolated (app default) and owned by `ListeningController`, so it keeps working in
/// the background. Event-driven: one pending timer for the pipeline's next deadline.
///
/// Privacy: the activity's content leaves the app's memory (iOS keeps it for the widget
/// extension). Speech-derived text is part of it only while "Show speech summaries" is on, and
/// only for the episode in front; logs and reports here never contain it.
@Observable
final class LiveActivityController {
    enum Status: Equatable {
        case idle
        case running
        /// The activity could not be started or was ended by iOS while the app was not on screen;
        /// it is started again the next time the app is opened.
        case waitingForForeground
        /// Live Activities are turned off for this app in Settings.
        case notAllowed
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Not running"
            case .running: "Running"
            case .waitingForForeground: "Open the app to show it again"
            case .notAllowed: "Live Activities are off in Settings"
            case .failed(let message): "Failed: \(message)"
            }
        }
    }

    private static let settingsKey = "island.settings.v1"
    /// Set once protected data was seen to become unavailable on this installation.
    private static let lockSignalKey = "island.lockSignalObserved.v1"

    private(set) var settings: IslandSettings
    /// What the activity shows (or would show) right now.
    private(set) var content: IslandContent?
    private(set) var status: Status = .idle
    private(set) var statistics = IslandStatistics()
    private(set) var ambientStatistics = AmbientIconStatistics()
    private(set) var lockEstimate: DeviceLockEstimate = .unknown
    /// Expansion requests that were passed on to iOS, and the ones held back, by reason.
    private(set) var alertsSent = 0
    private(set) var alertsBlocked: [AlertGate.BlockReason: Int] = [:]
    /// Activities requested in this launch, and how often iOS ended one that was still wanted.
    private(set) var activitiesStarted = 0
    private(set) var endedBySystem = 0
    private(set) var activityStartedAt: Date?
    private(set) var isDemoRunning = false

    @ObservationIgnored private var pipeline: IslandPipeline
    @ObservationIgnored private var activity: Activity<HearingSenseActivityAttributes>?
    @ObservationIgnored private var needsStart = false
    @ObservationIgnored private var passcodeSet: Bool?
    @ObservationIgnored private var lockSignalObserved: Bool
    @ObservationIgnored private var protectedDataTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let jobs: AsyncStream<Job>.Continuation
    @ObservationIgnored private var log: (DiagnosticEventLog.Kind, String) -> Void = { _, _ in }
    #if DEBUG
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var demoBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private enum Job {
        /// End activities a previous launch left behind.
        case cleanUp
        case start
        case update(IslandContent, IslandAlertRequest?)
        case end
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(IslandSettings.self, from: $0) }
        settings = stored ?? .default
        pipeline = IslandPipeline(settings: stored ?? .default)
        lockSignalObserved = defaults.bool(forKey: Self.lockSignalKey)
        let (stream, continuation) = AsyncStream<Job>.makeStream()
        jobs = continuation
        worker = Task { [weak self] in
            for await job in stream {
                await self?.perform(job)
            }
        }
        // The lock estimate rests on this signal; it counts only once it was seen to change here.
        protectedDataTask = Task { [weak self] in
            let name = UIApplication.protectedDataWillBecomeUnavailableNotification
            for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                self?.protectedDataBecameUnavailable()
            }
        }
        refreshLockEstimate(checkPasscode: true)
        jobs.yield(.cleanUp)
    }

    private func protectedDataBecameUnavailable() {
        if !lockSignalObserved {
            lockSignalObserved = true
            defaults.set(true, forKey: Self.lockSignalKey)
            log(.lifecycle, "Live Activity: lock signal observed on this iPhone (protected data became unavailable)")
        }
        lockEstimate = .locked
    }

    deinit {
        deadlineTask?.cancel()
        stateTask?.cancel()
        worker?.cancel()
        jobs.finish()
        protectedDataTask?.cancel()
    }

    /// Where lifecycle messages go (the app's diagnostic log). Metadata only.
    func setLogger(_ logger: @escaping (DiagnosticEventLog.Kind, String) -> Void) {
        log = logger
    }

    // MARK: - Inputs (called by ListeningController's wiring)

    func sessionWillStart() {
        process(.sessionStarted(at: .now))
    }

    /// The microphone is off for now (interruption): the activity stays and shows "paused".
    func sessionPaused() {
        process(.sessionPaused(at: .now))
    }

    func sessionDidEnd() {
        #if DEBUG
        guard !isDemoRunning else { return }
        #endif
        process(.sessionEnded(at: .now))
    }

    /// Window 2: every confirmed sound event, including the ones the attention engine suppresses.
    func receive(_ update: AcousticEventUpdate) {
        process(.sound(update))
    }

    /// Window 4: what the attention engine wants presented.
    func receive(_ intent: AttentionPresentationIntent) {
        process(.intent(intent))
    }

    func appBecameActive() {
        refreshLockEstimate(checkPasscode: true)
        // An activity can only be requested while the app is on screen.
        if needsStart, pipeline.isLive { jobs.yield(.start) }
    }

    // MARK: - Settings

    func update(_ change: (inout IslandSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: Self.settingsKey) }
        log(.lifecycle, "Live Activity settings: activity \(updated.isEnabled ? "on" : "off"), ambient icons "
            + "\(updated.showsAmbientIcons ? "on" : "off"), expansion \(updated.expandsForImportantEvents ? "on" : "off"), "
            + "speech summaries \(updated.showsSpeechSummaries ? "on" : "off"), alert sound \(updated.playsAlertSound ? "on" : "off")")
        process(.settings(updated, at: .now))
    }

    // MARK: - Pipeline

    private func process(_ input: IslandInput) {
        for command in pipeline.process(input) {
            switch command {
            case .start:
                needsStart = true
                jobs.yield(.start)
            case .update(let content, let alert):
                jobs.yield(.update(content, alert.flatMap(gate)))
            case .end:
                needsStart = false
                jobs.yield(.end)
            }
        }
        content = pipeline.isLive ? pipeline.shown : nil
        statistics = pipeline.statistics
        ambientStatistics = pipeline.ambientStatistics
        scheduleDeadline()
    }

    /// Lets an expansion request through only when the iPhone is judged unlocked.
    private func gate(_ request: IslandAlertRequest) -> IslandAlertRequest? {
        refreshLockEstimate(checkPasscode: false)
        let isActive = UIApplication.shared.applicationState == .active
        var effective = settings
        #if DEBUG
        if Self.assumesUnlocked { effective.expandsForImportantEvents = true }
        #endif
        switch AlertGate.evaluate(settings: effective, lock: lockEstimate, appIsActive: isActive) {
        case .send:
            alertsSent += 1
            log(.recognition, "Live Activity: expansion requested for “\(request.title)” [\(request.priority)]")
            return request
        case .blocked(let reason):
            alertsBlocked[reason, default: 0] += 1
            log(.recognition, "Live Activity: silent update for “\(request.title)” [\(request.priority)] (\(reason.rawValue))")
            return nil
        }
    }

    private func refreshLockEstimate(checkPasscode: Bool) {
        if checkPasscode || passcodeSet == nil {
            // True when a passcode is set; this does not prompt and evaluates nothing.
            passcodeSet = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        }
        #if DEBUG
        if Self.assumesUnlocked {
            lockEstimate = .unlocked
            return
        }
        #endif
        let isAvailable = UIApplication.shared.isProtectedDataAvailable
        if !isAvailable, !lockSignalObserved {
            lockSignalObserved = true
            defaults.set(true, forKey: Self.lockSignalKey)
        }
        lockEstimate = DeviceLockEstimate.estimate(passcodeSet: passcodeSet, protectedDataAvailable: isAvailable,
                                                   lockSignalObserved: lockSignalObserved)
    }

    /// One timer for the pipeline's next deadline (an icon that lingered, an episode's expiry, a
    /// coalesced update, the keep-alive). Replaced whenever an input changes the deadline.
    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let deadline = pipeline.nextDeadline else {
            deadlineTask = nil
            return
        }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled, let self else { return }
            self.process(.tick(at: max(.now, deadline)))
        }
    }

    // MARK: - ActivityKit (one job at a time, in order)

    private func perform(_ job: Job) async {
        switch job {
        case .cleanUp:
            await endLeftovers()
        case .start:
            await startActivity()
        case .update(let content, let alert):
            // `Activity` is not declared Sendable, but its async methods are made to be awaited
            // from any context; this controller is the only one that holds the activity.
            guard let held = activity else { return }
            nonisolated(unsafe) let activity = held
            await activity.update(activityContent(content), alertConfiguration: alert.map(alertConfiguration))
        case .end:
            stateTask?.cancel()
            stateTask = nil
            if let held = activity {
                nonisolated(unsafe) let activity = held
                await activity.end(nil, dismissalPolicy: .immediate)
                log(.lifecycle, "Live Activity ended")
            }
            activity = nil
            activityStartedAt = nil
            status = .idle
        }
    }

    private func startActivity() async {
        // The session may have ended, or the activity may exist, by the time this job runs.
        guard pipeline.isLive, activity == nil, let content = pipeline.shown else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = .notAllowed
            needsStart = false
            log(.lifecycle, "Live Activity not started: Live Activities are turned off for Hearing Sense in Settings")
            return
        }
        await endLeftovers()
        guard pipeline.isLive, activity == nil else { return }
        let start = Date.now
        do {
            let requested = try Activity.request(attributes: HearingSenseActivityAttributes(sessionStart: start),
                                                 content: activityContent(pipeline.shown ?? content), pushType: nil)
            activity = requested
            activityStartedAt = start
            activitiesStarted += 1
            needsStart = false
            status = .running
            observe(requested)
            log(.lifecycle, "Live Activity started (\(content.redactedSummary))")
        } catch {
            // Typically: requested while the app was not on screen. Tried again in `appBecameActive`.
            needsStart = true
            status = UIApplication.shared.applicationState == .active ? .failed(error.localizedDescription)
                : .waitingForForeground
            log(.error, "Live Activity could not be started: \(error.localizedDescription)")
        }
    }

    /// Ends every activity of this app that this controller does not hold (a previous launch that
    /// was terminated while listening), so there is never a second one.
    private func endLeftovers() async {
        for found in Activity<HearingSenseActivityAttributes>.activities where found.id != activity?.id {
            nonisolated(unsafe) let leftover = found
            await leftover.end(nil, dismissalPolicy: .immediate)
            log(.lifecycle, "Live Activity: ended a leftover activity of an earlier launch")
        }
    }

    /// iOS ends a Live Activity after its maximum duration (8 hours, per Apple's documentation)
    /// and the user can remove it. If the session is still running it is requested again as soon
    /// as the app is on screen; it cannot be requested from the background.
    private func observe(_ observed: Activity<HearingSenseActivityAttributes>) {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in observed.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                guard state == .ended || state == .dismissed, self.activity?.id == observed.id else { continue }
                self.activity = nil
                self.activityStartedAt = nil
                guard self.pipeline.isLive else { continue }
                self.endedBySystem += 1
                self.needsStart = true
                self.status = .waitingForForeground
                self.log(.lifecycle, "Live Activity was ended by iOS or the user (\(state)); listening continues")
                if UIApplication.shared.applicationState == .active { self.jobs.yield(.start) }
            }
        }
    }

    private func activityContent(_ content: IslandContent) -> ActivityContent<IslandContent> {
        ActivityContent(state: Self.sanitized(content), staleDate: Date.now.addingTimeInterval(pipeline.policy.staleAfter),
                        relevanceScore: content.mode == .attention ? 100 : 50)
    }

    /// A symbol this iOS version does not have would draw as nothing: use a generic one instead.
    private static func sanitized(_ content: IslandContent) -> IslandContent {
        var content = content
        if UIImage(systemName: content.symbolName) == nil { content.symbolName = "waveform" }
        if let ambient = content.ambientSymbolName, UIImage(systemName: ambient) == nil { content.ambientSymbolName = nil }
        return content
    }

    /// Title and body are generic titles (never speech-derived). They are what an alert shows on
    /// devices that present it as a banner; on the iPhone the island expands instead.
    private func alertConfiguration(_ request: IslandAlertRequest) -> AlertConfiguration {
        AlertConfiguration(title: LocalizedStringResource(String.LocalizationValue(request.title)),
                           body: LocalizedStringResource(String.LocalizationValue(request.body)),
                           sound: settings.playsAlertSound ? .default : .named("hs-silence.wav"))
    }

    // MARK: - Diagnostics

    /// Compact state for the periodic debug export. Metadata only.
    var heartbeat: String {
        let blocked = alertsBlocked.values.reduce(0, +)
        return "island=\(content?.mode.rawValue ?? "off") lock=\(lockEstimate.rawValue) updates=\(statistics.updates) "
            + "keepAlives=\(statistics.keepAlives) icons=\(ambientStatistics.changes) alertsSent=\(alertsSent) "
            + "alertsBlocked=\(blocked) activities=\(activitiesStarted) endedBySystem=\(endedBySystem)"
    }

    /// Text for sharing test results. Contains no speech-derived text.
    func reportText() -> String {
        var lines = ["Live Activity (Dynamic Island / Lock Screen)"]
        lines.append("Status: \(status.title); showing: \(content?.redactedSummary ?? "nothing"); lock estimate: "
            + "\(lockEstimate.rawValue) (passcode \(passcodeSet.map { $0 ? "set" : "not set" } ?? "unknown"), "
            + "lock signal \(lockSignalObserved ? "observed" : "never observed"))")
        lines.append("Settings: activity \(settings.isEnabled ? "on" : "off"), ambient icons "
            + "\(settings.showsAmbientIcons ? "on" : "off"), expansion \(settings.expandsForImportantEvents ? "on" : "off"), "
            + "speech summaries \(settings.showsSpeechSummaries ? "on" : "off"), alert sound \(settings.playsAlertSound ? "on" : "off")")
        lines.append("Activities started \(activitiesStarted), ended by iOS or the user \(endedBySystem); updates "
            + "\(statistics.updates), keep-alives \(statistics.keepAlives), coalesced \(statistics.coalesced)")
        lines.append("Ambient icons: \(ambientStatistics.changes) changes from \(ambientStatistics.soundInputs) sound inputs; "
            + "held back \(ambientStatistics.heldBack), below quality \(ambientStatistics.belowQuality), "
            + "excluded \(ambientStatistics.excluded), stale \(ambientStatistics.staleEvents)")
        let blocked = AlertGate.BlockReason.allCases.compactMap { reason in
            alertsBlocked[reason].map { "\(reason.rawValue) \($0)" }
        }
        lines.append("Attention episodes shown \(statistics.attentionEpisodes); expansion requests \(statistics.alertRequests) "
            + "(rate-limited \(statistics.alertRequestsRateLimited)): sent to iOS \(alertsSent), silent instead "
            + (blocked.isEmpty ? "0" : blocked.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }
}

#if DEBUG
import AttentionReplay

// Debug aids for checking the presentation without a microphone. Release builds do not
// contain them.
extension LiveActivityController {
    /// `--hs-island-demo <name>` starts the activity after launch and plays one synthetic scene.
    static let demoArgument = "--hs-island-demo"
    /// `--hs-assume-unlocked` makes the lock estimate "unlocked" and treats "Expand for important
    /// events" as on for this launch (the Simulator has no usable lock signal, so expansion
    /// requests would otherwise never be sent there). For layout checks only.
    static let assumeUnlockedArgument = "--hs-assume-unlocked"

    static var assumesUnlocked: Bool { ProcessInfo.processInfo.arguments.contains(assumeUnlockedArgument) }

    static var requestedDemo: DemoScene? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: demoArgument) else { return nil }
        return index + 1 < arguments.count ? DemoScene(rawValue: arguments[index + 1]) ?? .ambient : .ambient
    }

    enum DemoScene: String, CaseIterable {
        case idle, ambient, knock, siren, speech

        var title: String {
            switch self {
            case .idle: "Listening only"
            case .ambient: "Ordinary sounds (rain, dog, bird)"
            case .knock: "Rain, then a door knock"
            case .siren: "Music, then a siren"
            case .speech: "Rain, then a spoken reminder"
            }
        }

        /// Synthetic events (`synthetic.replay`); the same builders the Window 4 scenes use.
        var scenario: AttentionScenario {
            var scene = ScenarioBuilder(id: "island-demo-\(rawValue)", title: title, summary: "Live Activity demo.")
            switch self {
            case .idle:
                break
            case .ambient:
                scene.sound("rain", at: 2, duration: 40, label: .ambient, confirmDelay: 0, endAfter: 3)
                scene.sound("dog", at: 9, duration: 5, label: .optional, confirmDelay: 0, endAfter: 2)
                scene.sound("bird", at: 24, duration: 6, label: .ambient, confirmDelay: 0, endAfter: 2)
            case .knock:
                scene.sound("rain", at: 2, duration: 40, label: .ambient, confirmDelay: 0, endAfter: 3)
                scene.sound("door", at: 9, duration: 1, label: .important, confirmDelay: 0, endAfter: 2)
            case .siren:
                scene.sound("music", at: 2, duration: 40, label: .irrelevant, confirmDelay: 0, endAfter: 3)
                scene.sound("siren", at: 9, duration: 15, label: .important, confirmDelay: 0, endAfter: 3)
            case .speech:
                scene.sound("rain", at: 2, duration: 40, label: .ambient, confirmDelay: 0, endAfter: 3)
                scene.speech(at: 7, label: .optional, name: "Reminder") { speech in
                    speech.final("we have a biology test tomorrow", at: 10)
                    speech.summary("Biology Test Tomorrow", at: 12, category: .reminder, timeOrNumber: "tomorrow")
                    speech.completed(at: 24)
                }
            }
            return scene.build()
        }
    }

    /// Starts the activity without a listening session and plays a synthetic scene into the
    /// attention engine (whose injected sounds and intents arrive here like real ones). The
    /// microphone stays off. A background task keeps the app running for a short while after it
    /// leaves the screen, which is when the island shows the activity.
    func runDemo(_ scene: DemoScene, attention: AttentionController) {
        stopDemo(attention: attention)
        isDemoRunning = true
        log(.lifecycle, "Live Activity demo “\(scene.title)” (synthetic events, microphone off)")
        demoBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "island-demo") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.demoBackgroundTask)
            self.demoBackgroundTask = .invalid
        }
        process(.sessionStarted(at: .now))
        attention.inject(scene.scenario)
        demoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(scene.scenario.duration + 8))
            guard !Task.isCancelled, let self else { return }
            self.stopDemo(attention: attention)
        }
    }

    func stopDemo(attention: AttentionController) {
        guard isDemoRunning else { return }
        demoTask?.cancel()
        demoTask = nil
        attention.stopInjection()
        isDemoRunning = false
        process(.sessionEnded(at: .now))
        if demoBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(demoBackgroundTask)
            demoBackgroundTask = .invalid
        }
    }
}
#endif
