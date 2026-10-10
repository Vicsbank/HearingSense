// hs-attention-eval — deterministic replay of scripted scenes through the production
// AttentionEngine (Window 4). No microphone, no classifier, no language model, no training.
//
//   hs-attention-eval scenarios [--json <file>]      the 18 scenes in the three modes
//   hs-attention-eval trace <scenario-id> [--mode quiet|balanced|sensitive]
//   hs-attention-eval soak [--hours 1] [--seed N] [--json <file>]
//   hs-attention-eval determinism                    replays everything twice and compares
//   hs-attention-eval list
//
// Every number printed here describes scripted, synthetic input (model id `synthetic.replay`).
// It shows how the engine's rules behave; it is not a measurement of real-world accuracy.

import Attention
import AttentionReplay
import Foundation
import HearingSenseAudio
import HearingSenseDomain

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "scenarios"

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func preferences(_ mode: AttentionMode) -> AttentionPreferences { AttentionPreferences(mode: mode) }

func percent(_ value: Double?) -> String {
    value.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) + " %" } ?? "–"
}

func number(_ value: Double?, _ digits: Int = 1) -> String {
    value.map { $0.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) } ?? "–"
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

struct ModeSummary: Codable {
    var mode: String
    var metrics: ScenarioMetrics
    var importantRetention: Double?
    var duplicateSuppression: Double?
    var unnecessaryAlertReduction: Double?
    var unnecessaryAlertsPerHour: Double?
    var baselineUnnecessaryAlertsPerHour: Double?

    init(mode: AttentionMode, metrics: ScenarioMetrics) {
        self.mode = mode.rawValue
        self.metrics = metrics
        importantRetention = metrics.importantRetention
        duplicateSuppression = metrics.duplicateSuppression
        unnecessaryAlertReduction = metrics.unnecessaryAlertReduction
        unnecessaryAlertsPerHour = metrics.unnecessaryAlertsPerHour
        baselineUnnecessaryAlertsPerHour = metrics.baselineUnnecessaryAlertsPerHour
    }
}

struct ScenarioSummary: Codable {
    var id: String
    var title: String
    var summary: String
    var modes: [ModeSummary]
}

struct Report: Codable {
    var tool = "hs-attention-eval"
    var note = "Scripted synthetic input replayed through the production AttentionEngine. Not real-world accuracy."
    var generated: Date
    var labels: [String: String]
    var scenarios: [ScenarioSummary]
    var totals: [ModeSummary]
    var processMemoryMBBefore: Double?
    var processMemoryMBAfter: Double?
}

let labelDefinitions: [String: String] = [
    "important": "Should lead to an alert in every mode (warning signal, knock, possible spoken warning, new independent occurrence).",
    "optional": "Depends on mode and context (dog, ordinary or informative speech). Neither required nor an error.",
    "ambient": "Background sound. Unwanted in Quiet and Balanced; Sensitive mentions it once at low priority by design.",
    "irrelevant": "Must never alert (music, probable lyrics, handling noise, muted categories).",
    "duplicate": "A repeat of something already reported.",
]

func write(_ report: Report, to path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    do {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: url)
        print("\nWrote \(path)")
    } catch {
        print("Could not write \(path): \(error.localizedDescription)")
    }
}

func printHeader() {
    print(pad("scenario", 34) + pad("mode", 10) + pad("alerts", 8) + pad("base", 6) + pad("important", 11)
        + pad("dup.suppr", 11) + pad("unnec", 7) + pad("b.unnec", 9) + pad("SHOW/UPD/SUP/DEF/RES/EXP", 26)
        + pad("p50 µs", 8) + "p95 µs")
}

func row(_ name: String, _ mode: AttentionMode, _ metrics: ScenarioMetrics) -> String {
    let actions = AttentionAction.allCases.map { "\(metrics.actions[$0.rawValue] ?? 0)" }.joined(separator: "/")
    return pad(name, 34) + pad(mode.rawValue, 10) + pad("\(metrics.engineAlerts)", 8) + pad("\(metrics.baselineAlerts)", 6)
        + pad("\(metrics.importantRetained)/\(metrics.importantSources)", 11)
        + pad("\(metrics.duplicatesSuppressed)/\(metrics.duplicateSources)", 11)
        + pad("\(metrics.unnecessaryAlerts)", 7) + pad("\(metrics.baselineUnnecessaryAlerts)", 9) + pad(actions, 26)
        + pad(number(metrics.processingMedianMicroseconds), 8) + number(metrics.processingP95Microseconds)
}

func printTotals(_ totals: [ModeSummary]) {
    print("\nTotals per mode (synthetic scenes):")
    for total in totals {
        let metrics = total.metrics
        print("  \(pad(total.mode, 10)) important retained \(metrics.importantRetained)/\(metrics.importantSources) "
            + "(\(percent(metrics.importantRetention))); duplicates suppressed \(metrics.duplicatesSuppressed)/"
            + "\(metrics.duplicateSources) (\(percent(metrics.duplicateSuppression))); unnecessary alerts "
            + "\(metrics.unnecessaryAlerts) vs baseline \(metrics.baselineUnnecessaryAlerts) "
            + "(reduction \(percent(metrics.unnecessaryAlertReduction))); alerts \(metrics.engineAlerts) vs baseline "
            + "\(metrics.baselineAlerts); by label \(metrics.engineAlertsByLabel.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
    }
}

func latencySummary(_ runs: [ScenarioRun]) -> (median: Double, p95: Double, maximum: Double, count: Int) {
    let all = runs.flatMap(\.processingNanoseconds).map { $0 / 1000 }
    return (AttentionReplayer.percentile(all, 0.5), AttentionReplayer.percentile(all, 0.95), all.max() ?? 0, all.count)
}

switch command {
case "list":
    for scenario in ScenarioLibrary.all {
        print("\(pad(scenario.id, 36)) \(scenario.title) — \(scenario.summary)")
    }

case "trace":
    guard arguments.count > 1, let scenario = ScenarioLibrary.scenario(id: arguments[1]) else {
        print("Usage: hs-attention-eval trace <scenario-id> [--mode quiet|balanced|sensitive]")
        exit(2)
    }
    let mode = option("--mode").flatMap(AttentionMode.init(rawValue:)) ?? .balanced
    let run = AttentionReplayer.run(scenario, preferences: preferences(mode))
    print("\(scenario.title) — \(mode.displayName)\n\(scenario.summary)\n")
    print("Scripted sources:")
    for truth in scenario.truths {
        print("  \(pad(truth.key, 10)) t=\(number(truth.time.timeIntervalSince(scenario.start)))s  \(pad(truth.label.rawValue, 11)) \(truth.name)")
    }
    print("\nDecisions (private speech text is never printed):")
    for item in run.decisions {
        let time = item.decision.decidedAt.timeIntervalSince(scenario.start)
        let intent = item.decision.intent.map { " → \($0.action.rawValue)/\($0.interruption.rawValue)\($0.hasPrivateDetail ? " +private" : "")" } ?? ""
        print("  t=\(pad(number(time) + "s", 8)) \(pad(item.sourceKey ?? "-", 10)) \(item.decision.summary)\(intent)")
    }
    print("\n" + row(scenario.id, mode, run.metrics))

case "scenarios":
    let before = ProcessResourceUsage.sample().memoryFootprintMB
    var summaries: [ScenarioSummary] = []
    var totals: [AttentionMode: ScenarioMetrics] = [:]
    var runs: [ScenarioRun] = []
    printHeader()
    for scenario in ScenarioLibrary.all {
        var modes: [ModeSummary] = []
        for mode in AttentionMode.allCases {
            let run = AttentionReplayer.run(scenario, preferences: preferences(mode))
            runs.append(run)
            modes.append(ModeSummary(mode: mode, metrics: run.metrics))
            totals[mode, default: ScenarioMetrics()].add(run.metrics)
            print(row(scenario.id, mode, run.metrics))
        }
        summaries.append(ScenarioSummary(id: scenario.id, title: scenario.title, summary: scenario.summary, modes: modes))
    }
    let totalSummaries = AttentionMode.allCases.map { ModeSummary(mode: $0, metrics: totals[$0] ?? ScenarioMetrics()) }
    printTotals(totalSummaries)
    let latency = latencySummary(runs)
    print("\nDecision time per input (wall clock, this Mac, \(latency.count) inputs): median \(number(latency.median)) µs, "
        + "p95 \(number(latency.p95)) µs, max \(number(latency.maximum)) µs")
    let after = ProcessResourceUsage.sample().memoryFootprintMB
    if let path = option("--json") {
        write(Report(generated: .now, labels: labelDefinitions, scenarios: summaries, totals: totalSummaries,
                     processMemoryMBBefore: before, processMemoryMBAfter: after), to: path)
    }

case "soak":
    let hours = option("--hours").flatMap(Double.init) ?? 1
    let seed = option("--seed").flatMap(UInt64.init) ?? 20_261_010
    let scenario = ScenarioLibrary.soak(hours: hours, seed: seed)
    let before = ProcessResourceUsage.sample().memoryFootprintMB
    print("\(scenario.title) (seed \(seed)): \(scenario.truths.count) scripted sources, \(scenario.steps.count) inputs")
    print("Sources by label: " + Dictionary(grouping: scenario.truths, by: \.label.rawValue).mapValues(\.count)
        .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    printHeader()
    var modes: [ModeSummary] = []
    var runs: [ScenarioRun] = []
    for mode in AttentionMode.allCases {
        let run = AttentionReplayer.run(scenario, preferences: preferences(mode))
        runs.append(run)
        modes.append(ModeSummary(mode: mode, metrics: run.metrics))
        print(row(scenario.id, mode, run.metrics))
    }
    print("")
    for summary in modes {
        let metrics = summary.metrics
        print("  \(pad(summary.mode, 10)) important \(percent(metrics.importantRetention)); duplicates suppressed "
            + "\(percent(metrics.duplicateSuppression)); unnecessary alerts/h \(number(metrics.unnecessaryAlertsPerHour)) "
            + "(baseline \(number(metrics.baselineUnnecessaryAlertsPerHour))); alerts/h "
            + "\(number(Double(metrics.engineAlerts) / hours)) (baseline \(number(Double(metrics.baselineAlerts) / hours))); "
            + "max episodes \(metrics.maximumEpisodes), max deferred \(metrics.maximumDeferred), left at the end "
            + "\(metrics.finalEpisodes); engine delay p50/p95 \(number(metrics.engineDelayMedian, 2))/\(number(metrics.engineDelayP95, 2)) s")
        print("             alerts by label: " + metrics.engineAlertsByLabel.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    }
    let latency = latencySummary(runs)
    let after = ProcessResourceUsage.sample().memoryFootprintMB
    print("\nDecision time per input (wall clock, this Mac, \(latency.count) inputs): median \(number(latency.median)) µs, "
        + "p95 \(number(latency.p95)) µs, max \(number(latency.maximum)) µs")
    print("Process memory: \(number(before)) MB before, \(number(after)) MB after the three runs")
    if let path = option("--json") {
        write(Report(generated: .now, labels: labelDefinitions,
                     scenarios: [ScenarioSummary(id: scenario.id, title: scenario.title, summary: scenario.summary, modes: modes)],
                     totals: modes, processMemoryMBBefore: before, processMemoryMBAfter: after), to: path)
    }

case "determinism":
    var differences = 0
    var compared = 0
    for scenario in ScenarioLibrary.all + [ScenarioLibrary.soak(hours: 0.5)] {
        for mode in AttentionMode.allCases {
            let first = AttentionReplayer.run(scenario, preferences: preferences(mode)).decisions.map(\.decision)
            let second = AttentionReplayer.run(scenario, preferences: preferences(mode)).decisions.map(\.decision)
            compared += first.count
            if first != second {
                differences += 1
                print("DIFFERENT: \(scenario.id) \(mode.rawValue)")
            }
        }
    }
    print("Replayed every scene twice in every mode: \(compared) decisions compared, \(differences) runs differ")
    exit(differences == 0 ? 0 : 1)

default:
    print("Unknown command \(command). Commands: scenarios, trace, soak, determinism, list")
    exit(2)
}
