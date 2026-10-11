// hs-semantic-eval — evaluation of semantic attention on synthetic, labelled utterances
// (Window 6). Forward-only inference with the on-device language model; no training.
//
//   hs-semantic-eval run --set dev|heldout [--methods keyword,embedding,model] [--json <file>] [--errors]
//   hs-semantic-eval recap [--split dev|heldout] [--json <file>] [--texts]   recaps of synthetic conversations
//   hs-semantic-eval availability
//   hs-semantic-eval judge "<utterance>" [--profile student|traveler|worker]   one utterance, with the model's answer
//
// The embedding threshold is always chosen on the development set and then applied unchanged.
// Every number describes synthetic text on this Mac. It is not a measurement on an iPhone and
// not a measurement of real conversations.

import ConversationUnderstanding
import Foundation
import SemanticAttention
import SemanticEvaluation

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "run"

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func residentMegabytes() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

switch command {
case "availability":
    let reasoner = FoundationModelRelevanceReasoner()
    print("Language model: \(await reasoner.availability())")
    print("Sentence embedding (English): \(SentenceEmbeddingScorer().isAvailable ? "available" : "not available")")

case "judge":
    guard arguments.count > 1 else {
        print("Usage: hs-semantic-eval judge \"<utterance>\" [--profile student]")
        exit(2)
    }
    let goals = SemanticDataset.goals(for: option("--profile") ?? "student")
    let reasoner = FoundationModelRelevanceReasoner(
        style: FoundationModelRelevanceReasoner.Style(rawValue: option("--style") ?? "window6") ?? .window6)
    let utterance = SemanticUtterance(text: arguments[1])
    do {
        let started = Date()
        let judgement = try await reasoner.judge(utterance, goals: goals.map(\.goal))
        print("model (\(Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(2)))) s): \(judgement)")
        let decision = EvidenceVerifier.standard.verify(judgement, utterance: utterance, goals: goals.map(\.goal))
        print("verified: \(decision.redactedSummary)")
        print("headline: \(decision.headline.isEmpty ? "–" : decision.headline) · reason: \(decision.reason)")
    } catch {
        print("failed: \(error)")
        exit(1)
    }

case "run":
    guard let split = SemanticDataset.Split(rawValue: option("--set") ?? "dev") else {
        print("--set dev|heldout|dev2|sealed|dev3|sealed2")
        exit(2)
    }
    let methods = (option("--methods") ?? "keyword,embedding,model").split(separator: ",").map(String.init)
    var dataset: SemanticDataset
    let development: SemanticDataset
    do {
        dataset = try SemanticDataset.load(split)
        // --ids <file>: only these items (development subsets; separated by spaces or lines).
        if let path = option("--ids"), !split.isSealed {
            let wanted = Set(try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init))
            dataset.items = dataset.items.filter { wanted.contains($0.id) }
        }
        development = try SemanticDataset.load(.dev)
    } catch {
        print("Could not load the dataset: \(error)")
        exit(1)
    }
    let counts = Dictionary(grouping: dataset.items, by: \.expected).mapValues(\.count)
    print("Set \(split.rawValue): \(dataset.items.count) synthetic utterances — "
        + SemanticDataset.Expected.allCases.map { "\($0.rawValue) \(counts[$0] ?? 0)" }.joined(separator: ", "))
    if split == .heldout { print("Held-out set: report only. Do not change prompts or thresholds after looking at it.") }
    if split.isSealed { print("SEALED set: run once with the frozen configuration. Never tune on it.") }
    print("")

    var results: [SemanticMetrics] = []
    var outcomesByMethod: [String: [SemanticItemOutcome]] = [:]
    var confusions: [String: SemanticConfusion] = [:]
    for method in methods {
        let outcomes: [SemanticItemOutcome]
        let name: String
        switch method {
        case "keyword":
            name = "Keyword baseline"
            outcomes = SemanticEvaluator.runKeyword(dataset)
        case "embedding":
            let scorer = SentenceEmbeddingScorer()
            guard scorer.isAvailable else {
                print("Sentence embedding not available on this system; skipped.\n")
                continue
            }
            let threshold = SemanticEvaluator.bestThreshold(development, scorer: scorer)
            name = "Sentence-embedding retrieval (threshold \(threshold), chosen on dev)"
            outcomes = SemanticEvaluator.runSimilarity(dataset, scorer: scorer, threshold: threshold)
        case "model":
            // --config optimized alone selects the whole Window 6.1 configuration.
            let isOptimized = option("--config") == "optimized"
            let style = FoundationModelRelevanceReasoner.Style(rawValue: option("--style") ?? (isOptimized ? "lean" : "window6"))
                ?? .window6
            let turns = Int(option("--turns") ?? "") ?? (isOptimized ? FoundationModelRelevanceReasoner.optimizedSessionTurns : 1)
            let reasoner = FoundationModelRelevanceReasoner(style: style, sessionTurns: turns)
            guard await reasoner.availability().isUsable else {
                print("Language model not available on this system; skipped.\n")
                continue
            }
            // --config window6 | optimized: the whole engine configuration at once. Without it,
            // the standard configuration with the first pass on unless --no-triage is given.
            var configuration: SemanticAttentionEngine.Configuration?
            switch option("--config") {
            case "window6": configuration = .window6
            case "optimized": configuration = .standard
            default: break
            }
            if arguments.contains("--no-confirm") { configuration = configuration ?? .standard; configuration?.confirmsRelevant = false }
            let usesTriage = configuration?.usesTriage ?? !arguments.contains("--no-triage")
            name = "Foundation Models, style \(style.rawValue), first pass \(usesTriage ? "on" : "off"), second look "
                + ((configuration ?? .standard).confirmsRelevant && style != .window6 ? "on" : "off")
            let before = residentMegabytes()
            let started = Date()
            outcomes = await SemanticEvaluator.runEngine(dataset, reasoner: reasoner, usesTriage: usesTriage,
                                                         configuration: configuration) { done, total in
                if done % 10 == 0 || done == total { FileHandle.standardError.write(Data("  \(done)/\(total)\n".utf8)) }
            }
            print("  wall time \(Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))) s; "
                + "this process \(before.formatted(.number.precision(.fractionLength(0)))) → "
                + "\(residentMegabytes().formatted(.number.precision(.fractionLength(0)))) MB resident "
                + "(the model itself runs in a system process and is not included)")
        default:
            print("Unknown method \(method)")
            continue
        }
        let metrics = SemanticEvaluator.metrics(outcomes, dataset: dataset, method: name)
        results.append(metrics)
        outcomesByMethod[method] = outcomes
        print(SemanticEvaluator.report(metrics))
        let confusion = SemanticConfusion(outcomes, dataset: dataset)
        confusions[method] = confusion
        print(confusion.report)
        if arguments.contains("--errors") {
            let byID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.id, $0) })
            for item in dataset.items {
                guard let outcome = byID[item.id] else { continue }
                let wrong = switch item.expected {
                case .relevant: !outcome.alerted
                case .irrelevant, .repeat: outcome.alerted
                case .ambiguous: false
                }
                if wrong {
                    print("    ✗ \(item.id) [\(item.category), expected \(item.expected.rawValue)] \(item.text)"
                        + " → \(outcome.verdict ?? (outcome.alerted ? "alert" : "none")) @\(outcome.stage ?? "-")"
                        + " kind=\(outcome.kind ?? "-") subject=\(outcome.subject ?? "-") goal=\(outcome.matchedGoal ?? "-")"
                        + (outcome.corrections.isEmpty ? "" : " (\(outcome.corrections.joined(separator: ",")))"))
                }
            }
        }
        print("")
    }
    if let path = option("--json") {
        struct Output: Codable {
            var split: String
            var items: Int
            var note: String
            var metrics: [SemanticMetrics]
            var confusion: [String: SemanticConfusion]
            var outcomes: [String: [SemanticItemOutcome]]
        }
        let output = Output(split: split.rawValue, items: dataset.items.count,
                            note: "Synthetic utterances, evaluated on a Mac. Not an iPhone measurement.",
                            metrics: results, confusion: confusions, outcomes: outcomesByMethod)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(output).write(to: URL(fileURLWithPath: path))
            print("Wrote \(path)")
        } catch {
            print("Could not write \(path): \(error)")
        }
    }

case "recap":
    // Recaps of the synthetic conversations: fact recall, negations, statements removed by the
    // checks, the continued-session update. `--texts` prints what the model wrote.
    let dataset: ConversationDataset
    do {
        dataset = try ConversationDataset.load()
    } catch {
        print("Could not load the conversations: \(error)")
        exit(1)
    }
    let summarizer = FoundationModelRecapSummarizer()
    guard await summarizer.isAvailable() else {
        print("Language model not available on this system.")
        exit(1)
    }
    let split = option("--split")
    print("Conversation recaps — \(split ?? "all") scenes (synthetic; evaluated on a Mac)")
    let results = await RecapEvaluator.run(dataset, split: split, summarizer: summarizer) { id in
        FileHandle.standardError.write(Data("  \(id)\n".utf8))
    }
    print(RecapEvaluator.report(results))
    if arguments.contains("--texts") {
        for result in results {
            print("\n[\(result.id)] \(result.title) (\(result.source), \(result.corrections.joined(separator: ",")))")
            print(result.summary)
            for point in result.keyPoints { print("  • \(point)") }
            if let updated = result.updatedSummary { print("  after the update: \(updated)") }
        }
    }
    if let path = option("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }

case "timing":
    // How long one judgement takes with and without a prepared session (a session is prepared
    // while nothing is being said; the evaluation loop gives it no such pause).
    let goals = SemanticDataset.goals(for: "student").map(\.goal)
    let reasoner = FoundationModelRelevanceReasoner()
    let samples = ["The exam has been postponed until Friday.", "I think I left my umbrella at the coffee shop.",
                   "Please move away from the windows and go to the gym immediately.", "This sandwich is actually pretty good.",
                   "Attendance now counts toward the final mark.", "Did you watch the game last night?"]
    for pause in [0.0, 1.5] {
        var times: [Double] = []
        for sample in samples {
            if pause > 0 {
                await reasoner.prewarm()
                try? await Task.sleep(for: .seconds(pause))
            }
            let started = Date()
            _ = try? await reasoner.judge(SemanticUtterance(text: sample), goals: goals)
            times.append(Date().timeIntervalSince(started))
        }
        print("pause \(pause) s before each request: " + times.map { $0.formatted(.number.precision(.fractionLength(2))) }
            .joined(separator: "  ") + " s")
    }

case "triage":
    // Experiment: how good and how fast is a one-word first pass? (Development set only.)
    let dataset = try SemanticDataset.load(.dev)
    let reasoner = FoundationModelRelevanceReasoner()
    var passed: [SemanticDataset.Expected: (yes: Int, total: Int)] = [:]
    var times: [Double] = []
    var missed: [String] = []
    for item in dataset.items {
        let goals = SemanticDataset.goals(for: item.profile).map(\.goal)
        let started = Date()
        let answer = (try? await reasoner.couldMatter(SemanticUtterance(text: item.text), goals: goals)) ?? true
        times.append(Date().timeIntervalSince(started))
        var entry = passed[item.expected] ?? (0, 0)
        entry.total += 1
        if answer { entry.yes += 1 }
        passed[item.expected] = entry
        if !answer, item.expected == .relevant { missed.append(item.id) }
    }
    times.sort()
    for expected in SemanticDataset.Expected.allCases {
        let entry = passed[expected] ?? (0, 0)
        print("\(expected.rawValue): passed on \(entry.yes) of \(entry.total)")
    }
    print("median \(times[times.count / 2]) s, p95 \(times[Int(Double(times.count) * 0.95)]) s; relevant items stopped: \(missed)")

case "throughput", "speculation", "contention", "together":
    // Stream benchmarks (Window 6.1): synthetic, timestamped sentences through the engine's
    // queue, as in the app. Development data only.
    //   hs-semantic-eval throughput --config window6|optimized [--interval 1.5] [--count 40] [--profile student2]
    //   hs-semantic-eval speculation [--final-delay 0.8] [--count 24] [--revise-every 6]
    //   hs-semantic-eval contention [--interval 1.5] [--count 16]
    //   hs-semantic-eval together [--size 3]     accuracy of judging waiting sentences together
    let isWindow6 = option("--config") == "window6"
    let style: FoundationModelRelevanceReasoner.Style = isWindow6 ? .window6 : .lean
    let configuration: SemanticAttentionEngine.Configuration = isWindow6 ? .window6 : .standard
    let profile = option("--profile") ?? "student2"
    let count = Int(option("--count") ?? "") ?? 40
    let all = try SemanticDataset.load(.dev2).items.filter { $0.profile == profile && $0.expected != .repeat }
    // --mix dense: the file order, in which more than half of the sentences are relevant.
    // Default: one relevant sentence in about six, spread among the others, which is still
    // far more than in ordinary conversation.
    var items = Array(all.prefix(count))
    if option("--mix") != "dense", command == "throughput" {
        let relevant = all.filter { $0.expected == .relevant && $0.context.isEmpty }
        let others = all.filter { $0.expected != .relevant && $0.context.isEmpty }
        items = []
        var nextRelevant = 0
        for (index, item) in others.enumerated() where items.count < count {
            items.append(item)
            // Every fifth place, taking every fourth relevant sentence so that all kinds occur.
            if index % 5 == 2, relevant.indices.contains(nextRelevant), items.count < count {
                items.append(relevant[nextRelevant])
                nextRelevant += 4
            }
        }
    }
    let turns = Int(option("--turns") ?? "") ?? (isWindow6 ? 1 : FoundationModelRelevanceReasoner.optimizedSessionTurns)
    let reasoner = FoundationModelRelevanceReasoner(style: style, sessionTurns: turns)
    var json: Data?
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    switch command {
    case "throughput":
        let interval = Double(option("--interval") ?? "") ?? 1.5
        let result = await SemanticStreamBenchmark.throughput(
            name: "\(isWindow6 ? "Window 6" : "Window 6.1") engine, style \(style.rawValue)", items: items, interval: interval,
            reasoner: reasoner, configuration: configuration)
        print(result.report)
        json = try? encoder.encode(result)
    case "speculation":
        let delay = Double(option("--final-delay") ?? "") ?? 0.8
        let reviseEvery = Int(option("--revise-every") ?? "") ?? 6
        var results: [SemanticStreamBenchmark.SpeculationResult] = []
        var plain: [String: String] = [:]
        for usesSpeculation in [false, true] {
            var (result, verdicts) = await SemanticStreamBenchmark.speculation(
                name: usesSpeculation ? "early evaluation of the stable partial transcript" : "final transcript only",
                items: items, finalDelay: delay, usesSpeculation: usesSpeculation, reviseEvery: reviseEvery,
                reasoner: FoundationModelRelevanceReasoner(style: style, sessionTurns: turns), configuration: configuration)
            if usesSpeculation {
                result.verdictsEqualToPlainRun = verdicts.count { plain[$0.key] == $0.value }
                print(result.report)
                print("  same outcome as with the final transcript only: \(result.verdictsEqualToPlainRun ?? 0) of \(verdicts.count)")
            } else {
                plain = verdicts
                print(result.report)
            }
            results.append(result)
        }
        json = try? encoder.encode(results)
    case "contention":
        let interval = Double(option("--interval") ?? "") ?? 1.5
        let scenes = try ConversationDataset.load().scenes
        guard let scene = scenes.first(where: { $0.split == "dev" }) ?? scenes.first else { exit(1) }
        var results: [SemanticStreamBenchmark.ContentionResult] = []
        // A few warning-like sentences among ordinary ones, so that some arrive during the recap.
        let urgent = all.filter(\.isUrgent)
        var mixed: [SemanticDataset.Item] = []
        for (index, item) in all.filter({ !$0.isUrgent }).prefix(count).enumerated() {
            mixed.append(item)
            if index >= 4, index % 3 == 1, urgent.indices.contains((index - 4) / 3) { mixed.append(urgent[(index - 4) / 3]) }
        }
        for mode in SemanticStreamBenchmark.ContentionMode.allCases {
            let old = mode == .window6Pause
            let result = await SemanticStreamBenchmark.contention(
                mode: mode, items: mixed, interval: interval, recapAfter: 4, scene: scene,
                reasoner: old ? FoundationModelRelevanceReasoner(style: .window6) : .optimized,
                summarizer: FoundationModelRecapSummarizer(), configuration: old ? .window6 : .standard)
            print(result.report)
            results.append(result)
            try? await Task.sleep(for: .seconds(2))
        }
        json = try? encoder.encode(results)
    default:
        // Sentences in groups, as they are judged when they wait: how often does a group
        // request miss a relevant sentence that is judged relevant on its own?
        let size = Int(option("--size") ?? "") ?? 3
        let dataset = try SemanticDataset.load(.dev2)
        let goalsByProfile = Dictionary(uniqueKeysWithValues: Set(dataset.items.map(\.profile)).map {
            ($0, SemanticDataset.goals(for: $0).map(\.goal))
        })
        var groupsWithRelevant = 0, groupsFlagged = 0, namedRight = 0, groupsWithout = 0, falselyFlagged = 0
        var times: [Double] = []
        var missed: [String] = []
        for profile in goalsByProfile.keys.sorted() {
            let scored = dataset.items.filter { $0.profile == profile && ($0.expected == .relevant || $0.expected == .irrelevant) && $0.context.isEmpty }
            for start in stride(from: 0, to: scored.count - size + 1, by: size) {
                let group = Array(scored[start ..< start + size])
                let started = Date()
                guard let answer = try? await reasoner.judgeTogether(group.map { SemanticUtterance(text: $0.text) },
                                                                     goals: goalsByProfile[profile] ?? []) else { continue }
                times.append(Date().timeIntervalSince(started))
                let flagged = answer.judgement.verdict != .irrelevant && answer.judgement.goalIndex != 0
                let relevant = group.enumerated().filter { $0.element.expected == .relevant }
                if relevant.isEmpty {
                    groupsWithout += 1
                    if flagged { falselyFlagged += 1 }
                } else {
                    groupsWithRelevant += 1
                    if flagged {
                        groupsFlagged += 1
                        if relevant.contains(where: { $0.offset == answer.line - 1 }) { namedRight += 1 }
                    } else {
                        missed.append(contentsOf: relevant.map(\.element.id))
                    }
                }
            }
        }
        times.sort()
        print("""
        Sentences judged \(size) at a time (development set 2, file order, no context items)
          groups with a relevant sentence: \(groupsWithRelevant); recognized as containing one: \(groupsFlagged); the named sentence is a relevant one: \(namedRight)
          relevant sentences in groups that were waved through: \(missed.count) (\(missed.joined(separator: " ")))
          groups without a relevant sentence: \(groupsWithout); flagged anyway (costs requests, not correctness): \(falselyFlagged)
          seconds per group request: median \(times.isEmpty ? 0 : times[times.count / 2])
        """)
    }
    if let path = option("--json"), let json {
        try? json.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }

case "cues":
    // The order cue for warning-like sentences on the development sets (no model): how many
    // of the short urgent instructions it sends to the front, and how much else.
    let gate = UtteranceGate()
    for split in [SemanticDataset.Split.dev, .dev2] {
        let items = try SemanticDataset.load(split).items
        let urgent = items.filter { $0.isUrgent || ($0.isImportant && $0.expected == .relevant) }
        let rest = items.filter { !$0.isImportant && !$0.isUrgent }
        let missed = urgent.filter { !gate.isLikelyUrgent($0.text) }
        print("\(split.rawValue): urgent or important sentences sent first \(urgent.count - missed.count) of \(urgent.count)"
            + " (not: \(missed.map(\.id).joined(separator: " "))); other sentences sent first "
            + "\(rest.count { gate.isLikelyUrgent($0.text) }) of \(rest.count)")
    }

case "latency":
    // Where the time of one judgement goes (Window 6.1): per style, with and without a session
    // that was prepared in an idle gap, with and without the goals read in advance.
    //   hs-semantic-eval latency [--styles window6,compact,reasoned] [--count 12] [--gap 1.0]
    let styles = (option("--styles") ?? "window6,compact,reasoned").split(separator: ",")
        .compactMap { FoundationModelRelevanceReasoner.Style(rawValue: String($0)) }
    let count = Int(option("--count") ?? "") ?? 12
    let gap = Double(option("--gap") ?? "") ?? 1.0
    let dataset = try SemanticDataset.load(.dev)
    let goals = SemanticDataset.goals(for: option("--profile") ?? "student").map(\.goal)
    // Every sixth item: a mix of relevant and irrelevant sentences.
    let samples = stride(from: 0, to: dataset.items.count, by: max(1, dataset.items.count / count)).prefix(count)
        .map { dataset.items[$0].text }
    func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
    func text(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
    print("style | preparation | prepared session | first token | generation | total | tokens in (cached) | tokens out")
    for style in styles {
        for mode in ["cold", "prepared", "prepared+goals"] {
            let reasoner = FoundationModelRelevanceReasoner(style: style, measuresFirstToken: !arguments.contains("--no-stream"),
                                                            sessionTurns: Int(option("--turns") ?? "") ?? 1)
            var timings: [ReasonerTiming] = []
            for sample in samples {
                if mode == "prepared" { await reasoner.prewarm() }
                if mode == "prepared+goals" { await reasoner.prewarm(goals: goals) }
                try? await Task.sleep(for: .seconds(gap))
                if let timing = try? await reasoner.judge(SemanticUtterance(text: sample), goals: goals).timing {
                    timings.append(timing)
                }
                // `judge` prepares the next session by itself; "cold" must not profit from it.
                if mode == "cold" { try? await Task.sleep(for: .seconds(0.2)) }
            }
            let output = timings.compactMap(\.outputTokens).map(Double.init)
            print("\(style.rawValue) | \(mode) | prep \(text(median(timings.map(\.preparation)))) s | first "
                + "\(text(median(timings.compactMap(\.firstToken)))) s | generation \(text(median(timings.map(\.generation)))) s | "
                + "total \(text(median(timings.map(\.total)))) s (max \(text(timings.map(\.total).max() ?? 0))) | in "
                + "\(Int(median(timings.compactMap(\.inputTokens).map(Double.init)))) "
                + "(\(Int(median(timings.compactMap(\.cachedInputTokens).map(Double.init))))) | out \(Int(median(output))) "
                + "| n \(timings.count)")
        }
    }

case "probe":
    // Research (Window 6.2): the model asked directly, one variable at a time.
    //   hs-semantic-eval probe --set dev3 --variant lean [--turns 6] [--seed 1] [--repeat-schema] [--repeat-goals]
    //                          [--json <file>]
    guard let split = SemanticDataset.Split(rawValue: option("--set") ?? "dev3"), !split.isSealed,
          let dataset = try? SemanticDataset.load(split), let variant = ProbeCatalog.variants[option("--variant") ?? "lean"]
    else {
        print("probe --set dev|dev2|dev3 --variant " + ProbeCatalog.variants.keys.sorted().joined(separator: "|"))
        exit(2)
    }
    var options = SemanticProbe.Options()
    options.sessionTurns = Int(option("--turns") ?? "") ?? 1
    options.seed = option("--seed").flatMap { UInt64($0) }
    options.repeatsSchema = arguments.contains("--repeat-schema")
    options.repeatsGoals = arguments.contains("--repeat-goals")
    print("Probe \(variant.name) on \(split.rawValue): \(dataset.items.count) items, session of \(options.sessionTurns), "
        + "order \(options.seed.map { "shuffled \($0)" } ?? "as written")")
    let answers = await SemanticProbe.run(dataset, variant: variant, options: options) { done, total in
        if done % 20 == 0 || done == total { FileHandle.standardError.write(Data("  \(done)/\(total)\n".utf8)) }
    }
    let run = ProbeRun(set: split.rawValue, variant: variant.name, turns: options.sessionTurns, seed: options.seed,
                       answers: answers, score: SemanticProbe.score(answers, dataset: dataset))
    printProbe(run, dataset: dataset)
    if let path = option("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(run).write(to: URL(fileURLWithPath: path))
    }

case "probe-cost":
    // Where the time goes: hs-semantic-eval probe-cost --variant lean [--profile tenant]
    guard let variant = ProbeCatalog.variants[option("--variant") ?? "lean"], let dataset = try? SemanticDataset.load(.dev3) else {
        print("probe-cost --variant " + ProbeCatalog.variants.keys.sorted().joined(separator: "|"))
        exit(2)
    }
    let profile = option("--profile") ?? "tenant"
    let sentences = dataset.items.filter { $0.profile == profile && $0.context.isEmpty }.map(\.text)
    print("Costs of \(variant.name), goals of \(profile)")
    let costs = await SemanticProbe.costs(variant: variant, goals: SemanticDataset.goals(for: profile).map(\.goal),
                                          sentences: sentences,
                                          checkInstructions: FoundationModelRelevanceReasoner.confirmInstructions) { print("  " + $0) }
    if let path = option("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(costs).write(to: URL(fileURLWithPath: path))
    }

case "probe-check":
    // A second request on every positive answer of an earlier probe run.
    //   hs-semantic-eval probe-check --from <probe json> --check confirm [--json <file>]
    guard let path = option("--from"), let data = FileManager.default.contents(atPath: path),
          var run = try? JSONDecoder().decode(ProbeRun.self, from: data),
          let split = SemanticDataset.Split(rawValue: run.set), !split.isSealed,
          let dataset = try? SemanticDataset.load(split), let check = ProbeCatalog.checks[option("--check") ?? "confirm"]
    else {
        print("probe-check --from <probe json> --check " + ProbeCatalog.checks.keys.sorted().joined(separator: "|"))
        exit(2)
    }
    print("Check \(check.name) on the positive answers of \(run.variant) (\(run.set))")
    run.answers = await SemanticProbe.check(run.answers, dataset: dataset, check: check) { done, total in
        if done % 20 == 0 || done == total { FileHandle.standardError.write(Data("  \(done)/\(total)\n".utf8)) }
    }
    run.check = check.name
    run.checkedScore = SemanticProbe.score(run.answers, dataset: dataset, keeps: check.keeps)
    print("  before: " + run.score.line)
    printProbe(run, dataset: dataset, keeps: check.keeps)
    let checkSeconds = run.answers.compactMap(\.checkSeconds)
    if !checkSeconds.isEmpty {
        print("  check: \(checkSeconds.count) requests, mean "
            + "\((checkSeconds.reduce(0, +) / Double(checkSeconds.count)).formatted(.number.precision(.fractionLength(2)))) s")
    }
    if let path = option("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(run).write(to: URL(fileURLWithPath: path))
    }

default:
    print("Commands: run, recap, availability, judge, timing, triage, latency, probe, probe-check")
    exit(2)
}
