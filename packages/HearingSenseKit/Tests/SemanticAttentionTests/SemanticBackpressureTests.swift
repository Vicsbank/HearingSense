import Foundation
@testable import SemanticAttention
import Testing

/// Window 6.2: what the engine does when sentences arrive faster than the model answers.
@Suite struct SemanticBackpressureTests {
    private static let talk = ["I think I left my umbrella at the coffee shop.", "That movie was way too long.",
                               "My cousin is visiting from Portland next week.", "We should try the new noodle place.",
                               "The printer on the second floor is jammed again."]

    private func decisions(of engine: SemanticAttentionEngine, count: Int) async -> [SemanticAttentionDecision] {
        let task = Task {
            var collected: [SemanticAttentionDecision] = []
            for await decision in engine.decisions {
                collected.append(decision)
                if collected.count == count { break }
            }
            return collected
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            task.cancel()
        }
        let collected = await task.value
        timeout.cancel()
        return collected
    }

    /// Four sentences while the model is slow: the first is being judged, three wait.
    private func submitFour(to engine: SemanticAttentionEngine) async {
        for index in 0 ..< 4 {
            await engine.submit(Fixture.utterance(Self.talk[index], at: Double(index)))
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    @Test func whileBehindAndSpeechContinuesTheNewestSentenceGoesFirst() async {
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.behindAfter = 0.02
        configuration.pauseInterval = 10
        let reasoner = ScriptedReasoner(delay: .milliseconds(80))
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        await submitFour(to: engine)
        let decisions = await decisions(of: engine, count: 4)
        #expect(decisions.count == 4)
        #expect(await reasoner.judged == [Self.talk[0], Self.talk[3], Self.talk[2], Self.talk[1]])
        #expect(await engine.statistics.servedNewestFirst == 2)
        #expect(await engine.statistics.dropped == 0)
    }

    @Test func inAPauseTheOldestSentenceGoesFirstAgain() async {
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.behindAfter = 0.02
        configuration.pauseInterval = 0.01
        let reasoner = ScriptedReasoner(delay: .milliseconds(80))
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        await submitFour(to: engine)
        _ = await decisions(of: engine, count: 4)
        #expect(await reasoner.judged == Array(Self.talk.prefix(4)))
        #expect(await engine.statistics.servedNewestFirst == 0)
    }

    @Test func oldestFirstKeepsTheOrderWhateverTheDelay() async {
        var configuration = SemanticAttentionEngine.Configuration.window6_1
        configuration.behindAfter = 0.02
        let reasoner = ScriptedReasoner(delay: .milliseconds(60))
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        await submitFour(to: engine)
        _ = await decisions(of: engine, count: 4)
        #expect(await reasoner.judged == Array(Self.talk.prefix(4)))
    }

    @Test func aSentenceThatWaitedTooLongIsGivenUpAndSaidSo() async {
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.maximumWait = 0.05
        configuration.servingOrder = .oldestFirst
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant(headline: "")], delay: .milliseconds(150))
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        await engine.submit(Fixture.utterance(Self.talk[0]))
        try? await Task.sleep(for: .milliseconds(15))
        let late = Fixture.utterance(Fixture.exam, at: 1)
        await engine.submit(late)
        let decisions = await decisions(of: engine, count: 2)
        let given = decisions.first { $0.utteranceID == late.id }
        #expect(given?.stage == .expired)
        #expect(given?.isAccepted == false)
        #expect((given?.queueWait ?? 0) > 0.05)
        #expect(await engine.statistics.expired == 1)
        #expect(await engine.statistics.dropped == 1)
        #expect(await reasoner.judged == [Self.talk[0]])
    }

    @Test func aSentencePushedOutOfAFullLineIsReportedAsDroppedNotExpired() async {
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.queueCapacity = 1
        let reasoner = ScriptedReasoner(delay: .milliseconds(80))
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        for index in 0 ..< 3 {
            await engine.submit(Fixture.utterance(Self.talk[index], at: Double(index)))
            try? await Task.sleep(for: .milliseconds(10))
        }
        let decisions = await decisions(of: engine, count: 3)
        #expect(decisions.count { $0.stage == .dropped } == 1)
        #expect(await engine.statistics.dropped == 1)
        #expect(await engine.statistics.expired == 0)
    }
}
