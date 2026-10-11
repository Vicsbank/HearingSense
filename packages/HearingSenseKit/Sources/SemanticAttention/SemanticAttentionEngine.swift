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
/// - A sentence that looks like a warning goes first, in a lane of its own.
/// - The others are served oldest first while the model keeps up, and newest first while it is
///   behind and speech keeps arriving (`ServingOrder`).
/// - Nothing is discarded without a decision that says so: an utterance pushed out of a full
///   queue (`.dropped`) or one that waited longer than `maximumWait` (`.expired`) is reported
///   and counted.
///
/// This module never delays the attention engine's own phrase rule ("Watch out!"), which does
/// not pass through here and does not use the language model.
///
/// Decisions hold speech-derived text. `statistics` and `redactedSummary` do not.
public actor SemanticAttentionEngine {
    public struct Configuration: Hashable, Sendable {
        /// Utterances that may wait while one is being evaluated. Large enough that the time
        /// limit (`maximumWait`) is what ends a wait, not this number.
        public var queueCapacity = 36
        /// An utterance older than this when its turn comes is given up (reported and counted).
        /// Thirty seconds since Window 6.2: a sentence left behind while speech went on is still
        /// worth deciding in the next pause ("the exam moved to Friday" half a minute late), and
        /// with the newest sentence served first the old ones delay nobody.
        public var maximumWait: TimeInterval = 30
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
        /// Window 6.3. Give the model the sentence before only when the sentence cannot be
        /// understood without it ("It got moved to Friday", "No, three"); then that one sentence.
        /// A sentence that stands by itself is judged by itself: what happened to be said before
        /// it does not change its answer. (Measured: see the Window 6.3 report, "context".)
        public var givesContextOnlyToLeaningSentences = true
        /// Ask the model a one-word question first and run the full judgement only on a yes.
        /// Off since Window 6.1: the full judgement became fast enough that the extra request
        /// costs more than it saves (measured; see the optimization report).
        public var usesTriage = false
        /// Take a second, narrower look at a sentence that was judged relevant (not at warnings)
        /// before it is accepted. It can only make the decision more cautious.
        public var confirmsRelevant = true
        /// Also take the second look at a sentence the model called a warning (Window 6.2).
        /// Without it the model's word alone would make an alert urgent.
        public var confirmsWarnings = true
        /// Tell the second look which accepted statements a sentence may repeat (Window 6.2).
        public var asksAboutRepetition = true
        /// A sentence that stayed silent on the word of a session that had already answered for
        /// other sentences (only while sentences were waiting) is judged once more, in a session
        /// of its own, as soon as nothing waits. If it alerts then, the alert is late but not
        /// lost. Measured: with a continued session 3–4 of 223 decisions differ from those of a
        /// session per sentence; in the stream benchmarks one relevant sentence of six stayed
        /// silent that way.
        public var rechecksContinuedAnswers = true
        /// Sentences kept for that second judgement, and how old one may be.
        public var recheckCapacity = 24
        public var recheckLifetime: TimeInterval = 60
        /// Prepare the next request's session whenever nothing is waiting (Window 6.2). Off for
        /// a reasoner that keeps one session for several sentences: preparing another one makes
        /// the system forget what the kept one has read.
        public var preparesWhenIdle = true
        /// Which waiting sentence is evaluated next (Window 6.2).
        public var servingOrder = ServingOrder.newestWhenBehind
        /// The line is behind when its oldest sentence has waited this long.
        public var behindAfter: TimeInterval = 3
        /// No sentence for this long is a pause in the speech.
        public var pauseInterval: TimeInterval = 1.5
        /// Window 6.3. Compare what a sentence says about whom it is for with what the listener
        /// wrote about themselves (`AudienceAnalyzer`): a sentence for another group, or for
        /// another person about that person's own business, is not alerted.
        public var usesAudienceCues = true
        /// Window 6.3. Hold back a sentence that begins with a group of the same kind as the
        /// listener's but another one ("blue bus" for a listener on the red bus) on the word of
        /// the rule alone. **Off since the sealed evaluation.** It was on when the configuration
        /// was frozen (`window6_3Frozen`), and on the sealed set it took back 7 correct alerts for
        /// 4 false ones: "The laundry room closes at eight" for a listener in dorm 6, and
        /// sentences that begin with another group but go on to say what follows for all. Recall
        /// comes first in this project, so the rule no longer decides; the cue is still found and
        /// reported with the decision. What it should become is a narrow question to the model,
        /// as for a person called by name; that needs a new held-out set to be measured.
        public var holdsBackOtherGroups = false
        /// Window 6.3. A sentence that calls the listener by name alerts under the goal about
        /// being spoken to, whatever the model made of it.
        public var alertsWhenCalledByName = true
        /// Window 6.3. A sentence that stops before it has said anything is not alerted.
        public var holdsBackCutOffSentences = true
        /// Window 6.3. Two things a speaker says in so many words are taken at their word: that
        /// nothing is different ("the same as before", "as usual"), and that this is a reminder
        /// of something the listener was already alerted to ("Don't forget, …").
        public var takesSpeakersAtTheirWord = true

        public init() {}

        public static let standard = Configuration()

        /// The configuration that was frozen and run on the sealed set of Window 6.3 (commit
        /// `1e269b8`): as `standard`, with the rule for another group deciding by itself.
        public static var window6_3Frozen: Configuration {
            var configuration = Configuration()
            configuration.holdsBackOtherGroups = true
            return configuration
        }

        /// How the engine behaved in Window 6.2, for comparisons: nothing is known about the
        /// listener, and nothing is done about cut-off sentences.
        public static var window6_2: Configuration {
            var configuration = Configuration()
            configuration.usesAudienceCues = false
            configuration.alertsWhenCalledByName = false
            configuration.holdsBackCutOffSentences = false
            configuration.takesSpeakersAtTheirWord = false
            configuration.givesContextOnlyToLeaningSentences = false
            return configuration
        }

        /// How the engine behaved in Window 6, for comparisons: a first pass before every
        /// judgement, four waiting utterances with the oldest discarded, nothing judged
        /// together, no second look.
        public static var window6: Configuration {
            var configuration = Configuration.window6_2
            configuration.queueCapacity = 4
            configuration.maximumWait = 12
            configuration.usesTriage = true
            configuration.confirmsRelevant = false
            configuration.confirmsWarnings = false
            configuration.asksAboutRepetition = false
            configuration.preparesWhenIdle = false
            configuration.servingOrder = .oldestFirst
            return configuration
        }

        /// How the engine behaved in Window 6.1, for comparisons: twelve waiting sentences
        /// served oldest first, given up after twenty seconds.
        public static var window6_1: Configuration {
            var configuration = Configuration.window6_2
            configuration.queueCapacity = 12
            configuration.maximumWait = 20
            configuration.confirmsWarnings = false
            configuration.asksAboutRepetition = false
            configuration.preparesWhenIdle = false
            configuration.servingOrder = .oldestFirst
            return configuration
        }
    }

    /// The order in which waiting sentences are evaluated.
    public enum ServingOrder: String, Hashable, Sendable {
        /// In the order they were said, always.
        case oldestFirst
        /// In the order they were said while the model keeps up. While it is behind and speech
        /// keeps arriving, the newest sentence goes first: what was just said is what the
        /// listener can still act on, and the decisions that are made stay fresh. In a pause the
        /// oldest goes first again, because it is the one closest to being given up. A sentence
        /// that has waited `maximumWait` is given up, visibly.
        ///
        /// Chosen by simulation and measurement (Window 6.2 report): under lasting overload it
        /// decides as many sentences as oldest-first does, seconds earlier; after a burst it
        /// loses fewer than newest-first alone.
        case newestWhenBehind
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
        /// Of those, the ones that waited longer than `maximumWait` (the others were pushed out
        /// of a full line).
        public var expired = 0
        /// Sentences evaluated ahead of older ones because the line was behind.
        public var servedNewestFirst = 0
        /// Requests asked a second time after the model failed.
        public var retries = 0
        /// First answers given by a session that had answered for an earlier sentence (only
        /// while sentences were waiting; see `FoundationModelRelevanceReasoner.Reuse`).
        public var continuedSessions = 0
        /// Of those that stayed silent: judged again in a session of their own, and how many of
        /// these alerted after all (late).
        public var rechecks = 0
        public var recheckAlerts = 0
        public var accepted = 0
        public var uncertain = 0
        public var repeated = 0
        public var corrected = 0
        public var maximumQueueLength = 0
        public var totalModelTime: TimeInterval = 0
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
        /// Window 6.3: sentences that named another group; requests about a sentence that called
        /// a person by name, and how many of them said it was that person's own business;
        /// alerts because the listener's name was called; sentences held back as cut off.
        public var otherGroupSentences = 0
        public var concernCalls = 0
        public var concernDemoted = 0
        public var calledByName = 0
        public var cutOff = 0
        public var markedReminders = 0
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
        var text: String
        var stems: Set<String>
        var isNegated: Bool
        var quantities: Set<String>
        var date: Date
    }

    private struct Entry {
        var utterance: SemanticUtterance
        var submitted: Date
        var isUrgent: Bool
    }

    private let reasoner: any SemanticRelevanceReasoning
    private let scorer: (any GoalSimilarityScoring)?
    private let gate: UtteranceGate
    private let verifier: EvidenceVerifier
    public let configuration: Configuration
    public nonisolated let scheduler: ModelInferenceScheduler

    private var goals: [AttentionGoal] = []
    /// What the listener wrote about themselves, and what was read from it and from the goals.
    private var about = ""
    public private(set) var listener = ListenerProfile.unknown
    private var listenerTask: Task<Void, Never>?
    private var isEnabled = true
    private var queue: [Entry] = []
    /// The stable partial transcript waiting to be evaluated ahead of its final form.
    private var provisional: SemanticUtterance?
    private var speculativeTask: (key: String, task: Task<RelevanceJudgement, any Error>)?
    private var worker: Task<Void, Never>?
    /// Sentences that look like a warning have a lane of their own: they do not stand behind
    /// an ordinary sentence that is itself waiting for the model (for a recap to finish, say).
    /// Decided silent by a continued session; judged again when nothing waits.
    private var recheckQueue: [Entry] = []
    private var urgentQueue: [Entry] = []
    private var urgentWorker: Task<Void, Never>?
    private var cache: [String: CacheEntry] = [:]
    private var accepted: [Accepted] = []
    private var generation = 0
    private var lastSubmission = Date.distantPast
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
        var verifier = verifier
        verifier.requiresSecondLookForUrgency = configuration.confirmsRelevant && configuration.confirmsWarnings
        verifier.checksNoChangeMarkers = configuration.takesSpeakersAtTheirWord
        self.verifier = verifier
        self.configuration = configuration
        self.scheduler = scheduler
        (decisions, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    // MARK: - Control

    /// - Parameter about: the listener's optional line about themselves ("I'm Nora, on the red
    ///   bus with group B"). Typed by them, kept on the device, used only to tell whether a
    ///   sentence that names someone means them.
    public func setGoals(_ goals: [AttentionGoal], about: String = "") {
        let active = goals.filter { $0.isEnabled && !$0.text.isEmpty }
        let about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active != self.goals || about != self.about else { return }
        self.goals = active
        self.about = about
        cache.removeAll()
        // What rules can read is there at once; what the model copies out of the goals follows.
        listener = configuration.usesAudienceCues ? .byRule(about: about, goals: active) : .unknown
        listenerTask?.cancel()
        listenerTask = nil
        // The model is only needed for a goal that says something about the listener in passing.
        guard configuration.usesAudienceCues, active.contains(where: { ListenerIdentity.speaksOfSelf($0.text) }) else { return }
        listenerTask = Task { [weak self, reasoner, scheduler, timeout = configuration.timeout] in
            let profile = try? await scheduler.run(.background, timeout: timeout * 2) {
                try await reasoner.describeListener(about: about, goals: active)
            }
            guard let profile, !Task.isCancelled else { return }
            await self?.setListener(profile, about: about, goals: active)
        }
    }

    private func setListener(_ profile: ListenerProfile, about: String, goals: [AttentionGoal]) {
        guard about == self.about, goals == self.goals else { return }
        listener = profile
    }

    /// Waits until what the listener wrote has been read (the evaluation tool and the tests).
    public func listenerIsDescribed() async {
        await listenerTask?.value
    }

    public func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        if !isEnabled { reset() }
    }

    public var isActive: Bool { isEnabled && !goals.isEmpty }

    public var queueLength: Int { queue.count }

    /// Nothing waits, nothing is being evaluated, and no second judgement is due.
    public var isIdle: Bool {
        worker == nil && urgentWorker == nil && queue.isEmpty && urgentQueue.isEmpty && recheckQueue.isEmpty
    }

    /// Sentences submitted and not yet being evaluated, the warning lane included.
    public var waitingCount: Int { queue.count + urgentQueue.count }

    /// Holds back new evaluations. Since Window 6.1 a recap does not need this: it takes its
    /// turn through the scheduler, ahead of goal matching. Kept for hosts without a scheduler.
    public func setPaused(_ isPaused: Bool) {
        guard isPaused != self.isPaused else { return }
        self.isPaused = isPaused
        if !isPaused, !queue.isEmpty || provisional != nil || !recheckQueue.isEmpty { startWorkerIfNeeded() }
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
        recheckQueue.removeAll()
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
        lastSubmission = now
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
        if configuration.givesContextOnlyToLeaningSentences {
            utterance.context = SemanticText.leansOnContext(utterance.text) ? Array(utterance.context.suffix(1)) : []
        } else {
            utterance.context = Array(utterance.context.suffix(configuration.maximumContextUtterances))
        }
        return utterance
    }

    /// Not evaluated, and said so: the decision carries the stage and how long it waited.
    private func report(dropped entry: Entry, expired: Bool = false) {
        statistics.dropped += 1
        if expired { statistics.expired += 1 }
        var decision = SemanticAttentionDecision(utteranceID: entry.utterance.id, date: entry.utterance.date,
                                                 verdict: .irrelevant, stage: expired ? .expired : .dropped)
        decision.queueWait = Date().timeIntervalSince(entry.submitted)
        decision.latency = decision.queueWait
        continuation.yield(decision)
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
                if let entry = nextEntry() {
                    let started = Date()
                    var decision = await evaluate(entry.utterance, priority: entry.isUrgent ? .urgentCandidate : .attention)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    finish(&decision, entry: entry, started: started)
                    if configuration.rechecksContinuedAnswers, decision.usedContinuedSession, decision.verdict == .irrelevant {
                        if recheckQueue.count >= configuration.recheckCapacity { recheckQueue.removeFirst() }
                        recheckQueue.append(entry)
                    }
                }
            } else if let utterance = provisional {
                provisional = nil
                await speculate(on: utterance, generation: generation)
            } else if !recheckQueue.isEmpty {
                await recheck(recheckQueue.removeFirst(), generation: generation)
            } else {
                break
            }
        }
        guard generation == self.generation else { return }
        worker = nil
        // Nothing is waiting: the next request's session can read the instructions and the goals
        // now. (Only now: prepared while a sentence waits, it would make that sentence slower.)
        if configuration.preparesWhenIdle, queue.isEmpty, urgentQueue.isEmpty, isActive {
            let goals = selectGoals(for: "")
            Task { [reasoner] in await reasoner.prewarm(goals: goals) }
        }
    }

    /// The second judgement of a sentence that a continued session called silent: in a session
    /// of its own, with nothing of the earlier answer used. Only an alert is reported (as a
    /// second, late decision for the same utterance); a second "silent" changes nothing.
    private func recheck(_ entry: Entry, generation: Int) async {
        guard Date().timeIntervalSince(entry.submitted) <= configuration.recheckLifetime else { return }
        statistics.rechecks += 1
        cache[cacheKey(entry.utterance)] = nil
        await reasoner.forget()
        let started = Date()
        var decision = await evaluate(entry.utterance, priority: .background)
        guard generation == self.generation, !Task.isCancelled, decision.isAccepted else { return }
        statistics.recheckAlerts += 1
        decision.corrections.append("alert_on_second_judgement")
        finish(&decision, entry: entry, started: started)
    }

    /// The sentence to evaluate next, after giving up those that have waited too long.
    private func nextEntry() -> Entry? {
        let now = Date()
        while let first = queue.first, now.timeIntervalSince(first.submitted) > configuration.maximumWait {
            report(dropped: queue.removeFirst(), expired: true)
        }
        guard let first = queue.first else { return nil }
        if configuration.servingOrder == .newestWhenBehind, queue.count > 1,
           now.timeIntervalSince(first.submitted) > configuration.behindAfter,
           now.timeIntervalSince(lastSubmission) < configuration.pauseInterval
        {
            statistics.servedNewestFirst += 1
            return queue.removeLast()
        }
        return queue.removeFirst()
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

        let started = Date()
        let outcome: Outcome
        do {
            // One turn for everything this utterance needs from the model: the first answer and
            // the second look. Given back in between, an ordinary sentence would get in before
            // the second look of a warning.
            let usesTriage = configuration.usesTriage && priority != .urgentCandidate
            outcome = try await scheduler.run(priority, timeout: configuration.timeout) { [self] in
                try await answers(for: utterance, goals: selected, key: key, usesTriage: usesTriage)
            }
        } catch {
            return failure(error, utterance: utterance, started: started)
        }
        switch outcome {
        case .triaged(let seconds):
            return SemanticAttentionDecision(utteranceID: utterance.id, date: utterance.date, verdict: .irrelevant,
                                             stage: .triage, modelTime: seconds)
        case .judged(let judgement, let stage, let modelTime):
            return decide(judgement, utterance: utterance, goals: selected, stage: stage, modelTime: modelTime)
        }
    }

    private enum Outcome: Sendable {
        case triaged(TimeInterval)
        case judged(RelevanceJudgement, SemanticStage, TimeInterval)
    }

    /// The model's answers for one utterance. Runs inside one turn of the scheduler.
    private func answers(for utterance: SemanticUtterance, goals selected: [AttentionGoal], key: String,
                         usesTriage: Bool) async throws -> Outcome
    {
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
            if usesTriage {
                statistics.triageCalls += 1
                if try await !reasoner.couldMatter(utterance, goals: selected) {
                    statistics.triaged += 1
                    let seconds = Date().timeIntervalSince(started)
                    statistics.totalModelTime += seconds
                    return .triaged(seconds)
                }
            }
            statistics.modelCalls += 1
            judgement = try await reasoner.judge(utterance, goals: selected)
            modelTime = judgement.timing?.total ?? Date().timeIntervalSince(started)
            statistics.totalModelTime += modelTime
            statistics.outputTokens += judgement.timing?.outputTokens ?? 0
            if judgement.timing?.retried == true { statistics.retries += 1 }
            if judgement.timing?.continuedSession == true { statistics.continuedSessions += 1 }
            store(judgement, key: key, goals: selected, date: utterance.date, isSpeculative: false)
        }
        let placed = await placed(judgement, utterance: utterance, goals: selected, key: key)
        let checked = await confirmed(placed, utterance: utterance, goals: selected, key: key)
        if stage == .model { modelTime = checked.timing?.total ?? modelTime }
        return .judged(checked, stage, modelTime)
    }

    /// Window 6.3: whom the sentence is for, as far as its own words and the listener's own text
    /// can tell. Rules find the cue; the model is asked one narrow question, and only when the
    /// sentence calls a person by name who is not, or may not be, the listener.
    private func placed(_ judgement: RelevanceJudgement, utterance: SemanticUtterance, goals: [AttentionGoal],
                        key: String) async -> RelevanceJudgement
    {
        guard judgement.audience == nil, !judgement.isCutOff, !judgement.isCalledByName else { return judgement }
        var judgement = judgement
        let wouldAlert = verifier.verify(judgement, utterance: utterance, goals: goals).verdict == .relevant
        let cue = configuration.usesAudienceCues ? AudienceAnalyzer.cue(in: utterance.text, identity: listener.identity) : .none
        // A sentence that looks like a warning is never held back by any of this.
        let looksUrgent = gate.isLikelyUrgent(utterance.text)
        if !wouldAlert {
            // The listener's own name, and a goal that asks to be told when someone speaks to them.
            guard cue.kind == .listenerNamed, configuration.alertsWhenCalledByName,
                  self.goals.indices.contains(listener.spokenToGoal - 1),
                  let index = goals.firstIndex(where: { $0.id == self.goals[listener.spokenToGoal - 1].id })
            else { return judgement }
            let timing = judgement.timing
            judgement = RelevanceJudgement(goalIndex: index + 1, verdict: .relevant, statementKind: .question)
            judgement.timing = timing
            judgement.isCalledByName = true
            statistics.calledByName += 1
        } else if configuration.holdsBackCutOffSentences, !looksUrgent, SemanticText.isCutOff(utterance.text) {
            judgement.isCutOff = true
            statistics.cutOff += 1
        } else if !looksUrgent {
            switch cue.kind {
            case .otherGroup:
                statistics.otherGroupSentences += 1
                if configuration.holdsBackOtherGroups { judgement.audience = .otherGroup }
            case .otherPerson, .unknownPerson:
                let started = Date()
                // No answer: it was said to someone else, and nothing says it is for everyone.
                let concern = try? await reasoner.concern(of: utterance)
                statistics.concernCalls += 1
                statistics.totalModelTime += Date().timeIntervalSince(started)
                judgement.timing?.total += Date().timeIntervalSince(started)
                if concern != .everyones {
                    judgement.audience = cue.kind
                    statistics.concernDemoted += 1
                }
            case .none, .listenerNamed, .listenerGroup:
                break
            }
        } else {
            return judgement
        }
        if cache[key] != nil { cache[key]?.judgement = judgement }
        return judgement
    }

    /// The second look, where one is due. Its answer is kept with the judgement, so a cached
    /// judgement is not looked at twice.
    private func confirmed(_ judgement: RelevanceJudgement, utterance: SemanticUtterance, goals: [AttentionGoal],
                           key: String) async -> RelevanceJudgement
    {
        guard configuration.confirmsRelevant, judgement.confirmation == nil, !judgement.isCalledByName,
              configuration.confirmsWarnings || judgement.urgency != .high,
              verifier.verify(judgement, utterance: utterance, goals: goals).verdict == .relevant,
              goals.indices.contains(judgement.goalIndex - 1)
        else { return judgement }
        let goal = goals[judgement.goalIndex - 1]
        var judgement = judgement
        let started = Date()
        let earlier = configuration.asksAboutRepetition
            ? SemanticRepetition.candidates(for: utterance.text, among: accepted.filter {
                utterance.date.timeIntervalSince($0.date) <= configuration.noveltyWindow
            }.map(\.text)) : []
        if configuration.takesSpeakersAtTheirWord, !earlier.isEmpty, SemanticText.hasRepetitionMarker(utterance.text) {
            // "Reminder, …" of something that shares its words with an alert of a moment ago:
            // the speaker says it is not news, and no model is needed to agree.
            judgement.confirmation = .saidBefore
            statistics.markedReminders += 1
            if cache[key] != nil { cache[key]?.judgement = judgement }
            return judgement
        }
        // A failed second look leaves the first judgement as it is (and a warning not urgent).
        guard var answer = try? await reasoner.confirm(utterance, goal: goal, earlier: earlier) else { return judgement }
        // Nothing was listed that it could repeat.
        if answer == .saidBefore, earlier.isEmpty { answer = .hereAndNow }
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
        decision.usedContinuedSession = judgement.timing?.continuedSession == true && stage == .model
        decision.audience = configuration.usesAudienceCues
            ? AudienceAnalyzer.cue(in: utterance.text, identity: listener.identity).kind : .none
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
        let isRepeat = decision.corrections.contains("said_before") || accepted.contains {
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
            accepted.append(Accepted(goalID: goalID, text: utterance.text, stems: stems, isNegated: isNegated, quantities: quantities,
                                     date: utterance.date))
        }
    }
}
