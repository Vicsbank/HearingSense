import Testing
@testable import SummaryPostprocessing

/// Component F: the orchestrator, end to end (first recap).
@Suite struct SummaryPostprocessorTests {
    let postprocessor = SummaryPostprocessor()

    /// A synthetic two-minute phone call with many separate facts, numbers spoken as words.
    static let clinicLines = [
        "good morning this is the Willow Street clinic how can I help",
        "hi I need to book a checkup for my son Theo",
        "sure the first opening is Tuesday the ninth at ten fifteen",
        "that works but he has school until three on Tuesdays",
        "then how about Thursday the eleventh at four thirty p.m.",
        "Thursday at four thirty is perfect",
        "great the visit takes about forty five minutes",
        "please bring his insurance card and the vaccination record",
        "the copay is twenty five dollars and we take cards only",
        "is there parking",
        "yes the garage on Pine Avenue is free for two hours",
        "the clinic is on the third floor in suite three ten",
        "Dr. Okonkwo will see him",
        "should he skip breakfast",
        "no he can eat normally there is no blood test this time",
        "if you need to cancel call us twenty four hours ahead",
        "our number is five five five oh one nine eight",
        "we also send a text reminder the day before",
        "he is allergic to penicillin by the way",
        "thanks I'll note the penicillin allergy in his file",
    ]

    static let clinicFacts = [
        "Theo has a checkup at the Willow Street clinic.",
        "The first opening was Tuesday the 9th at 10:15.",
        "Theo has school until 3 on Tuesdays.",
        "The checkup is on Thursday the 11th at 4:30 PM.",
        "The visit takes about 45 minutes.",
        "Bring his insurance card and the vaccination record.",
        "The copay is $25 and only cards are accepted.",
        "Parking in the Pine Avenue garage is free for 2 hours.",
        "The clinic is on the third floor in suite 310.",
        "Dr. Okonkwo will see Theo.",
        "Theo does not need to skip breakfast.",
        "There is no blood test this time.",
        "Cancellations need 24 hours notice.",
        "The clinic number is 555-0198.",
        "A text reminder is sent the day before.",
        "Theo is allergic to penicillin.",
        "The penicillin allergy will be noted in his file.",
    ]

    @Test func aTwoMinuteConversationWithManyFactsLosesNoneOfThem() {
        let output = postprocessor.process(DraftText(title: "Theo's checkup", summary: Self.clinicFacts.joined(separator: " ")),
                                           transcriptLines: Self.clinicLines)
        #expect(Self.clinicFacts.count >= 15)
        #expect(output.removedCount == 0)
        #expect(output.summaryStatements == Self.clinicFacts)
        #expect(output.title == "Theo's checkup")
        for report in output.reports {
            #expect(!report.verdict.removesStatement, "\(report.reason)")
        }
    }

    @Test func invertedOrInventedFactsAreRemovedAndTheRestStays() {
        let draft = DraftText(title: "", summary: "The copay is $35. The visit takes about 45 minutes. The clinic is on the fifth floor.",
                              keyPoints: ["There is a blood test this time.", "Bring the insurance card."])
        let output = postprocessor.process(draft, transcriptLines: Self.clinicLines)
        #expect(output.summaryStatements == ["The visit takes about 45 minutes."])
        #expect(output.keyPoints == ["Bring the insurance card."])
        #expect(output.removedCount == 3)
        #expect(output.corrections.contains(ReasonCode.inventedValue.rawValue))
        #expect(output.corrections.contains(ReasonCode.negationFlip.rawValue))
    }

    @Test func narrationAndStuttersAreTakenOutWithoutLosingTheFact() {
        let lines = ["Tomorrow, tomorrow we have the meeting with Ms. Wang at three in room 204."]
        let draft = DraftText(title: "Meeting with Ms. Wang",
                              summary: "Someone said tomorrow, tomorrow, the meeting with Ms. Wang takes place at three in room 204.")
        let output = postprocessor.process(draft, transcriptLines: lines)
        #expect(output.summary == "Tomorrow, the meeting with Ms. Wang takes place at three in room 204.")
        #expect(!output.summary.lowercased().contains("someone said"))
        #expect(output.title == "Meeting with Ms. Wang")
    }

    @Test func fillerIsDroppedAndCountedApart() {
        let draft = DraftText(title: "", summary: "The conversation covered several topics. The visit takes about 45 minutes.")
        let output = postprocessor.process(draft, transcriptLines: Self.clinicLines)
        #expect(output.summaryStatements == ["The visit takes about 45 minutes."])
        #expect(output.fillerCount == 1)
        #expect(output.removedCount == 0)
    }

    @Test func aTitleIsCheckedOnlyForItsValues() {
        let output = postprocessor.process(DraftText(title: "Checkup on Friday the 13th", summary: "The visit takes about 45 minutes."),
                                           transcriptLines: Self.clinicLines)
        #expect(output.title.isEmpty)
        #expect(output.corrections.contains(ReasonCode.titleReplaced.rawValue))
        #expect(postprocessor.process(DraftText(title: "Booking a checkup", summary: ""), transcriptLines: Self.clinicLines).title == "Booking a checkup")
    }

    @Test func nothingIsInventedFromEmptyInput() {
        let empty = postprocessor.process(DraftText(title: "", summary: ""), transcriptLines: [])
        #expect(empty.summary.isEmpty && empty.keyPoints.isEmpty && empty.statementCount == 0)
        // Without a transcript, a value cannot be grounded: the statement goes.
        let noTranscript = postprocessor.process(DraftText(title: "Bus", summary: "The bus leaves at 9."), transcriptLines: [])
        #expect(noTranscript.summary.isEmpty)
        #expect(noTranscript.removedCount == 1)
    }

    @Test func everyOutputStatementWasAnInputStatement() {
        let draft = DraftText(title: "", summary: "Someone said the visit takes about 45 minutes. The copay is $35. Tomorrow, tomorrow, Theo goes to the clinic.",
                              keyPoints: ["Bring his insurance card and the vaccination record."])
        let output = postprocessor.process(draft, transcriptLines: Self.clinicLines)
        let inputWords = Set(SummaryText.words(in: draft.summary + " " + draft.keyPoints.joined(separator: " ")))
        for statement in output.summaryStatements + output.keyPoints {
            #expect(SummaryText.words(in: statement).allSatisfy(inputWords.contains))
        }
    }

    @Test func reasonsAndCorrectionsHoldCodesOnly() {
        let codes = Set(ReasonCode.allCases.map(\.rawValue))
        let draft = DraftText(title: "Checkup on the 13th",
                              summary: "The copay is $35. " + Self.clinicFacts.joined(separator: " ") + " " + Self.clinicLines[7] + ".",
                              keyPoints: ["Pupils were reminded about punctuality.", "Dr. Okonkwo will see Theo."])
        let output = postprocessor.process(draft, transcriptLines: Self.clinicLines)
        #expect(output.reports.allSatisfy { codes.contains($0.reason) })
        #expect(output.corrections.allSatisfy { codes.contains($0) })
        #expect(output.reasonCounts.keys.allSatisfy { codes.contains($0) })
        // No reason or correction carries a word of the conversation.
        let spoken = Set(Self.clinicLines.flatMap { SummaryText.words(in: $0) })
        for code in output.corrections + output.reports.map(\.reason) {
            #expect(!code.split(separator: "_").contains { spoken.contains(String($0)) && $0.count > 6 })
        }
    }

    @Test func theResultDependsOnlyOnTheInput() {
        let draft = DraftText(title: "Checkup", summary: Self.clinicFacts.joined(separator: " ") + " The copay is $35.",
                              keyPoints: ["The visit takes about 45 minutes.", "Pupils were reminded about punctuality."])
        let first = postprocessor.process(draft, transcriptLines: Self.clinicLines)
        let second = SummaryPostprocessor().process(draft, transcriptLines: Self.clinicLines)
        #expect(first == second)
        #expect(first.reports.map(\.reason) == second.reports.map(\.reason))
    }

    @Test func anOptionalVerifierRemovesOnlyWhatItRejectsAndUnansweredStaysUnverified() {
        let draft = DraftText(title: "", summary: "Pupils were reminded about punctuality. The visit takes about 45 minutes. Theo does not need to skip breakfast.")
        let output = postprocessor.process(draft, transcriptLines: Self.clinicLines)
        #expect(output.uncertainStatements.contains("Pupils were reminded about punctuality."))
        let verified = output.applying(verifierVerdicts: ["Pupils were reminded about punctuality.": false,
                                                          "The visit takes about 45 minutes.": false])
        #expect(!verified.summary.contains("Pupils"))
        // A supported statement is not removed by a verifier.
        #expect(verified.summary.contains("The visit takes about 45 minutes."))
        #expect(verified.removedCount == output.removedCount + 1)
        #expect(!verified.unverifiedStatements.contains("Pupils were reminded about punctuality."))
        #expect(verified.unverifiedStatements == verified.uncertainStatements)
        #expect(verified.reports.contains { $0.reason == ReasonCode.verifierRejected.rawValue })
        // No answer at all: nothing changes, nothing is called verified.
        let timedOut = output.applying(verifierVerdicts: [:])
        #expect(timedOut == output)
        #expect(timedOut.unverifiedStatements == output.uncertainStatements)
    }
}
