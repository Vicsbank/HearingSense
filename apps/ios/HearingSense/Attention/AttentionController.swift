import Attention
import AttentionReplay
import HearingSenseAudio
import HearingSenseDomain
import Observation
import SwiftUI

/// Runs the Attention Priority Engine (Window 4) for the app: feeds it the confirmed sound
/// events and speech results the existing pipelines already produce, keeps the user's attention
/// preferences, and publishes what the engine decided.
///
/// Main-actor isolated (app default) and owned by `ListeningController`, not by a view, so it
/// keeps working while the app is in the background. Event-driven: the engine runs when an input
/// arrives and once at its own next deadline (one pending timer at most); nothing polls. A
/// decision takes microseconds and no audio callback ever reaches this type.
///
/// It presents nothing outside the app: `onIntent` is the hand-over point for Window 5
/// (`LiveActivityController`: Live Activity / Dynamic Island). No notification is sent here.
///
/// Privacy: preferences are the only thing stored (`UserDefaults`, JSON). The decision log is in
/// memory, bounded, and holds metadata only — speech-derived text is removed before a decision is
/// logged, and `reportText()` never contains any.
@Observable
final class AttentionController {
    static let logCapacity = 200
    private static let preferencesKey = "attention.preferences.v1"

    private(set) var preferences: AttentionPreferences
    /// Episodes the engine wants shown, most important first.
    private(set) var presented: [AttentionEvent] = []
    /// Episodes that are followed but not shown (suppressed, deferred, timed out).
    private(set) var tracked: [AttentionEvent] = []
    private(set) var deferred: [AttentionEventID] = []
    private(set) var cooldowns: [AttentionCooldown] = []
    private(set) var budgetUsed = 0
    private(set) var budgetLimit = 0
    private(set) var statistics = AttentionStatistics()
    /// Recent decisions, newest first, without speech-derived text.
    private(set) var decisions: [AttentionDecision] = []
    private(set) var isSessionActive = false
    private(set) var isInjecting = false
    /// Wall-clock time of the engine per input (this device).
    private(set) var processing = ProcessingTime()

    /// Window 5 attaches here. Called on the main actor for every presentation change.
    @ObservationIgnored var onIntent: ((AttentionPresentationIntent) -> Void)?
    /// Synthetic sound events of the debug injection, for consumers that normally get sound events
    /// from the recognition pipeline (Window 5's ambient icons). Never called for real events.
    @ObservationIgnored var onInjectedSound: ((AcousticEventUpdate) -> Void)?

    @ObservationIgnored private var engine: AttentionEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var injectionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var log: (DiagnosticEventLog.Kind, String) -> Void = { _, _ in }
    @ObservationIgnored private let clock = ContinuousClock()

    struct ProcessingTime: Equatable {
        var inputs = 0
        var totalMicroseconds = 0.0
        var maximumMicroseconds = 0.0
        var meanMicroseconds: Double { inputs > 0 ? totalMicroseconds / Double(inputs) : 0 }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(AttentionPreferences.self, from: $0) }
        preferences = stored ?? .default
        engine = AttentionEngine(preferences: stored ?? .default)
        refresh()
    }

    deinit {
        deadlineTask?.cancel()
        for task in injectionTasks.values { task.cancel() }
    }

    /// Where engine messages go (the app's diagnostic log). Metadata only.
    func setLogger(_ logger: @escaping (DiagnosticEventLog.Kind, String) -> Void) {
        log = logger
    }

    // MARK: - Inputs from the pipelines (called by ListeningController's wiring)

    func sessionWillStart() {
        isSessionActive = true
        process(.sessionStarted(at: .now))
    }

    /// Capture stopped (user, interruption or failure): nothing stays presented.
    func sessionDidEnd() {
        guard isSessionActive else { return }
        isSessionActive = false
        process(.sessionEnded(at: .now))
        log(.recognition, "Attention session ended: \(statistics.count(.show)) shown, \(statistics.count(.update)) updated, "
            + "\(statistics.count(.suppress)) suppressed, \(statistics.count(.defer)) deferred")
    }

    /// Pipeline outputs that arrive after the session ended (the engines finish asynchronously)
    /// are dropped, so nothing appears after Stop.
    func receive(_ update: AcousticEventUpdate) {
        guard isSessionActive else { return }
        process(.sound(update))
    }

    func receive(_ result: SpeechSemanticResult) {
        guard isSessionActive else { return }
        process(.speech(result))
    }

    /// The speech pipeline discarded its events (transcription switched off).
    func speechDataCleared() {
        process(.speechDataCleared(at: .now))
    }

    // MARK: - Preferences

    func setMode(_ mode: AttentionMode) {
        guard mode != preferences.mode else { return }
        var updated = preferences
        updated.mode = mode
        apply(updated, note: "Attention mode: \(mode.displayName)")
    }

    func setSetting(_ setting: CategorySetting, for category: AttentionCategory) {
        guard setting != preferences.setting(for: category) else { return }
        var updated = preferences
        updated.set(setting, for: category)
        apply(updated, note: "Attention category \(category.rawValue): \(setting.rawValue)")
    }

    func setSpeechAttention(_ speech: SpeechAttention) {
        guard speech != preferences.speech else { return }
        var updated = preferences
        updated.speech = speech
        apply(updated, note: "Speech attention: \(speech.rawValue)")
    }

    func restoreDefaults() {
        guard !preferences.isDefault else { return }
        apply(.default, note: "Attention settings restored to defaults")
    }

    private func apply(_ updated: AttentionPreferences, note: String) {
        preferences = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: Self.preferencesKey) }
        log(.recognition, note)
        process(.preferences(updated, at: .now))
    }

    // MARK: - Engine

    private func process(_ input: AttentionInput) {
        var produced: [AttentionDecision] = []
        let elapsed = clock.measure { produced = engine.process(input) }
        let microseconds = Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12
        processing.inputs += 1
        processing.totalMicroseconds += microseconds
        processing.maximumMicroseconds = max(processing.maximumMicroseconds, microseconds)

        for decision in produced {
            if let intent = decision.intent { onIntent?(intent) }
            record(decision)
        }
        refresh()
        scheduleDeadline()
    }

    private func record(_ decision: AttentionDecision) {
        // Metadata only from here on.
        var redacted = decision
        redacted.event.privateContent = nil
        redacted.intent?.privateDetail = nil
        decisions.insert(redacted, at: 0)
        if decisions.count > Self.logCapacity { decisions.removeLast(decisions.count - Self.logCapacity) }
        switch decision.action {
        case .show, .update, .resolve, .expire:
            if decision.intent != nil { log(.recognition, "Attention \(decision.summary)") }
        case .suppress, .defer:
            break
        }
    }

    private func refresh() {
        let snapshot = engine.snapshot
        presented = snapshot.presented
        tracked = snapshot.tracked
        deferred = snapshot.deferred
        cooldowns = snapshot.cooldowns
        budgetUsed = snapshot.budgetUsed
        budgetLimit = snapshot.budgetLimit
        statistics = snapshot.statistics
    }

    /// One timer for the engine's next deadline (an expiration, a deferred presentation, a stale
    /// source). Replaced whenever an input changes the deadline.
    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let deadline = engine.nextDeadline else {
            deadlineTask = nil
            return
        }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled, let self else { return }
            self.process(.tick(at: max(.now, deadline)))
        }
    }

    func clearDecisionLog() {
        decisions.removeAll()
    }

    // MARK: - Synthetic injection (debug screen; no microphone involved)

    /// Plays a scripted scene into the running engine in real time. The events are synthetic
    /// (`synthetic.replay`) and go through exactly the path real events take.
    func inject(_ scenario: AttentionScenario) {
        let inputs = scenario.playback(startingAt: .now)
        let id = UUID()
        isInjecting = true
        log(.recognition, "Attention debug: injecting synthetic scene “\(scenario.title)” (\(inputs.count) inputs)")
        // Several scenes can play at once (a knock, then speech a moment later).
        injectionTasks[id] = Task { [weak self] in
            let start = ContinuousClock.now
            for item in inputs {
                try? await Task.sleep(until: start + .seconds(item.offset), clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                if case .sound(let update) = item.input { self.onInjectedSound?(update) }
                self.process(item.input)
            }
            guard let self else { return }
            self.injectionTasks[id] = nil
            self.isInjecting = !self.injectionTasks.isEmpty
        }
    }

    func stopInjection() {
        for task in injectionTasks.values { task.cancel() }
        injectionTasks.removeAll()
        isInjecting = false
    }

    // MARK: - Diagnostics

    /// Compact state for the periodic debug export. Metadata only.
    var heartbeat: String {
        "attention=\(preferences.mode.rawValue) shown=\(statistics.count(.show)) updated=\(statistics.count(.update)) "
            + "suppressed=\(statistics.count(.suppress)) deferred=\(statistics.count(.defer)) "
            + "presented=\(presented.count) tracked=\(tracked.count) fusions=\(statistics.fusions)"
    }

    /// Text for sharing test results: settings, counters, state and recent decisions. Contains no
    /// audio, no transcript and no summary text (titles are generic labels).
    func reportText() -> String {
        let fraction = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        let categories: String = preferences.categories.isEmpty ? "all automatic"
            : preferences.categories.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value.rawValue)" }.joined(separator: ", ")
        let counts: String = AttentionAction.allCases.map { "\($0.rawValue) \(statistics.count($0))" }
            .joined(separator: ", ")
        var lines: [String] = ["Attention priority engine"]
        lines.append("Mode: \(preferences.mode.displayName) · speech attention \(preferences.speech.rawValue) · "
            + "category settings: \(categories)")
        lines.append("Inputs \(statistics.inputs) (sound \(statistics.soundInputs), speech \(statistics.speechInputs), "
            + "speech progress ignored \(statistics.speechProgressIgnored))")
        lines.append("Decisions: \(counts)")
        lines.append("Episodes created \(statistics.episodesCreated), fusions \(statistics.fusions), "
            + "rejoins \(statistics.rejoins), escalations \(statistics.escalations), "
            + "stale sources \(statistics.staleSources), evictions \(statistics.evictions)")
        lines.append("State: \(presented.count) presented, \(tracked.count) tracked, \(deferred.count) deferred; "
            + "maximum episodes \(statistics.maximumEpisodes), maximum deferred \(statistics.maximumDeferred); "
            + "budget \(budgetUsed)/\(budgetLimit)")
        lines.append("Decision time per input: mean \(processing.meanMicroseconds.formatted(fraction)) µs, "
            + "max \(processing.maximumMicroseconds.formatted(fraction)) µs over \(processing.inputs) inputs")
        lines.append("")
        lines.append("Recent decisions (newest first; speech-derived text omitted):")
        for decision in decisions.prefix(80) {
            let time = decision.decidedAt.formatted(.iso8601.time(includingFractionalSeconds: true))
            let intent = decision.intent.map { " → \($0.action.rawValue)/\($0.interruption.rawValue)" } ?? ""
            lines.append("\(time) \(decision.summary)\(intent)")
        }
        return lines.joined(separator: "\n")
    }
}
