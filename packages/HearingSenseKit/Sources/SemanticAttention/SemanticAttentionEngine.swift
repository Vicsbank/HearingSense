import Foundation

/// Matches what is said nearby against the user's goals by reasoning about meaning (Window 6,
/// reworked in Window 6.1 for speed and for conversation that comes faster than the model).
///
/// Stages, cheapest first:
/// 1. `UtteranceGate`: fillers and backchannel never reach a model.
/// 2. Cache: an utterance that was just decided is not decided again. A stable partial
///    transcript may be evaluated ahead of its final form (`submitProvisional`); the final text
///    then finds the answer here. Nothing provisional is ever reported or remembered as said.
/// 3. Goal selection: with many goals, the closest ones by a cheap similarity score.
/// 4. The language model, once per utterance (`SemanticRelevanceReasoning`), on a turn given by
///    the `ModelInferenceScheduler`, which the recap shares.
/// 5. `EvidenceVerifier`: deterministic checks that can only make the result more cautious.
/// 6. Novelty: the same statement accepted a short while ago is not accepted again.
///
/// When sentences wait (speech faster than the model, or the model busy with a recap):
/// - A sentence that looks like a warning goes first and is always judged on its own.
/// - Waiting sentences are judged together, up to `maximumBatch` in one request. If the model
///   says none of them matters, all are settled by that one request. If it names one, that one
///   is decided and the others are judged again on their own, so a second relevant sentence in
///   the same group is not lost.
/// - Nothing is discarded without a decision that says so: an utterance pushed out of a full
///   queue, or one that waited longer than `maximumWait`, is reported with stage `.dropped`
///   and counted.
///
/// This module never delays the attention engine's own phrase rule ("Watch out!"), which does
/// not pass through here and does not use the language model.
///
/// Decisions hold speech-derived text. `statistics` and `redactedSummary` do not.
public actor SemanticAttentionEngine {
    public struct Configuration: Hashable, Sendable {
        /// Utterances that may wait while one is being evaluated.
        public var queueCapacity = 12
        /// An utterance older than this when its turn comes is dropped (reported and counted).
        public var maximumWait: TimeInterval = 20
        /// A decision later than this after submission is counted as a missed deadline. It is
        /// still made: "the exam moved to Friday" is worth knowing five seconds late.
        public var deadline: TimeInterval = 4
        /// The model's answer is abandoned after this long.
        public var timeout: TimeInterval = 8
        public var cacheCapacity = 48
        public var cacheLifetime: TimeInterval = 120
        /// A statement accepted within this time is not accepted again.
        public var noveltyWindow: TimeInterval = 300
        /// Word overlap (Jaccard, by stem) from which two statements count as the same.
        public var noveltySimilarity = 0.6
        public var maximumContextUtterances = 3
        /// Ask the model a one-word question first and run the full judgement only on a yes.
        /// Off since Window 6.1: the full judgement became fast enough that the extra request
        /// costs more than it saves (measured; see the optimization report).
        public var usesTriage = false
        /// Take a second, narrower look at a sentence that was judged relevant (not at warnings)
        /// before it is accepted. It can only make the decision more cautious.
        public var confirmsRelevant = true
        /// Waiting sentences from which they are judged together; 0 never does. Off: measured on
        /// the development set, a group request waved through 7 of 34 groups that contained a
        /// relevant sentence. The mechanism stays for a model that can do it.
        public var batchThreshold = 0
        public var maximumBatch = 3

        public init() {}

        public static let standard = Configuration()

        /// How the engine behaved in Window 6, for comparisons: a first pass before every
        /// judgement, four waiting utterances with the oldest discarded, nothing judged
        /// together, no second look.
        public static var window6: Configuration {
            var configuration = Configuration()
            configuration.queueCapacity = 4
            configuration.maximumWait = 12
            configuration.usesTriage = true
            configuration.confirmsRelevant = false
            return configuration
        }
    }

    public struct Statistics: Hashable, Sendable {
        public var submitted = 0
        public var gated = 0
        public var cacheHits = 0
        public var modelCalls = 0
        public var triageCalls = 0
        /// Utterances the first pass stopped.
        public var triaged = 0
        public var modelFailures = 0
        public var timeouts = 0
        /// Utterances reported as dropped: pushed out of a full queue or waited too long.
        public var dropped = 0
        public var accepted = 0
        public var uncertain = 0
        public var repeated = 0
        public var corrected = 0
        public var maximumQueueLength = 0
        public var totalModelTime: TimeInterval = 0
        /// Requests that judged several waiting sentences together, and the sentences in them.
        public var batchCalls = 0
        public var batchedUtterances = 0
        /// Sentences settled by a group request that found nothing.
        public var settledByBatch = 0
        /// Sentences judged again on their own after their group contained a match.
        public var requeuedAfterBatch = 0
        /// Evaluations of a stable partial transcript; how many the final text could use; how
        /// many were abandoned because the final text was different or something else came first.
        /// Second looks at relevant sentences, and how many of them took the alert back.
        public var confirmCalls = 0
        public var confirmDemoted = 0
        public var speculativeCalls = 0
        public var speculativeHits = 0
        public var speculativeCancelled = 0
        /// Decisions made later than `deadline` after submission.
        public var deadlineMisses = 0
        public var outputTokens = 0
        /// Seconds from submission to the start of evaluation, and to the decision (newest last).
        public var queueWaits: [TimeInterval] = []
        public var latencies: [TimeInterval] = []

        public init() {}
    }

    private struct CacheEntry {
        var judgement: RelevanceJudgement
        var goalIDs: [UUID]
        var storedAt: Date
        var isSpeculative: Bool
    }

    private struct Accepted {
        var goalID: UUID
        var stems: Set<String>
        var isNegated: Bool
        var quantities: Set<String>
        var date: Date
    }

    private struct Entry {
        var utterance: SemanticUtterance
        var submitted: Date
        var isUrgent: Bool
        /// Judged in a group already: on its own from now on.
        var wasBatched = false
    }

    private let reasoner: any SemanticRelevanceReasoning
    private let scorer: (any GoalSimilarityScoring)?
    private let gate: UtteranceGate
    private let verifier: EvidenceVerifier
    public let configuration: Configuration
    public nonisolated let scheduler: ModelInferenceScheduler

    private var goals: [AttentionGoal] = []
    private var isEnabled = true
    private var queue: [Entry] = []
    /// The stable partial transcript waiting to be evaluated ahead of its final form.
    private var provisional: SemanticUtterance?
    private var speculativeTask: (key: String, task: Task<RelevanceJudgement, any Error>)?
    private var worker: Task<Void, Never>?
    /// Sentences that look like a warning have a lane of their own: they do not stand behind
    /// an ordinary sentence that is itself waiting for the model (for a recap to finish, say).
    private var urgentQueue: [Entry] = []
    private var urgentWorker: Task<Void, Never>?
    private var cache: [String: CacheEntry] = [:]
    private var accepted: [Accepted] = []
    private var generation = 0
    private var isPaused = false
    public private(set) var statistics = Statistics()
    private let sampleLimit = 2_000

    private let continuation: AsyncStream<SemanticAttentionDecision>.Continuation
    /// Every decision for a submitted utterance, in the order they were made. One consumer.
    public nonisolated let decisions: AsyncStream<SemanticAttentionDecision>

    public init(reasoner: any SemanticRelevanceReasoning, scorer: (any GoalSimilarityScoring)? = nil,
                gate: UtteranceGate = UtteranceGate(), verifier: EvidenceVerifier = .standard,
                configuration: Configuration = .standard, scheduler: ModelInferenceScheduler = ModelInferenceScheduler())
    {
        self.reasoner = reasoner
        self.scorer = scorer
        self.gate = gate
        self.verifier = verifier
        self.configuration = configuration
        self.scheduler = scheduler
        (decisions, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    // MARK: - Control

    public func setGoals(_ goals: [AttentionGoal]) {
        let active = goals.filter { $0.isEnabled && !$0.text.isEmpty }
        guard active != self.goals else { return }
        self.goals = active
        cache.removeAll()
    }

    public func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        if !isEnabled { reset() }
    }

    public var isActive: Bool { isEnabled && !goals.isEmpty }

    public var queueLength: Int { queue.count }

    /// Holds back new evaluations. Since Window 6.1 a recap does not need this: it takes its
    /// turn through the scheduler, ahead of goal matching. Kept for hosts without a scheduler.
    public func setPaused(_ isPaused: Bool) {
        guard isPaused != self.isPaused else { return }
        self.isPaused = isPaused
        if !isPaused, !queue.isEmpty || provisional != nil { startWorkerIfNeeded() }
    }

    public func prewarm() async {
        guard isActive else { return }
        await reasoner.prewarm(goals: selectGoals(for: ""))
    }

    /// Forgets everything speech-derived: waiting utterances, cached answers and the memory of
    /// accepted statements. Called when the session ends or the user clears speech data.
    public func reset() {
        generation += 1
        isPaused = false
        worker?.cancel()
        worker = nil
        urgentWorker?.cancel()
        urgentWorker = nil
        urgentQueue.removeAll()
        speculativeTask?.task.cancel()
        speculativeTask = nil
        provisional = nil
        Task { [reasoner] in await reasoner.forget() }
        queue.removeAll()
        cache.removeAll()
        accepted.removeAll()
    }

    public func resetStatistics() {
        statistics = Statistics()
    }

    // MARK: - Input

    /// Hands in a finalized utterance and returns at once. Its decision arrives on `decisions`.
    public func submit(_ utterance: SemanticUtterance, now: Date = Date()) {
        statistics.submitted += 1
        guard isActive else { return }
        guard gate.admits(utterance.text) else {
            statistics.gated += 1
            continuation.yield(SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date,
                                                         verdict: .irrelevant, stage: .gate))
            return
        }
        let isUrgent = gate.isLikelyUrgent(utterance.text)
        if isUrgent {
            urgentQueue.append(Entry(utterance: prepared(utterance), submitted: now, isUrgent: true))
            statistics.maximumQueueLength = max(statistics.maximumQueueLength, queue.count + urgentQueue.count)
            if urgentWorker == nil {
                let generation = generation
                urgentWorker = Task { [weak self] in await self?.drainUrgent(generation: generation) }
            }
            return
        }
        if queue.count >= configuration.queueCapacity {
            // The oldest sentence that does not look like a warning gives way.
            let index = queue.firstIndex { !$0.isUrgent } ?? 0
            report(dropped: queue.remove(at: index))
        }
        let entry = Entry(utterance: prepared(utterance), submitted: now, isUrgent: isUrgent)
        if isUrgent, let index = queue.firstIndex(where: { !$0.isUrgent }) {
            queue.insert(entry, at: index)
        } else {
            queue.append(entry)
        }
        statistics.maximumQueueLength = max(statistics.maximumQueueLength, queue.count)
        // An evaluation of a partial transcript that turned out differently is of no use now.
        provisional = nil
        if let speculativeTask, speculativeTask.key != cacheKey(entry.utterance) {
            speculativeTask.task.cancel()
        }
        startWorkerIfNeeded()
    }

    /// Hands in a partial transcript that has stopped changing (see `StablePartialDetector`).
    /// It is evaluated only while nothing finalized is waiting, and its answer is used only if
    /// the final transcript has the same words. It produces no decision of its own.
    public func submitProvisional(_ utterance: SemanticUtterance) {
        guard isActive, queue.isEmpty, gate.admits(utterance.text) else { return }
        let prepared = prepared(utterance)
        guard cache[cacheKey(prepared)] == nil, speculativeTask?.key != cacheKey(prepared) else { return }
        provisional = prepared
        startWorkerIfNeeded()
    }

    private func prepared(_ utterance: SemanticUtterance) -> SemanticUtterance {
        var utterance = utterance
        utterance.text = gate.clipped(utterance.text)
        utterance.context = Array(utterance.context.suffix(configuration.maximumContextUtterances))
        return utterance
    }

    private func report(dropped entry: Entry) {
        statistics.dropped += 1
        continuation.yield(SemanticAttentionDecision(utteranceID: entry.utterance.id, date: entry.utterance.date,
                                                     verdict: .irrelevant, stage: .dropped))
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !isPaused else { return }
        let generation = generation
        worker = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drainUrgent(generation: Int) async {
        while generation == self.generation, !Task.isCancelled, !urgentQueue.isEmpty {
            let entry = urgentQueue.removeFirst()
            let started = Date()
            var decision = await evaluate(entry.utterance, priority: .urgentCandidate)
            guard generation == self.generation, !Task.isCancelled else { return }
            finish(&decision, entry: entry, started: started)
        }
        if generation == self.generation { urgentWorker = nil }
    }

    private func drain(generation: Int) async {
        while generation == self.generation, !Task.isCancelled, !isPaused {
            if !queue.isEmpty {
                let group = nextGroup()
                if group.count > 1 {
                    await evaluateTogether(group, generation: generation)
                } else if let entry = group.first {
                    let started = Date()
                    var decision = await evaluate(entry.utterance, priority: entry.isUrgent ? .urgentCandidate : .attention)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    finish(&decision, entry: entry, started: started)
                }
            } else if let utterance = provisional {
                provisional = nil
                await speculate(on: utterance, generation: generation)
            } else {
                break
            }
        }
        if generation == self.generation { worker = nil }
    }

    /// The sentences to evaluate next: one, or several waiting ones together.
    private func nextGroup() -> [Entry] {
        while let first = queue.first, Date().timeIntervalSince(first.submitted) > configuration.maximumWait {
            report(dropped: queue.removeFirst())
        }
        guard let first = queue.first else { return [] }
        let canBatch = reasoner.judgesTogether && configuration.batchThreshold > 0
            && queue.count >= configuration.batchThreshold && !first.isUrgent && !first.wasBatched
        guard canBatch else { return [queue.removeFirst()] }
        var group: [Entry] = []
        while group.count < configuration.maximumBatch, let next = queue.first, !next.isUrgent, !next.wasBatched,
              cache[cacheKey(next.utterance)] == nil
        {
            group.append(queue.removeFirst())
        }
        return group.isEmpty ? [queue.removeFirst()] : group
    }

    private func finish(_ decision: inout SemanticAttentionDecision, entry: Entry, started: Date) {
        let now = Date()
        decision.queueWait = started.timeIntervalSince(entry.submitted)
        decision.latency = now.timeIntervalSince(entry.submitted)
        if decision.latency > configuration.deadline {
            decision.isLate = true
            statistics.deadlineMisses += 1
        }
        record(&statistics.queueWaits, decision.queueWait)
        record(&statistics.latencies, decision.latency)
        continuation.yield(decision)
    }

    private func record(_ samples: inout [TimeInterval], _ value: TimeInterval) {
        if samples.count >= sampleLimit { samples.removeFirst(samples.count - sampleLimit + 1) }
        samples.append(value)
    }

    // MARK: - Evaluation

    /// Evaluates one utterance now, through every stage. Used by the queue, the tests and the
    /// evaluation tool.
    public func evaluate(_ utterance: SemanticUtterance,
                         priority: ModelInferenceScheduler.Priority = .attention) async -> SemanticAttentionDecision
    {
        guard isActive else {
            return SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date, verdict: .irrelevant,
                                             stage: .inactive)
        }
        guard gate.admits(utterance.text) else {
            return SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date, verdict: .irrelevant,
                                             stage: .gate)
        }
        let utterance = prepared(utterance)
        let selected = selectGoals(for: utterance.text)
        let key = cacheKey(utterance)

        // A partial transcript with the same words is being evaluated right now: wait for it.
        if let speculativeTask, speculativeTask.key == key { _ = await speculativeTask.task.result }

        var stage = SemanticStage.model
        var modelTime: TimeInterval = 0
        let judgement: RelevanceJudgement
        if let entry = cache[key], entry.goalIDs == selected.map(\.id),
           utterance.date.timeIntervalSince(entry.storedAt) <= configuration.cacheLifetime
        {
            statistics.cacheHits += 1
            if entry.isSpeculative {
                statistics.speculativeHits += 1
                cache[key]?.isSpeculative = false
            }
            judgement = entry.judgement
            stage = entry.isSpeculative ? .speculative : .cache
        } else {
            let started = Date()
            let reasoner = reasoner, subject = utterance, goals = selected
            do {
                if configuration.usesTriage, priority != .urgentCandidate {
                    statistics.triageCalls += 1
                    let passes = try await model(priority) { try await reasoner.couldMatter(subject, goals: goals) }
                    if !passes {
                        statistics.triaged += 1
                        let seconds = Date().timeIntervalSince(started)
                        statistics.totalModelTime += seconds
                        return SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date,
                                                         verdict: .irrelevant, stage: .triage, modelTime: seconds)
                    }
                }
                statistics.modelCalls += 1
                judgement = try await model(priority) { try await reasoner.judge(subject, goals: goals) }
            } catch {
                return failure(error, utterance: utterance, started: started)
            }
            modelTime = judgement.timing?.total ?? Date().timeIntervalSince(started)
            statistics.totalModelTime += modelTime
            statistics.outputTokens += judgement.timing?.outputTokens ?? 0
            store(judgement, key: key, goals: selected, date: utterance.date, isSpeculative: false)
        }
        let checked = await confirmed(judgement, utterance: utterance, goals: selected, key: key, priority: priority)
        if stage == .model { modelTime = checked.timing?.total ?? modelTime }
        return decide(checked, utterance: utterance, goals: selected, stage: stage, modelTime: modelTime)
    }

    /// The second look, where one is due. Its answer is kept with the judgement, so a cached
    /// judgement is not looked at twice.
    private func confirmed(_ judgement: RelevanceJudgement, utterance: SemanticUtterance, goals: [AttentionGoal],
                           key: String, priority: ModelInferenceScheduler.Priority) async -> RelevanceJudgement
    {
        guard configuration.confirmsRelevant, judgement.confirmation == nil, judgement.urgency != .high,
              verifier.verify(judgement, utterance: utterance, goals: goals).verdict == .relevant,
              goals.indices.contains(judgement.goalIndex - 1)
        else { return judgement }
        let goal = goals[judgement.goalIndex - 1]
        var judgement = judgement
        let reasoner = reasoner
        let started = Date()
        // A failed second look leaves the first judgement as it is.
        guard let answer = try? await model(priority, { try await reasoner.confirm(utterance, goal: goal) }) else { return judgement }
        statistics.confirmCalls += 1
        statistics.totalModelTime += Date().timeIntervalSince(started)
        judgement.confirmation = answer
        judgement.timing?.total += Date().timeIntervalSince(started)
        if cache[key] != nil { cache[key]?.judgement = judgement }
        return judgement
    }

    /// Verifier, novelty, counters.
    private func decide(_ judgement: RelevanceJudgement, utterance: SemanticUtterance, goals: [AttentionGoal],
                        stage: SemanticStage, modelTime: TimeInterval) -> SemanticAttentionDecision
    {
        var decision = verifier.verify(judgement, utterance: utterance, goals: goals, stage: stage)
        if decision.corrections.contains("second_look") { statistics.confirmDemoted += 1 }
        decision.hadSecondLook = judgement.confirmation != nil && stage == .model
        decision.modelTime = modelTime
        decision.outputTokens = stage == .model ? judgement.timing?.outputTokens ?? 0 : 0
        if !decision.corrections.isEmpty { statistics.corrected += 1 }
        applyNovelty(to: &decision, utterance: utterance)
        switch decision.verdict {
        case .relevant: if decision.isNovel { statistics.accepted += 1 }
        case .uncertain: statistics.uncertain += 1
        case .irrelevant: break
        }
        return decision
    }

    private func failure(_ error: any Error, utterance: SemanticUtterance, started: Date) -> SemanticAttentionDecision {
        if case SemanticReasonerError.timedOut = error { statistics.timeouts += 1 }
        if case ModelInferenceScheduler.SchedulerError.timedOut = error { statistics.timeouts += 1 }
        statistics.modelFailures += 1
        // No model, no semantic alert. Never a guess from keywords.
        return SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date, verdict: .irrelevant,
                                         stage: .fallback, modelTime: Date().timeIntervalSince(started))
    }

    /// Several waiting sentences in one request.
    private func evaluateTogether(_ group: [Entry], generation: Int) async {
        let started = Date()
        let utterances = group.map(\.utterance)
        let selected = selectGoals(for: utterances.map(\.text).joined(separator: " "))
        statistics.batchCalls += 1
        statistics.batchedUtterances += group.count
        let reasoner = reasoner
        let answer: BatchJudgement
        do {
            answer = try await model(.attention) { try await reasoner.judgeTogether(utterances, goals: selected) }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            // The group request failed: each sentence still gets its own.
            requeue(group)
            statistics.modelFailures += 1
            return
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        let modelTime = answer.judgement.timing?.total ?? Date().timeIntervalSince(started)
        statistics.totalModelTime += modelTime
        statistics.outputTokens += answer.judgement.timing?.outputTokens ?? 0
        let named = answer.line - 1
        if answer.judgement.verdict == .irrelevant || answer.judgement.goalIndex == 0 {
            // Nothing in the group matters: all settled by one request.
            for entry in group {
                statistics.settledByBatch += 1
                var decision = SemanticAttentionDecision(
                    utteranceID: entry.utterance.id, date: entry.utterance.date, verdict: .irrelevant,
                    statementKind: answer.judgement.statementKind, stage: .batch, modelTime: modelTime / Double(group.count))
                decision.batchSize = group.count
                finish(&decision, entry: entry, started: started)
            }
        } else if group.indices.contains(named) {
            // One sentence is named: it is decided here, the others are judged on their own.
            let entry = group[named]
            let checked = await confirmed(answer.judgement, utterance: entry.utterance, goals: selected,
                                          key: cacheKey(entry.utterance), priority: .attention)
            guard generation == self.generation, !Task.isCancelled else { return }
            var decision = decide(checked, utterance: entry.utterance, goals: selected, stage: .batch,
                                  modelTime: modelTime)
            decision.batchSize = group.count
            decision.outputTokens = answer.judgement.timing?.outputTokens ?? 0
            finish(&decision, entry: entry, started: started)
            requeue(group.enumerated().filter { $0.offset != named }.map(\.element))
        } else {
            requeue(group)
        }
    }

    /// Back to the front of the queue, in their order, each to be judged on its own.
    private func requeue(_ entries: [Entry]) {
        statistics.requeuedAfterBatch += entries.count
        let marked = entries.map { entry in
            var entry = entry
            entry.wasBatched = true
            return entry
        }
        let index = queue.firstIndex { !$0.isUrgent } ?? queue.count
        queue.insert(contentsOf: marked, at: index)
    }

    /// Evaluates a stable partial transcript and keeps the answer for the final text.
    private func speculate(on utterance: SemanticUtterance, generation: Int) async {
        let selected = selectGoals(for: utterance.text)
        let key = cacheKey(utterance)
        guard cache[key] == nil else { return }
        statistics.speculativeCalls += 1
        let reasoner = reasoner, scheduler = scheduler, timeout = configuration.timeout
        let task = Task {
            try await scheduler.run(.background, timeout: timeout) { try await reasoner.judge(utterance, goals: selected) }
        }
        speculativeTask = (key, task)
        let result = await task.result
        guard generation == self.generation else { return }
        if speculativeTask?.key == key { speculativeTask = nil }
        switch result {
        case .success(let judgement):
            statistics.totalModelTime += judgement.timing?.total ?? 0
            statistics.outputTokens += judgement.timing?.outputTokens ?? 0
            store(judgement, key: key, goals: selected, date: utterance.date, isSpeculative: true)
        case .failure:
            statistics.speculativeCancelled += 1
        }
    }

    private func model<Value: Sendable>(_ priority: ModelInferenceScheduler.Priority,
                                        _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value
    {
        try await scheduler.run(priority, timeout: configuration.timeout, operation: operation)
    }

    /// The words of the utterance and of its context: the same words in the same context get
    /// the same answer.
    private func cacheKey(_ utterance: SemanticUtterance) -> String {
        (utterance.context.suffix(configuration.maximumContextUtterances) + [utterance.text])
            .map { SemanticText.words(in: $0).joined(separator: " ") }.joined(separator: "|")
    }

    private func store(_ judgement: RelevanceJudgement, key: String, goals: [AttentionGoal], date: Date, isSpeculative: Bool) {
        if cache.count >= configuration.cacheCapacity,
           let oldest = cache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key
        {
            cache[oldest] = nil
        }
        cache[key] = CacheEntry(judgement: judgement, goalIDs: goals.map(\.id), storedAt: date, isSpeculative: isSpeculative)
    }

    private func selectGoals(for text: String) -> [AttentionGoal] {
        guard goals.count > AttentionGoal.maximumActive, let scorer else {
            return Array(goals.prefix(AttentionGoal.maximumActive))
        }
        let ranked = goals.enumerated().map { (index: $0.offset, score: scorer.score(utterance: text, goal: $0.element.text)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(AttentionGoal.maximumActive).map(\.index).sorted()
        return ranked.map { goals[$0] }
    }

    /// A statement that was accepted a short while ago (a repeated
    /// announcement) is marked as not novel and is not presented again. A statement that
    /// differs in a negation, a number or a day is a new one.
    private func applyNovelty(to decision: inout SemanticAttentionDecision, utterance: SemanticUtterance) {
        accepted.removeAll { utterance.date.timeIntervalSince($0.date) > configuration.noveltyWindow }
        guard decision.verdict == .relevant, let goalID = decision.matchedGoalID else { return }
        let statement = SemanticText.withoutRepetitionMarker(utterance.text)
        let stems = SemanticText.stems(in: statement)
        let isNegated = SemanticText.isNegated(statement)
        let quantities = SemanticText.quantities(in: statement)
        let isRepeat = accepted.contains {
            // Whatever goal is named this time: the model may file the same announcement under
            // "grades" once and under "schedule" the next time.
            $0.isNegated == isNegated && $0.quantities == quantities
                && SemanticText.jaccard($0.stems, stems) >= configuration.noveltySimilarity
        }
        if isRepeat {
            decision.isNovel = false
            decision.presentation = .none
            statistics.repeated += 1
        } else {
            accepted.append(Accepted(goalID: goalID, stems: stems, isNegated: isNegated, quantities: quantities,
                                     date: utterance.date))
        }
    }
}
