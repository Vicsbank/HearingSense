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
