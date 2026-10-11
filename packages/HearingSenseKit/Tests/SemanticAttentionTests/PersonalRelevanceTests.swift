import Foundation
@testable import SemanticAttention
import Testing

/// Window 6.3: whether a sentence that names someone means the listener.
@Suite struct ListenerIdentityTests {
    @Test func namesAreCopiedFromTheListenersOwnWords() {
        #expect(ListenerIdentity.names(in: "My name is Alma. I'm in the back row.") == ["Alma"])
        #expect(ListenerIdentity.names(in: "I'm Kofi, on the night shift") == ["Kofi"])
        #expect(ListenerIdentity.names(in: "Tell me when someone says my name, Ines") == ["Ines"])
        #expect(ListenerIdentity.names(in: "Alert me if anyone wants me, people call me Bo") == ["Bo"])
        #expect(ListenerIdentity.names(in: "my name is alma") == ["Alma"])
    }

    @Test func nothingThatIsNotANameIsTakenForOne() {
        #expect(ListenerIdentity.names(in: "I'm with the walking group").isEmpty)
        #expect(ListenerIdentity.names(in: "Let me know when the chef calls me or tells me to do something").isEmpty)
        #expect(ListenerIdentity.names(in: "Warn me if I'm in the way").isEmpty)
        #expect(ListenerIdentity.names(in: "Tell me anything that could affect my grades.").isEmpty)
    }

    @Test func theAboutLineGivesTheLabelsThatTellTheListenersGroupFromOthers() {
        let names = ["Alma"]
        #expect(ListenerIdentity.groups(inAbout: "I'm Alma, on the green boat with crew D.", names: names) == ["green boat", "crew D"])
        #expect(ListenerIdentity.groups(inAbout: "My name is Alma. I sit at table nine with the Hartmann party.", names: names)
            == ["table nine", "Hartmann party"])
        // A word that names no particular one of its kind compares with nothing.
        #expect(ListenerIdentity.groups(inAbout: "I'm Alma and I am in a class.", names: names).isEmpty)
        #expect(ListenerIdentity.groups(inAbout: "", names: []).isEmpty)
    }

    @Test func aPhraseCopiedByTheModelIsKeptOnlyIfTheGoalSaysItOfTheListener() {
        let goal = "Tell me about changes to the five o'clock pottery course, that's the one I take."
        let other = "Let me know about anything that changes my work shift or my hours."
        let identity = ListenerIdentity().adding(copied: ["five o'clock pottery course", "team B", "work shift", "course"],
                                                 from: [goal, other])
        // "team B" stands nowhere, "work shift" stands in a goal that says nothing of the listener,
        // "course" alone tells nothing apart.
        #expect(identity.groups == ["five pottery course"])
    }

    @Test func theGoalAboutBeingSpokenToIsFoundByItsWords() {
        #expect(ListenerIdentity.spokenToGoal(in: ["Tell me about the gate.", "Notify me if someone is trying to get my attention."]) == 2)
        #expect(ListenerIdentity.spokenToGoal(in: ["Let me know when a stranger is speaking to me."]) == 1)
        #expect(ListenerIdentity.spokenToGoal(in: ["Alert me if someone is looking for me or wants a word with me."]) == 1)
        #expect(ListenerIdentity.spokenToGoal(in: ["Tell me anything that could affect my grades.", "Warn me about danger."]) == 0)
    }
}

@Suite struct AudienceAnalyzerTests {
    static let identity = ListenerIdentity(names: ["Alma"], groups: ["green boat", "crew D", "table nine"])

    private func kind(_ sentence: String, _ identity: ListenerIdentity = identity) -> AudienceCue.Kind {
        AudienceAnalyzer.cue(in: sentence, identity: identity).kind
    }

    @Test func theListenersOwnNameIsRecognisedAlsoMisheard() {
        #expect(kind("Alma, have you got a minute?") == .listenerNamed)
        #expect(kind("Hey Alma, over here.") == .listenerNamed)
        #expect(kind("Thanks for waiting, Alma.") == .listenerNamed)
        let jordan = ListenerIdentity(names: ["Jordan"])
        #expect(kind("Jordon, your turn.", jordan) == .listenerNamed)
    }

    @Test func anotherPersonsNameIsNotTheListeners() {
        #expect(kind("Peter, your taxi is outside.") == .otherPerson)
        #expect(kind("Excuse me, Sarah, is this your coat?") == .otherPerson)
        #expect(kind("Good job today, Michael, really.") == .otherPerson)
    }

    @Test func aNameCannotBePlacedWhenTheListenersIsNotKnown() {
        #expect(kind("Peter, your taxi is outside.", .unknown) == .unknownPerson)
        #expect(kind("Hey Sarah, come and look at this.", .unknown) == .unknownPerson)
    }

    @Test func wordsBeforeACommaThatAreNotNamesAreNotTakenForOne() {
        for sentence in ["Sorry, is this seat taken?", "Careful, that step is loose.", "Remember, we leave at six.",
                         "No, it starts at nine.", "Everyone, please sit down.", "Stop, don't touch that!"]
        {
            #expect(kind(sentence) == .none, "\(sentence)")
            #expect(kind(sentence, .unknown) == .none, "\(sentence)")
        }
    }

    @Test func theListenersOwnGroupIsRecognised() {
        #expect(kind("Green boat, you launch first.") == .listenerGroup)
        #expect(kind("Crew D, life jackets on.") == .listenerGroup)
        #expect(kind("The green boat goes out at ten.") == .listenerGroup)
        #expect(kind("Peter, tell everyone at table nine the soup is coming.") == .listenerGroup)
    }

    @Test func anotherGroupOfTheSameKindIsToldApartByItsMark() {
        #expect(kind("Yellow boat, you launch first.") == .otherGroup)
        #expect(kind("Crew A, life jackets on.") == .otherGroup)
        #expect(kind("Table four, your starters are ready.") == .otherGroup)
        #expect(kind("The yellow boat goes out at ten.") == .otherGroup)
        #expect(kind("Could crew B please come to the jetty?") == .otherGroup)
        #expect(kind("My cousin's boat sank last year.") != .listenerGroup)
    }

    @Test func aGroupWithoutAMarkOrForEveryoneSaysNothing() {
        #expect(kind("The boats go out at ten.") == .none)
        #expect(kind("All boats back by noon, please.") == .none)
        #expect(kind("Both crews meet at the jetty.") == .none)
        #expect(kind("The boat keys are in the office.") == .none)
        // Another group mentioned, but not as the one the sentence is said to or begins with.
        #expect(kind("I told the yellow boat that everyone launches at ten.") == .none)
    }

    @Test func withoutAnythingKnownAboutTheListenerNoGroupIsToldApart() {
        #expect(kind("Yellow boat, you launch first.", .unknown) == .none)
        #expect(kind("Crew A, life jackets on.", .unknown) == .none)
    }

    @Test func aDifferentTimeTellsTwoClassesApart() {
        let identity = ListenerIdentity(groups: ["five pottery course"])
        #expect(kind("The eight o'clock pottery course is cancelled.", identity) == .otherGroup)
        #expect(kind("The five o'clock pottery course is cancelled.", identity) == .listenerGroup)
        #expect(kind("Five o'clock pottery, we are in the small studio.", identity) == .listenerGroup)
    }

    @Test func cutOffAndLeaningSentencesAreRecognisedByTheirForm() {
        #expect(SemanticText.isCutOff("So what we decided for tomorrow is that the"))
        #expect(SemanticText.isCutOff("and after lunch everybody has to"))
        #expect(!SemanticText.isCutOff("Who is it for?"))
        #expect(!SemanticText.isCutOff("The gate has changed to twelve."))
        #expect(!SemanticText.isCutOff("Come in"))
        #expect(SemanticText.leansOnContext("It got moved to Friday."))
        #expect(SemanticText.leansOnContext("No, the other one."))
        #expect(SemanticText.leansOnContext("And then he left."))
        #expect(!SemanticText.leansOnContext("The meeting got moved to Friday."))
    }
}

/// The engine with what the listener wrote about themselves.
@Suite struct PersonalRelevanceEngineTests {
    static let boats = AttentionGoal(text: "Tell me when my boat goes out or the launch time changes.", createdAt: Fixture.origin)
    static let spoken = AttentionGoal(text: "Let me know when someone is talking to me.", createdAt: Fixture.origin)
    static let about = "I'm Alma, on the green boat with crew D."

    private func engine(_ reasoner: ScriptedReasoner, about: String = about,
                        configuration: SemanticAttentionEngine.Configuration = .standard) async -> SemanticAttentionEngine
    {
        await Fixture.engine(reasoner, goals: [Self.boats, Self.spoken, Fixture.emergency], about: about, configuration: configuration)
    }

    @Test func whatTheListenerWroteIsReadWhenTheGoalsAreSet() async {
        let engine = await engine(ScriptedReasoner())
        let listener = await engine.listener
        #expect(listener.identity.names == ["Alma"])
        #expect(listener.identity.groups == ["green boat", "crew D"])
        #expect(listener.spokenToGoal == 2)
    }

    @Test func aSentenceForAnotherGroupIsListedNotAlerted() async {
        let sentence = "Yellow boat, you launch at nine instead of ten."
        let reasoner = ScriptedReasoner([sentence: Fixture.relevant(headline: "")])
        let engine = await engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(sentence))
        #expect(!decision.isAccepted)
        #expect(decision.verdict == .uncertain)
        #expect(decision.presentation == .listOnly)
        #expect(decision.subject == .someoneElse)
        #expect(decision.audience == .otherGroup)
        #expect(decision.corrections.contains("another_group"))
        // Settled by the words alone: neither the narrow question nor the second look is asked.
        #expect(await reasoner.concernAsked.isEmpty)
        #expect(await reasoner.confirmed.isEmpty)
        #expect(await engine.statistics.otherGroupSentences == 1)
    }

    @Test func aSentenceForTheListenersOwnGroupAlerts() async {
        let sentence = "Green boat, you launch at nine instead of ten."
        let reasoner = ScriptedReasoner([sentence: Fixture.relevant(headline: "")])
        let decision = await engine(reasoner).evaluate(Fixture.utterance(sentence))
        #expect(decision.isAccepted)
        #expect(decision.audience == .listenerGroup)
    }

    @Test func aSentenceSaidToAnotherPersonAboutTheirOwnBusinessIsNotAlerted() async {
        let sentence = "Peter, your boat goes out at nine tomorrow."
        let reasoner = ScriptedReasoner([sentence: Fixture.relevant(headline: "")])
        let engine = await engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(sentence))
        #expect(!decision.isAccepted)
        #expect(decision.presentation == .listOnly)
        #expect(decision.corrections.contains("said_to_someone_else"))
        #expect(await reasoner.concernAsked == [sentence])
        #expect(await reasoner.confirmed.isEmpty)
        #expect(await engine.statistics.concernDemoted == 1)
    }

    @Test func aSentenceSaidToAnotherPersonAboutSomethingForEveryoneStillAlerts() async {
        let sentence = "Peter, the launch time for all boats moves to nine."
        let reasoner = ScriptedReasoner([sentence: Fixture.relevant(headline: "")])
        await reasoner.setConcerns([sentence: .everyones])
        let engine = await engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(sentence))
        #expect(decision.isAccepted)
        #expect(await reasoner.concernAsked == [sentence])
        // It goes on to the second look like any other alert.
        #expect(await reasoner.confirmed == [sentence])
    }

    @Test func whenTheNarrowQuestionFailsASentenceSaidToSomeoneElseStaysSilent() async {
        let sentence = "Peter, your boat goes out at nine tomorrow."
        let reasoner = ScriptedReasoner([sentence: Fixture.relevant(headline: "")])
        await reasoner.setFailsConcern(true)
        let decision = await engine(reasoner).evaluate(Fixture.utterance(sentence))
        #expect(!decision.isAccepted)
        #expect(decision.corrections.contains("said_to_someone_else"))
    }

    @Test func aNameIsNotTakenForTheListenersWhenTheirsIsUnknown() async {
        let sentence = "Peter, your boat goes out at nine tomorrow."
        // As the production reasoner answers: no text of its own.
        let reasoner = ScriptedReasoner([sentence: RelevanceJudgement(goalIndex: 1, verdict: .relevant)])
        let decision = await engine(reasoner, about: "").evaluate(Fixture.utterance(sentence))
        // Not invented either way: kept as a possible match, and said why.
        #expect(!decision.isAccepted)
        #expect(decision.presentation == .listOnly)
        #expect(decision.isPersonalRelevanceUncertain)
        #expect(decision.audience == .unknownPerson)
        #expect(decision.corrections.contains("audience_unknown"))
        #expect(decision.reason.hasPrefix("Said to someone by name"))
    }

    @Test func theListenersNameAlertsUnderTheGoalAboutBeingSpokenTo() async {
        let sentence = "Alma, did you bring the charts?"
        // The model makes nothing of it.
        let reasoner = ScriptedReasoner()
        let engine = await engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(sentence))
        #expect(decision.isAccepted)
        #expect(decision.matchedGoalID == Self.spoken.id)
        #expect(decision.corrections.contains("called_by_name"))
        #expect(decision.urgency == .normal)
        #expect(decision.reason.hasPrefix("Someone said your name"))
        #expect(await reasoner.confirmed.isEmpty)
        #expect(await engine.statistics.calledByName == 1)
    }

    @Test func withoutAGoalAboutBeingSpokenToTheNameAloneDoesNotAlert() async {
        let sentence = "Alma, did you bring the charts?"
        let engine = await Fixture.engine(ScriptedReasoner(), goals: [Self.boats, Fixture.emergency], about: Self.about)
        #expect(await engine.evaluate(Fixture.utterance(sentence)).isAccepted == false)
    }

    @Test func aCutOffSentenceIsListedNotAlerted() async {
        let sentence = "So the new launch time for the green boat is going to be"
        let reasoner = ScriptedReasoner([sentence: Fixture.relevant(headline: "")])
        let engine = await engine(reasoner)
        let decision = await engine.evaluate(Fixture.utterance(sentence))
        #expect(!decision.isAccepted)
        #expect(decision.presentation == .listOnly)
        #expect(decision.corrections.contains("cut_off"))
        #expect(await reasoner.confirmed.isEmpty)
        #expect(await engine.statistics.cutOff == 1)
    }

    @Test func aSentenceThatLooksLikeAWarningIsNeverHeldBack() async {
        // Said to someone else by name, and cut off: still a warning for whoever is near.
        for sentence in ["Peter, watch out, the boom is swinging!", "Fire, everybody get out of the"] {
            let reasoner = ScriptedReasoner([sentence: Fixture.relevant(goal: 3, headline: "", urgency: .high)])
            let decision = await engine(reasoner).evaluate(Fixture.utterance(sentence))
            #expect(decision.isAccepted, "\(sentence)")
            #expect(await reasoner.concernAsked.isEmpty)
        }
    }

    @Test func theWindow6_2ConfigurationKnowsNothingOfTheListener() async {
        let other = "Yellow boat, you launch at nine instead of ten."
        let called = "Alma, did you bring the charts?"
        let reasoner = ScriptedReasoner([other: Fixture.relevant(headline: "")])
        let engine = await engine(reasoner, configuration: .window6_2)
        #expect(await engine.listener == .unknown)
        #expect(await engine.evaluate(Fixture.utterance(other)).isAccepted)
        #expect(await engine.evaluate(Fixture.utterance(called, at: 30)).isAccepted == false)
    }

    @Test func aChangedAboutLineIsReadAgain() async {
        let sentence = "Yellow boat, you launch at nine instead of ten."
        let reasoner = ScriptedReasoner([sentence: Fixture.relevant(headline: "")])
        let engine = await engine(reasoner)
        #expect(await engine.evaluate(Fixture.utterance(sentence)).isAccepted == false)
        await engine.setGoals([Self.boats, Self.spoken, Fixture.emergency], about: "I'm Alma, on the yellow boat.")
        await engine.listenerIsDescribed()
        #expect(await engine.evaluate(Fixture.utterance(sentence, at: 30)).isAccepted)
    }

    @Test func aStatementThatSaysNothingIsDifferentIsNoNews() async {
        let sentence = "The green boat goes out at ten, the same as yesterday."
        let reasoner = ScriptedReasoner([sentence: Fixture.relevant(headline: "")])
        let decision = await engine(reasoner).evaluate(Fixture.utterance(sentence))
        #expect(!decision.isAccepted)
        #expect(decision.verdict == .irrelevant)
        #expect(decision.corrections.contains("no_change_marker"))
        #expect(EvidenceVerifier.saysNothingChanges("Launch is at ten as usual."))
        #expect(EvidenceVerifier.saysNothingChanges("No, that was just a rumour."))
        // The opposite, and a change said with the same words, are left to the model.
        #expect(!EvidenceVerifier.saysNothingChanges("It is not the same as yesterday, we launch at nine."))
        #expect(!EvidenceVerifier.saysNothingChanges("Same boat, but we launch at nine now."))
    }

    @Test func aReminderOfAnAlertOfAMomentAgoIsNotAlertedAgainAndNeedsNoModel() async {
        let first = "The green boat launches an hour early tomorrow, at nine."
        let reminder = "Don't forget, the green boat launches at nine tomorrow, an hour early."
        let reasoner = ScriptedReasoner([first: Fixture.relevant(headline: ""), reminder: Fixture.relevant(headline: "")])
        let engine = await engine(reasoner)
        #expect(await engine.evaluate(Fixture.utterance(first)).isAccepted)
        let decision = await engine.evaluate(Fixture.utterance(reminder, at: 60))
        #expect(!decision.isAccepted)
        #expect(!decision.isNovel)
        #expect(await reasoner.confirmed == [first])
        #expect(await engine.statistics.markedReminders == 1)
        // A reminder with a new time is news, and goes to the second look.
        let changed = "Don't forget, the green boat launches at eight tomorrow."
        await reasoner.setJudgement(changed, Fixture.relevant(headline: ""))
        #expect(await engine.evaluate(Fixture.utterance(changed, at: 120)).isAccepted)
    }

    @Test func aDayOrTimeWithAnApostropheIsStillThatDay() {
        #expect(SemanticText.quantities(in: "Tonight's class is at six.") == ["tonight", "six"])
        #expect(SemanticText.quantities(in: "Friday's exam moved.") == ["friday"])
    }
}
