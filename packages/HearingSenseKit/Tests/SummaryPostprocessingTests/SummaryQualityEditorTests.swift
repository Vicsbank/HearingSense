import Testing
@testable import SummaryPostprocessing

/// Component E: cleanup that only deletes.
@Suite struct SummaryQualityEditorTests {
    private func analyzed(_ text: String) -> AnalyzedText { AnalyzedText(text) }

    @Test func narrationOpenersThatNameNoOneAreRemoved() {
        #expect(SummaryQualityEditor.tidied("Someone said that the lot reopens on Friday.") == "The lot reopens on Friday.")
        #expect(SummaryQualityEditor.tidied("Someone said they are playing a game right now, probably.") == "They are playing a game right now, probably.")
        #expect(SummaryQualityEditor.tidied("The speaker also mentioned that the exam moved to Friday.") == "The exam moved to Friday.")
        #expect(SummaryQualityEditor.tidied("Someone said the lot is closed and that cars will be towed.") == "The lot is closed and cars will be towed.")
        #expect(SummaryQualityEditor.tidied("They also said the bus leaves at 7:45.") == "The bus leaves at 7:45.")
        // A named person, an announcement and a short remainder stay as they are.
        #expect(SummaryQualityEditor.tidied("Maya said that she is late.") == "Maya said that she is late.")
        #expect(SummaryQualityEditor.tidied("It was announced that the lot reopens on Friday.") == "It was announced that the lot reopens on Friday.")
        #expect(SummaryQualityEditor.tidied("Someone said no.") == "Someone said no.")
    }

    @Test func aWordSaidTwiceInARowIsWrittenOnce() {
        #expect(SummaryQualityEditor.tidied("Someone said tomorrow, tomorrow, they will have the meeting with Ms. Wang.")
            == "Tomorrow, they will have the meeting with Ms. Wang.")
        #expect(SummaryQualityEditor.tidied("The meeting meeting is on Friday.") == "The meeting is on Friday.")
        #expect(SummaryQualityEditor.tidied("The code is five five two.") == "The code is five five two.")
        #expect(SummaryQualityEditor.tidied("They drive to Walla Walla on Friday.") == "They drive to Walla Walla on Friday.")
        #expect(SummaryQualityEditor.tidied("It was very very late.") == "It was very very late.")
        #expect(SummaryQualityEditor.tidied("She had had enough.") == "She had had enough.")
    }

    @Test func tidyingNeverAddsAWord() {
        let samples = ["Someone said that the lot reopens on Friday.", "Someone said tomorrow, tomorrow, the bus leaves at nine.",
                       "The speaker noted that Priya leads the group and that Sam orders lunch."]
        for sample in samples {
            let before = Set(SummaryText.words(in: sample))
            let after = SummaryText.words(in: SummaryQualityEditor.tidied(sample))
            #expect(after.allSatisfy(before.contains))
        }
    }

    @Test func fillerSaysNothingAboutWhatWasSaid() {
        #expect(SummaryQualityEditor.isFiller(analyzed("The conversation covered several topics.")))
        #expect(SummaryQualityEditor.isFiller(analyzed("A few announcements were made before starting.")))
        #expect(SummaryQualityEditor.isFiller(analyzed("They agreed to do this after this.")))
        #expect(!SummaryQualityEditor.isFiller(analyzed("The meeting is at 3.")))
        #expect(!SummaryQualityEditor.isFiller(analyzed("The group met with Priya.")))
        #expect(!SummaryQualityEditor.isFiller(analyzed("A conversation occurred about scheduling and errands.")))
    }

    @Test func genericTranscriptCommentaryIsFillerButSubstantiveAbsenceIsNot() {
        let boilerplate = ["No other specific times, names, or tasks were mentioned in the conversation.",
                           "No other details or names were provided.", "The plan remains as stated in the transcript."]
        for text in boilerplate { #expect(SummaryQualityEditor.isFiller(analyzed(text))) }
        #expect(!SummaryQualityEditor.isFiller(analyzed("No other flights are available.")))
        #expect(!SummaryQualityEditor.isFiller(analyzed("No other flights were mentioned in the conversation.")))
        #expect(!SummaryQualityEditor.isFiller(analyzed("Maya provided the tickets.")))
        #expect(!SummaryQualityEditor.isFiller(analyzed("Some speech could not be transcribed.")))
        #expect(!SummaryQualityEditor.isFiller(analyzed("The meeting is unchanged and remains on Friday.")))
        let output = SummaryPostprocessor().process(DraftText(title: "", summary: "Tickets are free now. " + boilerplate.joined(separator: " ")),
                                                   transcriptLines: ["tickets are free now"])
        #expect(output.summaryStatements == ["Tickets are free now."])
        #expect(output.fillerCount == 3)
    }

    @Test func unfinishedFragmentsAreRecognized() {
        #expect(SummaryQualityEditor.isIncompleteFragment("The meeting is on the"))
        #expect(SummaryQualityEditor.isIncompleteFragment("Bring the forms and"))
        #expect(SummaryQualityEditor.isIncompleteFragment("Done."))
        #expect(!SummaryQualityEditor.isIncompleteFragment("The dog food is the big bag"))
        #expect(!SummaryQualityEditor.isIncompleteFragment("Ask Priya what the slides are for."))
    }

    @Test func aStatementThatAddsNothingIsCoveredAndOneThatSaysMoreIsNot() {
        let full = SummaryQualityEditor.signature(of: analyzed("They are almost out of milk and eggs, and the twenty-pound dog food is needed."))
        #expect(SummaryQualityEditor.isCovered(SummaryQualityEditor.signature(of: analyzed("The dog food is twenty pounds.")), by: full))
        #expect(SummaryQualityEditor.isCovered(SummaryQualityEditor.signature(of: analyzed("The dog food is needed.")), by: full))
        #expect(!SummaryQualityEditor.isCovered(SummaryQualityEditor.signature(of: analyzed("The dog food is from Greenfield Market.")), by: full))
        // Polarity and relation words count.
        let open = SummaryQualityEditor.signature(of: analyzed("The gym is open on Monday."))
        #expect(!SummaryQualityEditor.isCovered(SummaryQualityEditor.signature(of: analyzed("The gym is not open on Monday.")), by: open))
        let likes = SummaryQualityEditor.signature(of: analyzed("Jonah hates oat milk."))
        #expect(!SummaryQualityEditor.isCovered(SummaryQualityEditor.signature(of: analyzed("Jonah likes oat milk.")), by: likes))
        // Values count: another day is something new.
        #expect(!SummaryQualityEditor.isCovered(SummaryQualityEditor.signature(of: analyzed("The gym is open on Tuesday.")), by: open))
    }

    @Test func repeatedSentencesAndKeyPointsAreDroppedOnce() {
        let lines = ["we are almost out of milk and eggs", "and the dog food the big bag the twenty pound one"]
        let summary = "They are almost out of milk and eggs. The dog food is the big bag. The dog food is the big bag. The dog food is twenty pounds."
        let output = SummaryPostprocessor().process(
            DraftText(title: "", summary: summary, keyPoints: ["The dog food is the big bag.", "Milk and eggs are needed."]),
            transcriptLines: lines)
        #expect(output.summaryStatements == ["They are almost out of milk and eggs.", "The dog food is the big bag.", "The dog food is twenty pounds."])
        // A key point identical to a summary sentence is a repeat; a shorter digest stays.
        #expect(output.keyPoints == ["Milk and eggs are needed."])
        #expect(output.duplicateCount == 2)
        #expect(output.removedCount == 0)
    }
}
