import Foundation

/// Matches what is said nearby against the user's goals by reasoning about meaning (Window 6).
///
/// Stages, cheapest first, so the language model runs only where it is useful:
/// 1. `UtteranceGate`: fillers and backchannel never reach a model.
/// 2. Cache: an utterance that was just decided is not decided again.
/// 3. Goal selection: with many goals, the closest ones by a cheap similarity score.
/// 4. The language model, twice at most: a one-word first pass ("could this matter at all?"),
///    then the full judgement only on a yes (`SemanticRelevanceReasoning`).
/// 5. `EvidenceVerifier`: deterministic checks that can only make the result more cautious.
/// 6. Novelty: the same statement accepted a short while ago is not accepted again.
///
/// One evaluation runs at a time. Waiting utterances are bounded: when the queue is full the
/// oldest one is dropped (the newest speech matters most) and counted. Short utterances with a
/// word of alarm go to the front. This module never delays the attention engine's own phrase
/// rule ("Watch out!"), which does not pass through here.
///
/// Decisions hold speech-derived text. `statistics` and `redactedSummary` do not.
public actor SemanticAttentionEngine {
    public struct Configuration: Hashable, Sendable {
        /// Utterances that may wait while one is being evaluated.
        public var queueCapacity = 4
        /// An utterance older than this when its turn comes is dropped: a late alert is worse than none.
        public var maximumWait: TimeInterval = 12
        /// The model's answer is abandoned after this long.
        public var timeout: TimeInterval = 8
        public var cacheCapacity = 32
        public var cacheLifetime: TimeInterval = 120
        /// A statement accepted within this time is not accepted again.
        public var noveltyWindow: TimeInterval = 300
        /// Word overlap (Jaccard, by stem) from which two statements count as the same.
        public var noveltySimilarity = 0.6
        public var maximumContextUtterances = 3
        /// Ask the model a one-word question first and run the full judgement only on a yes.
        /// Utterances with a word of alarm skip the first pass: nothing that sounds like a
        /// warning is decided by the cheaper question.
        public var usesTriage = true

        public init() {}

        public static let standard = Configuration()
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
        public var dropped = 0
        public var accepted = 0
        public var uncertain = 0
        public var repeated = 0
        public var corrected = 0
        public var maximumQueueLength = 0
        public var totalModelTime: TimeInterval = 0

        public init() {}
    }

    private struct CacheEntry {
        var judgement: RelevanceJudgement
        var goalIDs: [UUID]
        var storedAt: Date
    }

    private struct Accepted {
        var goalID: UUID
        var stems: Set<String>
        var isNegated: Bool
        var quantities: Set<String>
        var date: Date
    }

    private let reasoner: any SemanticRelevanceReasoning
    private let scorer: (any GoalSimilarityScoring)?
    private let gate: UtteranceGate
    private let verifier: EvidenceVerifier
    public let configuration: Configuration

    private var goals: [AttentionGoal] = []
    private var isEnabled = true
    private var queue: [(utterance: SemanticUtterance, submitted: Date)] = []
    private var worker: Task<Void, Never>?
    private var cache: [String: CacheEntry] = [:]
    private var accepted: [Accepted] = []
    private var generation = 0
    public private(set) var statistics = Statistics()

    private let continuation: AsyncStream<SemanticAttentionDecision>.Continuation
    /// Every decision for a submitted utterance, in the order they were made. One consumer.
    public nonisolated let decisions: AsyncStream<SemanticAttentionDecision>

    public init(reasoner: any SemanticRelevanceReasoning, scorer: (any GoalSimilarityScoring)? = nil,
                gate: UtteranceGate = UtteranceGate(), verifier: EvidenceVerifier = .standard,
                configuration: Configuration = .standard)
    {
        self.reasoner = reasoner
        self.scorer = scorer
        self.gate = gate
        self.verifier = verifier
        self.configuration = configuration
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

    public func prewarm() async {
        guard isActive else { return }
        await reasoner.prewarm()
    }

    /// Forgets everything speech-derived: waiting utterances, cached answers and the memory of
    /// accepted statements. Called when the session ends or the user clears speech data.
    public func reset() {
        generation += 1
        worker?.cancel()
        worker = nil
        queue.removeAll()
        cache.removeAll()
        accepted.removeAll()
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
        if queue.count >= configuration.queueCapacity {
            let oldest = queue.removeFirst()
            statistics.dropped += 1
            continuation.yield(SemanticAttentionDecision(utteranceID: oldest.utterance.id, date: oldest.utterance.date,
                                                         verdict: .irrelevant, stage: .dropped))
        }
        if gate.isLikelyUrgent(utterance.text) {
            queue.insert((utterance, now), at: 0)
        } else {
            queue.append((utterance, now))
        }
        statistics.maximumQueueLength = max(statistics.maximumQueueLength, queue.count)
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let generation = generation
        worker = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drain(generation: Int) async {
        while generation == self.generation, !Task.isCancelled, !queue.isEmpty {
            let (utterance, submitted) = queue.removeFirst()
            if Date().timeIntervalSince(submitted) > configuration.maximumWait {
                statistics.dropped += 1
                continuation.yield(SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date,
                                                             verdict: .irrelevant, stage: .dropped))
                continue
            }
            var decision = await evaluate(utterance)
            guard generation == self.generation, !Task.isCancelled else { return }
            decision.latency = Date().timeIntervalSince(submitted)
            continuation.yield(decision)
        }
        if generation == self.generation { worker = nil }
    }

    // MARK: - Evaluation

    /// Evaluates one utterance now, through every stage. Used by the queue, the tests and the
    /// evaluation tool.
    public func evaluate(_ utterance: SemanticUtterance) async -> SemanticAttentionDecision {
        guard isActive else {
            return SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date, verdict: .irrelevant,
                                             stage: .inactive)
        }
        guard gate.admits(utterance.text) else {
            return SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date, verdict: .irrelevant,
                                             stage: .gate)
        }
        var utterance = utterance
        utterance.text = gate.clipped(utterance.text)
        utterance.context = Array(utterance.context.suffix(configuration.maximumContextUtterances))
        let selected = selectGoals(for: utterance.text)

        let key = SemanticText.words(in: utterance.text).joined(separator: " ")
        var stage = SemanticStage.model
        var modelTime: TimeInterval = 0
        let judgement: RelevanceJudgement
        if let entry = cache[key], entry.goalIDs == selected.map(\.id),
           utterance.date.timeIntervalSince(entry.storedAt) <= configuration.cacheLifetime, utterance.context.isEmpty
        {
            statistics.cacheHits += 1
            judgement = entry.judgement
            stage = .cache
        } else {
            let started = Date()
            let reasoner = reasoner, subject = utterance, goals = selected
            do {
                if configuration.usesTriage, !gate.isLikelyUrgent(utterance.text) {
                    statistics.triageCalls += 1
                    let passes = try await withTimeout { try await reasoner.couldMatter(subject, goals: goals) }
                    if !passes {
                        statistics.triaged += 1
                        let seconds = Date().timeIntervalSince(started)
                        statistics.totalModelTime += seconds
                        return SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date,
                                                         verdict: .irrelevant, stage: .triage, modelTime: seconds)
                    }
                }
                statistics.modelCalls += 1
                judgement = try await withTimeout { try await reasoner.judge(subject, goals: goals) }
            } catch {
                if case SemanticReasonerError.timedOut = error { statistics.timeouts += 1 }
                statistics.modelFailures += 1
                // No model, no semantic alert. Never a guess from keywords.
                return SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date, verdict: .irrelevant,
                                                 stage: .fallback, modelTime: Date().timeIntervalSince(started))
            }
            modelTime = Date().timeIntervalSince(started)
            statistics.totalModelTime += modelTime
            if utterance.context.isEmpty {
                if cache.count >= configuration.cacheCapacity,
                   let oldest = cache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key
                {
                    cache[oldest] = nil
                }
                cache[key] = CacheEntry(judgement: judgement, goalIDs: selected.map(\.id), storedAt: utterance.date)
            }
        }

        var decision = verifier.verify(judgement, utterance: utterance, goals: selected, stage: stage)
        decision.modelTime = modelTime
        if !decision.corrections.isEmpty { statistics.corrected += 1 }
        applyNovelty(to: &decision, utterance: utterance)
        switch decision.verdict {
        case .relevant: if decision.isNovel { statistics.accepted += 1 }
        case .uncertain: statistics.uncertain += 1
        case .irrelevant: break
        }
        return decision
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

    private func withTimeout<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let timeout = configuration.timeout
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw SemanticReasonerError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SemanticReasonerError.timedOut }
            return first
        }
    }

    /// A statement that was accepted a short while ago (a repeated
    /// announcement) is marked as not novel and is not presented again. A statement that
    /// differs in a negation, a number or a day is a new one.
    private func applyNovelty(to decision: inout SemanticAttentionDecision, utterance: SemanticUtterance) {
        accepted.removeAll { utterance.date.timeIntervalSince($0.date) > configuration.noveltyWindow }
        guard decision.verdict == .relevant, let goalID = decision.matchedGoalID else { return }
        let stems = SemanticText.stems(in: utterance.text)
        let isNegated = SemanticText.isNegated(utterance.text)
        let quantities = SemanticText.quantities(in: utterance.text)
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
