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
/// - An alert configuration (the only way to ask iOS to present an update prominently) is attached
///   only for a verified highest-priority acoustic event, or for a summary the user asked for,
///   and only when `AlertGate` lets it through: "Prominent alerts" is on (the default) and the
///   iPhone is judged unlocked. The lock state is an estimate (see `DeviceLockEstimate`), so
///   "locked" and "cannot tell" both mean a silent update — unless the user opted in to
///   "Also when the iPhone is locked" (off by default), which applies to acoustic events only.
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
        /// iOS ended the activity at its limit of about eight hours. Listening goes on; the app
        /// requests no activity in its place for this session.
        case endedAtLimit
        /// Live Activities are turned off for this app in Settings.
        case notAllowed
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Not running"
            case .running: "Running"
            case .waitingForForeground: "Open the app to show it again"
            case .endedAtLimit: "Ended by iOS after about eight hours; still listening. Turn Hearing Sense off and on to show it again"
            case .notAllowed: "Live Activities are off in Settings"
            case .failed(let message): "Failed: \(message)"
            }
        }
    }

    private static let settingsKey = "island.settings.v2"
    /// Where builds before the decision of 2026-10-11 stored the settings ("Prominent alerts"
    /// was off by default then). Read once, see `IslandSettings.migrated(fromVersion1:)`.
    private static let legacySettingsKey = "island.settings.v1"
    /// Set once protected data was seen to become unavailable on this installation.
    private static let lockSignalKey = "island.lockSignalObserved.v1"
    /// One line about the carry-over from `island.settings.v1`, for the diagnostics report.
    private static let migrationNoteKey = "island.settings.migrationNote"

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
    /// When the activity was requested. iOS ends a Live Activity after about eight hours; the
    /// app neither replaces a running activity nor requests a new one after that limit
    /// (decision of 2026-10-11). A new listening session gets a new activity.
    private(set) var activityStartedAt: Date?
    /// The activity of this session was ended by iOS at its limit.
    private(set) var reachedSystemLimit = false
    @ObservationIgnored private let lifetime = ActivityLifetimePolicy.standard
    private(set) var isDemoRunning = false
    /// Every update handed to ActivityKit in this launch (bounded), for measuring the real update
    /// rate on a device. Metadata only: `summary` is `IslandContent.redactedSummary`.
    private(set) var updateLog: [UpdateRecord] = []

    struct UpdateRecord: Equatable {
        var date: Date
        var summary: String
        var requestedExpansion: Bool
        /// How long `Activity.update` took to return.
        var milliseconds: Double
    }

    static let updateLogCapacity = 400

    @ObservationIgnored private var pipeline: IslandPipeline
    @ObservationIgnored private var activity: Activity<HearingSenseActivityAttributes>?
    @ObservationIgnored private var needsStart = false
    @ObservationIgnored private var passcodeSet: Bool?
    @ObservationIgnored private var lockSignalObserved: Bool
    @ObservationIgnored private var protectedDataTask: Task<Void, Never>?
    @ObservationIgnored private var protectedDataAvailableTask: Task<Void, Never>?
    /// When the "protected data will become unavailable" notice last arrived without an
    /// "available" notice (or the app coming to the front) since. While set, the estimate is `locked`.
    @ObservationIgnored private var willLockNoticeAt: Date?
    /// The lock state the pipeline was last told (it takes speech-derived text out while locked).
    @ObservationIgnored private var pipelineKnowsLocked = false
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
        /// Every job queued before this one has been carried out.
        case barrier(CheckedContinuation<Void, Never>)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var stored = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(IslandSettings.self, from: $0) }
        if stored == nil, let legacy = defaults.data(forKey: Self.legacySettingsKey) {
            // Carried over once, every stored value kept: a stored "Prominent alerts: off" stays off.
            let migrated = IslandSettings.migrated(fromVersion1: legacy)
            if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: Self.settingsKey) }
            defaults.set("\(Date.now.formatted(.iso8601)): settings of the earlier build carried over, every stored value kept "
                + "(prominent alerts \(migrated.expandsForImportantEvents ? "on" : "off"), ambient icons "
                + "\(migrated.showsAmbientIcons ? "on" : "off"), alert sound \(migrated.playsAlertSound ? "on" : "off")); "
                + "“while locked” starts off", forKey: Self.migrationNoteKey)
            stored = migrated
        }
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
        protectedDataAvailableTask = Task { [weak self] in
            let name = UIApplication.protectedDataDidBecomeAvailableNotification
            for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                self?.protectedDataBecameAvailable()
            }
        }
        refreshLockEstimate(checkPasscode: true)
        jobs.yield(.cleanUp)
    }

    private func protectedDataBecameUnavailable() {
        if !lockSignalObserved {
            lockSignalObserved = true
            defaults.set(true, forKey: Self.lockSignalKey)
        }
        willLockNoticeAt = .now
        // Measured on the iPhone 18 Pro: how long before the data is actually unavailable this arrives.
        log(.lifecycle, "Lock signal: protected data will become unavailable (data available right now: "
            + "\(UIApplication.shared.isProtectedDataAvailable))")
        lockEstimate = .locked
        syncLockWithPipeline()
    }

    private func protectedDataBecameAvailable() {
        willLockNoticeAt = nil
        log(.lifecycle, "Lock signal: protected data became available")
        refreshLockEstimate(checkPasscode: false)
        syncLockWithPipeline()
    }

    /// Tells the pipeline when the lock estimate changes between "locked" and anything else, so
    /// that speech-derived text leaves the activity's content while the iPhone is locked (one
    /// silent update, and only if such text is there). Never called from inside `process`'s
    /// command loop: `process` calls it at its end.
    private func syncLockWithPipeline() {
        let isLocked = lockEstimate == .locked
        guard isLocked != pipelineKnowsLocked else { return }
        pipelineKnowsLocked = isLocked
        process(.deviceLock(isLocked: isLocked, at: .now))
    }

    deinit {
        deadlineTask?.cancel()
        stateTask?.cancel()
        worker?.cancel()
        jobs.finish()
        protectedDataTask?.cancel()
        protectedDataAvailableTask?.cancel()
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

    /// Window 7: where a summary the user asked for stands (nil: ordinary listening). It decides
    /// which controls the expanded Dynamic Island offers.
    func receive(conversation state: IslandConversation?) {
        process(.conversation(state, at: .now))
    }

    /// Window 7: the acoustic scene in generic words; secondary text of the expanded presentation.
    func receive(sceneTitle: String?) {
        process(.scene(sceneTitle, at: .now))
    }

    /// The user switched transcription off or deleted the speech data: no speech-derived text
    /// stays in the activity, whether or not a speech episode is presented right now.
    func speechDataCleared() {
        process(.speechTextCleared(at: .now))
    }

    func appBecameActive() {
        // On screen means unlocked: a lock notice without its "available" counterpart is over.
        willLockNoticeAt = nil
        refreshLockEstimate(checkPasscode: true)
        syncLockWithPipeline()
        // An activity can only be requested while the app is on screen. A session whose activity
        // could not be started, or was removed before its time, shows one again when the user
        // opens the app. A running activity is never replaced, and after the system's limit
        // nothing is requested for this session.
        if lifetime.decide(sessionIsLive: pipeline.isLive, hasActivity: activity != nil, reachedLimit: reachedSystemLimit,
                           appIsActive: true) == .start
        {
            jobs.yield(.start)
        }
    }

    // MARK: - Settings

    func update(_ change: (inout IslandSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        let switches: [(String, KeyPath<IslandSettings, Bool>)] = [
            ("Show in the Dynamic Island", \.isEnabled), ("Icons for ordinary sounds", \.showsAmbientIcons),
            ("Prominent alerts", \.expandsForImportantEvents), ("Prominent alerts while locked", \.alertsWhileLocked),
            ("Show speech summaries", \.showsSpeechSummaries),
            ("Play the alert sound", \.playsAlertSound), ("Show the summary when it is ready", \.expandsForSummaries),
        ]
        for (name, keyPath) in switches where settings[keyPath: keyPath] != updated[keyPath: keyPath] {
            SettingsAudit.record(name, from: settings[keyPath: keyPath], to: updated[keyPath: keyPath], defaults: defaults)
        }
        settings = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: Self.settingsKey) }
        log(.lifecycle, "Live Activity settings: activity \(updated.isEnabled ? "on" : "off"), ambient icons "
            + "\(updated.showsAmbientIcons ? "on" : "off"), prominent alerts \(updated.expandsForImportantEvents ? "on" : "off") "
            + "(while locked: \(updated.alertsWhileLocked ? "on" : "off")), speech summaries \(updated.showsSpeechSummaries ? "on" : "off"), alert sound \(updated.playsAlertSound ? "on" : "off")")
        process(.settings(updated, at: .now))
    }

    /// Whether the Live Activity of the open session exists, after every queued ActivityKit job
    /// was carried out. An App Intent that switches listening on awaits this before it returns:
    /// `AudioRecordingIntent` requires a Live Activity for as long as the audio session is
    /// active, and App Intents ends the process ("AudioRecordingIntent was performed with an
    /// active audio session but without a Live Activity") when `perform()` returns without one.
    /// The start itself is a queued job, so without the wait the intent returned first.
    ///
    /// The request is the user's (they pressed the Action Button): an activity that iOS ended
    /// earlier is requested again here.
    func ensureRunning() async -> Bool {
        if pipeline.isLive, activity == nil {
            needsStart = true
            reachedSystemLimit = false
            jobs.yield(.start)
        }
        await withCheckedContinuation { jobs.yield(.barrier($0)) }
        return activity != nil
    }

    // MARK: - Pipeline

    private func process(_ input: IslandInput) {
        for command in pipeline.process(input) {
            switch command {
            case .start:
                needsStart = true
                reachedSystemLimit = false
                jobs.yield(.start)
            case .update(let content, let alert):
                jobs.yield(.update(content, alert.flatMap(gate)))
            case .end:
                needsStart = false
                reachedSystemLimit = false
                jobs.yield(.end)
            }
        }
        content = pipeline.isLive ? pipeline.shown : nil
        statistics = pipeline.statistics
        ambientStatistics = pipeline.ambientStatistics
        scheduleDeadline()
        // `gate` may have refreshed the estimate while the commands were carried out.
        syncLockWithPipeline()
    }

    /// Lets a request for a prominent presentation through only when the iPhone is judged
    /// unlocked, or when the user opted in to alerts on the locked iPhone.
    private func gate(_ request: IslandAlertRequest) -> IslandAlertRequest? {
        refreshLockEstimate(checkPasscode: false)
        let isActive = UIApplication.shared.applicationState == .active
        var effective = settings
        #if DEBUG
        if Self.assumesUnlocked { effective.expandsForImportantEvents = true }
        #endif
        switch AlertGate.evaluate(settings: effective, lock: lockEstimate, appIsActive: isActive,
                                  isUserRequested: request.isUserRequested) {
        case .send:
            alertsSent += 1
            log(.recognition, "Live Activity: prominent presentation requested for “\(request.title)” [\(request.priority)]"
                + (lockEstimate == .unlocked ? "" : " (lock estimate \(lockEstimate.rawValue), allowed by the user's opt-in)"))
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
                                                   lockSignalObserved: lockSignalObserved,
                                                   lockNoticePending: willLockNoticeAt != nil)
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
        case .barrier(let continuation):
            continuation.resume()
        case .cleanUp:
            await endLeftovers()
        case .start:
            await startActivity()
        case .update(let content, let alert):
            // `Activity` is not declared Sendable, but its async methods are made to be awaited
            // from any context; this controller is the only one that holds the activity.
            guard let held = activity else { return }
            nonisolated(unsafe) let activity = held
            let sent = Date.now
            let started = ContinuousClock.now
            await activity.update(activityContent(content), alertConfiguration: alert.map(alertConfiguration))
            let elapsed = (ContinuousClock.now - started).components
            updateLog.append(UpdateRecord(date: sent, summary: content.redactedSummary, requestedExpansion: alert != nil,
                                          milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15))
            if updateLog.count > Self.updateLogCapacity { updateLog.removeFirst(updateLog.count - Self.updateLogCapacity) }
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
        guard pipeline.isLive, activity == nil, !reachedSystemLimit, let content = pipeline.shown else { return }
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
    /// and the user can remove it. Listening is not affected by either.
    /// - Ended at the limit: nothing is requested in its place for this session.
    /// - Removed earlier: it is shown again when the user opens the app (`appBecameActive`).
    private func observe(_ observed: Activity<HearingSenseActivityAttributes>) {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in observed.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                guard state == .ended || state == .dismissed, self.activity?.id == observed.id else { continue }
                let atLimit = self.activityStartedAt.map { self.lifetime.endedAtLimit(startedAt: $0, endedAt: .now) } ?? false
                self.activity = nil
                self.activityStartedAt = nil
                guard self.pipeline.isLive else { continue }
                self.endedBySystem += 1
                if atLimit {
                    self.reachedSystemLimit = true
                    self.needsStart = false
                    self.status = .endedAtLimit
                    self.log(.lifecycle, "Live Activity ended at the system's limit (\(state)); listening continues, and no "
                        + "activity is requested in its place")
                } else {
                    self.needsStart = true
                    self.status = .waitingForForeground
                    self.log(.lifecycle, "Live Activity was ended by iOS or the user (\(state)); listening continues, "
                        + "and the activity is shown again when the app is opened")
                }
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
        // The app's own drawings (`CustomSoundGlyph`) are not SF Symbols and need no check.
        func exists(_ name: String) -> Bool { CustomSoundGlyph(symbolName: name) != nil || UIImage(systemName: name) != nil }
        if !exists(content.symbolName) { content.symbolName = "waveform" }
        if let ambient = content.ambientSymbolName, !exists(ambient) { content.ambientSymbolName = nil }
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
        let live = DeviceLockEstimate.estimate(passcodeSet: passcodeSet,
                                               protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                                               lockSignalObserved: lockSignalObserved,
                                               lockNoticePending: willLockNoticeAt != nil)
        return "island=\(content?.mode.rawValue ?? "off") lock=\(live.rawValue) willLockNotice=\(willLockNoticeAt != nil) updates=\(statistics.updates) "
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
            + "\(settings.showsAmbientIcons ? "on" : "off"), prominent alerts \(settings.expandsForImportantEvents ? "on" : "off") "
            + "(while locked: \(settings.alertsWhileLocked ? "on" : "off")), speech summaries \(settings.showsSpeechSummaries ? "on" : "off"), alert sound \(settings.playsAlertSound ? "on" : "off")")
        lines.append("Settings storage: " + (defaults.string(forKey: Self.migrationNoteKey)
                ?? (defaults.data(forKey: Self.settingsKey) == nil ? "nothing stored (defaults in use)" : "stored by this build's format")))
        if let activityStartedAt {
            lines.append("Activity started \(activityStartedAt.formatted(.iso8601)); iOS ends it at about "
                + lifetime.expectedEnd(startedAt: activityStartedAt).formatted(.iso8601) + " (it is not replaced)")
        }
        lines.append("Activities started \(activitiesStarted), ended by iOS or the user \(endedBySystem)"
            + (reachedSystemLimit ? " (at the system's limit)" : "") + "; updates "
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
        lines.append("Secondary-only changes not sent: \(statistics.secondaryChangesNotSent)")
        lines.append("Requested summaries: states shown \(statistics.conversationStates), expansion requests when ready "
            + "\(statistics.summaryReadyRequests); speech episodes that asked for no expansion: \(statistics.speechAlertsWithheld)")
        lines.append("Speech summaries presented \(statistics.summariesPresented) (without an expansion request: "
            + "\(statistics.summariesWithoutExpansion)); speech episodes without a summary kept as an icon: "
            + "\(statistics.speechWithoutSummary); speech text withheld right now because locked: \(pipelineKnowsLocked ? "yes" : "no")")
        if let first = updateLog.first, let last = updateLog.last {
            let span = last.date.timeIntervalSince(first.date)
            let gaps = zip(updateLog.dropFirst(), updateLog).map { $0.date.timeIntervalSince($1.date) }
            let rate = span > 0 ? Double(updateLog.count - 1) / span * 3600 : 0
            let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
            lines.append("Updates handed to ActivityKit: \(updateLog.count) in \(span.formatted(style)) s"
                + " (\(rate.formatted(style)) per hour over that span); shortest gap "
                + "\((gaps.min() ?? 0).formatted(style)) s; update call mean "
                + "\((updateLog.map(\.milliseconds).reduce(0, +) / Double(updateLog.count)).formatted(style)) ms, max "
                + "\((updateLog.map(\.milliseconds).max() ?? 0).formatted(style)) ms")
            lines.append("Update log (oldest first; speech-derived text omitted):")
            for record in updateLog.suffix(150) {
                lines.append("  \(record.date.formatted(.iso8601.time(includingFractionalSeconds: true))) "
                    + "\(record.milliseconds.formatted(style)) ms  \(record.summary)" + (record.requestedExpansion ? "  [expansion requested]" : ""))
            }
        }
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

    /// `--hs-demo-key-at <seconds>`: when the scene's main event happens (default 9 s).
    static let demoKeyAtArgument = "--hs-demo-key-at"
    /// `--hs-demo-after-background`: the scene starts when the app leaves the screen (Home, another
    /// app, or the lock button) instead of at launch. Without a listening session iOS suspends the
    /// app about 30 s after that, so device checks of the locked screen time their event from the
    /// moment of locking: "lock the iPhone, the knock comes N seconds later".
    static let demoAfterBackgroundArgument = "--hs-demo-after-background"

    static var requestedDemo: DemoScene? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: demoArgument) else { return nil }
        return index + 1 < arguments.count ? DemoScene(rawValue: arguments[index + 1]) ?? .ambient : .ambient
    }

    static var requestedDemoKeyTime: TimeInterval {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: demoKeyAtArgument), index + 1 < arguments.count,
              let value = TimeInterval(arguments[index + 1]) else { return 9 }
        return max(value, 0.5)
    }

    static var demoStartsAfterBackground: Bool {
        ProcessInfo.processInfo.arguments.contains(demoAfterBackgroundArgument)
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
        /// An ordinary sound starts within a second; the scene's main event happens at `keyAt`.
        func scenario(keyAt: TimeInterval = 9) -> AttentionScenario {
            var scene = ScenarioBuilder(id: "island-demo-\(rawValue)", title: title, summary: "Live Activity demo.")
            let lead = min(1, keyAt / 2)
            switch self {
            case .idle:
                break
            case .ambient:
                scene.sound("rain", at: lead, duration: keyAt + 31, label: .ambient, confirmDelay: 0, endAfter: 3)
                scene.sound("dog", at: keyAt, duration: 5, label: .optional, confirmDelay: 0, endAfter: 2)
                scene.sound("bird", at: keyAt + 15, duration: 6, label: .ambient, confirmDelay: 0, endAfter: 2)
            case .knock:
                scene.sound("rain", at: lead, duration: keyAt + 31, label: .ambient, confirmDelay: 0, endAfter: 3)
                scene.sound("door", at: keyAt, duration: 1, label: .important, confirmDelay: 0, endAfter: 2)
            case .siren:
                scene.sound("music", at: lead, duration: keyAt + 31, label: .irrelevant, confirmDelay: 0, endAfter: 3)
                scene.sound("siren", at: keyAt, duration: 15, label: .important, confirmDelay: 0, endAfter: 3)
            case .speech:
                scene.sound("rain", at: lead, duration: keyAt + 31, label: .ambient, confirmDelay: 0, endAfter: 3)
                scene.speech(at: max(keyAt - 5, lead), label: .optional, name: "Reminder") { speech in
                    speech.final("we have a biology test tomorrow", at: max(keyAt - 2, lead + 0.5))
                    speech.summary("Biology Test Tomorrow", at: keyAt, category: .reminder, timeOrNumber: "tomorrow")
                    speech.completed(at: keyAt + 12)
                }
            }
            return scene.build()
        }
    }

    /// Starts the activity without a listening session and plays a synthetic scene into the
    /// attention engine (whose injected sounds and intents arrive here like real ones). The
    /// microphone stays off. A background task keeps the app running for a short while after it
    /// leaves the screen, which is when the island shows the activity.
    func runDemo(_ scene: DemoScene, attention: AttentionController, keyAt: TimeInterval = 9,
                 afterBackground: Bool = false)
    {
        stopDemo(attention: attention)
        isDemoRunning = true
        let scenario = scene.scenario(keyAt: keyAt)
        log(.lifecycle, "Live Activity demo “\(scene.title)” (synthetic events, microphone off; main event at "
            + "\(keyAt.formatted()) s" + (afterBackground ? " after the app leaves the screen)" : ")"))
        demoBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "island-demo") { [weak self] in
            guard let self else { return }
            self.log(.lifecycle, "Live Activity demo: background time is over; iOS suspends the app now")
            UIApplication.shared.endBackgroundTask(self.demoBackgroundTask)
            self.demoBackgroundTask = .invalid
        }
        process(.sessionStarted(at: .now))
        demoTask = Task { [weak self] in
            if afterBackground {
                let entered = NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification)
                    .map { _ in () }
                for await _ in entered { break }
                guard !Task.isCancelled, let self else { return }
                self.log(.lifecycle, "Live Activity demo: app left the screen, scene starts")
            }
            guard !Task.isCancelled else { return }
            attention.inject(scenario)
            try? await Task.sleep(for: .seconds(scenario.duration + 8))
            guard !Task.isCancelled, let self else { return }
            self.stopDemo(attention: attention)
        }
    }

    /// Ends every activity of this app that this controller does not hold (the emergency stop of
    /// the device test mode: what an earlier process left on the island goes as well).
    /// `--hs-island-conversation summarizing|ready|ready-short|ready-long|ready-longtitle|following|notice`: a sample conversation state for layout checks of the
    /// expanded island (synthetic text; nothing was said and nothing is summarized).
    static var requestedConversationSample: IslandConversation? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--hs-island-conversation"), index + 1 < arguments.count else { return nil }
        // Each sample is a full summary; the island's preview is made from it as in the product.
        func summary(_ phase: IslandConversation.Phase, title: String, text: String, points: [String]) -> IslandConversation {
            IslandConversation(phase: phase, title: phase == .following ? "Following Conversation" : "Summary Ready",
                               detail: IslandSummaryPreview.body(summary: text, keyPoints: points, newestFirst: phase == .following,
                                                                 fits: ConversationIntelligenceController.fitsIslandPreview),
                               // With `--hs-sample-history`: the first sample summary, so that "Open" can be followed.
                               recordID: arguments.contains("--hs-sample-history")
                                   ? UUID(uuidString: "00000000-0000-0000-0000-000000000001") : nil,
                               since: .now)
        }
        let medium = "Maya and Jon agreed to meet for lunch on Friday at 12:30 at the noodle place on Fifth Street. "
            + "Jon will book a table for four and Maya brings the signed forms for the science fair."
        let long = "The group report is due next Thursday and the group meets on Saturday at ten in study room 204 of the science "
            + "building, because the library is closed on weekends. The graphs have to be finished by Friday night so that the "
            + "report can be written on Saturday. The exam was postponed until the Friday after, and the teacher will send the "
            + "new room by email. Nobody has booked the projector yet."
        switch arguments[index + 1] {
        case "summarizing": return IslandConversation(phase: .summarizing, title: "Summarizing", since: .now)
        case "ready", "ready-medium":
            return summary(.summaryReady, title: "Lunch on Friday", text: medium,
                           points: ["Lunch is on Friday at 12:30 at the noodle place on Fifth Street.", "Jon books a table for four."])
        case "ready-short":
            return summary(.summaryReady, title: "Bus change", text: "The 14 bus leaves from the north stop this week.", points: [])
        case "ready-long":
            return summary(.summaryReady, title: "Group report", text: long,
                           points: ["The group meets on Saturday at ten in study room 204 of the science building.",
                                    "The graphs have to be finished by Friday night.", "The exam was postponed until the Friday after."])
        case "ready-longtitle":
            return summary(.summaryReady, title: "Meeting with Ms. Wang about the science fair schedule",
                           text: "The meeting with Ms. Wang is tomorrow at 3 p.m. in room 204. The poster has to be printed before it.",
                           points: [])
        case "following":
            return summary(.following, title: "Lunch on Friday", text: medium,
                           points: ["Lunch is on Friday at 12:30 at the noodle place on Fifth Street.", "Jon books a table for four."])
        case "notice": return IslandConversation(phase: .notice, title: "Nothing to Summarize",
                                                 message: "Open Hearing Sense for details.", since: .now)
        default: return nil
        }
    }

    func endLeftoverActivities() {
        Task { await endLeftovers() }
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
