import Foundation
import HearingSenseDomain
import Testing
@testable import SemanticSummary

/// Deterministic checks on hand-written (synthetic) transcripts and candidate headlines. No
/// language model runs here; real-model results are in docs/testing/WINDOW3_TEST_RESULTS.md.
@Suite struct UtteranceAnalysisTests {
    @Test func detectsNegationButNotNeutralIdioms() {
        #expect(UtteranceAnalysis("Your package has NOT arrived.").isNegated)
        #expect(UtteranceAnalysis("Class doesn’t start at 3 PM.").negations == ["doesn't"])
        #expect(UtteranceAnalysis("Please don't open the door.").isNegated)
        #expect(UtteranceAnalysis("I will never be late again").isNegated)
        #expect(UtteranceAnalysis("There is no school on Friday").isNegated)
        #expect(!UtteranceAnalysis("Your package arrived.").isNegated)
        #expect(!UtteranceAnalysis("Hey, don't forget we have a biology test tomorrow.").isNegated)
        #expect(!UtteranceAnalysis("No problem, I can't wait!").isNegated)
        // An idiom does not hide a real negation elsewhere in the sentence.
        #expect(UtteranceAnalysis("Don't forget, the store is not open today").isNegated)
        // "note" and "nothing" style look-alikes: only whole words count.
        #expect(!UtteranceAnalysis("Take a note about the knot").isNegated)
    }

    @Test func findsTimeExpressionsAndKeepsTheirNumbersApart() {
        #expect(UtteranceAnalysis("Class starts at 3 PM.").timeExpressions == ["3 pm"])
        #expect(UtteranceAnalysis("Class starts at 3 PM.").numbers.isEmpty)
        #expect(UtteranceAnalysis("The bus leaves at 7:30 tomorrow morning.").timeExpressions == ["7:30", "tomorrow", "morning"])
        #expect(UtteranceAnalysis("Meet me at 10:15 a.m. on Friday").timeExpressions == ["10:15 am", "friday"])
        #expect(UtteranceAnalysis("Dinner at five o'clock").timeExpressions == ["five o'clock"])
        let meeting = UtteranceAnalysis("The meeting starts in five minutes in room 12.")
        #expect(meeting.timeExpressions.isEmpty && meeting.numbers == ["five", "12"])
        #expect(UtteranceAnalysis("I am hungry").timeExpressions.isEmpty)
    }

    @Test func recognizesQuestions() {
        #expect(UtteranceAnalysis("Did you see my keys anywhere").isQuestion)
        #expect(UtteranceAnalysis("Hey, can you help me").isQuestion)
        #expect(UtteranceAnalysis("You saw that?").isQuestion)
        #expect(!UtteranceAnalysis("Your package arrived.").isQuestion)
    }

    @Test func groundingAcceptsInflectionsAndRejectsOtherWords() {
        let source = UtteranceAnalysis("Can you help me carry these boxes to the meeting that starts at 3 PM?")
        for word in ["help", "Carrying", "box", "Boxes", "meetings", "starting", "started", "3", "pm", "carried"] {
            #expect(source.supports(word), "\(word)")
        }
        for word in ["package", "4", "am", "car", "test", "meat", "cart"] {
            #expect(!source.supports(word), "\(word)")
        }
    }
}

@Suite struct SummaryValidatorTests {
    let validator = SummaryValidator()

    func accepted(_ headline: String, for transcript: String) -> SpeechSummary? {
        if case .accepted(let summary) = validator.validate(headline: headline, transcript: transcript) { summary } else { nil }
    }

    func issues(_ headline: String, for transcript: String) -> [SummaryValidator.Issue] {
        if case .rejected(let issues) = validator.validate(headline: headline, transcript: transcript) { issues } else { [] }
    }

    // The five representative sentences from the Window 3 brief.

    @Test func packageArrived() {
        #expect(accepted("Package Arrived", for: "Your package arrived.")?.text == "Package Arrived")
        #expect(issues("Package Not Arrived", for: "Your package arrived.") == [.negationInvented])
    }

    @Test func packageHasNotArrived() {
        let transcript = "Your package has NOT arrived."
        #expect(issues("Package Arrived", for: transcript) == [.negationDropped])
        #expect(accepted("Package Not Arrived", for: transcript)?.reliability == .validated)
        #expect(accepted("package hasn't arrived", for: transcript)?.text == "Package Hasn't Arrived")
    }

    @Test func classStartsAtThreePM() {
        let transcript = "Class starts at 3 PM."
        #expect(accepted("Class Starts At 3 PM", for: transcript)?.reliability == .validated)
        // A dropped time is repaired from the transcript, never invented.
        let repaired = accepted("Class Starts", for: transcript)
        #expect(repaired?.text == "Class Starts 3 PM" && repaired?.reliability == .repaired)
        #expect(issues("Class Starts At 4 PM", for: transcript).contains(.unsupportedTime(["4 pm"])))
        #expect(issues("Class Starts Tomorrow", for: transcript).contains(.unsupportedTime(["tomorrow"])))
    }

    @Test func classDoesNotStartAtThreePM() {
        let transcript = "Class does NOT start at 3 PM."
        #expect(issues("Class Starts At 3 PM", for: transcript) == [.negationDropped])
        #expect(issues("Class Starts", for: transcript).contains(.negationDropped))
        #expect(accepted("Class Does Not Start", for: transcript)?.text == "Class Does Not Start 3 PM")
        #expect(accepted("Class Not At 3 PM", for: transcript)?.reliability == .validated)
    }

    @Test func pleaseDontOpenTheDoor() {
        let transcript = "Please don't open the door."
        #expect(issues("Open Door", for: transcript) == [.negationDropped])
        #expect(issues("Open The Door Please", for: transcript) == [.negationDropped])
        #expect(accepted("Don't Open Door", for: transcript) != nil)
        #expect(accepted("Do Not Open Door", for: transcript) != nil)
        // A paraphrase that avoids the negation is not accepted either: its words are not in the transcript.
        #expect(issues("Keep Door Closed", for: transcript).contains(.negationDropped))
    }

    @Test func idiomaticDontForgetIsNotANegation() {
        let transcript = "Hey, don't forget we have a biology test tomorrow."
        #expect(accepted("Biology Test Tomorrow", for: transcript)?.reliability == .validated)
        #expect(accepted("Biology Test", for: transcript)?.text == "Biology Test Tomorrow")
        #expect(accepted("Don't Forget Biology Test Tomorrow", for: transcript) != nil)
    }

    @Test func rejectsContentThatIsNotInTheTranscript() {
        #expect(issues("Amazon Package Arrived", for: "Your package arrived.") == [.unsupportedWords(["amazon"])])
        #expect(issues("Package Arrived Yesterday", for: "Your package arrived.")
            .contains(.unsupportedTime(["yesterday"])))
        #expect(issues("Fire Alarm", for: "Can you help me carry these boxes?") == [.unsupportedWords(["fire", "alarm"])])
        #expect(issues("5 Boxes", for: "Can you help me carry these boxes?") == [.unsupportedWords(["5"])])
    }

    @Test func allowsAFewGenericLabelWords() {
        #expect(accepted("Help Requested", for: "Can you help me carry these boxes?") != nil)
        #expect(accepted("Meeting Starting Soon", for: "The meeting starts in five minutes.")?.reliability
            == .validatedWithWarnings)
        #expect(accepted("Meeting Starts Five Minutes", for: "The meeting starts in five minutes.")?.reliability
            == .validated)
    }

    @Test func enforcesTheDisplayLimitButAllowsLongerThanTargetWhenNeeded() {
        let transcript = "I will not be home until nine tonight."
        let longer = accepted("Not Home Until Nine Tonight", for: transcript)
        #expect(longer?.wordCount == 5 && longer?.notes.contains("longer than 3 words") == true)
        #expect(issues("I Will Not Be Home Until Nine Tonight", for: transcript)
            == [.tooLong(words: 8, limit: 6)])
        var strict = SummaryPolicy()
        strict.maximumWords = 3
        // With no room to append the time, the headline is rejected instead of shown without it.
        #expect(SummaryValidator(policy: strict).validate(headline: "Class Does Not", transcript: "Class does not start at 3 PM.")
            == .rejected([.timeDropped(["3 pm"])]))
    }

    @Test func aClockTimeIsKeptEvenWhenTheDayIsKept() {
        let transcript = "The bus leaves at 7:30 tomorrow morning."
        #expect(UtteranceAnalysis(transcript).clockTimes == ["7:30"])
        let repaired = accepted("Bus Leaves Tomorrow", for: transcript)
        #expect(repaired?.text == "Bus Leaves Tomorrow 7:30" && repaired?.reliability == .repaired)
        #expect(accepted("Bus Leaves 7:30", for: transcript)?.reliability == .validated)
        // Day words alone are enough when the sentence has no clock time.
        #expect(accepted("Essay Due Friday", for: "The essay is due on Friday.")?.reliability == .validated)
    }

    @Test func rejectsEmptyHeadlines() {
        #expect(issues("", for: "Your package arrived.") == [.empty])
        #expect(issues("  \"...\" ", for: "Your package arrived.") == [.empty])
    }

    @Test func formatsHeadlinesInTitleCase() {
        #expect(SummaryValidator.format("\"BIOLOGY TEST TOMORROW.\"", transcript: "biology test tomorrow") == "Biology Test Tomorrow")
        #expect(SummaryValidator.format("class at 3 pm", transcript: "Class starts at 3 PM.") == "Class At 3 PM")
        #expect(SummaryValidator.format("tv is broken", transcript: "The TV is broken") == "TV Is Broken")
        #expect(SummaryValidator.format("don’t open door!", transcript: "") == "Don't Open Door")
        #expect(SummaryValidator.wordCount("Class At 3 PM") == 4)
    }

    @Test func issueNamesContainNoTranscriptText() {
        let all: [SummaryValidator.Issue] = [.empty, .tooLong(words: 9, limit: 6), .negationDropped, .negationInvented,
                                             .unsupportedWords(["secret"]), .unsupportedTime(["3 pm"]),
                                             .timeDropped(["3 pm"]), .numberDropped(["42"])]
        for issue in all {
            #expect(!issue.name.contains("secret") && !issue.name.contains("3") && !issue.name.contains("42"))
        }
    }
}

@Suite struct RuleBasedInterpreterTests {
    @Test func categorizesWithKeywordRules() {
        let expectations: [(String, SpeechSemanticCategory)] = [
            ("Can you help me carry these boxes?", .request),
            ("Hey, could you close the window please", .request),
            ("Did you see my keys anywhere", .question),
            ("What time is it?", .question),
            ("Hey, don't forget we have a biology test tomorrow.", .reminder),
            ("Remember the math exam tomorrow.", .reminder),
            ("Be careful, the floor is wet.", .warning),
            ("Hi there", .greeting),
            ("Good morning", .greeting),
            ("Your package arrived.", .other),
            ("", .unknown),
        ]
        for (text, category) in expectations {
            #expect(RuleBasedInterpreter.category(of: text) == category, "\(text)")
        }
    }

    @Test func detailsComeFromRules() {
        let details = RuleBasedInterpreter.details(of: "Class does not start at 3 PM.")
        #expect(details.isNegated && !details.isQuestion && details.timeOrNumber == "3 pm" && details.source == .rules)
        #expect(RuleBasedInterpreter.details(of: "Did you see five dogs?").timeOrNumber == "five")
    }

    @Test func flagsTranscriptsThatAreTooThinToInterpret() {
        #expect(RuleBasedInterpreter.isUnclear(SemanticRequest(transcript: "")))
        #expect(RuleBasedInterpreter.isUnclear(SemanticRequest(transcript: "uh the the and so it")))
        #expect(RuleBasedInterpreter.isUnclear(SemanticRequest(
            transcript: "Your package arrived",
            quality: .assess(meanConfidence: 0.3, minimumConfidence: 0.1, wordCount: 3))))
        #expect(!RuleBasedInterpreter.isUnclear(SemanticRequest(transcript: "Hello.")))
        #expect(!RuleBasedInterpreter.isUnclear(SemanticRequest(transcript: "Your package arrived")))
    }
}
