import ConversationUnderstanding
import Foundation
import SemanticAttention

/// Benchmarks of the semantic engine as it is used in the app: sentences arriving over time
/// through `submit`, decisions leaving on the stream, the recap competing for the model
/// (Window 6.1). Synthetic, timestamped text; no microphone.
public enum SemanticStreamBenchmark {
    public struct Quantiles: Sendable, Codable {
        public var p50: Double?
        public var p95: Double?
        public var p99: Double?
        public var max: Double?
        public var count: Int

        public init(_ values: [Double]) {
            let sorted = values.sorted()
            func quantile(_ q: Double) -> Double? {
                sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int((Double(sorted.count) * q).rounded(.down)))]
            }
            (p50, p95, p99, max, count) = (quantile(0.5), quantile(0.95), quantile(0.99), sorted.last, sorted.count)
        }

        public var text: String {
            func seconds(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–" }
            return "p50 \(seconds(p50))  p95 \(seconds(p95))  p99 \(seconds(p99))  max \(seconds(max))  (n \(count))"
        }
    }

    public struct ThroughputResult: Sendable, Codable {
        public var name: String
        public var interval: Double
        public var sentences: Int
        public var seconds: Double
        public var decided: Int
        /// Sentences that never got a decision of any kind before the benchmark gave up waiting.
        public var unaccounted: Int
        public var dropped: Int
        public var droppedRelevant: [String]
        public var endToEnd: Quantiles
        public var queueWait: Quantiles
        public var model: Quantiles
        public var maximumQueueLength: Int
        public var modelCalls: Int
        public var deadlineMisses: Int
        public var modelCallsPerMinute: Double
        public var sentencesPerMinute: Double
        public var outputTokens: Int
        /// Model time of sentences that needed one request, and of those that got a second look.
        public var modelOneRequest: Quantiles
        public var modelWithSecondLook: Quantiles
        public var secondLooks: Int
        public var confusion: SemanticConfusion
        public var outcomes: [SemanticItemOutcome]
        /// Window 6.2. How the sentences arrived ("every 1.5 s", "bursty", …).
        public var pattern = ""
        /// Sentences given up after waiting too long, and those pushed out of a full line.
        public var expired = 0
        public var notEvaluated: [String] = []
        public var notEvaluatedRelevant: [String] = []
        /// The waiting line, sampled every 50 ms: its mean length, and how long after the last
        /// sentence arrived the last decision was made.
        public var meanQueueLength = 0.0
        public var recoverySeconds = 0.0
        /// End to end for the sentences that should have alerted.
        public var endToEndRelevant = Quantiles([])
        public var servedNewestFirst = 0
        /// Requests to the model beyond one per evaluated sentence that were not second looks
        /// (a request repeated after a failure, an early evaluation that was not used).
        public var extraModelCalls = 0
        public var modelFailures = 0
        /// First answers given by a session that continued, the silent ones among them that were
        /// judged again in a session of their own, and how many of those alerted after all.
        public var continuedSessions = 0
        public var rechecks = 0
        public var recheckAlerts = 0

        public var report: String {
            """
            \(name) — \(pattern.isEmpty ? "one sentence every \(interval) s" : pattern), \(sentences) sentences in \(seconds.formatted(.number.precision(.fractionLength(1)))) s
              decided \(decided), dropped \(dropped) (relevant among them: \(droppedRelevant.isEmpty ? "none" : droppedRelevant.joined(separator: " "))), without any decision \(unaccounted)
              end to end           \(endToEnd.text)
              waiting for a turn   \(queueWait.text)
              model                \(model.text)
                one request        \(modelOneRequest.text)
                with a second look \(modelWithSecondLook.text)
              longest queue \(maximumQueueLength); first judgements \(modelCalls) (\(modelCallsPerMinute.formatted(.number.precision(.fractionLength(1)))) per minute); later than the deadline \(deadlineMisses)
              throughput \(sentencesPerMinute.formatted(.number.precision(.fractionLength(1)))) sentences per minute; output tokens \(outputTokens)
              not evaluated: \(notEvaluated.count) (expired \(expired), pushed out \(dropped - expired)); relevant among them: \(notEvaluatedRelevant.isEmpty ? "none" : notEvaluatedRelevant.joined(separator: " "))
              relevant sentences   \(endToEndRelevant.text)
              waiting line: mean \(meanQueueLength.formatted(.number.precision(.fractionLength(2)))), longest \(maximumQueueLength); empty \(recoverySeconds.formatted(.number.precision(.fractionLength(2)))) s after the last sentence arrived; served newest first \(servedNewestFirst)
              second looks \(secondLooks); extra model requests \(extraModelCalls); model failures \(modelFailures)
              answers from a continued session \(continuedSessions); judged again when nothing waited \(rechecks), alerts found that way \(recheckAlerts)
              under load: TP \(confusion.truePositives) FP \(confusion.falsePositives) FN \(confusion.falseNegatives) TN \(confusion.trueNegatives); missed \(confusion.falseNegativeIDs.joined(separator: " ")); false alerts \(confusion.falsePositiveIDs.joined(separator: " "))
            """
        }
    }

    private actor Collector {
        var decisions: [UUID: SemanticAttentionDecision] = [:]
        var arrival: [UUID: Date] = [:]

        func add(_ decision: SemanticAttentionDecision) {
            decisions[decision.utteranceID] = decision
            arrival[decision.utteranceID] = Date()
        }

        var count: Int { decisions.count }
    }

    /// Submits the items at a fixed interval and waits for their decisions.
    /// Arrival times, in seconds from the start, for `count` sentences (Window 6.2).
    /// - "bursty": runs of 3–7 sentences 0.5–1.3 s apart with pauses of 2.5–8 s between them.
    /// - "dense": 20 s of silence, 25 sentences 0.8 s apart, 15 s of silence, then the rest 0.8 s apart.
    /// - a number: one sentence every that many seconds.
    public static func offsets(pattern: String, count: Int, seed: UInt64 = 7) -> [Double] {
        var generator = SplitMix(state: seed)
        switch pattern {
        case "bursty":
            var offsets: [Double] = [], time = 0.0
            while offsets.count < count {
                for _ in 0 ..< Int.random(in: 3 ... 7, using: &generator) where offsets.count < count {
                    offsets.append(time)
                    time += Double.random(in: 0.5 ... 1.3, using: &generator)
                }
                time += Double.random(in: 2.5 ... 8, using: &generator)
            }
            return offsets
        case "dense":
            return (0 ..< count).map { $0 < 25 ? 20 + Double($0) * 0.8 : 20 + 25 * 0.8 + 15 + Double($0 - 25) * 0.8 }
        default:
            let interval = Double(pattern) ?? 1.5
            return (0 ..< count).map { Double($0) * interval }
        }
    }

    public static func throughput(name: String, items: [SemanticDataset.Item], interval: Double,
                                  pattern: String = "", offsets: [Double]? = nil,
                                  reasoner: any SemanticRelevanceReasoning,
                                  configuration: SemanticAttentionEngine.Configuration,
                                  scheduler: ModelInferenceScheduler = ModelInferenceScheduler()) async -> ThroughputResult
    {
        guard let profile = items.first?.profile else { fatalError("no items") }
        let goals = SemanticDataset.goals(for: profile)
        let engine = SemanticAttentionEngine(reasoner: reasoner, scorer: SentenceEmbeddingScorer(),
                                             configuration: configuration, scheduler: scheduler)
        await engine.setGoals(goals.map(\.goal), about: SemanticDataset.about(for: profile))
        await engine.listenerIsDescribed()
        await engine.prewarm()
        try? await Task.sleep(for: .seconds(1))
        let collector = Collector()
        let consumer = Task {
            for await decision in engine.decisions { await collector.add(decision) }
        }
        var ids: [String: UUID] = [:]
        let started = Date()
        let sampler = Task {
            var samples: [Int] = []
            while !Task.isCancelled {
                samples.append(await engine.waitingCount)
                try? await Task.sleep(for: .milliseconds(50))
            }
            return samples
        }
        var lastArrival = started
        for (index, item) in items.enumerated() {
            let due = started.addingTimeInterval(offsets.map { $0[index] } ?? Double(index) * interval)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let utterance = SemanticUtterance(text: item.text, context: item.context, date: Date())
            ids[item.id] = utterance.id
            lastArrival = Date()
            await engine.submit(utterance)
        }
        // Everything submitted gets a decision (accepted, rejected or dropped); wait for them.
        let giveUp = Date().addingTimeInterval(90)
        while await collector.count < items.count, Date() < giveUp { try? await Task.sleep(for: .milliseconds(50)) }
        let seconds = Date().timeIntervalSince(started)
        let recovery = Date().timeIntervalSince(lastArrival)
        // Second judgements of sentences that a continued session called silent come after that.
        while await !engine.isIdle, Date() < giveUp { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(100))
        sampler.cancel()
        let samples = await sampler.value
        consumer.cancel()
        let decisions = await collector.decisions
        let statistics = await engine.statistics
        var outcomes: [SemanticItemOutcome] = []
        var droppedRelevant: [String] = []
        var notEvaluated: [String] = [], notEvaluatedRelevant: [String] = [], relevantLatencies: [Double] = []
        for item in items {
            guard let id = ids[item.id], let decision = decisions[id] else {
                notEvaluated.append(item.id)
                if item.expected == .relevant { notEvaluatedRelevant.append(item.id) }
                continue
            }
            if decision.stage == .dropped || decision.stage == .expired {
                notEvaluated.append(item.id)
                if item.expected == .relevant { notEvaluatedRelevant.append(item.id) }
            } else if item.expected == .relevant {
                relevantLatencies.append(decision.latency)
            }
            if decision.stage == .dropped || decision.stage == .expired, item.expected == .relevant { droppedRelevant.append(item.id) }
            let key = decision.matchedGoalID.flatMap { goalID in goals.first { $0.goal.id == goalID }?.key }
            outcomes.append(SemanticItemOutcome(
                id: item.id, alerted: decision.isAccepted, verdict: decision.verdict.rawValue, matchedGoal: key,
                stage: decision.stage.rawValue, corrections: decision.corrections, isNovel: decision.isNovel, score: nil,
                seconds: decision.latency, modelSeconds: decision.modelTime, outputTokens: decision.outputTokens,
                queueSeconds: decision.queueWait))
        }
        let evaluated = decisions.values.filter { $0.stage != .dropped && $0.stage != .expired && $0.stage != .gate }
        var result = ThroughputResult(
            name: name, interval: interval, sentences: items.count, seconds: seconds, decided: decisions.count,
            unaccounted: items.count - decisions.count, dropped: statistics.dropped, droppedRelevant: droppedRelevant,
            endToEnd: Quantiles(evaluated.map(\.latency)), queueWait: Quantiles(evaluated.map(\.queueWait)),
            model: Quantiles(evaluated.map(\.modelTime).filter { $0 > 0 }),
            maximumQueueLength: statistics.maximumQueueLength, modelCalls: statistics.modelCalls + statistics.triageCalls,
            deadlineMisses: statistics.deadlineMisses,
            modelCallsPerMinute: Double(statistics.modelCalls + statistics.triageCalls) / seconds * 60,
            sentencesPerMinute: Double(decisions.values.count { $0.stage != .dropped && $0.stage != .expired }) / seconds * 60,
            outputTokens: statistics.outputTokens,
            modelOneRequest: Quantiles(evaluated.filter { !$0.hadSecondLook }.map(\.modelTime).filter { $0 > 0 }),
            modelWithSecondLook: Quantiles(evaluated.filter(\.hadSecondLook).map(\.modelTime)),
            secondLooks: statistics.confirmCalls,
            confusion: SemanticConfusion(outcomes, dataset: SemanticDataset(split: .dev2, items: items)), outcomes: outcomes)
        result.pattern = pattern
        result.expired = statistics.expired
        result.notEvaluated = notEvaluated
        result.notEvaluatedRelevant = notEvaluatedRelevant
        result.meanQueueLength = samples.isEmpty ? 0 : Double(samples.reduce(0, +)) / Double(samples.count)
        result.recoverySeconds = recovery
        result.endToEndRelevant = Quantiles(relevantLatencies)
        result.servedNewestFirst = statistics.servedNewestFirst
        result.modelFailures = statistics.modelFailures
        result.continuedSessions = statistics.continuedSessions
        result.rechecks = statistics.rechecks
        result.recheckAlerts = statistics.recheckAlerts
        result.extraModelCalls = max(0, statistics.modelCalls + statistics.triageCalls + statistics.speculativeCalls
            + statistics.retries - statistics.rechecks - evaluated.count { $0.stage == .model })
        return result
    }

    // MARK: - Early evaluation of partial transcripts

    public struct SpeculationResult: Sendable, Codable {
        public var name: String
        public var sentences: Int
        public var finalDelay: Double
        /// From the end of the speech to the decision.
        public var speechEndToDecision: Quantiles
        /// From the final transcript to the decision.
        public var finalToDecision: Quantiles
        public var modelCalls: Int
        public var speculativeCalls: Int
        public var speculativeHits: Int
        public var speculativeCancelled: Int
        /// Sentences whose final text differed from the partial one, and how many of those
        /// were decided on the final text (all of them must be).
        public var revised: Int
        public var revisedDecidedOnFinalText: Int
        public var verdictsEqualToPlainRun: Int?

        public var report: String {
            """
            \(name) — \(sentences) sentences, final transcript \(finalDelay) s after the end of the speech
              speech end → decision   \(speechEndToDecision.text)
              final text → decision   \(finalToDecision.text)
              model requests \(modelCalls) on final text + \(speculativeCalls) early; early answers used \(speculativeHits), abandoned \(speculativeCancelled)
              final text different from the partial one: \(revised); of these decided on the final text: \(revisedDecidedOnFinalText)
            """
        }
    }

    /// One sentence at a time. The partial transcript is complete when the speech ends; the
    /// final transcript follows `finalDelay` later. With `usesSpeculation` the partial text is
    /// offered to the engine when `StablePartialDetector` says so. Every `reviseEvery`-th
    /// sentence the final text differs from the partial one (its last word was misheard).
    public static func speculation(name: String, items: [SemanticDataset.Item], finalDelay: Double, usesSpeculation: Bool,
                                   reviseEvery: Int, reasoner: any SemanticRelevanceReasoning,
                                   configuration: SemanticAttentionEngine.Configuration) async
        -> (result: SpeculationResult, verdicts: [String: String])
    {
        guard let profile = items.first?.profile else { fatalError("no items") }
        let goals = SemanticDataset.goals(for: profile)
        let engine = SemanticAttentionEngine(reasoner: reasoner, configuration: configuration)
        await engine.setGoals(goals.map(\.goal), about: SemanticDataset.about(for: profile))
        await engine.listenerIsDescribed()
        await engine.prewarm()
        try? await Task.sleep(for: .seconds(1))
        let collector = Collector()
        let consumer = Task {
            for await decision in engine.decisions { await collector.add(decision) }
        }
        var fromSpeechEnd: [Double] = [], fromFinal: [Double] = []
        var revised = 0, revisedOnFinal = 0
        var verdicts: [String: String] = [:]
        for (index, item) in items.enumerated() {
            let isRevised = reviseEvery > 0 && index % reviseEvery == reviseEvery - 1
            // What the recognizer shows while the last word is still uncertain.
            let partial = isRevised ? item.text.split(separator: " ").dropLast().joined(separator: " ") + " uh" : item.text
            let id = UUID()
            var detector = StablePartialDetector()
            let speechEnd = Date()
            detector.revise(partial, utterance: id, at: speechEnd)
            if usesSpeculation, let check = detector.nextCheck, check.timeIntervalSince(speechEnd) < finalDelay {
                try? await Task.sleep(for: .seconds(check.timeIntervalSince(speechEnd)))
                if let text = detector.offer(at: Date()) {
                    await engine.submitProvisional(SemanticUtterance(id: id, text: text, context: item.context, date: Date()))
                }
            }
            let untilFinal = speechEnd.addingTimeInterval(finalDelay).timeIntervalSinceNow
            if untilFinal > 0 { try? await Task.sleep(for: .seconds(untilFinal)) }
            let final = Date()
            let before = await engine.statistics
            await engine.submit(SemanticUtterance(id: id, text: item.text, context: item.context, date: final))
            let giveUp = Date().addingTimeInterval(20)
            while await collector.decisions[id] == nil, Date() < giveUp { try? await Task.sleep(for: .milliseconds(10)) }
            guard let decision = await collector.decisions[id], let arrived = await collector.arrival[id] else { continue }
            fromSpeechEnd.append(arrived.timeIntervalSince(speechEnd))
            fromFinal.append(arrived.timeIntervalSince(final))
            verdicts[item.id] = decision.isAccepted ? "alert" : decision.verdict.rawValue
            if isRevised {
                revised += 1
                // Decided on the final text: a model request was made after the final arrived.
                let after = await engine.statistics
                if after.modelCalls > before.modelCalls, decision.stage == .model { revisedOnFinal += 1 }
            }
            try? await Task.sleep(for: .seconds(0.3))
        }
        consumer.cancel()
        let statistics = await engine.statistics
        return (SpeculationResult(
            name: name, sentences: items.count, finalDelay: finalDelay, speechEndToDecision: Quantiles(fromSpeechEnd),
            finalToDecision: Quantiles(fromFinal), modelCalls: statistics.modelCalls,
            speculativeCalls: statistics.speculativeCalls, speculativeHits: statistics.speculativeHits,
            speculativeCancelled: statistics.speculativeCancelled, revised: revised,
            revisedDecidedOnFinalText: revisedOnFinal, verdictsEqualToPlainRun: nil), verdicts)
    }

    // MARK: - Recap beside goal matching

    public struct ContentionResult: Sendable, Codable {
        public var name: String
        public var recapSeconds: Double
        public var recapSource: String
        public var recapWait: Double?
        public var sentences: Int
        public var endToEnd: Quantiles
        /// Decisions for sentences submitted while the recap was being written.
        public var endToEndDuringRecap: Quantiles
        public var urgentDuringRecap: Quantiles
        public var dropped: Int
        public var maximumRunning: Int

        public var report: String {
            """
            \(name)
              recap: \(recapSource) in \(recapSeconds.formatted(.number.precision(.fractionLength(2)))) s\(recapWait.map { ", waited \($0.formatted(.number.precision(.fractionLength(2)))) s for its turn" } ?? "")
              goal matching, all \(sentences) sentences       \(endToEnd.text)
              submitted while the recap was written   \(endToEndDuringRecap.text)
              warning-like sentences among those      \(urgentDuringRecap.text)
              dropped \(dropped); most model sessions at once \(maximumRunning)
            """
        }
    }

    public enum ContentionMode: String, Sendable, CaseIterable {
        /// The recap alone, nothing else using the model.
        case recapAlone
        /// Window 6: no shared scheduler; goal matching is paused while the recap is written.
        case window6Pause
        /// No coordination at all: both use the model whenever they want.
        case uncoordinated
        /// Window 6.1: one scheduler, the recap ahead of goal matching.
        case scheduled
        /// As `scheduled`, and one warning-like sentence may run beside the recap.
        case scheduledUrgentBeside
    }

    /// Sentences arrive every `interval` seconds; after `recapAfter` sentences the user asks
    /// for a recap of a synthetic conversation.
    public static func contention(mode: ContentionMode, items: [SemanticDataset.Item], interval: Double, recapAfter: Int,
                                  scene: ConversationDataset.Scene, reasoner: any SemanticRelevanceReasoning,
                                  summarizer: any ConversationSummarizing,
                                  configuration: SemanticAttentionEngine.Configuration) async -> ContentionResult
    {
        var schedulerConfiguration = ModelInferenceScheduler.Configuration.standard
        schedulerConfiguration.allowsUrgentBesideUserRequest = mode == .scheduledUrgentBeside
        if mode == .uncoordinated { schedulerConfiguration.maximumConcurrent = 8 }
        let scheduler = ModelInferenceScheduler(configuration: schedulerConfiguration)
        let recapEngine = ConversationRecapEngine(summarizer: summarizer)
        let (buffer, now) = scene.buffer(includingLater: false)
        let excerpt = buffer.excerpt(now: now)

        if mode == .recapAlone {
            let recap = await recapEngine.recap(excerpt)
            return ContentionResult(name: mode.rawValue, recapSeconds: recap.modelSeconds, recapSource: recap.source.rawValue,
                                    recapWait: nil, sentences: 0, endToEnd: Quantiles([]), endToEndDuringRecap: Quantiles([]),
                                    urgentDuringRecap: Quantiles([]), dropped: 0, maximumRunning: 1)
        }

        guard let profile = items.first?.profile else { fatalError("no items") }
        let goals = SemanticDataset.goals(for: profile)
        let engine = SemanticAttentionEngine(reasoner: reasoner, configuration: configuration, scheduler: scheduler)
        await engine.setGoals(goals.map(\.goal), about: SemanticDataset.about(for: profile))
        await engine.listenerIsDescribed()
        await engine.prewarm()
        try? await Task.sleep(for: .seconds(1))
        let collector = Collector()
        let consumer = Task {
            for await decision in engine.decisions { await collector.add(decision) }
        }
        var ids: [UUID: (submitted: Date, isUrgent: Bool)] = [:]
        var recapTask: Task<(ConversationRecap, Date, Date), Never>?
        let started = Date()
        for (index, item) in items.enumerated() {
            let wait = started.addingTimeInterval(Double(index) * interval).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if index == recapAfter {
                recapTask = Task {
                    let asked = Date()
                    switch mode {
                    case .window6Pause:
                        await engine.setPaused(true)
                        let recap = await recapEngine.recap(excerpt)
                        await engine.setPaused(false)
                        return (recap, asked, Date())
                    case .uncoordinated, .recapAlone:
                        let recap = await recapEngine.recap(excerpt)
                        return (recap, asked, Date())
                    case .scheduled, .scheduledUrgentBeside:
                        let recap = (try? await scheduler.run(.userRequest) { await recapEngine.recap(excerpt) })
                            ?? ConversationRecap(title: "", summary: "", source: .unavailable)
                        return (recap, asked, Date())
                    }
                }
            }
            let utterance = SemanticUtterance(text: item.text, context: item.context, date: Date())
            ids[utterance.id] = (Date(), item.isUrgent)
            await engine.submit(utterance)
        }
        let (recap, asked, finished) = await recapTask?.value
            ?? (ConversationRecap(title: "", summary: "", source: .unavailable), Date(), Date())
        let giveUp = Date().addingTimeInterval(60)
        while await collector.count < items.count, Date() < giveUp { try? await Task.sleep(for: .milliseconds(50)) }
        consumer.cancel()
        let decisions = await collector.decisions
        let statistics = await engine.statistics
        let schedulerStatistics = await scheduler.statistics
        let evaluated = decisions.values.filter { $0.stage != .dropped && $0.stage != .gate }
        let during = evaluated.filter { decision in
            guard let entry = ids[decision.utteranceID] else { return false }
            return entry.submitted >= asked && entry.submitted <= finished
        }
        return ContentionResult(
            name: mode.rawValue, recapSeconds: finished.timeIntervalSince(asked), recapSource: recap.source.rawValue,
            recapWait: schedulerStatistics[.userRequest].waits.first, sentences: items.count,
            endToEnd: Quantiles(evaluated.map(\.latency)), endToEndDuringRecap: Quantiles(during.map(\.latency)),
            urgentDuringRecap: Quantiles(during.filter { ids[$0.utteranceID]?.isUrgent == true }.map(\.latency)),
            dropped: statistics.dropped, maximumRunning: schedulerStatistics.maximumRunning)
    }
}
