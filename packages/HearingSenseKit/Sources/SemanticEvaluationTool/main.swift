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
    let reasoner = FoundationModelRelevanceReasoner()
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
        print("--set dev|heldout")
        exit(2)
    }
    let methods = (option("--methods") ?? "keyword,embedding,model").split(separator: ",").map(String.init)
    let dataset: SemanticDataset, development: SemanticDataset
    do {
        dataset = try SemanticDataset.load(split)
        development = try SemanticDataset.load(.dev)
    } catch {
        print("Could not load the dataset: \(error)")
        exit(1)
    }
    let counts = Dictionary(grouping: dataset.items, by: \.expected).mapValues(\.count)
    print("Set \(split.rawValue): \(dataset.items.count) synthetic utterances — "
        + SemanticDataset.Expected.allCases.map { "\($0.rawValue) \(counts[$0] ?? 0)" }.joined(separator: ", "))
    if split == .heldout { print("Held-out set: report only. Do not change prompts or thresholds after looking at it.") }
    print("")

    var results: [SemanticMetrics] = []
    var outcomesByMethod: [String: [SemanticItemOutcome]] = [:]
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
            let reasoner = FoundationModelRelevanceReasoner()
            guard await reasoner.availability().isUsable else {
                print("Language model not available on this system; skipped.\n")
                continue
            }
            let usesTriage = !arguments.contains("--no-triage")
            name = "Foundation Models reasoning + verifier (production pipeline, first pass \(usesTriage ? "on" : "off"))"
            let before = residentMegabytes()
            let started = Date()
            outcomes = await SemanticEvaluator.runEngine(dataset, reasoner: reasoner, usesTriage: usesTriage) { done, total in
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
                        + " → \(outcome.verdict ?? (outcome.alerted ? "alert" : "none"))"
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
            var outcomes: [String: [SemanticItemOutcome]]
        }
        let output = Output(split: split.rawValue, items: dataset.items.count,
                            note: "Synthetic utterances, evaluated on a Mac. Not an iPhone measurement.",
                            metrics: results, outcomes: outcomesByMethod)
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

case "ground":
    // Window 8: the reading check of recap statements (`isGrounded`) on statements whose truth
    // is known: true ones must be kept, planted false ones should be caught. Synthetic text.
    let summarizer = FoundationModelRecapSummarizer()
    guard await summarizer.isAvailable() else {
        print("Language model not available on this system.")
        exit(1)
    }
    // `--single`: one request per statement (the model's verdict alone). Default: one request
    // per scene (cited lines + verdict), then the check against the cited lines, as in the app.
    let single = arguments.contains("--single")
    var kept = 0, truths = 0, caught = 0, falsehoods = 0
    var seconds: [Double] = []
    for scene in GroundingProbe.scenes {
        print("\n[\(scene.name)]")
        let lines = scene.transcript.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var verdicts: [(Bool?, String)] = []
        let started = Date()
        if single {
            for (statement, _) in scene.statements {
                let begun = Date()
                let verdict = (try? await summarizer.isGrounded(statement, in: scene.transcript)).flatMap { $0 }
                seconds.append(Date().timeIntervalSince(begun))
                verdicts.append((verdict, ""))
            }
        } else {
            let evidence = (try? await summarizer.evidence(for: scene.statements.map(\.0), in: lines)).flatMap { $0 }
            seconds.append(Date().timeIntervalSince(started))
            for (index, (statement, _)) in scene.statements.enumerated() {
                guard let item = evidence?[index] else { verdicts.append((nil, "")); continue }
                let problem = RecapValidator().groundingProblem(statement, evidence: item, lines: lines)
                verdicts.append((problem == nil, "lines \(item.lines.map { $0 + 1 }) model:\(item.isSupported ? "yes" : "no") \(problem ?? "")"))
            }
        }
        for (index, (statement, isTrue)) in scene.statements.enumerated() {
            let (judged, note) = verdicts[index]
            if isTrue { truths += 1; if judged != false { kept += 1 } } else { falsehoods += 1; if judged == false { caught += 1 } }
            let mark = judged == nil ? "?  " : (judged == isTrue ? "ok " : "BAD")
            print("  \(mark) \(isTrue ? "true " : "false") \(statement)  [\(note)]")
        }
    }
    seconds.sort()
    print("\ntrue statements kept \(kept)/\(truths); false statements caught \(caught)/\(falsehoods); "
        + "time per request median \(seconds[seconds.count / 2].formatted(.number.precision(.fractionLength(2)))) s, "
        + "max \((seconds.last ?? 0).formatted(.number.precision(.fractionLength(2)))) s")

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

default:
    print("Commands: run, recap, availability, judge, timing, triage")
    exit(2)
}


/// Statements with a known answer for `ground`. Invented conversations.
enum GroundingProbe {
    struct Scene {
        var name: String
        var transcript: String
        var statements: [(String, Bool)]
    }

    static let scenes: [Scene] = [
        Scene(name: "casual", transcript: """
            Vic, are you coming down for dinner?
            Yeah, in a minute, I am still on the call.
            They are playing the new game right now, probably.
            My family is visiting on Sunday, so I have to clean the room.
            Tomorrow, tomorrow we have the meeting with Ms. Wang at three.
            Don't forget she wants the signed form before the meeting.
            The other student in my group has not answered yet.
            Okay, I will remind him tonight.
            """, statements: [
                ("The meeting with Ms. Wang is tomorrow at three.", true),
                ("Ms. Wang wants the signed form before the meeting.", true),
                ("The family is visiting on Sunday.", true),
                ("A student in the group has not answered yet.", true),
                ("They are probably playing the new game right now.", true),
                ("Vic is a student in their family.", false),
                ("Vic had a boring day.", false),
                ("The meeting with Ms. Wang is on Sunday.", false),
                ("Ms. Wang is visiting the family on Sunday.", false),
                ("The signed form is not needed before the meeting.", false),
                ("Vic is angry because the room is not clean.", false),
            ]),
        Scene(name: "project", transcript: """
            So for the chemistry project, are we still meeting on Thursday?
            No, Thursday doesn't work, the library closes at five that day.
            What about Saturday morning then, around ten?
            Saturday at ten works, but not at the library, it's closed on weekends.
            We could use the study room in the science building, room 204.
            I have the data on my laptop, but the graphs are not finished.
            Then please finish the graphs by Friday night so we can write the report on Saturday.
            """, statements: [
                ("The meeting is on Saturday at ten in room 204 of the science building.", true),
                ("Thursday does not work because the library closes at five.", true),
                ("The graphs are not finished yet.", true),
                ("The graphs should be finished by Friday night.", true),
                ("The library is closed on weekends.", true),
                ("The meeting is on Thursday at five in the library.", false),
                ("The graphs are finished.", false),
                ("The report is due on Friday night.", false),
                ("The teacher asked for the report by Saturday.", false),
                ("They will meet at the library on Saturday.", false),
            ]),
        Scene(name: "pharmacy", transcript: """
            Take one tablet twice a day with food, morning and evening.
            Don't take it with grapefruit juice.
            Keep taking it for ten days, even if you feel better after three.
            If you get a rash, stop and call the doctor.
            You don't need an appointment for the refill, but it is not automatic, you have to call us.
            """, statements: [
                ("One tablet is taken twice a day with food.", true),
                ("It should not be taken with grapefruit juice.", true),
                ("The tablets are taken for ten days.", true),
                ("With a rash, the tablets are stopped and the doctor is called.", true),
                ("The refill is not automatic and has to be requested by phone.", true),
                ("The tablets are taken for three days.", false),
                ("An appointment is needed for the refill.", false),
                ("It should be taken with grapefruit juice.", false),
                ("The doctor prescribed the tablets because of a rash.", false),
            ]),
    ]
}
