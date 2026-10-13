// hs-qwen-eval — Window 9: runs the REAL Qwen engine (native Swift MLX, on the Mac) and the
// production postprocessing on synthetic English conversations, and compares the raw model
// output with the final output of each postprocessing mode.
//
//   hs-qwen-eval fresh    [--data <en_fresh_w9.json>] [--modes legacy,window9] [--texts] [--json <file>] [--engine qwen|apple]
//   hs-qwen-eval dev      [--split dev|heldout]            Window 7 scenes (RecapEvaluator) with the Qwen engine
//   hs-qwen-eval latency  [--runs N]                        cold load and warm request timing
//
// Synthetic text only. Results are Mac numbers: not an iPhone measurement. The fresh cases are
// small and focused (regression and reading), not a statistical benchmark.
import ConversationUnderstanding
import Foundation
import QwenRuntime
import SemanticEvaluation

// MARK: - Cases

struct Fact: Codable { var id: String; var text: String; var all: [[String]] }
struct MustNot: Codable { var text: String; var all: [[String]]; var unless: [String]? }
struct RecapCase: Codable { var id: String; var focus: String; var lines: [String]; var facts: [Fact]; var must_not: [MustNot] }
struct ContinueCase: Codable {
    var id: String; var focus: String; var first: [String]; var later: [String]; var facts: [Fact]; var must_not: [MustNot]
}
struct CaseFile: Codable { var recaps: [RecapCase]; var continues: [ContinueCase] }

// MARK: - Scoring

func normalize(_ text: String) -> String {
    var out = ""
    for character in text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") {
        if character.isLetter || character.isNumber || ":$%' ".contains(character) { out.append(character) }
        else if character == "-" || character == "–" { out.append(" ") }
        else if character == "." || character == "," { out.append(" ") }
        else { out.append(" ") }
    }
    // Keep "3:30" and "$18" and "10%" intact; a trailing colon is dropped by the split below.
    return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

func sentences(of text: String) -> [String] {
    var result: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
        if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { result.append(s) }
    }
    // Foundation can split the label "Superseded:" into its own sentence. Carry it
    // onto the next sentence so historical text cannot score as a current claim.
    var pendingSuperseded = false
    return result.compactMap { text in
        let normalized = normalize(text)
        if normalized == "superseded" || normalized == "superseded:" { pendingSuperseded = true; return nil }
        defer { pendingSuperseded = false }
        return pendingSuperseded ? "superseded " + normalized : normalized
    }
}

func matches(_ groups: [[String]], in sentence: String) -> Bool {
    groups.allSatisfy { group in group.contains { sentence.contains(normalize($0)) } }
}

struct Score {
    var factsPresent = 0, factsTotal = 0, violations = 0, missed: [String] = [], violated: [String] = []
}

func score(_ sentences: [String], facts: [Fact], mustNot: [MustNot]) -> Score {
    var result = Score()
    result.factsTotal = facts.count
    let current = sentences.filter { !$0.hasPrefix("superseded ") && !$0.hasPrefix("superseded:") }
    for fact in facts {
        if current.contains(where: { matches(fact.all, in: $0) }) { result.factsPresent += 1 } else { result.missed.append(fact.id) }
    }
    for item in mustNot {
        let hit = current.contains { sentence in
            matches(item.all, in: sentence) && !(item.unless ?? []).contains { sentence.contains(normalize($0)) }
        }
        if hit { result.violations += 1; result.violated.append(item.text) }
    }
    return result
}

// MARK: - Replay (so that every mode post-processes the SAME raw model output)

struct ReplaySummarizer: ConversationSummarizing {
    var recapDraft: RecapDraft?
    var updateDraft: RecapDraft?
    let base: any ConversationSummarizing

    func isAvailable() async -> Bool { await base.isAvailable() }
    func prewarm() async {}
    func recap(transcript: String, notes: [String]) async throws -> RecapDraft {
        if let recapDraft { return recapDraft }
        return try await base.recap(transcript: transcript, notes: notes)
    }
    func update(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft {
        if let updateDraft { return updateDraft }
        return try await base.update(previous: previous, newTranscript: newTranscript)
    }
    func restate(_ statement: String) async throws -> String { try await base.restate(statement) }
    func rewrite(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft {
        try await base.rewrite(previous: previous, newTranscript: newTranscript)
    }
    func evidence(for statements: [String], in lines: [String]) async throws -> [StatementEvidence]? {
        try await base.evidence(for: statements, in: lines)
    }
}

let origin = Date(timeIntervalSince1970: 1_780_000_000)

func buffer(_ lines: [String], from start: Double) -> (RollingConversationBuffer, Date) {
    var buffer = RollingConversationBuffer(policy: .standard)
    buffer.begin(at: origin.addingTimeInterval(start - 1))
    var now = origin.addingTimeInterval(start)
    for line in lines {
        let begin = now
        now = now.addingTimeInterval(3.5)
        buffer.append(BufferedUtterance(text: line, start: begin, end: now), now: now)
    }
    return (buffer, now)
}

func draftSentences(_ draft: RecapDraft) -> [String] { sentences(of: draft.summary) + draft.keyPoints.map(normalize) }
func recapSentences(_ recap: ConversationRecap) -> [String] {
    recap.isSummary ? sentences(of: recap.summary) + recap.keyPoints.map(normalize) : []
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "fresh"
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }

let useApple = option("--engine") == "apple"
let directory = QwenModelLocator.locate()
guard command == "rescore" || useApple || directory != nil else { print("no complete Qwen checkpoint found"); exit(2) }
let qwen = QwenSummarizationEngine(modelDirectory: directory ?? URL(fileURLWithPath: "/nonexistent/qwen"))
let apple = AppleFoundationSummarizationEngine()
let engine: any ConversationSummarizing = useApple ? apple : qwen
if command != "rescore" { print("engine:", useApple ? "Apple on-device model" : qwen.identity.detail) }

switch command {
case "rescore":
    // Re-score saved synthetic native outputs without loading weights or making model calls.
    let path = option("--data") ?? "data/summary_regression/en_fresh_w9.json"
    guard let input = option("--input"), let saved = FileManager.default.contents(atPath: input),
          var report = try? JSONSerialization.jsonObject(with: saved) as? [[String: Any]],
          let data = FileManager.default.contents(atPath: path),
          let cases = try? JSONDecoder().decode(CaseFile.self, from: data) else { print("cannot read report/cases"); exit(2) }
    let modes = (option("--modes") ?? "legacy,window9,window9_verified").split(separator: ",").map(String.init)
    var totals: [String: (present: Int, total: Int, violations: Int)] = [:]
    for index in report.indices {
        let id = report[index]["id"] as? String ?? ""
        let recap = cases.recaps.first { $0.id == id }
        let continuation = cases.continues.first { $0.id == id }
        guard let facts = recap?.facts ?? continuation?.facts, let forbidden = recap?.must_not ?? continuation?.must_not else { continue }
        for label in modes + (recap == nil ? [] : ["raw"]) {
            let isSummary = label == "raw" || recap == nil || report[index][label + "_is_summary"] as? Bool == true
            let text = isSummary ? report[index][label + "_summary"] as? String ?? "" : ""
            let points = isSummary ? report[index][label + "_keyPoints"] as? [String] ?? [] : []
            let result = score(sentences(of: text) + points.map(normalize), facts: facts, mustNot: forbidden)
            report[index][label + "_facts"] = result.factsPresent
            report[index][label + "_violations"] = result.violations
            report[index][label + "_missed"] = result.missed
            report[index][label + "_violated"] = result.violated
            let key = (recap == nil ? "continue-" : "") + label
            var row = totals[key] ?? (0, 0, 0)
            row.present += result.factsPresent; row.total += result.factsTotal; row.violations += result.violations
            totals[key] = row
        }
    }
    print("Re-scored saved native outputs; NO new model execution. Source: \(input)")
    for (key, row) in totals.sorted(by: { $0.key < $1.key }) {
        print("\(key): facts \(row.present)/\(row.total), must-not violations \(row.violations)")
    }
    if let output = option("--json") {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
case "fresh":
    let path = option("--data") ?? "data/summary_regression/en_fresh_w9.json"
    guard let data = FileManager.default.contents(atPath: path), let cases = try? JSONDecoder().decode(CaseFile.self, from: data) else {
        print("cannot read cases at \(path)"); exit(2)
    }
    let modes = (option("--modes") ?? "window9").split(separator: ",").map(String.init)
    guard modes.allSatisfy({ ["legacy", "window9", "window9_verified"].contains($0) }) else {
        print("unknown mode; choose legacy, window9, window9_verified"); exit(2)
    }
    let showTexts = arguments.contains("--texts")
    var table: [String: (present: Int, total: Int, violations: Int, removed: Int, statements: Int, none: Int)] = [:]
    var rawTotals = (present: 0, total: 0, violations: 0)
    var modelSeconds: [Double] = []
    var report: [[String: Any]] = []

    func accumulate(_ label: String, _ s: Score, removed: Int = 0, statements: Int = 0, none: Bool = false) {
        var row = table[label] ?? (0, 0, 0, 0, 0, 0)
        row.present += s.factsPresent; row.total += s.factsTotal; row.violations += s.violations
        row.removed += removed; row.statements += statements; row.none += none ? 1 : 0
        table[label] = row
    }

    for item in arguments.contains("--only-continue") ? [] : cases.recaps {
        let (buf, now) = buffer(item.lines, from: 0)
        let excerpt = buf.excerpt(now: now)
        let probe = ConversationRecapEngine(summarizer: engine)
        let transcript = probe.transcript(of: excerpt)
        let started = Date()
        guard let draft = try? await engine.recap(transcript: transcript, notes: []) else {
            print("[\(item.id)] model failed")
            rawTotals.total += item.facts.count
            for mode in modes { accumulate(mode, score([], facts: item.facts, mustNot: item.must_not), none: true) }
            report.append(["id": item.id, "model_failed": true, "total": item.facts.count])
            continue
        }
        modelSeconds.append(Date().timeIntervalSince(started))
        let rawScore = score(draftSentences(draft), facts: item.facts, mustNot: item.must_not)
        rawTotals.present += rawScore.factsPresent; rawTotals.total += rawScore.factsTotal; rawTotals.violations += rawScore.violations
        print("\n[\(item.id)] \(item.focus)  raw: facts \(rawScore.factsPresent)/\(rawScore.factsTotal) violations \(rawScore.violations)"
            + " (\(seconds(modelSeconds.last ?? 0)) s)")
        if showTexts { print("  RAW: \(draft.summary)"); for point in draft.keyPoints { print("   • \(point)") } }
        var entry: [String: Any] = ["id": item.id, "raw_facts": rawScore.factsPresent, "total": rawScore.factsTotal,
                                    "raw_violations": rawScore.violations, "raw_missed": rawScore.missed, "model_seconds": modelSeconds.last ?? 0]
        for mode in modes {
            var policy = ConversationRecapEngine.Policy()
            policy.postprocessing = mode == "legacy" ? .legacy : .window9
            if mode == "window9_verified" { policy.verification = .uncertainOnly }
            let finalEngine = ConversationRecapEngine(summarizer: ReplaySummarizer(recapDraft: draft, updateDraft: nil, base: engine), policy: policy)
            let begun = Date()
            let recap = await finalEngine.recap(excerpt)
            let postSeconds = Date().timeIntervalSince(begun)
            let finalScore = score(recapSentences(recap), facts: item.facts, mustNot: item.must_not)
            accumulate(mode, finalScore, removed: recap.corrections.count, statements: recap.summary.isEmpty ? 0 : 1, none: !recap.isSummary)
            print("  \(mode): \(recap.isSummary ? "summary" : "NO SUMMARY (\(recap.source.rawValue))") facts \(finalScore.factsPresent)/\(finalScore.factsTotal)"
                + " violations \(finalScore.violations) verbatim \(seconds(recap.verbatimShare)) post \(seconds(postSeconds)) s corrections \(recap.corrections.joined(separator: ","))"
                + (finalScore.missed.isEmpty ? "" : " missed \(finalScore.missed)") + (finalScore.violated.isEmpty ? "" : " VIOLATED \(finalScore.violated)"))
            if showTexts { print("  FINAL(\(mode)): \(recap.summary)"); for point in recap.keyPoints { print("   • \(point)") } }
            entry[mode + "_facts"] = finalScore.factsPresent
            entry[mode + "_is_summary"] = recap.isSummary
            entry[mode + "_violations"] = finalScore.violations
            entry[mode + "_summary"] = recap.summary
            entry[mode + "_keyPoints"] = recap.keyPoints
            entry[mode + "_corrections"] = recap.corrections
            entry[mode + "_missed"] = finalScore.missed
            entry[mode + "_post_seconds"] = postSeconds
            entry[mode + "_total_seconds"] = (modelSeconds.last ?? 0) + postSeconds
        }
        entry["raw_summary"] = draft.summary
        entry["raw_keyPoints"] = draft.keyPoints
        report.append(entry)
    }

    if !useApple && !arguments.contains("--only-continue") {
        let metrics = await qwen.lastMetrics
        print("Qwen load: \(seconds(await qwen.loadSeconds ?? 0)) s; MLX active \(seconds(Double(metrics.activeBytes) / 1e9)) GB, peak \(seconds(Double(metrics.peakBytes) / 1e9)) GB")
    }

    // Continue cases: first recap, then an update with the later speech.
    for item in cases.continues {
        let (buf, now) = buffer(item.first, from: 0)
        let excerpt = buf.excerpt(now: now)
        let probe = ConversationRecapEngine(summarizer: engine)
        let transcript = probe.transcript(of: excerpt)
        guard let firstDraft = try? await engine.recap(transcript: transcript, notes: []) else {
            print("[\(item.id)] model failed")
            for mode in modes { accumulate("continue-" + mode, score([], facts: item.facts, mustNot: item.must_not), none: true) }
            report.append(["id": item.id, "model_failed": true, "total": item.facts.count])
            continue
        }
        let laterUtterances = item.later.enumerated().map { index, text in
            BufferedUtterance(text: text, start: now.addingTimeInterval(Double(index) * 3.5 + 1), end: now.addingTimeInterval(Double(index + 1) * 3.5 + 1))
        }
        let fresh = laterUtterances.map(\.text).joined(separator: "\n")
        print("\n[\(item.id)] \(item.focus)")
        var entry: [String: Any] = ["id": item.id]
        for mode in modes {
            var policy = ConversationRecapEngine.Policy()
            policy.postprocessing = mode == "legacy" ? .legacy : .window9
            if mode == "window9_verified" { policy.verification = .uncertainOnly }
            let firstEngine = ConversationRecapEngine(summarizer: ReplaySummarizer(recapDraft: firstDraft, updateDraft: nil, base: engine), policy: policy)
            let first = await firstEngine.recap(excerpt)
            guard first.isSummary else {
                print("  \(mode): first recap rejected")
                accumulate("continue-" + mode, score([], facts: item.facts, mustNot: item.must_not), none: true)
                entry[mode + "_first_rejected"] = true
                continue
            }
            let previous = RecapDraft(title: first.title, summary: first.summary, keyPoints: first.keyPoints)
            let started = Date()
            guard let addition = try? await engine.update(previous: previous, newTranscript: fresh) else {
                print("  \(mode): update failed")
                accumulate("continue-" + mode, score(recapSentences(first), facts: item.facts, mustNot: item.must_not), none: true)
                entry[mode + "_update_failed"] = true
                continue
            }
            let updateSeconds = Date().timeIntervalSince(started)
            let updater = ConversationRecapEngine(summarizer: ReplaySummarizer(recapDraft: firstDraft, updateDraft: addition, base: engine), policy: policy)
            let postStarted = Date()
            let updated = await updater.update(first, earlierTranscript: transcript, new: laterUtterances)
            let postSeconds = Date().timeIntervalSince(postStarted)
            let result = updated ?? first
            let s = score(recapSentences(result), facts: item.facts, mustNot: item.must_not)
            accumulate("continue-" + mode, s, none: updated == nil)
            print("  \(mode): update \(updated == nil ? "NOTHING/REJECTED" : "applied") facts \(s.factsPresent)/\(s.factsTotal) violations \(s.violations)"
                + " update model \(seconds(updateSeconds)) s, total \(seconds(updateSeconds + postSeconds)) s" + (s.missed.isEmpty ? "" : " missed \(s.missed)") + (s.violated.isEmpty ? "" : " VIOLATED \(s.violated)"))
            if showTexts { print("  AFTER: \(result.summary)"); for point in result.keyPoints { print("   • \(point)") }; print("  ADDITION RAW: \(addition.summary) outdated=\(addition.outdated)") }
            entry[mode + "_facts"] = s.factsPresent
            entry[mode + "_violations"] = s.violations
            entry[mode + "_summary"] = result.summary
            entry[mode + "_keyPoints"] = result.keyPoints
            entry[mode + "_missed"] = s.missed
            entry[mode + "_violated"] = s.violated
            entry[mode + "_model_seconds"] = updateSeconds
            entry[mode + "_post_seconds"] = postSeconds
            entry[mode + "_total_seconds"] = updateSeconds + postSeconds
        }
        report.append(entry)
    }

    if !useApple && arguments.contains("--only-continue") {
        let metrics = await qwen.lastMetrics
        print("Qwen load: \(seconds(await qwen.loadSeconds ?? 0)) s; MLX active \(seconds(Double(metrics.activeBytes) / 1e9)) GB, peak \(seconds(Double(metrics.peakBytes) / 1e9)) GB")
    }
    print("\n=== Totals (synthetic, small; regression only) ===")
    print("raw model output: facts \(rawTotals.present)/\(rawTotals.total), must-not violations \(rawTotals.violations)")
    for (label, row) in table.sorted(by: { $0.key < $1.key }) {
        print("\(label): facts \(row.present)/\(row.total), must-not violations \(row.violations), no-summary \(row.none)")
    }
    modelSeconds.sort()
    if !modelSeconds.isEmpty {
        print("model time per recap (warm after first): median \(seconds(modelSeconds[modelSeconds.count / 2])) s, max \(seconds(modelSeconds.last ?? 0)) s")
    }
    if let out = option("--json"), let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? json.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }

case "dev":
    let dataset = try ConversationDataset.load()
    let split = option("--split") ?? "dev"
    let results = await RecapEvaluator.run(dataset, split: split, summarizer: engine) { id in
        FileHandle.standardError.write(Data("  \(id)\n".utf8))
    }
    print(RecapEvaluator.report(results))

case "latency":
    guard !useApple else { print("latency command measures Qwen only"); exit(2) }
    let runs = Int(option("--runs") ?? "5") ?? 5
    guard (1...10).contains(runs) else { print("choose 1–10 runs"); exit(2) }
    let started = Date()
    await qwen.prewarm()
    print("cold load: \(seconds(Date().timeIntervalSince(started))) s")
    let (buf, now) = buffer(["we are meeting at seven forty five", "bring twenty dollars for the tickets", "the show starts at eight", "parking is behind the library", "Dana will bring the programs", "we should leave by seven"], from: 0)
    let transcript = ConversationRecapEngine(summarizer: qwen).transcript(of: buf.excerpt(now: now))
    for run in 1 ... runs {
        let begun = Date()
        do {
            let draft = try await qwen.recap(transcript: transcript, notes: [])
            guard !draft.summary.isEmpty else { print("run \(run): empty summary"); exit(1) }
        } catch {
            print("run \(run): failed (\(String(describing: type(of: error))))"); exit(1)
        }
        let m = await qwen.lastMetrics
        print("run \(run): \(seconds(Date().timeIntervalSince(begun))) s, prompt \(m.promptTokens) tok, generated \(m.generatedTokens) tok, \(seconds(m.tokensPerSecond)) tok/s, active \(seconds(Double(m.activeBytes) / 1e9)) GB, peak \(seconds(Double(m.peakBytes) / 1e9)) GB")
    }

default:
    print("unknown command \(command)")
}
