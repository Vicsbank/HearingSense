import Foundation
import FoundationModels
import SemanticAttention

/// Where the time of a request goes (Window 6.2 research): text the model has to read again,
/// text it still holds, tokens it writes, and what another session's request does to all that.
extension SemanticProbe {
    public struct Cost: Codable, Sendable {
        public var label: String
        public var seconds: Double
        public var inputTokens: Int?
        public var cachedTokens: Int?
        public var outputTokens: Int?

        public var line: String {
            "\(label.padding(toLength: 46, withPad: " ", startingAt: 0)) \(seconds.formatted(.number.precision(.fractionLength(2)))) s"
                + "  in \(inputTokens.map(String.init) ?? "–") (held \(cachedTokens.map(String.init) ?? "–"))  out \(outputTokens.map(String.init) ?? "–")"
        }
    }

    public static func costs(variant: Variant, goals: [AttentionGoal], sentences: [String], checkInstructions: String,
                             log: @Sendable (String) -> Void) async -> [Cost]
    {
        var costs: [Cost] = []
        var next = 0
        func sentence() -> String {
            defer { next += 1 }
            return sentences[next % sentences.count]
        }
        func timed(_ label: String, _ session: LanguageModelSession, goals: [AttentionGoal], schema: Bool) async {
            var answer = Answer(id: "", kind: "", goal: 0, verdict: "", turn: 0, seconds: 0)
            let started = Date()
            try? await ask(session, prompt(sentence(), context: [], goals: goals), variant: variant, includesSchema: schema,
                           goalCount: goals.count, into: &answer)
            let cost = Cost(label: label, seconds: Date().timeIntervalSince(started), inputTokens: answer.inputTokens,
                            cachedTokens: answer.cachedTokens, outputTokens: answer.outputTokens)
            costs.append(cost)
            log(cost.line)
        }
        func fresh() -> LanguageModelSession {
            LanguageModelSession(model: SystemLanguageModel.default, instructions: variant.instructions)
        }
        func other() async {
            // Another session uses the model (a second look, a recap).
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: checkInstructions)
            _ = try? await session.respond(to: "Sentence: " + quoted(sentence()), generating: ProbeAbout.self,
                                           options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16))
        }
        let goalText = "The listener's goals:\n" + goals.enumerated().map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n") + "\n"

        await timed("warm-up (not counted)", fresh(), goals: goals, schema: true)
        for index in 1 ... 4 { await timed("new session, nothing prepared #\(index)", fresh(), goals: goals, schema: true) }
        for index in 1 ... 4 {
            let session = fresh()
            session.prewarm(promptPrefix: Prompt(goalText))
            try? await Task.sleep(for: .seconds(1.5))
            await timed("new session, prepared 1.5 s ahead #\(index)", session, goals: goals, schema: true)
        }
        do {
            let session = fresh()
            session.prewarm(promptPrefix: Prompt(goalText))
            await timed("new session, prepared and asked at once", session, goals: goals, schema: true)
        }
        let kept = fresh()
        for turn in 1 ... 12 {
            await timed("kept session, request \(turn)", kept, goals: turn == 1 ? goals : [], schema: turn == 1)
        }
        await other()
        await timed("kept session after another session's request", kept, goals: [], schema: false)
        await other()
        kept.prewarm()
        try? await Task.sleep(for: .seconds(2))
        await timed("… after another's request, made ready, 2 s", kept, goals: [], schema: false)
        await other()
        kept.prewarm()
        await timed("… after another's request, made ready, at once", kept, goals: [], schema: false)

        // Two requests at the same moment in two sessions: does the system run them side by side?
        let first = fresh(), second = fresh()
        let started = Date()
        async let one: Void = { _ = try? await first.respond(to: prompt(sentences[0], context: [], goals: goals),
                                                              generating: ProbeKindGoal.self) }()
        async let two: Void = { _ = try? await second.respond(to: prompt(sentences[1], context: [], goals: goals),
                                                              generating: ProbeKindGoal.self) }()
        _ = await (one, two)
        let together = Cost(label: "two new sessions asked at the same moment (both)", seconds: Date().timeIntervalSince(started))
        costs.append(together)
        log(together.line)
        return costs
    }
}

/// When the parts of a structured answer arrive (Window 6.2): can a request be abandoned as
/// soon as its first field says that the sentence is everyday talk?
extension SemanticProbe {
    public static func streamTimeline(instructions: String, goals: [AttentionGoal], sentences: [String],
                                      log: @Sendable (String) -> Void) async
    {
        for sentence in sentences {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let asked = Date()
            var line = ""
            var seen = (kind: false, goal: false, verdict: false)
            var count = 0
            do {
                let stream = session.streamResponse(to: prompt(sentence, context: [], goals: goals),
                                                    generating: ProbeKindGoalVerdict.self,
                                                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 40))
                for try await partial in stream {
                    count += 1
                    let seconds = Date().timeIntervalSince(asked).formatted(.number.precision(.fractionLength(2)))
                    if !seen.kind, let kind = partial.content.kind {
                        seen.kind = true
                        line += " kind=\(kind.rawValue)@\(seconds)"
                    }
                    if !seen.goal, let goal = partial.content.goal {
                        seen.goal = true
                        line += " goal=\(goal)@\(seconds)"
                    }
                    if !seen.verdict, let verdict = partial.content.verdict {
                        seen.verdict = true
                        line += " verdict=\(verdict.rawValue)@\(seconds)"
                    }
                }
            } catch {
                line += " failed \(type(of: error))"
            }
            log("\(count) parts, done@\(Date().timeIntervalSince(asked).formatted(.number.precision(.fractionLength(2))))\(line)")
        }
    }

    /// The same request abandoned after its first field: how long until the answer's kind is
    /// known, and how long the next request then takes (is the model free at once?).
    public static func abandonTimeline(instructions: String, goals: [AttentionGoal], sentences: [String],
                                       log: @Sendable (String) -> Void) async
    {
        for sentence in sentences {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let asked = Date()
            var kind = ""
            let task = Task { () -> String in
                let stream = session.streamResponse(to: prompt(sentence, context: [], goals: goals),
                                                    generating: ProbeKindGoalVerdict.self,
                                                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 40))
                for try await partial in stream {
                    if let kind = partial.content.kind { return kind.rawValue }
                }
                return "-"
            }
            kind = (try? await task.value) ?? "failed"
            let known = Date().timeIntervalSince(asked)
            // The next sentence, asked at once in a new session.
            let next = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let again = Date()
            _ = try? await next.respond(to: prompt(sentence, context: [], goals: goals), generating: ProbeKindGoal.self,
                                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24))
            log("kind=\(kind) known after \(known.formatted(.number.precision(.fractionLength(2)))) s; the next full request "
                + "took \(Date().timeIntervalSince(again).formatted(.number.precision(.fractionLength(2)))) s")
        }
    }
}

/// How long ahead a session has to be prepared for the preparation to help (Window 6.2).
extension SemanticProbe {
    public static func leadTimes(variant: Variant, goals: [AttentionGoal], sentences: [String], leads: [Double],
                                 log: @Sendable (String) -> Void) async
    {
        let goalText = "The listener's goals:\n" + goals.enumerated().map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n") + "\n"
        var next = 0
        func measure(_ lead: Double?) async -> (Double, Int?) {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: variant.instructions)
            if let lead {
                session.prewarm(promptPrefix: Prompt(goalText))
                try? await Task.sleep(for: .seconds(lead))
            }
            var answer = Answer(id: "", kind: "", goal: 0, verdict: "", turn: 0, seconds: 0)
            next += 1
            let started = Date()
            try? await ask(session, prompt(sentences[next % sentences.count], context: [], goals: goals), variant: variant,
                           includesSchema: false, goalCount: goals.count, into: &answer)
            return (Date().timeIntervalSince(started), answer.cachedTokens)
        }
        _ = await measure(nil)
        for lead in [nil] + leads.map(Optional.some) {
            var seconds: [Double] = [], held: [Int] = []
            for _ in 0 ..< 4 {
                let (time, cached) = await measure(lead)
                seconds.append(time)
                held.append(cached ?? 0)
                try? await Task.sleep(for: .seconds(0.3))
            }
            let label = lead.map { "prepared \($0) s ahead" } ?? "not prepared"
            log("\(label.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                + seconds.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " ")
                + "  held \(held.map(String.init).joined(separator: " "))")
        }
    }
}
