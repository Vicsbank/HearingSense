import Foundation
import SemanticAttention

/// What one method did with one item.
public struct SemanticItemOutcome: Sendable, Codable {
    public var id: String
    public var alerted: Bool
    /// `relevant`, `uncertain`, `irrelevant` for the engine; nil for the baselines.
    public var verdict: String?
    public var matchedGoal: String?
    public var stage: String?
    public var corrections: [String]
    public var isNovel: Bool
    public var score: Double?
    public var seconds: Double
    public var modelSeconds: Double
    /// Tokens the model wrote for this item (engine only, when the system reports them).
    public var outputTokens: Int?
    /// Seconds the item waited for its turn (stream benchmarks only).
    public var queueSeconds: Double?
    /// What kind of statement the model saw, and whom it concerns (engine only).
    public var kind: String?
    public var subject: String?
    /// The audience cue of the sentence, when there is one (Window 6.3; engine only).
    public var audience: String?

    public init(id: String, alerted: Bool, verdict: String?, matchedGoal: String?, stage: String?, corrections: [String],
                isNovel: Bool, score: Double?, seconds: Double, modelSeconds: Double, outputTokens: Int? = nil,
                queueSeconds: Double? = nil, kind: String? = nil, subject: String? = nil, audience: String? = nil)
    {
        self.outputTokens = outputTokens
        self.queueSeconds = queueSeconds
        self.kind = kind
        self.subject = subject
        self.audience = audience
        self.id = id
        self.alerted = alerted
        self.verdict = verdict
        self.matchedGoal = matchedGoal
        self.stage = stage
        self.corrections = corrections
        self.isNovel = isNovel
        self.score = score
        self.seconds = seconds
        self.modelSeconds = modelSeconds
    }
}

public struct SemanticMetrics: Sendable, Codable {
    public struct Rate: Sendable, Codable {
        public var hits: Int
        public var total: Int
        public var value: Double? { total == 0 ? nil : Double(hits) / Double(total) }

        /// Wilson score interval, 95 %.
        public var interval: (low: Double, high: Double)? {
            guard total > 0 else { return nil }
            let z = 1.96, n = Double(total), p = Double(hits) / n
            let centre = (p + z * z / (2 * n)) / (1 + z * z / n)
            let half = z * ((p * (1 - p) + z * z / (4 * n)) / n).squareRoot() / (1 + z * z / n)
            return (max(0, centre - half), min(1, centre + half))
        }

        public var text: String {
            guard let value, let interval else { return "– (0)" }
            func percent(_ number: Double) -> String { (number * 100).formatted(.number.precision(.fractionLength(1))) }
            return "\(percent(value)) % (\(hits)/\(total); 95 % CI \(percent(interval.low))–\(percent(interval.high)))"
        }
    }

    public var method: String
    public var split: String
    public var precision: Rate
    public var recall: Rate
    public var f1: Double?
    /// Alerts on items labelled irrelevant.
    public var falseAlertRate: Rate
    /// Second alerts for a repeated statement.
    public var repeatAlerts: Rate
    public var importantMisses: Rate
    /// Among correct alerts: the named goal is one of the acceptable ones (engine only).
    public var goalAccuracy: Rate
    public var byCategory: [String: Rate]
    /// Ambiguous items: alerted / kept as uncertain / nothing.
    public var ambiguousAlerted: Int
    public var ambiguousUncertain: Int
    public var ambiguousTotal: Int
    /// Derived, not measured: `falseAlertRate` times an assumed number of irrelevant utterances per hour.
    public var falseAlertsPerHour: Double?
    public var assumedUtterancesPerHour: Double
    public var medianSeconds: Double?
    public var p95Seconds: Double?
    public var medianModelSeconds: Double?
    public var modelCalls: Int
    /// Utterances stopped by the model's fast first pass.
    public var triaged: Int
    public var gated: Int
    public var fallbacks: Int
    public var corrections: [String: Int]
}

public enum SemanticEvaluator {
    /// Continuous conversation with one finalized utterance every 15 seconds, none of it relevant.
    public static let assumedUtterancesPerHour = 240.0

    // MARK: - Methods

    /// Baseline 1: an alert whenever the utterance shares a keyword with a goal.
    public static func runKeyword(_ dataset: SemanticDataset) -> [SemanticItemOutcome] {
        let scorer = KeywordGoalScorer()
        return dataset.items.map { item in
            let started = Date()
            let scored = SemanticDataset.goals(for: item.profile).map { ($0.key, scorer.score(utterance: item.text, goal: $0.goal.text)) }
            let best = scored.max { $0.1 < $1.1 }
            let alerted = (best?.1 ?? 0) > 0
            return SemanticItemOutcome(id: item.id, alerted: alerted, verdict: nil, matchedGoal: alerted ? best?.0 : nil,
                                       stage: nil, corrections: [], isNovel: true, score: best?.1,
                                       seconds: Date().timeIntervalSince(started), modelSeconds: 0)
        }
    }

    /// Baseline 2: an alert when the closest goal's similarity reaches a threshold.
    public static func runSimilarity(_ dataset: SemanticDataset, scorer: any GoalSimilarityScoring,
                                     threshold: Double) -> [SemanticItemOutcome]
    {
        dataset.items.map { item in
            let started = Date()
            let scored = SemanticDataset.goals(for: item.profile).map { ($0.key, scorer.score(utterance: item.text, goal: $0.goal.text)) }
            let best = scored.max { $0.1 < $1.1 }
            let alerted = (best?.1 ?? 0) >= threshold
            return SemanticItemOutcome(id: item.id, alerted: alerted, verdict: nil, matchedGoal: alerted ? best?.0 : nil,
                                       stage: nil, corrections: [], isNovel: true, score: best?.1,
                                       seconds: Date().timeIntervalSince(started), modelSeconds: 0)
        }
    }

    /// The threshold with the best F1 on a dataset (use the development set only).
    public static func bestThreshold(_ dataset: SemanticDataset, scorer: any GoalSimilarityScoring) -> Double {
        var best = (threshold: 1.0, f1: -1.0)
        for step in 40 ... 100 {
            let threshold = Double(step) / 100
            let metrics = metrics(runSimilarity(dataset, scorer: scorer, threshold: threshold), dataset: dataset, method: "")
            if let f1 = metrics.f1, f1 > best.f1 { best = (threshold, f1) }
        }
        return best.threshold
    }

    /// The production pipeline: gate, model, verifier, novelty. One engine per profile; the
    /// items are evaluated in file order, 20 seconds apart, as a conversation would arrive.
    public static func runEngine(_ dataset: SemanticDataset, reasoner: any SemanticRelevanceReasoning,
                                 usesTriage: Bool = true, verifier: EvidenceVerifier = .standard,
                                 configuration base: SemanticAttentionEngine.Configuration? = nil, seed: UInt64? = nil,
                                 conversationContext: Int = 0,
                                 progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [SemanticItemOutcome]
    {
        // With a seed the items of each profile are shuffled first (Window 6.2: a decision must
        // not depend on what happened to be said before).
        var dataset = dataset
        dataset.items = SemanticProbe.ordered(dataset, seed: seed)
        var outcomes: [SemanticItemOutcome] = []
        var engines: [String: SemanticAttentionEngine] = [:]
        var said: [String: [String]] = [:]
        let origin = Date(timeIntervalSince1970: 1_780_000_000)
        // A repetition is said one minute after the statement it repeats (the file lists the
        // repetitions at the end); the items are then evaluated in the order of their times.
        var dates: [String: Date] = [:]
        for (index, item) in dataset.items.enumerated() where item.repeatOf == nil {
            dates[item.id] = origin.addingTimeInterval(Double(index) * 20)
        }
        for (index, item) in dataset.items.enumerated() where item.repeatOf != nil {
            dates[item.id] = item.repeatOf.flatMap { dates[$0] }?.addingTimeInterval(60)
                ?? origin.addingTimeInterval(Double(index) * 20)
        }
        let ordered = dataset.items.enumerated().sorted {
            let first = dates[$0.element.id] ?? origin, second = dates[$1.element.id] ?? origin
            return first != second ? first < second : $0.offset < $1.offset
        }.map(\.element)
        for (index, item) in ordered.enumerated() {
            let goals = SemanticDataset.goals(for: item.profile)
            let engine: SemanticAttentionEngine
            if let existing = engines[item.profile] {
                engine = existing
            } else {
                var configuration = base ?? SemanticAttentionEngine.Configuration.standard
                if base == nil { configuration.usesTriage = usesTriage }
                engine = SemanticAttentionEngine(reasoner: reasoner, scorer: SentenceEmbeddingScorer(), verifier: verifier,
                                                 configuration: configuration)
                await engine.setGoals(goals.map(\.goal), about: SemanticDataset.about(for: item.profile))
                await engine.listenerIsDescribed()
                engines[item.profile] = engine
            }
            let date = dates[item.id] ?? origin
            // As in the app (Window 6.3): every sentence comes with the sentences said before it,
            // here the ones before it in the file, whatever they were about. A sentence written
            // with a context of its own has that one directly before it.
            var context = item.context
            if conversationContext > 0 {
                context = Array((said[item.profile] ?? []).suffix(conversationContext)) + item.context
                said[item.profile, default: []].append(item.text)
            }
            let utterance = SemanticUtterance(text: item.text, context: context, date: date)
            let started = Date()
            let decision = await engine.evaluate(utterance)
            let key = decision.matchedGoalID.flatMap { id in goals.first { $0.goal.id == id }?.key }
            outcomes.append(SemanticItemOutcome(
                id: item.id, alerted: decision.isAccepted, verdict: decision.verdict.rawValue, matchedGoal: key,
                stage: decision.stage.rawValue, corrections: decision.corrections, isNovel: decision.isNovel, score: nil,
                seconds: Date().timeIntervalSince(started), modelSeconds: decision.modelTime,
                outputTokens: decision.outputTokens, kind: decision.statementKind.rawValue,
                subject: decision.subject.rawValue, audience: decision.audience == .none ? nil : decision.audience.rawValue))
            progress?(index + 1, dataset.items.count)
        }
        return outcomes
    }

    // MARK: - Metrics

    public static func metrics(_ outcomes: [SemanticItemOutcome], dataset: SemanticDataset, method: String) -> SemanticMetrics {
        let byID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.id, $0) })
        var truePositives = 0, falseNegatives = 0, falsePositives = 0, irrelevantTotal = 0, irrelevantAlerted = 0
        var repeats = 0, repeatAlerts = 0, important = 0, importantMissed = 0, goalRight = 0
        var ambiguousAlerted = 0, ambiguousUncertain = 0, ambiguousTotal = 0
        var categories: [String: SemanticMetrics.Rate] = [:]
        var corrections: [String: Int] = [:]
        for item in dataset.items {
            guard let outcome = byID[item.id] else { continue }
            for correction in outcome.corrections { corrections[correction, default: 0] += 1 }
            var isCorrect: Bool?
            switch item.expected {
            case .relevant:
                if outcome.alerted {
                    truePositives += 1
                    if let goal = outcome.matchedGoal, item.acceptableGoals.contains(goal) { goalRight += 1 }
                } else {
                    falseNegatives += 1
                }
                if item.isImportant {
                    important += 1
                    if !outcome.alerted { importantMissed += 1 }
                }
                isCorrect = outcome.alerted
            case .irrelevant:
                irrelevantTotal += 1
                if outcome.alerted {
                    irrelevantAlerted += 1
                    falsePositives += 1
                }
                isCorrect = !outcome.alerted
            case .repeat:
                repeats += 1
                if outcome.alerted {
                    repeatAlerts += 1
                    falsePositives += 1
                }
                isCorrect = !outcome.alerted
            case .ambiguous:
                ambiguousTotal += 1
                if outcome.alerted { ambiguousAlerted += 1 } else if outcome.verdict == "uncertain" { ambiguousUncertain += 1 }
            }
            if let isCorrect {
                var rate = categories[item.category] ?? .init(hits: 0, total: 0)
                rate.total += 1
                if isCorrect { rate.hits += 1 }
                categories[item.category] = rate
            }
        }
        let precision = SemanticMetrics.Rate(hits: truePositives, total: truePositives + falsePositives)
        let recall = SemanticMetrics.Rate(hits: truePositives, total: truePositives + falseNegatives)
        let f1: Double? = if let p = precision.value, let r = recall.value, p + r > 0 { 2 * p * r / (p + r) } else { nil }
        let falseAlertRate = SemanticMetrics.Rate(hits: irrelevantAlerted, total: irrelevantTotal)
        let times = outcomes.map(\.seconds).sorted()
        let modelTimes = outcomes.map(\.modelSeconds).filter { $0 > 0 }.sorted()
        func quantile(_ values: [Double], _ q: Double) -> Double? {
            values.isEmpty ? nil : values[min(values.count - 1, Int((Double(values.count) * q).rounded(.down)))]
        }
        return SemanticMetrics(
            method: method, split: dataset.split.rawValue, precision: precision, recall: recall, f1: f1,
            falseAlertRate: falseAlertRate, repeatAlerts: .init(hits: repeatAlerts, total: repeats),
            importantMisses: .init(hits: importantMissed, total: important),
            goalAccuracy: .init(hits: goalRight, total: truePositives), byCategory: categories,
            ambiguousAlerted: ambiguousAlerted, ambiguousUncertain: ambiguousUncertain, ambiguousTotal: ambiguousTotal,
            falseAlertsPerHour: falseAlertRate.value.map { $0 * assumedUtterancesPerHour },
            assumedUtterancesPerHour: assumedUtterancesPerHour, medianSeconds: quantile(times, 0.5),
            p95Seconds: quantile(times, 0.95), medianModelSeconds: quantile(modelTimes, 0.5),
            modelCalls: outcomes.count { $0.stage == "model" }, triaged: outcomes.count { $0.stage == "triage" },
            gated: outcomes.count { $0.stage == "gate" },
            fallbacks: outcomes.count { $0.stage == "fallback" }, corrections: corrections)
    }

    public static func report(_ metrics: SemanticMetrics) -> String {
        func seconds(_ value: Double?) -> String {
            value.map { $0 < 0.01 ? "< 0.01 s" : $0.formatted(.number.precision(.fractionLength(2))) + " s" } ?? "–"
        }
        var lines = [
            "\(metrics.method) — \(metrics.split) set",
            "  precision            \(metrics.precision.text)",
            "  recall               \(metrics.recall.text)",
            "  F1                   \(metrics.f1.map { $0.formatted(.number.precision(.fractionLength(3))) } ?? "–")",
            "  false alerts         \(metrics.falseAlertRate.text) of irrelevant utterances",
            "  false alerts / hour  \(metrics.falseAlertsPerHour.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")"
                + " (derived: rate × \(Int(metrics.assumedUtterancesPerHour)) irrelevant utterances per hour, an assumption)",
            "  repeated alerts      \(metrics.repeatAlerts.text)",
            "  important missed     \(metrics.importantMisses.text)",
            "  goal named correctly \(metrics.goalAccuracy.text)",
            "  ambiguous items      \(metrics.ambiguousAlerted) alerted, \(metrics.ambiguousUncertain) kept as uncertain, "
                + "\(metrics.ambiguousTotal - metrics.ambiguousAlerted - metrics.ambiguousUncertain) nothing (of \(metrics.ambiguousTotal))",
            "  time per utterance   median \(seconds(metrics.medianSeconds)), p95 \(seconds(metrics.p95Seconds)); "
                + "model median \(seconds(metrics.medianModelSeconds)); full judgements \(metrics.modelCalls), "
                + "stopped by the first pass \(metrics.triaged), "
                + "gated \(metrics.gated), fallbacks \(metrics.fallbacks)",
        ]
        if !metrics.corrections.isEmpty {
            lines.append("  verifier corrections " + metrics.corrections.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        lines.append("  by category          " + metrics.byCategory.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value.hits)/\($0.value.total)" }.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
}
