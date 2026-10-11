import Foundation
@testable import SemanticAttention
import Testing

/// A language model with scripted answers. Test-only.
actor ScriptedReasoner: SemanticRelevanceReasoning {
    var judgements: [String: RelevanceJudgement]
    var triage: [String: Bool]
    var delay: Duration
    var fails = false
    private(set) var judged: [String] = []
    private(set) var triaged: [String] = []

    /// Answers of the second look, and what it was asked and told (Windows 6.1 and 6.2).
    var confirmations: [String: StatementConfirmation] = [:]
    var failsConfirmation = false
    private(set) var confirmed: [String] = []
    private(set) var earlier: [String: [String]] = [:]

    init(_ judgements: [String: RelevanceJudgement] = [:], triage: [String: Bool] = [:], delay: Duration = .zero) {
        self.judgements = judgements
        self.triage = triage
        self.delay = delay
    }

    func setConfirmations(_ confirmations: [String: StatementConfirmation]) { self.confirmations = confirmations }
    func setFailsConfirmation(_ fails: Bool) { failsConfirmation = fails }

    func confirm(_ utterance: SemanticUtterance, goal: AttentionGoal) async throws -> StatementConfirmation? {
        try await confirm(utterance, goal: goal, earlier: [])
    }

    func confirm(_ utterance: SemanticUtterance, goal: AttentionGoal, earlier: [String]) async throws -> StatementConfirmation? {
        confirmed.append(utterance.text)
        self.earlier[utterance.text] = earlier
        if failsConfirmation { throw SemanticReasonerError.modelFailure("scripted") }
        return confirmations[utterance.text] ?? .hereAndNow
    }

    func setFails(_ fails: Bool) { self.fails = fails }

    nonisolated func availability() async -> SemanticReasonerAvailability { .available }
    nonisolated func prewarm() async {}

    func judge(_ utterance: SemanticUtterance, goals: [AttentionGoal]) async throws -> RelevanceJudgement {
        judged.append(utterance.text)
        if delay > .zero { try await Task.sleep(for: delay) }
        if fails { throw SemanticReasonerError.modelFailure("scripted") }
        return judgements[utterance.text] ?? .none
    }

    func couldMatter(_ utterance: SemanticUtterance, goals: [AttentionGoal]) async throws -> Bool {
        triaged.append(utterance.text)
        return triage[utterance.text] ?? true
    }
}

enum Fixture {
    static let origin = Date(timeIntervalSince1970: 1_780_000_000)
    static let grades = AttentionGoal(text: "Tell me anything that could affect my grades.", createdAt: origin)
    static let emergency = AttentionGoal(text: "Warn me about clear emergency instructions nearby.", createdAt: origin)
    static let exam = "The exam has been postponed until Friday."

    static func relevant(goal: Int = 1, headline: String = "exam postponed until Friday", evidence: String = "",
                         urgency: SemanticUrgency = .normal, kind: StatementKind = .statement,
                         subject: StatementSubject = .listenerOrGroup) -> RelevanceJudgement
    {
        RelevanceJudgement(goalIndex: goal, verdict: .relevant, consequence: "The exam date changed.", evidence: evidence,
                           headline: headline, urgency: urgency, statementKind: kind, subject: subject)
    }

    static func utterance(_ text: String, at seconds: TimeInterval = 0, lowQuality: Bool = false) -> SemanticUtterance {
        SemanticUtterance(text: text, date: origin.addingTimeInterval(seconds), isLowQuality: lowQuality)
    }

    static func engine(_ reasoner: ScriptedReasoner, goals: [AttentionGoal] = [grades, emergency],
                       configuration: SemanticAttentionEngine.Configuration = .standard) async -> SemanticAttentionEngine
    {
        let engine = SemanticAttentionEngine(reasoner: reasoner, configuration: configuration)
        await engine.setGoals(goals)
        return engine
    }
}

@Suite struct SemanticAttentionEngineTests {
    @Test func aRelevantStatementIsAcceptedForItsGoal() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant()])
        let engine = await Fixture.engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(Fixture.exam))
        #expect(decision.verdict == .relevant)
        #expect(decision.isAccepted)
        #expect(decision.matchedGoalID == Fixture.grades.id)
        #expect(decision.presentation == .notify)
        #expect(decision.headline == "exam postponed until Friday")
        // No span cited by the model: the utterance itself is the evidence.
        #expect(decision.evidence == Fixture.exam)
        #expect(decision.stage == .model)
    }

    @Test func fillersNeverReachTheModel() async {
        let reasoner = ScriptedReasoner()
        let engine = await Fixture.engine(reasoner)
        for text in ["Yeah, okay.", "Uh huh", "Oh, right, sure.", "Thanks!"] {
            let decision = await engine.evaluate(Fixture.utterance(text))
            #expect(decision.stage == .gate)
            #expect(decision.verdict == .irrelevant)
        }
        #expect(await reasoner.judged.isEmpty)
        #expect(await reasoner.triaged.isEmpty)
    }

    @Test func withoutGoalsOrWhenDisabledNothingIsEvaluated() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant()])
        let empty = await Fixture.engine(reasoner, goals: [])
        #expect(await empty.evaluate(Fixture.utterance(Fixture.exam)).stage == .inactive)
        let disabledGoal = AttentionGoal(text: "Anything about grades", isEnabled: false)
        let disabled = await Fixture.engine(reasoner, goals: [disabledGoal])
        #expect(await disabled.evaluate(Fixture.utterance(Fixture.exam)).stage == .inactive)
        let off = await Fixture.engine(reasoner)
        await off.setEnabled(false)
        #expect(await off.evaluate(Fixture.utterance(Fixture.exam)).stage == .inactive)
        #expect(await reasoner.judged.isEmpty)
    }

    @Test func theFirstPassStopsEverydayTalkBeforeTheFullJudgement() async {
        let talk = "This sandwich is actually pretty good."
        let reasoner = ScriptedReasoner([talk: Fixture.relevant()], triage: [talk: false])
        // The first pass is off by default since Window 6.1.
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.usesTriage = true
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        let decision = await engine.evaluate(Fixture.utterance(talk))
        #expect(decision.stage == .triage)
        #expect(decision.verdict == .irrelevant)
        #expect(await reasoner.judged.isEmpty)
        #expect(await engine.statistics.triaged == 1)
    }

    @Test func anythingThatSoundsLikeAWarningSkipsTheFirstPass() async {
        let warning = "Everyone leave through the north exit now."
        let reasoner = ScriptedReasoner([warning: Fixture.relevant(goal: 2, headline: "leave through north exit", urgency: .high)],
                                        triage: [warning: false])
        let engine = await Fixture.engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(warning))
        #expect(await reasoner.triaged.isEmpty)
        #expect(decision.isAccepted)
        #expect(decision.presentation == .alert)
        #expect(decision.matchedGoalID == Fixture.emergency.id)
    }

    @Test func theSameStatementIsNotAcceptedTwiceButAChangedDayIs() async {
        let reminder = "Reminder, the exam has been postponed until Friday."
        let moved = "The exam has been postponed until Monday."
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant(), reminder: Fixture.relevant(goal: 2),
                                         moved: Fixture.relevant(headline: "exam postponed until Monday")])
        let engine = await Fixture.engine(reasoner)
        #expect(await engine.evaluate(Fixture.utterance(Fixture.exam)).isAccepted)
        // Repeated a minute later, filed under another goal by the model: still a repetition.
        let second = await engine.evaluate(Fixture.utterance(reminder, at: 60))
        #expect(second.verdict == .relevant)
        #expect(!second.isNovel)
        #expect(!second.isAccepted)
        #expect(second.presentation == .none)
        // A different day is a different statement.
        #expect(await engine.evaluate(Fixture.utterance(moved, at: 90)).isAccepted)
        // After the novelty window the reminder counts again.
        #expect(await engine.evaluate(Fixture.utterance(reminder, at: 60 + 400)).isAccepted)
        #expect(await engine.statistics.repeated == 1)
    }

    @Test func anIdenticalUtteranceIsAnsweredFromTheCache() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant()])
        let engine = await Fixture.engine(reasoner)
        _ = await engine.evaluate(Fixture.utterance(Fixture.exam))
        let again = await engine.evaluate(Fixture.utterance("the exam has been postponed until friday", at: 30))
        #expect(again.stage == .cache)
        #expect(!again.isNovel)
        #expect(await reasoner.judged.count == 1)
        // Changing the goals empties the cache.
        await engine.setGoals([Fixture.grades])
        _ = await engine.evaluate(Fixture.utterance(Fixture.exam, at: 60))
        #expect(await reasoner.judged.count == 2)
    }

    @Test func aModelFailureGivesNoAlertAndNoGuess() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant()])
        await reasoner.setFails(true)
        let engine = await Fixture.engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(Fixture.exam))
        #expect(decision.stage == .fallback)
        #expect(decision.verdict == .irrelevant)
        #expect(!decision.isAccepted)
        #expect(await engine.statistics.modelFailures == 1)
    }

    @Test func aSlowModelIsAbandoned() async {
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.timeout = 0.05
        configuration.usesTriage = false
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant()], delay: .seconds(2))
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        let started = Date()
        let decision = await engine.evaluate(Fixture.utterance(Fixture.exam))
        #expect(decision.stage == .fallback)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(await engine.statistics.timeouts == 1)
    }

    @Test func theQueueIsBoundedAndDropsTheOldestWaitingUtterance() async {
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.queueCapacity = 2
        configuration.usesTriage = false
        let reasoner = ScriptedReasoner(delay: .milliseconds(150))
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        let texts = (1 ... 6).map { "Statement number \($0) about the weather." }
        var ids: [UUID: String] = [:]
        for text in texts {
            let utterance = Fixture.utterance(text)
            ids[utterance.id] = text
            await engine.submit(utterance)
        }
        var stages: [String: SemanticStage] = [:]
        for await decision in engine.decisions {
            stages[ids[decision.utteranceID] ?? "?"] = decision.stage
            if stages.count == texts.count { break }
        }
        let statistics = await engine.statistics
        #expect(statistics.dropped >= 2)
        #expect(statistics.maximumQueueLength <= 2)
        #expect(stages.values.count { $0 == .dropped } == statistics.dropped)
        // The newest utterance is never the one that is dropped.
        #expect(stages[texts[5]] == .model)
    }

    @Test func anUrgentLookingUtteranceGoesToTheFrontOfTheQueue() async {
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.usesTriage = false
        let reasoner = ScriptedReasoner(delay: .milliseconds(120))
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        await engine.submit(Fixture.utterance("First we talked about the homework."))
        await engine.submit(Fixture.utterance("Then about the bus ride home."))
        await engine.submit(Fixture.utterance("And about lunch as well."))
        await engine.submit(Fixture.utterance("Fire, get out of the building!"))
        var count = 0
        for await _ in engine.decisions {
            count += 1
            if count == 4 { break }
        }
        let order = await reasoner.judged
        #expect(order.count == 4)
        // Whatever was waiting, the warning is evaluated before it (at most one utterance was already under way).
        #expect((order.firstIndex(of: "Fire, get out of the building!") ?? 9) <= 1)
    }

    @Test func whilePausedNothingIsEvaluatedAndTheQueueStaysBounded() async {
        var configuration = SemanticAttentionEngine.Configuration.standard
        configuration.queueCapacity = 2
        configuration.usesTriage = false
        let reasoner = ScriptedReasoner()
        let engine = await Fixture.engine(reasoner, configuration: configuration)
        await engine.setPaused(true)
        for index in 1 ... 5 { await engine.submit(Fixture.utterance("Statement number \(index) about the weather.")) }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await reasoner.judged.isEmpty)
        #expect(await engine.statistics.dropped == 3)
        await engine.setPaused(false)
        var evaluated = 0
        for await decision in engine.decisions where decision.stage == .model {
            evaluated += 1
            if evaluated == 2 { break }
        }
        #expect(await reasoner.judged.count == 2)
    }

    @Test func resetForgetsWaitingUtterancesAndWhatWasAccepted() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant()])
        let engine = await Fixture.engine(reasoner)
        #expect(await engine.evaluate(Fixture.utterance(Fixture.exam)).isAccepted)
        await engine.reset()
        // Neither the cache nor the novelty memory remembers the statement.
        let again = await engine.evaluate(Fixture.utterance(Fixture.exam, at: 30))
        #expect(again.stage == .model)
        #expect(again.isAccepted)
    }

    @Test func aDecisionSummaryForLogsHoldsNoSpeechText() async {
        let reasoner = ScriptedReasoner([Fixture.exam: Fixture.relevant()])
        let engine = await Fixture.engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(Fixture.exam))
        for word in ["exam", "postponed", "Friday", "date"] {
            #expect(!decision.redactedSummary.localizedCaseInsensitiveContains(word))
        }
    }
}

@Suite struct EvidenceVerifierTests {
    let verifier = EvidenceVerifier.standard
    let goals = [Fixture.grades, Fixture.emergency]

    private func verify(_ judgement: RelevanceJudgement, _ text: String = Fixture.exam, lowQuality: Bool = false)
        -> SemanticAttentionDecision
    {
        verifier.verify(judgement, utterance: Fixture.utterance(text, lowQuality: lowQuality), goals: goals)
    }

    @Test func aWishAJokeOrAFragmentIsNotAnEvent() {
        for kind in [StatementKind.hypothetical, .reported, .unclear] {
            let decision = verify(Fixture.relevant(kind: kind))
            #expect(decision.verdict == .uncertain)
            #expect(decision.presentation == .listOnly)
            #expect(!decision.isAccepted)
            #expect(decision.corrections == ["not_asserted"])
        }
    }

    @Test func aQuestionAddressedToTheListenerCanStillMatter() {
        let decision = verify(Fixture.relevant(headline: "cover the closing shift Saturday", kind: .question),
                              "Can you cover the closing shift on Saturday?")
        #expect(decision.isAccepted)
    }

    @Test func aStatementThatNothingChangesIsNotAnAlert() {
        let decision = verify(Fixture.relevant(headline: "", kind: .noChange),
                              "No, the test is not cancelled, it's still on Thursday.")
        #expect(decision.verdict == .irrelevant)
        #expect(decision.matchedGoalID == nil)
        #expect(decision.corrections.contains("nothing_changes"))
    }

    @Test func aHypotheticalMarkerOverridesTheModel() {
        let decision = verify(Fixture.relevant(headline: "cancelled the final exam"),
                              "What if they cancelled the final exam, that would be amazing.")
        #expect(decision.verdict == .uncertain)
        #expect(decision.statementKind == .hypothetical)
    }

    @Test func somebodyElsesSituationIsKeptOutOfTheAlerts() {
        let decision = verify(Fixture.relevant(headline: "friend got a better grade", subject: .someoneElse),
                              "My friend got a better grade than I did on her history paper.")
        #expect(decision.verdict == .uncertain)
        #expect(decision.corrections.contains("about_someone_else"))
        #expect(decision.isPersonalRelevanceUncertain)
    }

    @Test func citedEvidenceMustHaveBeenSaid() {
        let decision = verify(Fixture.relevant(evidence: "the final project deadline moved to next month"))
        #expect(decision.verdict == .uncertain)
        #expect(decision.evidence.isEmpty)
        #expect(decision.corrections.contains("evidence_not_in_utterance"))
        let grounded = verify(Fixture.relevant(evidence: "exam has been postponed"))
        #expect(grounded.verdict == .relevant)
        #expect(grounded.evidence == "exam has been postponed")
    }

    @Test func aHeadlineMayNotAddWordsLoseANegationOrChangeANumber() {
        #expect(verify(Fixture.relevant(headline: "Professor Smith cancels chemistry final")).headline.isEmpty)
        let late = "Late submissions will no longer be accepted starting this week."
        #expect(verify(Fixture.relevant(headline: "late submissions accepted this week"), late).headline.isEmpty)
        #expect(verify(Fixture.relevant(headline: "late submissions no longer accepted"), late).headline
            == "late submissions no longer accepted")
        #expect(verify(Fixture.relevant(headline: "exam postponed until Monday")).headline.isEmpty)
        #expect(verify(Fixture.relevant(headline: "the exam has been postponed until this coming Friday for everyone")).headline.isEmpty)
        // The verdict stands: only the text that would be shown is withheld.
        #expect(verify(Fixture.relevant(headline: "exam postponed until Monday")).isAccepted)
    }

    @Test func aReasonMayNotNameADayOrNumberThatWasNotSaid() {
        var judgement = Fixture.relevant(headline: "report is due next Wednesday")
        judgement.consequence = "Report due date changed to Friday instead of Monday"
        let decision = verify(judgement, "One more thing, the report is due next Wednesday, not Monday.")
        #expect(decision.reason.isEmpty)
        #expect(decision.corrections.contains("reason_detail"))
        #expect(decision.verdict == .relevant)
        judgement.consequence = "The report is due on Wednesday, not Monday"
        #expect(verify(judgement, "One more thing, the report is due next Wednesday, not Monday.").reason
            == "The report is due on Wednesday, not Monday")
    }

    @Test func aGoalThatDoesNotExistIsNoMatch() {
        #expect(verify(Fixture.relevant(goal: 5)).verdict == .irrelevant)
        #expect(verify(Fixture.relevant(goal: 0)).verdict == .irrelevant)
        #expect(verify(Fixture.relevant(goal: 0)).corrections == ["no_goal"])
    }

    @Test func poorRecognitionMakesAMatchUncertain() {
        let decision = verify(Fixture.relevant(), lowQuality: true)
        #expect(decision.verdict == .uncertain)
        #expect(decision.corrections.contains("low_recognition_quality"))
    }

    @Test func onlyAnUrgentCertainMatchAsksForAnAlert() {
        #expect(verify(Fixture.relevant(urgency: .high)).presentation == .alert)
        #expect(verify(Fixture.relevant(urgency: .high, subject: .unclear)).presentation == .notify)
        #expect(verify(Fixture.relevant(urgency: .low)).presentation == .notify)
    }

    @Test func theVerifierNeverMakesADecisionLessCautious() {
        for verdict in SemanticVerdict.allCases {
            var judgement = Fixture.relevant()
            judgement.verdict = verdict
            let decision = verify(judgement)
            let order: [SemanticVerdict] = [.irrelevant, .uncertain, .relevant]
            #expect(order.firstIndex(of: decision.verdict)! <= order.firstIndex(of: verdict)!)
        }
    }
}

@Suite struct SemanticBaselineTests {
    @Test func theKeywordBaselineSeesSharedWordsOnly() {
        let scorer = KeywordGoalScorer()
        let goal = Fixture.grades.text
        #expect(scorer.keywords(of: goal) == ["grad"])
        #expect(scorer.score(utterance: "Your grades will be posted tonight.", goal: goal) > 0)
        // The brief's own example: relevant without a shared word.
        #expect(scorer.score(utterance: Fixture.exam, goal: goal) == 0)
        // And a shared word without relevance.
        #expect(scorer.score(utterance: "My friend got a better grade than I did.", goal: goal) > 0)
    }

    @Test func theGateIsGenerous() {
        let gate = UtteranceGate()
        #expect(gate.admits("Excuse me!"))
        #expect(gate.admits("Hey, wait"))
        #expect(gate.admits("Fire!"))
        #expect(!gate.admits("yeah okay"))
        #expect(!gate.admits(""))
        #expect(gate.isLikelyUrgent("Everyone exit the building"))
        #expect(!gate.isLikelyUrgent("The exam has been postponed until Friday."))
        #expect(gate.clipped(Array(repeating: "word", count: 200).joined(separator: " ")).split(separator: " ").count == 80)
    }

    @Test func goalTextIsNormalized() {
        #expect(AttentionGoal.normalized("  Tell me\nabout grades  ") == "Tell me about grades")
        #expect(AttentionGoal.normalized(String(repeating: "a", count: 500)).count == AttentionGoal.maximumLength)
    }
}
