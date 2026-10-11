import Foundation
@testable import SemanticAttention
import Testing

/// Window 6.1: the second look, text that is shown, sentences judged together, early
/// evaluation of partial transcripts, late decisions.
@Suite struct SemanticOptimizationTests {
    /// Collects the decisions of an engine until `count` have arrived.
    private func decisions(of engine: SemanticAttentionEngine, count: Int) async -> [SemanticAttentionDecision] {
        var collected: [SemanticAttentionDecision] = []
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
        collected = await task.value
        timeout.cancel()
        return collected
    }

    private static let talk = ["I think I left my umbrella at the coffee shop.", "That movie was way too long.",
                               "My cat knocked a plant off the shelf.", "We should go hiking this weekend."]

    // MARK: - Second look

    @Test func theSecondLookTakesBackAnAlertAboutSomeoneElse() async {
        let text = "My wife's company moved all their meetings online."
        let reasoner = ScriptedReasoner([text: Fixture.relevant(headline: "")])
        await reasoner.setConfirmations([text: .someoneElse])
        let engine = await Fixture.engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(text))
        #expect(decision.verdict == .uncertain)
        #expect(!decision.isAccepted)
        #expect(decision.corrections.contains("second_look"))
        #expect(decision.presentation == .listOnly)
        let statistics = await engine.statistics
        #expect(statistics.confirmCalls == 1)
        #expect(statistics.confirmDemoted == 1)
    }

    @Test func theSecondLookKeepsAStatementAboutHereAndNow() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant(headline: "")])
        let engine = await Fixture.engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(Fixture.exam))
        #expect(decision.isAccepted)
        #expect(await reasoner.confirmed == [Fixture.exam])
    }

    @Test func aWarningIsUrgentOnlyWhenTheSecondLookAgrees() async {
        let real = "That shelf is coming down, get back."
        let idiom = "Get out, no way she said that."
        let reasoner = ScriptedReasoner([real: Fixture.relevant(goal: 2, headline: "", urgency: .high),
                                         idiom: Fixture.relevant(goal: 2, headline: "", urgency: .high)])
        await reasoner.setConfirmations([idiom: .story])
        let engine = await Fixture.engine(reasoner)
        let warning = await engine.evaluate(Fixture.utterance(real))
        #expect(warning.isAccepted)
        #expect(warning.urgency == .high)
        #expect(warning.presentation == .alert)
        let saying = await engine.evaluate(Fixture.utterance(idiom, at: 30))
        #expect(!saying.isAccepted)
        #expect(saying.urgency == .normal)
        #expect(await reasoner.confirmed == [real, idiom])
    }

    @Test func withoutASecondLookTheModelsWordAloneDoesNotMakeAnAlertUrgent() async {
        let text = "That shelf is coming down, get back."
        let reasoner = ScriptedReasoner([text: Fixture.relevant(goal: 2, headline: "", urgency: .high)])
        await reasoner.setFailsConfirmation(true)
        let engine = await Fixture.engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(text))
        #expect(decision.isAccepted)
        #expect(decision.urgency == .normal)
        #expect(decision.presentation == .notify)
        #expect(decision.corrections.contains("urgency_unconfirmed"))
    }

    @Test func theWindow6_1ConfigurationStillLetsAWarningThroughUnchecked() async {
        let text = "That shelf is coming down, get back."
        let reasoner = ScriptedReasoner([text: Fixture.relevant(goal: 2, headline: "", urgency: .high)])
        await reasoner.setConfirmations([text: .story])
        let engine = await Fixture.engine(reasoner, configuration: .window6_1)
        let decision = await engine.evaluate(Fixture.utterance(text))
        #expect(decision.presentation == .alert)
        #expect(await reasoner.confirmed.isEmpty)
    }

    @Test func irrelevantSentencesGetNoSecondLookAndACachedAnswerIsNotLookedAtTwice() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant(headline: "")])
        let engine = await Fixture.engine(reasoner)
        _ = await engine.evaluate(Fixture.utterance(Self.talk[0]))
        _ = await engine.evaluate(Fixture.utterance(Fixture.exam))
        let again = await engine.evaluate(Fixture.utterance(Fixture.exam, at: 10))
        #expect(again.stage == .cache)
        #expect(await reasoner.confirmed == [Fixture.exam])
    }

    @Test func theSecondLookCanBeSwitchedOff() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant(headline: "")])
        await reasoner.setConfirmations([Fixture.exam: .past])
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.confirmsRelevant = false
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        #expect(await engine.evaluate(Fixture.utterance(Fixture.exam)).isAccepted)
        #expect(await reasoner.confirmed.isEmpty)
    }

    // MARK: - Text that is shown

    @Test func withoutModelTextTheHeadlineIsWhatWasSaid() {
        let goals = [Fixture.grades]
        let judgement = RelevanceJudgement(goalIndex: 1, verdict: .relevant)
        let decision = EvidenceVerifier.standard.verify(judgement, utterance: Fixture.utterance("The exam may be canceled."),
                                                        goals: goals)
        #expect(decision.headline == "The exam may be canceled")
        #expect(decision.evidence == "The exam may be canceled.")
        // The reason is fixed words and the user's own goal.
        #expect(decision.reason.hasSuffix(Fixture.grades.text))
        #expect(!decision.reason.lowercased().contains("canceled"))
    }

    @Test func aLongUtteranceIsShortenedOnlyIfNothingImportantIsCut() {
        let goals = [Fixture.grades]
        let judgement = RelevanceJudgement(goalIndex: 1, verdict: .relevant)
        let safe = "The essay is due on Friday and I will read every one of them over the weekend with great care."
        let kept = EvidenceVerifier.standard.verify(judgement, utterance: Fixture.utterance(safe), goals: goals)
        #expect(kept.headline == "The essay is due on Friday and I will read every one…")
        // The "not" and the day lie in the part that would be cut: no headline, the app shows the sentence.
        let unsafe = "The reading response that I mentioned to all of you last week in class is not due on Friday."
        let withheld = EvidenceVerifier.standard.verify(judgement, utterance: Fixture.utterance(unsafe), goals: goals)
        #expect(withheld.headline.isEmpty)
        #expect(withheld.corrections.contains("headline_not_shortened"))
        #expect(withheld.verdict == .relevant)
    }

    @Test func anAnnouncedRepetitionIsNotANewStatement() async {
        let first = "Late work will no longer receive credit."
        let again = "One more time, late work will no longer receive credit."
        let reasoner = ScriptedReasoner([first: Fixture.relevant(headline: ""), again: Fixture.relevant(headline: "")])
        let engine = await Fixture.engine(reasoner)
        #expect(await engine.evaluate(Fixture.utterance(first)).isAccepted)
        let repeated = await engine.evaluate(Fixture.utterance(again, at: 60))
        #expect(!repeated.isNovel)
        #expect(!repeated.isAccepted)
        #expect(SemanticText.withoutRepetitionMarker("Again, the bus is late.") == "the bus is late.")
        #expect(SemanticText.withoutRepetitionMarker("Again.") == "Again.")
    }

    // MARK: - Repetition in other words (Window 6.2)

    @Test func aRepetitionInOtherWordsNeedsSharedWordsAndTheSecondLook() async {
        let first = "The elevator will be out of service all day Wednesday for inspection."
        let again = "Again, no elevator on Wednesday, it's being inspected all day."
        let reasoner = ScriptedReasoner([first: Fixture.relevant(headline: ""), again: Fixture.relevant(headline: "")])
        await reasoner.setConfirmations([again: .saidBefore])
        let engine = await Fixture.engine(reasoner)
        #expect(await engine.evaluate(Fixture.utterance(first)).isAccepted)
        let repeated = await engine.evaluate(Fixture.utterance(again, at: 60))
        #expect(!repeated.isNovel)
        #expect(!repeated.isAccepted)
        #expect(repeated.verdict == .relevant)
        #expect(await reasoner.earlier[again] == [first])
        #expect(await engine.statistics.repeated == 1)
    }

    @Test func theSecondLookIsNotAskedAboutStatementsWithOtherNumbersOrOtherWords() async {
        let first = "The elevator will be out of service all day Wednesday for inspection."
        let otherDay = "The elevator will also be out on Thursday, they found another fault."
        let otherTopic = "Your rent goes up by sixty dollars a month."
        let reasoner = ScriptedReasoner([first: Fixture.relevant(headline: ""), otherDay: Fixture.relevant(headline: ""),
                                         otherTopic: Fixture.relevant(headline: "")])
        // Even if the model said so: with nothing listed, nothing can have been said before.
        await reasoner.setConfirmations([otherDay: .saidBefore, otherTopic: .saidBefore])
        let engine = await Fixture.engine(reasoner)
        #expect(await engine.evaluate(Fixture.utterance(first)).isAccepted)
        #expect(await engine.evaluate(Fixture.utterance(otherDay, at: 30)).isAccepted)
        #expect(await engine.evaluate(Fixture.utterance(otherTopic, at: 60)).isAccepted)
        #expect(await reasoner.earlier[otherDay] == [])
        #expect(await reasoner.earlier[otherTopic] == [])
    }

    @Test func repetitionCandidatesShareWordsAndNameNoOtherQuantity() {
        let earlier = ["Practice is moved to six thirty tomorrow morning.", "The keynote has moved from the main hall to ballroom B."]
        #expect(SemanticRepetition.candidates(for: "Reminder, tomorrow's practice is at six thirty in the morning.", among: earlier)
            == [earlier[0]])
        #expect(SemanticRepetition.candidates(for: "Practice tomorrow morning is at seven.", among: earlier).isEmpty)
        #expect(SemanticRepetition.candidates(for: "Once more, the keynote is in ballroom B, not the main hall.", among: earlier)
            == [earlier[1]])
        #expect(SemanticRepetition.candidates(for: "My cat knocked a plant off the shelf.", among: earlier).isEmpty)
    }

    // MARK: - Order

    @Test func aSentenceThatLooksLikeAWarningGoesFirst() async {
        let warning = "Everyone get out, fire in the kitchen!"
        let reasoner = ScriptedReasoner([warning: Fixture.relevant(goal: 2, headline: "", urgency: .high)],
                                        delay: .milliseconds(80))
        let engine = await Fixture.engine(reasoner)
        for (index, text) in (Array(Self.talk.prefix(3)) + [warning]).enumerated() {
            await engine.submit(Fixture.utterance(text, at: Double(index)))
            if index == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        }
        let decisions = await decisions(of: engine, count: 4)
        #expect(await reasoner.judged.prefix(2) == [Self.talk[0], warning])
        #expect(decisions.firstIndex { $0.evidence == warning } == 1)
        #expect(decisions[1].presentation == .alert)
    }

    @Test func aDecisionLaterThanTheDeadlineIsMadeAndCounted() async {
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.deadline = 0.05
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant(headline: "")], delay: .milliseconds(80))
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        await engine.submit(Fixture.utterance(Self.talk[0]))
        try? await Task.sleep(for: .milliseconds(20))
        await engine.submit(Fixture.utterance(Fixture.exam, at: 1))
        let decisions = await decisions(of: engine, count: 2)
        let exam = decisions.first { $0.evidence == Fixture.exam }
        #expect(exam?.isAccepted == true)
        #expect(exam?.isLate == true)
        #expect((exam?.queueWait ?? 0) > 0.05)
        #expect(await engine.statistics.deadlineMisses >= 1)
        #expect(await engine.statistics.dropped == 0)
    }

    // MARK: - Partial transcripts

    @Test func theFinalTextUsesTheAnswerOfAPartialTranscriptWithTheSameWords() async {
        let partial = "the exam has been postponed until friday"
        let reasoner = ScriptedReasoner([partial: Fixture.relevant(headline: "")], delay: .milliseconds(60))
        let engine = await Fixture.engine(reasoner)
        let stream = Task { await decisions(of: engine, count: 1) }
        await engine.submitProvisional(Fixture.utterance(partial))
        try? await Task.sleep(for: .milliseconds(20))
        // The final text arrives while the partial one is still being evaluated.
        await engine.submit(Fixture.utterance(Fixture.exam))
        let decisions = await stream.value
        #expect(decisions.count == 1)
        #expect(decisions.first?.stage == .speculative)
        #expect(decisions.first?.isAccepted == true)
        #expect(await reasoner.judged.count == 1)
        let statistics = await engine.statistics
        #expect(statistics.speculativeCalls == 1)
        #expect(statistics.speculativeHits == 1)
    }

    @Test func aPartialTranscriptAloneProducesNoDecisionAndADifferentFinalTextIsJudgedItself() async {
        let partial = "The exam has been postponed until fry"
        let reasoner = ScriptedReasoner([partial: Fixture.relevant(headline: ""), Fixture.exam: .none])
        let engine = await Fixture.engine(reasoner)
        await engine.submitProvisional(Fixture.utterance(partial))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await engine.statistics.accepted == 0)
        let stream = Task { await decisions(of: engine, count: 1) }
        await engine.submit(Fixture.utterance(Fixture.exam))
        let decisions = await stream.value
        // Only the final text counts: here it is judged irrelevant although the partial one was not.
        #expect(decisions.count == 1)
        #expect(decisions.first?.stage == .model)
        #expect(decisions.first?.verdict == .irrelevant)
        #expect(await reasoner.judged == [partial, Fixture.exam])
        #expect(await engine.statistics.speculativeHits == 0)
    }

    @Test func partialTranscriptsWaitWhileFinalizedSentencesAreWaiting() async {
        let reasoner = ScriptedReasoner(delay: .milliseconds(60))
        let engine = await Fixture.engine(reasoner)
        await engine.submit(Fixture.utterance(Self.talk[0]))
        await engine.submit(Fixture.utterance(Self.talk[1], at: 1))
        await engine.submitProvisional(Fixture.utterance("a partial transcript that is still growing"))
        _ = await decisions(of: engine, count: 2)
        #expect(await engine.statistics.speculativeCalls == 0)
    }

    @Test func theDetectorOffersAStablePartialTranscriptOnce() {
        var detector = StablePartialDetector()
        let id = UUID()
        let start = Fixture.origin
        detector.revise("The exam", utterance: id, at: start)
        detector.revise("The exam has been", utterance: id, at: start.addingTimeInterval(0.3))
        // Still growing: nothing yet.
        #expect(detector.offer(at: start.addingTimeInterval(0.5)) == nil)
        detector.revise("The exam has been postponed until Friday", utterance: id, at: start.addingTimeInterval(0.6))
        #expect(detector.nextCheck == start.addingTimeInterval(1.0))
        #expect(detector.offer(at: start.addingTimeInterval(0.9)) == nil)
        #expect(detector.offer(at: start.addingTimeInterval(1.0)) == "The exam has been postponed until Friday")
        // The same words again (only capitals and punctuation differ) are not offered twice.
        detector.revise("the exam has been postponed until friday,", utterance: id, at: start.addingTimeInterval(1.1))
        #expect(detector.offer(at: start.addingTimeInterval(2)) == nil)
    }

    @Test func theDetectorIsQuickerForACompleteSentenceAndBoundedPerUtterance() {
        var detector = StablePartialDetector()
        let id = UUID()
        let start = Fixture.origin
        detector.revise("Watch out.", utterance: id, at: start)
        #expect(detector.offer(at: start.addingTimeInterval(0.15)) == "Watch out.")
        detector.revise("Watch out for the step.", utterance: id, at: start.addingTimeInterval(0.5))
        #expect(detector.offer(at: start.addingTimeInterval(0.7)) == "Watch out for the step.")
        // Two early evaluations per utterance, however often the text is revised.
        detector.revise("Watch out for the step there.", utterance: id, at: start.addingTimeInterval(1))
        #expect(detector.offer(at: start.addingTimeInterval(3)) == nil)
        // A single word is not worth it.
        var short = StablePartialDetector()
        short.revise("Okay", utterance: UUID(), at: start)
        #expect(short.offer(at: start.addingTimeInterval(1)) == nil)
        // A new utterance starts afresh.
        detector.revise("The bus is late", utterance: UUID(), at: start.addingTimeInterval(4))
        #expect(detector.offer(at: start.addingTimeInterval(4.4)) == "The bus is late")
    }

    // MARK: - One scheduler

    @Test func goalMatchingTakesItsTurnsThroughTheScheduler() async {
        let scheduler = ModelInferenceScheduler()
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant(goal: 1, headline: "", urgency: .normal)])
        let engine = SemanticAttentionEngine(reasoner: reasoner, scheduler: scheduler)
        await engine.setGoals([Fixture.grades])
        _ = await engine.evaluate(Fixture.utterance(Fixture.exam))
        _ = await engine.evaluate(Fixture.utterance("Fire, everyone out now!"), priority: .urgentCandidate)
        let statistics = await scheduler.statistics
        // One turn for the judgement and its second look together (Window 6.2: given back in
        // between, another sentence could get in before the second look of a warning); then the
        // warning-like sentence in its own class.
        #expect(statistics[.attention].completed == 1)
        #expect(await reasoner.confirmed == [Fixture.exam])
        #expect(statistics[.urgentCandidate].completed == 1)
        #expect(statistics.maximumRunning == 1)
    }

    @Test func aWarningLikeSentenceDoesNotStandBehindSentencesThatWaitForARecap() async throws {
        var configuration = ModelInferenceScheduler.Configuration.standard
        configuration.allowsUrgentBesideUserRequest = true
        let scheduler = ModelInferenceScheduler(configuration: configuration)
        let warning = "Everyone get out, fire in the kitchen!"
        let reasoner = ScriptedReasoner([warning: Fixture.relevant(goal: 2, headline: "", urgency: .high)])
        let engine = SemanticAttentionEngine(reasoner: reasoner, scheduler: scheduler)
        await engine.setGoals([Fixture.grades, Fixture.emergency])
        // Something the user asked for has the model for a while.
        async let recap: Void = scheduler.run(.userRequest) { try await Task.sleep(for: .milliseconds(400)) }
        for _ in 0 ..< 200 where await scheduler.runningCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let stream = Task { await decisions(of: engine, count: 1) }
        await engine.submit(Fixture.utterance(Self.talk[0]))
        await engine.submit(Fixture.utterance(warning, at: 1))
        let first = await stream.value.first
        // The warning is decided while the recap is still running and the ordinary sentence waits.
        #expect(first?.evidence == warning)
        #expect(first?.presentation == .alert)
        #expect(await scheduler.runningCount >= 1)
        #expect(await reasoner.judged == [warning])
        try await recap
        #expect(await scheduler.statistics.maximumRunning == 2)
    }

    @Test func aDecisionLogLineStillHoldsNoWordOfTheUtterance() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant(headline: "")])
        let engine = await Fixture.engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(Fixture.exam))
        for word in ["exam", "postponed", "friday", "grades"] {
            #expect(!decision.redactedSummary.lowercased().contains(word))
        }
    }
}
