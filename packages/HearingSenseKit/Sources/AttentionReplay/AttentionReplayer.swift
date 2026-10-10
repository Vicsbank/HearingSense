import Attention
import Foundation
import HearingSenseDomain

/// An engine decision with the scripted source that caused it.
public struct AttributedDecision: Sendable {
    public var decision: AttentionDecision
    /// The source whose input produced the decision; for timer decisions, the episode's first source.
    public var sourceKey: String?
    /// Seconds between that source's latest input and the decision (0 unless the engine waited).
    public var engineDelay: TimeInterval

    /// An alert is a new presentation, or an update that asks for attention. Quiet content
    /// updates, suppressions, deferrals and endings are not alerts.
    public var isAlert: Bool {
        switch decision.action {
        case .show: true
        case .update: decision.intent.map { $0.interruption != .none } ?? false
        default: false
        }
    }
}

/// What the "show every confirmed event" baseline would have alerted on.
public struct BaselineAlert: Hashable, Sendable {
    public var sourceKey: String
    public var date: Date
}

/// Counts for one scenario in one mode. All numbers describe scripted, synthetic input.
public struct ScenarioMetrics: Hashable, Sendable, Codable {
    public var inputs = 0
    public var simulatedSeconds: TimeInterval = 0
    public var sources: [String: Int] = [:]
    public var engineAlerts = 0
    public var baselineAlerts = 0
    public var engineAlertsByLabel: [String: Int] = [:]
    public var baselineAlertsByLabel: [String: Int] = [:]
    public var importantSources = 0
    /// Important sources with at least one engine alert.
    public var importantRetained = 0
    public var duplicateSources = 0
    /// Duplicate sources without any engine alert.
    public var duplicatesSuppressed = 0
    /// Engine alerts on ambient, irrelevant or duplicate sources.
    public var unnecessaryAlerts = 0
    public var baselineUnnecessaryAlerts = 0
    public var actions: [String: Int] = [:]
    public var fusions = 0
    public var maximumEpisodes = 0
    public var maximumDeferred = 0
    /// Episodes still held by the engine after the tail of the run.
    public var finalEpisodes = 0
    /// Seconds the engine added between a source's input and its alert (deferrals), per alert.
    public var engineDelayMedian: TimeInterval = 0
    public var engineDelayP95: TimeInterval = 0
    /// Wall-clock time of `AttentionEngine.process`, per input, in microseconds.
    public var processingMedianMicroseconds: Double = 0
    public var processingP95Microseconds: Double = 0

    public init() {}

    public var importantRetention: Double? {
        importantSources > 0 ? Double(importantRetained) / Double(importantSources) : nil
    }

    public var duplicateSuppression: Double? {
        duplicateSources > 0 ? Double(duplicatesSuppressed) / Double(duplicateSources) : nil
    }

    /// Share of the baseline's unnecessary alerts that the engine did not raise.
    public var unnecessaryAlertReduction: Double? {
        baselineUnnecessaryAlerts > 0 ? 1 - Double(unnecessaryAlerts) / Double(baselineUnnecessaryAlerts) : nil
    }

    public var unnecessaryAlertsPerHour: Double? {
        simulatedSeconds > 0 ? Double(unnecessaryAlerts) / (simulatedSeconds / 3600) : nil
    }

    public var baselineUnnecessaryAlertsPerHour: Double? {
        simulatedSeconds > 0 ? Double(baselineUnnecessaryAlerts) / (simulatedSeconds / 3600) : nil
    }

    /// Adds another run's counts (latency percentiles are not combined).
    public mutating func add(_ other: ScenarioMetrics) {
        inputs += other.inputs
        simulatedSeconds += other.simulatedSeconds
        sources.merge(other.sources, uniquingKeysWith: +)
        engineAlerts += other.engineAlerts
        baselineAlerts += other.baselineAlerts
        engineAlertsByLabel.merge(other.engineAlertsByLabel, uniquingKeysWith: +)
        baselineAlertsByLabel.merge(other.baselineAlertsByLabel, uniquingKeysWith: +)
        importantSources += other.importantSources
        importantRetained += other.importantRetained
        duplicateSources += other.duplicateSources
        duplicatesSuppressed += other.duplicatesSuppressed
        unnecessaryAlerts += other.unnecessaryAlerts
        baselineUnnecessaryAlerts += other.baselineUnnecessaryAlerts
        actions.merge(other.actions, uniquingKeysWith: +)
        fusions += other.fusions
        maximumEpisodes = max(maximumEpisodes, other.maximumEpisodes)
        maximumDeferred = max(maximumDeferred, other.maximumDeferred)
        finalEpisodes += other.finalEpisodes
    }
}

public struct ScenarioRun: Sendable {
    public var scenario: AttentionScenario
    public var preferences: AttentionPreferences
    public var decisions: [AttributedDecision]
    public var baseline: [BaselineAlert]
    public var snapshot: AttentionSnapshot
    public var metrics: ScenarioMetrics
    /// Wall-clock nanoseconds of every `process` call.
    public var processingNanoseconds: [Double]

    public var alerts: [AttributedDecision] { decisions.filter(\.isAlert) }

    public func decisions(for key: String) -> [AttributedDecision] { decisions.filter { $0.sourceKey == key } }

    public func alerts(for key: String) -> [AttributedDecision] { alerts.filter { $0.sourceKey == key } }

    public func count(_ action: AttentionAction) -> Int { decisions.count { $0.decision.action == action } }

    /// Intents in the order Window 5 would receive them.
    public var intents: [AttentionPresentationIntent] { decisions.compactMap(\.decision.intent) }
}

/// Feeds a scenario to the production `AttentionEngine` and compares it with the baseline that
/// alerts on every confirmed sound, every new speech event and every new summary.
public enum AttentionReplayer {
    /// - Parameter tail: simulated time after the last scripted input during which pending
    ///   deadlines (expirations, deferred presentations) are still delivered.
    public static func run(_ scenario: AttentionScenario, preferences: AttentionPreferences = .default,
                           configuration: AttentionConfiguration = .standard, tail: TimeInterval = 180) -> ScenarioRun
    {
        var engine = AttentionEngine(configuration: configuration, preferences: preferences)
        var decisions: [AttributedDecision] = []
        var baseline: [BaselineAlert] = []
        var timings: [Double] = []
        var soundKeys: [AcousticEventID: String] = [:]
        var speechKeys: [SpeechEventID: String] = [:]
        var lastInput: [String: Date] = [:]
        var summaryRevisions: [SpeechEventID: Int] = [:]
        let clock = ContinuousClock()

        func key(for event: AttentionEvent) -> String? {
            guard let first = event.sources.min(by: { $0.firstObserved < $1.firstObserved }) else { return nil }
            switch first.source {
            case .sound(let id, _): return soundKeys[id]
            case .speech(let id): return speechKeys[id]
            }
        }

        func feed(_ input: AttentionInput, key sourceKey: String?) {
            var produced: [AttentionDecision] = []
            let elapsed = clock.measure { produced = engine.process(input) }
            timings.append(Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9)
            for decision in produced {
                let isFromSource: Bool = switch decision.trigger {
                case .sound, .speech: true
                case .timer, .preferences, .session: false
                }
                let attributed = isFromSource ? sourceKey : key(for: decision.event)
                let delay = attributed.flatMap { lastInput[$0] }.map { decision.decidedAt.timeIntervalSince($0) } ?? 0
                decisions.append(AttributedDecision(decision: decision, sourceKey: attributed, engineDelay: max(delay, 0)))
            }
        }

        func drainDeadlines(until limit: Date) {
            var guardCount = 0
            while let deadline = engine.nextDeadline, deadline <= limit, guardCount < 100_000 {
                feed(.tick(at: deadline), key: nil)
                guardCount += 1
            }
        }

        feed(.sessionStarted(at: scenario.start), key: nil)
        for step in scenario.steps {
            drainDeadlines(until: step.input.date)
            if let sourceKey = step.sourceKey {
                lastInput[sourceKey] = step.input.date
                switch step.input {
                case .sound(let update):
                    soundKeys[update.event.id] = sourceKey
                    if case .started = update { baseline.append(BaselineAlert(sourceKey: sourceKey, date: step.input.date)) }
                case .speech(let result):
                    if speechKeys[result.id] == nil {
                        baseline.append(BaselineAlert(sourceKey: sourceKey, date: step.input.date))
                    }
                    speechKeys[result.id] = sourceKey
                    if result.summaryRevision > summaryRevisions[result.id, default: 0] {
                        baseline.append(BaselineAlert(sourceKey: sourceKey, date: step.input.date))
                    }
                    summaryRevisions[result.id] = result.summaryRevision
                default:
                    break
                }
            }
            feed(step.input, key: step.sourceKey)
        }
        drainDeadlines(until: scenario.end.addingTimeInterval(tail))

        let snapshot = engine.snapshot
        var run = ScenarioRun(scenario: scenario, preferences: preferences, decisions: decisions, baseline: baseline,
                              snapshot: snapshot, metrics: ScenarioMetrics(), processingNanoseconds: timings)
        run.metrics = metrics(for: run, statistics: engine.statistics)
        return run
    }

    static func metrics(for run: ScenarioRun, statistics: AttentionStatistics) -> ScenarioMetrics {
        var metrics = ScenarioMetrics()
        let labels = Dictionary(uniqueKeysWithValues: run.scenario.truths.map { ($0.key, $0.label) })
        let alerts = run.alerts
        metrics.inputs = run.scenario.steps.count
        metrics.simulatedSeconds = run.scenario.duration
        for truth in run.scenario.truths { metrics.sources[truth.label.rawValue, default: 0] += 1 }
        metrics.engineAlerts = alerts.count
        metrics.baselineAlerts = run.baseline.count
        for alert in alerts {
            guard let label = alert.sourceKey.flatMap({ labels[$0] }) else { continue }
            metrics.engineAlertsByLabel[label.rawValue, default: 0] += 1
            if label.isUnnecessary { metrics.unnecessaryAlerts += 1 }
        }
        for alert in run.baseline {
            guard let label = labels[alert.sourceKey] else { continue }
            metrics.baselineAlertsByLabel[label.rawValue, default: 0] += 1
            if label.isUnnecessary { metrics.baselineUnnecessaryAlerts += 1 }
        }
        let alerted = Set(alerts.compactMap(\.sourceKey))
        for truth in run.scenario.truths {
            switch truth.label {
            case .important:
                metrics.importantSources += 1
                if alerted.contains(truth.key) { metrics.importantRetained += 1 }
            case .duplicate:
                metrics.duplicateSources += 1
                if !alerted.contains(truth.key) { metrics.duplicatesSuppressed += 1 }
            default:
                break
            }
        }
        for action in AttentionAction.allCases { metrics.actions[action.rawValue] = run.count(action) }
        metrics.fusions = statistics.fusions
        metrics.maximumEpisodes = statistics.maximumEpisodes
        metrics.maximumDeferred = statistics.maximumDeferred
        metrics.finalEpisodes = run.snapshot.presented.count + run.snapshot.tracked.count
        let delays = alerts.map(\.engineDelay)
        metrics.engineDelayMedian = percentile(delays, 0.5)
        metrics.engineDelayP95 = percentile(delays, 0.95)
        metrics.processingMedianMicroseconds = percentile(run.processingNanoseconds, 0.5) / 1000
        metrics.processingP95Microseconds = percentile(run.processingNanoseconds, 0.95) / 1000
        return metrics
    }

    /// Nearest-rank percentile; 0 for an empty list.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}
