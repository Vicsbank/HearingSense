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
        public var batchCalls: Int
        public var settledByBatch: Int
        public var requeuedAfterBatch: Int
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

        public var report: String {
            """
            \(name) — one sentence every \(interval) s, \(sentences) sentences in \(seconds.formatted(.number.precision(.fractionLength(1)))) s
              decided \(decided), dropped \(dropped) (relevant among them: \(droppedRelevant.isEmpty ? "none" : droppedRelevant.joined(separator: " "))), without any decision \(unaccounted)
              end to end           \(endToEnd.text)
              waiting for a turn   \(queueWait.text)
              model                \(model.text)
                one request        \(modelOneRequest.text)
                with a second look \(modelWithSecondLook.text)
              longest queue \(maximumQueueLength); model requests \(modelCalls) single + \(batchCalls) group (\(modelCallsPerMinute.formatted(.number.precision(.fractionLength(1)))) per minute); settled by a group request \(settledByBatch), judged again after one \(requeuedAfterBatch); later than the deadline \(deadlineMisses)
              throughput \(sentencesPerMinute.formatted(.number.precision(.fractionLength(1)))) sentences per minute; output tokens \(outputTokens)
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
    public static func throughput(name: String, items: [SemanticDataset.Item], interval: Double,
                                  reasoner: any SemanticRelevanceReasoning,
                                  configuration: SemanticAttentionEngine.Configuration,
                                  scheduler: ModelInferenceScheduler = ModelInferenceScheduler()) async -> ThroughputResult
    {
        guard let profile = items.first?.profile else { fatalError("no items") }
        let goals = SemanticDataset.goals(for: profile)
        let engine = SemanticAttentionEngine(reasoner: reasoner, scorer: SentenceEmbeddingScorer(),
                                             configuration: configuration, scheduler: scheduler)
        await engine.setGoals(goals.map(\.goal))
        await engine.prewarm()
        try? await Task.sleep(for: .seconds(1))
        let collector = Collector()
        let consumer = Task {
            for await decision in engine.decisions { await collector.add(decision) }
        }
        var ids: [String: UUID] = [:]
        let started = Date()
        for (index, item) in items.enumerated() {
            let due = started.addingTimeInterval(Double(index) * interval)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let utterance = SemanticUtterance(text: item.text, context: item.context, date: Date())
            ids[item.id] = utterance.id
            await engine.submit(utterance)
        }
        // Everything submitted gets a decision (accepted, rejected or dropped); wait for them.
        let giveUp = Date().addingTimeInterval(90)
        while await collector.count < items.count, Date() < giveUp { try? await Task.sleep(for: .milliseconds(50)) }
        let seconds = Date().timeIntervalSince(started)
        consumer.cancel()
        let decisions = await collector.decisions
        let statistics = await engine.statistics
        var outcomes: [SemanticItemOutcome] = []
        var droppedRelevant: [String] = []
        for item in items {
            guard let id = ids[item.id], let decision = decisions[id] else { continue }
            if decision.stage == .dropped, item.expected == .relevant { droppedRelevant.append(item.id) }
            let key = decision.matchedGoalID.flatMap { goalID in goals.first { $0.goal.id == goalID }?.key }
            outcomes.append(SemanticItemOutcome(
                id: item.id, alerted: decision.isAccepted, verdict: decision.verdict.rawValue, matchedGoal: key,
                stage: decision.stage.rawValue, corrections: decision.corrections, isNovel: decision.isNovel, score: nil,
                seconds: decision.latency, modelSeconds: decision.modelTime, outputTokens: decision.outputTokens,
                queueSeconds: decision.queueWait))
        }
        let evaluated = decisions.values.filter { $0.stage != .dropped && $0.stage != .gate }
        return ThroughputResult(
            name: name, interval: interval, sentences: items.count, seconds: seconds, decided: decisions.count,
            unaccounted: items.count - decisions.count, dropped: statistics.dropped, droppedRelevant: droppedRelevant,
            endToEnd: Quantiles(evaluated.map(\.latency)), queueWait: Quantiles(evaluated.map(\.queueWait)),
            model: Quantiles(evaluated.map(\.modelTime).filter { $0 > 0 }),
            maximumQueueLength: statistics.maximumQueueLength, modelCalls: statistics.modelCalls + statistics.triageCalls,
            batchCalls: statistics.batchCalls, settledByBatch: statistics.settledByBatch,
            requeuedAfterBatch: statistics.requeuedAfterBatch, deadlineMisses: statistics.deadlineMisses,
            modelCallsPerMinute: Double(statistics.modelCalls + statistics.triageCalls + statistics.batchCalls) / seconds * 60,
            sentencesPerMinute: Double(decisions.values.count { $0.stage != .dropped }) / seconds * 60,
            outputTokens: statistics.outputTokens,
            modelOneRequest: Quantiles(evaluated.filter { !$0.hadSecondLook }.map(\.modelTime).filter { $0 > 0 }),
            modelWithSecondLook: Quantiles(evaluated.filter(\.hadSecondLook).map(\.modelTime)),
            secondLooks: statistics.confirmCalls,
            confusion: SemanticConfusion(outcomes, dataset: SemanticDataset(split: .dev2, items: items)), outcomes: outcomes)
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
        await engine.setGoals(goals.map(\.goal))
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
        await engine.setGoals(goals.map(\.goal))
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
