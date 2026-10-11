import Attention
import ConversationUnderstanding
import HearingSenseAudio
import HearingSenseDomain
import Observation
import SemanticAttention
import SwiftUI

/// Window 6 in the app: semantic attention goals, the two-minute recap behind the Action Button,
/// continued understanding with live captions, and the saved history.
///
/// Main-actor isolated (app default) and owned by `ListeningController`, so it keeps working in
/// the background. It adds no microphone path: it reads the finalized utterances the Window 3
/// speech pipeline already produces.
///
/// Two separate opt-ins, both off until the user turns them on, and both require "Transcribe
/// nearby speech" (Window 3):
/// - *Semantic attention*: finalized utterances are compared with the user's goals by the
///   on-device language model. Nothing is kept beyond a short list of recent matches in memory.
/// - *Keep recent speech for recaps*: finalized utterances stay in memory for the look-back
///   time (two minutes by default) so that a recap can be asked for. Never written to disk.
///
/// What is stored on the device: the goals, and the summaries the user asked for. Log lines and
/// reports hold counts, states and timings only.
@Observable
final class ConversationIntelligenceController {
    /// A match (accepted or uncertain) as the app's own list shows it. In memory only.
    struct GoalMatch: Identifiable {
        let id: UUID
        var goalText: String
        var decision: SemanticAttentionDecision
        var receivedAt: Date
    }

    static let matchCapacity = 20
    private static let semanticKey = "conversation.semanticAttentionEnabled"
    private static let contextKey = "conversation.keepsRecentSpeech"
    private static let lookBackKey = "conversation.lookBackSeconds"

    /// `--hs-conversation-demo` (Debug builds): a scripted conversation instead of the microphone,
    /// with nothing read from or written to the device's storage. See `runDemo`.
    static var isDemoRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--hs-conversation-demo")
        #else
        false
        #endif
    }

    /// For App Intents, which have no reference to the app's object graph.
    private(set) static weak var shared: ConversationIntelligenceController?

    // Settings
    private(set) var isSemanticAttentionEnabled: Bool
    private(set) var keepsRecentSpeech: Bool
    private(set) var lookBack: TimeInterval
    private(set) var goals: [AttentionGoal]

    // Semantic attention
    private(set) var matches: [GoalMatch] = []
    private(set) var semanticStatistics = SemanticAttentionEngine.Statistics()

    /// Sentences that goal matching gave up on because they waited too long for the language
    /// model (Window 6.2). A count, shown so that an overload is never silent.
    var uncheckedSentences: Int { semanticStatistics.dropped }
    private(set) var isLanguageModelAvailable = false

    // Recap and continued understanding
    private(set) var phase = ConversationPhase.idle
    private(set) var status: ConversationStatus?
    private(set) var recap: ConversationRecap?
    private(set) var currentRecordID: UUID?
    private(set) var captions: [BufferedUtterance] = []
    private(set) var tentativeCaption: String?
    private(set) var unavailableMessage: String?
    private(set) var continuedSince: Date?
    private(set) var recapsMade = 0
    private(set) var updatesMade = 0
    private(set) var lastRecapSeconds: TimeInterval?

    // History
    private(set) var history: [ConversationRecord] = []
    private(set) var storageError: String?

    private(set) var isSessionActive = false
    private(set) var isTranscriptionOn = false

    /// Accepted goal matches go to the attention engine (Window 4), which decides on presentation.
    @ObservationIgnored var onSignal: ((SemanticAttentionSignal) -> Void)?
    /// Recap states go to the Live Activity as generic, lock-screen-safe episodes.
    @ObservationIgnored var onStatusIntent: ((AttentionPresentationIntent) -> Void)?
    /// The state of "Transcribe nearby speech" (Window 3), read whenever it matters.
    @ObservationIgnored var transcriptionProvider: () -> Bool = { false }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let goalStore: AttentionGoalStore
    @ObservationIgnored private let store: SwiftDataConversationHistory?
    @ObservationIgnored private let semanticEngine: SemanticAttentionEngine
    @ObservationIgnored private let recapEngine: ConversationRecapEngine
    @ObservationIgnored private var buffer: RollingConversationBuffer
    @ObservationIgnored private var machine = ConversationSessionMachine()
    @ObservationIgnored private var decisionTask: Task<Void, Never>?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var lastUtteranceIndex: [SpeechEventID: Int] = [:]
    /// The words the saved recap was written from, kept only while the session is followed so
    /// that an update can be checked against them. Cleared with the temporary context.
    @ObservationIgnored private var recapTranscript = ""
    @ObservationIgnored private var contextLines: [String] = []
    @ObservationIgnored private let inferenceScheduler: ModelInferenceScheduler
    /// Window 6.1: a partial transcript that has stopped changing is evaluated ahead of its final
    /// form. Its answer is used only if the final text has the same words; it is never shown.
    @ObservationIgnored private var partialDetector = StablePartialDetector()
    @ObservationIgnored private var partialID = UUID()
    @ObservationIgnored private var partialTask: Task<Void, Never>?
    @ObservationIgnored private var statusEpisode = 0
    @ObservationIgnored private var statusRevision = 0
    @ObservationIgnored private var log: (DiagnosticEventLog.Kind, String) -> Void = { _, _ in }

    /// - Parameter inMemory: no files are read or written (UI checks, previews).
    init(defaults: UserDefaults = .standard, inMemory: Bool = ConversationIntelligenceController.isDemoRequested,
         summarizer: any ConversationSummarizing = FoundationModelRecapSummarizer(),
         reasoner: any SemanticRelevanceReasoning = FoundationModelRelevanceReasoner.current)
    {
        self.defaults = defaults
        goalStore = AttentionGoalStore(inMemory: inMemory)
        isSemanticAttentionEnabled = defaults.bool(forKey: Self.semanticKey)
        keepsRecentSpeech = defaults.bool(forKey: Self.contextKey)
        let stored = defaults.double(forKey: Self.lookBackKey)
        let seconds = ConversationBufferPolicy.lookBackChoices.contains(stored) ? stored : ConversationBufferPolicy.standard.lookBack
        lookBack = seconds
        let loadedGoals = goalStore.load()
        goals = loadedGoals
        let policy = ConversationBufferPolicy(lookBack: seconds)
        buffer = RollingConversationBuffer(policy: policy)
        recapEngine = ConversationRecapEngine(summarizer: summarizer, bufferPolicy: policy)
        // One scheduler for everything that uses the language model here (Window 6.1): the
        // recap takes its turn ahead of goal matching instead of pausing it.
        let engine = SemanticAttentionEngine(reasoner: reasoner, scorer: SentenceEmbeddingScorer())
        semanticEngine = engine
        inferenceScheduler = engine.scheduler
        var opened: SwiftDataConversationHistory?
        var records: [ConversationRecord] = []
        var problem: String?
        do {
            let history = try SwiftDataConversationHistory(inMemory: inMemory)
            try history.completeInterrupted()
            records = try history.all()
            opened = history
        } catch {
            problem = "The summary history could not be opened: \(error.localizedDescription)"
        }
        store = opened
        history = records
        storageError = problem
        Self.shared = self
        let isEnabled = isSemanticAttentionEnabled
        decisionTask = Task { [weak self, decisions = engine.decisions] in
            for await decision in decisions {
                guard let self else { return }
                await self.handle(decision)
            }
        }
        Task {
            await engine.setGoals(loadedGoals)
            await engine.setEnabled(isEnabled)
        }
        Task { [weak self] in
            let isUsable = await reasoner.availability().isUsable
            self?.isLanguageModelAvailable = isUsable
        }
    }

    deinit {
        decisionTask?.cancel()
        workTask?.cancel()
        deadlineTask?.cancel()
    }

    func setLogger(_ logger: @escaping (DiagnosticEventLog.Kind, String) -> Void) {
        log = logger
    }

    // MARK: - Lifecycle (called by ListeningController)

    func sessionWillStart(isTranscriptionOn: Bool) {
        isSessionActive = true
        self.isTranscriptionOn = isTranscriptionOn
        lastUtteranceIndex.removeAll()
        contextLines.removeAll()
        machine.setListening(true)
        machine.setContextAllowed(keepsRecentSpeech && isTranscriptionOn)
        if keepsRecentSpeech, isTranscriptionOn { buffer.begin(at: .now) }
        if isSemanticAttentionEnabled, isTranscriptionOn { Task { [semanticEngine] in await semanticEngine.prewarm() } }
    }

    /// Capture stopped: a continued session is finalized and every temporary text is deleted.
    func sessionDidEnd() {
        guard isSessionActive else { return }
        isSessionActive = false
        run(machine.process(.listeningStopped(at: .now)))
        clearTemporaryText()
        partialTask?.cancel()
        partialDetector.finish()
        Task { [semanticEngine] in await semanticEngine.reset() }
        log(.recognition, "Conversation intelligence: \(recapsMade) recap(s), \(updatesMade) update(s), "
            + "\(semanticStatistics.accepted) goal match(es) this launch")
    }

    /// The user switched "Transcribe nearby speech" (Window 3).
    func transcriptionChanged(isOn: Bool) {
        guard isOn != isTranscriptionOn else { return }
        isTranscriptionOn = isOn
        applyContextPermission()
    }

    /// The speech pipeline discarded its events (transcription off, or "Clear speech data").
    func speechDataCleared() {
        isTranscriptionOn = transcriptionProvider()
        run(machine.process(.contextRevoked(at: .now)))
        machine.setContextAllowed(keepsRecentSpeech && isTranscriptionOn)
        clearTemporaryText()
        matches.removeAll()
        partialTask?.cancel()
        partialDetector.finish()
        Task { [semanticEngine] in await semanticEngine.reset() }
        if isSessionActive, keepsRecentSpeech, isTranscriptionOn { buffer.begin(at: .now) }
    }

    // MARK: - Input from the speech pipeline

    func receive(_ result: SpeechSemanticResult) {
        guard isSessionActive else { return }
        transcriptionChanged(isOn: transcriptionProvider())
        let now = Date.now
        let keeps = keepsRecentSpeech && isTranscriptionOn
        if keeps {
            buffer.setTentative(result.volatileText)
            tentativeCaption = buffer.tentative
        }
        let last = lastUtteranceIndex[result.id] ?? -1
        let matchesGoals = isSemanticAttentionEnabled && goals.contains(where: \.isEnabled)
        if matchesGoals, let partial = result.volatileText { offerPartial(partial, now: now) }
        for utterance in result.recentUtterances where utterance.index > last && !utterance.isPossiblyMusic {
            lastUtteranceIndex[result.id] = utterance.index
            // The utterance is final: whatever was offered of it early has done its work.
            partialTask?.cancel()
            partialDetector.finish()
            partialID = UUID()
            if keeps {
                buffer.append(BufferedUtterance(text: utterance.text, start: utterance.startDate, end: utterance.endDate,
                                                isLowQuality: utterance.quality == .poor), now: now)
                run(machine.process(.utterance(meaningfulWords: MeaningfulWords.count(in: utterance.text), end: now)))
            }
            if isSemanticAttentionEnabled, goals.contains(where: \.isEnabled) {
                let semantic = SemanticUtterance(text: utterance.text, context: contextLines, date: utterance.endDate,
                                                 isLowQuality: utterance.quality == .poor)
                Task { [semanticEngine] in await semanticEngine.submit(semantic) }
            }
            contextLines = Array((contextLines + [utterance.text]).suffix(2))
        }
        if result.state.isTerminal {
            lastUtteranceIndex[result.id] = nil
            // Speech was detected and nothing could be transcribed: a recap says so.
            if keeps, result.utteranceCount == 0, result.transcriptionAvailability.isUsable {
                buffer.noteMissingSpeech(from: result.startDate, to: result.updatedDate, now: now)
            }
        }
        if keeps {
            buffer.prune(now: now)
            captions = buffer.utterances
            scheduleDeadline()
        }
    }

    /// Hands a partial transcript to the detector and, when it has been stable for long enough,
    /// to the semantic engine for an early evaluation.
    private func offerPartial(_ text: String, now: Date) {
        guard !text.isEmpty else { return }
        partialDetector.revise(text, utterance: partialID, at: now)
        partialTask?.cancel()
        guard let check = partialDetector.nextCheck else { return }
        let context = contextLines
        partialTask = Task { [semanticEngine] in
            try? await Task.sleep(for: .seconds(max(0, check.timeIntervalSinceNow)))
            guard !Task.isCancelled, let stable = self.partialDetector.offer(at: .now) else { return }
            await semanticEngine.submitProvisional(SemanticUtterance(text: stable, context: context, date: .now))
        }
    }

    private func handle(_ decision: SemanticAttentionDecision) async {
        semanticStatistics = await semanticEngine.statistics
        guard decision.verdict != .irrelevant, isSessionActive else { return }
        let goalText = decision.matchedGoalID.flatMap { id in goals.first { $0.id == id }?.text } ?? ""
        matches.insert(GoalMatch(id: decision.id, goalText: goalText, decision: decision, receivedAt: .now), at: 0)
        if matches.count > Self.matchCapacity { matches.removeLast(matches.count - Self.matchCapacity) }
        // Metadata only: never the utterance, the headline or the reason.
        log(.recognition, "Goal decision: \(decision.redactedSummary), \(Self.seconds(decision.latency)) after the utterance "
            + "(model \(Self.seconds(decision.modelTime)))")
        guard decision.isAccepted, let goalID = decision.matchedGoalID else { return }
        let urgency: SemanticAttentionSignal.Urgency = switch decision.urgency {
        case .low: .low
        case .normal: .normal
        case .high: .high
        }
        onSignal?(SemanticAttentionSignal(id: decision.id, goalID: goalID, headline: decision.headline,
                                          statement: decision.evidence, urgency: urgency,
                                          isUncertain: decision.isPersonalRelevanceUncertain, date: .now))
    }

    // MARK: - Settings

    func setSemanticAttentionEnabled(_ isEnabled: Bool) {
        guard isEnabled != isSemanticAttentionEnabled else { return }
        isSemanticAttentionEnabled = isEnabled
        defaults.set(isEnabled, forKey: Self.semanticKey)
        if !isEnabled { matches.removeAll() }
        Task { [semanticEngine] in
            await semanticEngine.setEnabled(isEnabled)
            if isEnabled { await semanticEngine.prewarm() }
        }
        log(.recognition, "Semantic attention switched \(isEnabled ? "on" : "off") by the user")
    }

    func setKeepsRecentSpeech(_ keeps: Bool) {
        guard keeps != keepsRecentSpeech else { return }
        keepsRecentSpeech = keeps
        defaults.set(keeps, forKey: Self.contextKey)
        applyContextPermission()
        log(.recognition, "Recent speech for recaps switched \(keeps ? "on" : "off") by the user")
    }

    func setLookBack(_ seconds: TimeInterval) {
        guard ConversationBufferPolicy.lookBackChoices.contains(seconds), seconds != lookBack else { return }
        lookBack = seconds
        defaults.set(seconds, forKey: Self.lookBackKey)
        buffer.setPolicy(ConversationBufferPolicy(lookBack: seconds), now: .now)
        captions = buffer.utterances
    }

    private func applyContextPermission() {
        let allowed = keepsRecentSpeech && isTranscriptionOn
        if allowed {
            machine.setContextAllowed(true)
            if isSessionActive, buffer.collectingSince == nil { buffer.begin(at: .now) }
        } else {
            run(machine.process(.contextRevoked(at: .now)))
            clearTemporaryText()
        }
    }

    // MARK: - Goals

    @discardableResult
    func addGoal(_ text: String) -> Bool {
        let normalized = AttentionGoal.normalized(text)
        guard !normalized.isEmpty, !goals.contains(where: { $0.text.caseInsensitiveCompare(normalized) == .orderedSame })
        else { return false }
        goals.append(AttentionGoal(text: normalized))
        goalsChanged()
        return true
    }

    func setGoal(_ id: UUID, isEnabled: Bool) {
        guard let index = goals.firstIndex(where: { $0.id == id }), goals[index].isEnabled != isEnabled else { return }
        goals[index].isEnabled = isEnabled
        goalsChanged()
    }

    func updateGoal(_ id: UUID, text: String) {
        let normalized = AttentionGoal.normalized(text)
        guard !normalized.isEmpty, let index = goals.firstIndex(where: { $0.id == id }), goals[index].text != normalized else { return }
        goals[index].text = normalized
        goalsChanged()
    }

    func deleteGoals(_ ids: Set<UUID>) {
        goals.removeAll { ids.contains($0.id) }
        matches.removeAll { match in match.decision.matchedGoalID.map(ids.contains) ?? false }
        goalsChanged()
    }

    private func goalsChanged() {
        goalStore.save(goals)
        Task { [semanticEngine, goals] in await semanticEngine.setGoals(goals) }
        // The number only: a goal's wording is the user's and does not belong in a log.
        log(.recognition, "Attention goals changed: \(goals.count(where: \.isEnabled)) of \(goals.count) enabled")
    }

    // MARK: - Recap and continued understanding

    /// The Action Button shortcut, or the button in the app. First press: recap. While
    /// continuing: stop. Returns a generic sentence for the shortcut's answer (never speech text).
    @discardableResult
    func actionInvoked() -> String {
        unavailableMessage = nil
        transcriptionChanged(isOn: transcriptionProvider())
        let before = phase
        run(machine.process(.actionInvoked(at: .now)))
        switch (before, phase) {
        case (.continuing, _): return "Stopped following the conversation. The summary is saved in Hearing Sense."
        case (_, .preparing), (_, .summarizing): return "Writing a recap of the last \(Self.describe(lookBack)). It will be saved in Hearing Sense."
        default: return unavailableMessage ?? "A recap is already being written."
        }
    }

    func continueUnderstanding() {
        run(machine.process(.continueSelected(at: .now)))
    }

    func stopUnderstanding() {
        run(machine.process(.stopSelected(at: .now)))
    }

    /// What `actionInvoked()` would do now, for button titles.
    var actionTitle: String {
        switch phase {
        case .continuing: "Stop Following"
        case .preparing, .summarizing: "Writing Recap…"
        case .idle, .summaryAvailable: "Recap Last \(Self.describe(lookBack).capitalized)"
        }
    }

    var canRecap: Bool { isSessionActive && keepsRecentSpeech && isTranscriptionOn }
    var bufferedWordCount: Int { captions.reduce(0) { $0 + $1.wordCount } }

    private func run(_ effects: [ConversationEffect]) {
        for effect in effects {
            switch effect {
            case .generateRecap:
                let excerpt = buffer.excerpt(now: .now)
                recapTranscript = recapEngine.transcript(of: excerpt)
                run(machine.process(.excerptReady(at: .now)))
                workTask?.cancel()
                workTask = Task { [recapEngine, inferenceScheduler] in
                    // What the user asked for comes first: it takes the next turn at the model,
                    // ahead of goal matching, which keeps its waiting sentences meanwhile.
                    let scheduled = try? await inferenceScheduler.run(.userRequest) { await recapEngine.recap(excerpt) }
                    guard !Task.isCancelled else { return }
                    // Only a cancelled or refused turn leaves no recap; the recap is then written directly.
                    let recap: ConversationRecap
                    if let scheduled { recap = scheduled } else { recap = await recapEngine.recap(excerpt) }
                    guard !Task.isCancelled else { return }
                    self.recapsMade += 1
                    self.lastRecapSeconds = recap.modelSeconds
                    self.log(.recognition, "Recap: \(recap.source.rawValue), \(excerpt.utterances.count) utterance(s), "
                        + "\(excerpt.wordCount) words, model \(Self.seconds(recap.modelSeconds)), "
                        + "\(recap.corrections.count) correction(s)")
                    self.run(self.machine.process(.recapReady(recap, at: .now)))
                }
            case .cancelWork:
                workTask?.cancel()
                workTask = nil
            case .save(let recap, let isContinuing):
                self.recap = recap
                save(recap, status: isContinuing ? .continuing : .completed)
            case .requestUpdate(let since):
                guard let recap else {
                    run(machine.process(.updateFinished(nil, at: .now)))
                    break
                }
                let new = buffer.utterances(after: since)
                let earlier = recapTranscript
                workTask = Task { [recapEngine, inferenceScheduler] in
                    let scheduled = try? await inferenceScheduler.run(.userRequest) {
                        await recapEngine.update(recap, earlierTranscript: earlier, new: new)
                    }
                    guard !Task.isCancelled else { return }
                    let updated = scheduled ?? nil
                    guard !Task.isCancelled else { return }
                    if updated != nil {
                        self.updatesMade += 1
                        // Kept only as long as the session is followed; bounded.
                        self.recapTranscript = String((earlier + "\n" + new.map(\.text).joined(separator: "\n")).suffix(8000))
                    }
                    self.log(.recognition, "Recap update: \(updated == nil ? "nothing new" : "extended") from \(new.count) utterance(s)")
                    self.run(self.machine.process(.updateFinished(updated, at: .now)))
                }
            case .finalize:
                if let recap { save(recap, status: .completed) }
                currentRecordID = nil
            case .clearTemporaryContext:
                clearTemporaryText()
                if isSessionActive, keepsRecentSpeech, isTranscriptionOn { buffer.begin(at: .now) }
            case .status(let status, _):
                present(status)
            case .unavailable(let reason):
                unavailableMessage = reason.message
            }
        }
        phase = machine.phase
        continuedSince = machine.continuedSince
        scheduleDeadline()
    }

    private func save(_ recap: ConversationRecap, status: ConversationRecord.Status) {
        guard let store else { return }
        do {
            let now = Date.now
            if let id = currentRecordID, var record = try store.record(id) {
                record.apply(recap, at: now, status: status)
                try store.save(record)
            } else {
                let record = ConversationRecord(recap: recap, at: now, status: status)
                currentRecordID = record.id
                try store.save(record)
            }
            history = try store.all()
            storageError = nil
        } catch {
            storageError = "The summary could not be saved: \(error.localizedDescription)"
            log(.error, "Saving a summary failed: \(type(of: error))")
        }
    }

    /// Deletes every temporary speech text this controller holds.
    private func clearTemporaryText() {
        buffer.clear()
        captions = []
        tentativeCaption = nil
        recapTranscript = ""
        contextLines.removeAll()
        lastUtteranceIndex.removeAll()
        if phase == .idle { recap = nil }
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let deadline = [machine.nextDeadline, buffer.nextExpiry].compactMap(\.self).min() else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0) + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.buffer.prune(now: .now)
            self.captions = self.buffer.utterances
            self.run(self.machine.process(.tick(at: .now)))
        }
    }

    // MARK: - Dynamic Island

    /// The recap's state as an episode of the Live Activity: a generic title and icon, no
    /// speech-derived text, no interruption (it never asks for an expansion or a sound).
    private func present(_ newStatus: ConversationStatus?) {
        let now = Date.now
        if let old = status, newStatus == nil || newStatus != old {
            onStatusIntent?(statusIntent(old, action: .dismiss, at: now))
        }
        status = newStatus
        guard let newStatus else { return }
        statusEpisode += 1
        statusRevision = 1
        onStatusIntent?(statusIntent(newStatus, action: .present, at: now))
    }

    private func statusIntent(_ status: ConversationStatus, action: PresentationAction, at date: Date) -> AttentionPresentationIntent {
        // Ids far above the attention engine's own (which count up from 1).
        let event = AttentionEvent(id: AttentionEventID(rawValue: 1_000_000 + statusEpisode), revision: statusRevision,
                                   category: .other, kindID: "conversation_status", title: status.title,
                                   subtitle: "Hearing Sense", symbolName: status.symbolName, priority: .normal,
                                   createdAt: date, updatedAt: date, isPresented: action != .dismiss)
        return AttentionPresentationIntent(event: event, action: action, interruption: .none, timestamp: date,
                                           expiresAt: nil, reasons: [])
    }

    // MARK: - History

    func refreshHistory() {
        guard let store else { return }
        history = (try? store.all()) ?? history
    }

    func search(_ query: String) -> [ConversationRecord] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? history : history.filter { $0.matches(query) }
    }

    func record(_ id: UUID) -> ConversationRecord? {
        history.first { $0.id == id }
    }

    func edit(_ id: UUID, title: String, summary: String) {
        guard let store, var record = try? store.record(id) else { return }
        record.edit(title: title, summary: summary, at: .now)
        try? store.save(record)
        refreshHistory()
    }

    func delete(_ ids: Set<UUID>) {
        guard let store else { return }
        for id in ids {
            try? store.delete(id)
            if id == currentRecordID { currentRecordID = nil }
        }
        refreshHistory()
    }

    /// Deletes every saved summary.
    func deleteAllHistory() {
        try? store?.deleteAll()
        currentRecordID = nil
        refreshHistory()
        log(.recognition, "All saved summaries deleted by the user")
    }

    // MARK: - Reports

    static func seconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " s"
    }

    static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return seconds % 60 == 0 ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" : "\(seconds) seconds"
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }

    /// Counts, states and timings. No goal wording, no utterance, no summary.
    func reportText() -> String {
        let statistics = semanticStatistics
        let calls = statistics.modelCalls + statistics.triageCalls
        return [
            "Conversation intelligence (Window 6, semantic engine of Window 6.2)",
            "Semantic attention: \(isSemanticAttentionEnabled ? "on" : "off") · goals \(goals.count(where: \.isEnabled)) of \(goals.count) enabled"
                + " · language model \(isLanguageModelAvailable ? "available" : "not available")",
            "Utterances submitted \(statistics.submitted), gated \(statistics.gated), stopped by the first pass \(statistics.triaged), "
                + "full judgements \(statistics.modelCalls), cache hits \(statistics.cacheHits)",
            "Accepted \(statistics.accepted), uncertain \(statistics.uncertain), repeated \(statistics.repeated), "
                + "corrected by the verifier \(statistics.corrected), not checked \(statistics.dropped) "
                + "(of these given up after waiting \(statistics.expired)), "
                + "model failures \(statistics.modelFailures) (timeouts \(statistics.timeouts)), longest queue \(statistics.maximumQueueLength)",
            "Model time per call: \(calls > 0 ? Self.seconds(statistics.totalModelTime / Double(calls)) : "–") over \(calls) call(s)",
            "Second looks \(statistics.confirmCalls) (alerts taken back \(statistics.confirmDemoted)) · early evaluations of partial "
                + "transcripts \(statistics.speculativeCalls) (used \(statistics.speculativeHits), abandoned \(statistics.speculativeCancelled))"
                + " · decisions later than the deadline \(statistics.deadlineMisses)",
            "While behind: newest sentence served first \(statistics.servedNewestFirst) time(s) · answers from a session that "
                + "continued \(statistics.continuedSessions) · requests asked again after a failure \(statistics.retries)",
            "Waiting for a turn, median: \(Self.median(statistics.queueWaits).map(Self.seconds) ?? "–") · utterance to decision, "
                + "median: \(Self.median(statistics.latencies).map(Self.seconds) ?? "–")",
            "Recent speech for recaps: \(keepsRecentSpeech ? "on" : "off") · look-back \(Int(lookBack)) s · "
                + "buffered \(captions.count) utterance(s), \(bufferedWordCount) words, expired \(buffer.expiredUtterances)",
            "Recap phase: \(phase.rawValue) · recaps \(recapsMade) · updates \(updatesMade) · last recap model time "
                + "\(lastRecapSeconds.map(Self.seconds) ?? "–") · saved summaries \(history.count)",
        ].joined(separator: "\n")
    }
}

#if DEBUG
// MARK: - Demo without a microphone

extension ConversationIntelligenceController {
    private static let demoGoals = ["Tell me anything that could affect my grades.",
                                    "Let me know if somebody mentions a change to my schedule.",
                                    "Warn me about clear emergency instructions nearby."]

    /// Synthetic sentences, written for this project. Not a real conversation.
    private static let demoFirstPart = [
        "So for the chemistry project, are we still meeting on Thursday?",
        "No, Thursday doesn't work, the library closes at five that day.",
        "What about Saturday morning then, around ten?",
        "Saturday at ten works, but not at the library, it's closed on weekends.",
        "We could use the study room in the science building, room 204.",
        "By the way, the exam has been postponed until Friday.",
        "I have the data on my laptop, but the graphs are not finished.",
        "Then please finish the graphs by Friday night so we can write the report on Saturday.",
    ]
    private static let demoLaterPart = [
        "One more thing, the report is due next Wednesday, not Monday.",
        "And the teacher said it has to be at least six pages.",
        "Fine, then let's split it, three pages each.",
    ]

    /// Plays a scripted conversation through the same path as transcribed speech: the buffer,
    /// the semantic engine and the recap engine run for real (with the on-device language
    /// model where it exists); only the microphone and the recognizer are replaced. Both
    /// opt-ins are switched on for this launch only and nothing is stored.
    func runDemo(onGoalMatch: @escaping (SemanticAttentionSignal) -> Void) {
        guard Self.isDemoRequested, !isSessionActive else { return }
        log(.lifecycle, "Conversation demo (synthetic sentences, microphone off, nothing stored)")
        isSemanticAttentionEnabled = true
        keepsRecentSpeech = true
        if goals.isEmpty { goals = Self.demoGoals.map { AttentionGoal(text: $0) } }
        transcriptionProvider = { true }
        onSignal = onGoalMatch
        let goals = goals
        Task { [semanticEngine] in
            await semanticEngine.setGoals(goals)
            await semanticEngine.setEnabled(true)
        }
        sessionWillStart(isTranscriptionOn: true)
        Task {
            let id = SpeechEventID()
            var index = 0
            @MainActor func say(_ text: String) async {
                let now = Date.now
                var result = SpeechSemanticResult(
                    id: id, state: .transcribing, audioTime: AudioTimeRange(start: 0, end: Double(index + 1) * 4),
                    startDate: now, updatedDate: now,
                    transcript: SpeechTranscript(text: text, language: "en-US", isFinal: true, quality: .unknown,
                                                 audioTime: AudioTimeRange(start: Double(index) * 4, end: Double(index + 1) * 4)),
                    utteranceCount: index + 1, transcriptionAvailability: .available, modelAvailability: .available)
                result.recentUtterances = [SpeechUtterance(index: index, text: text, startDate: now.addingTimeInterval(-3),
                                                           endDate: now, quality: .good)]
                index += 1
                receive(result)
                try? await Task.sleep(for: .seconds(1.6))
            }
            try? await Task.sleep(for: .seconds(1))
            for line in Self.demoFirstPart { await say(line) }
            actionInvoked()
            // Wait for the recap, then keep following.
            for _ in 0 ..< 60 where phase != .summaryAvailable { try? await Task.sleep(for: .seconds(0.5)) }
            try? await Task.sleep(for: .seconds(2))
            continueUnderstanding()
            for line in Self.demoLaterPart { await say(line) }
            var tentative = SpeechSemanticResult(
                id: id, state: .transcribing, audioTime: AudioTimeRange(start: 0, end: 60), startDate: .now, updatedDate: .now,
                transcript: SpeechTranscript(text: "and I will bring", language: "en-US", isFinal: false, quality: .unknown,
                                             audioTime: AudioTimeRange(start: 56, end: 60)),
                utteranceCount: index, transcriptionAvailability: .available, modelAvailability: .available)
            tentative.volatileText = "and I will bring the"
            receive(tentative)
        }
    }
}
#endif
