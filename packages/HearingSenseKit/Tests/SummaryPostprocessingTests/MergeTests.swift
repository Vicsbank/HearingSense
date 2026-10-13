import Testing
@testable import SummaryPostprocessing

/// Incremental updates: duplicates removed, explicit changes applied in place, earlier facts
/// never lost silently.
@Suite struct MergeTests {
    let postprocessor = SummaryPostprocessor()

    let earlier = DraftText(title: "Team meeting",
                            summary: "The team meeting is on Thursday at 3 PM in room 204. Priya will bring the slides.",
                            keyPoints: ["The team meeting is on Thursday."])
    let earlierLines = ["the team meeting is on Thursday at three p.m. in room two oh four", "Priya will bring the slides"]

    @Test func anUpdateDropsRepeatsAndReplacesWhatTheNewSpeechChanged() {
        let newLines = ["actually let's move the team meeting to Friday", "same time same room", "and Sam will order lunch"]
        let addition = DraftText(title: "", summary: "The team meeting was moved to Friday. Priya will bring the slides. Sam will order lunch.",
                                 keyPoints: ["The meeting is now on Friday.", "Sam orders lunch."])
        let merged = postprocessor.merge(earlier: earlier, addition: addition, newLines: newLines, earlierLines: earlierLines)

        // The repeated sentence is there once.
        #expect(merged.summaryStatements.filter { $0 == "Priya will bring the slides." }.count == 1)
        #expect(merged.reports.contains { $0.verdict == .duplicate })
        // The new facts are added.
        #expect(merged.summaryStatements.contains("The team meeting was moved to Friday."))
        #expect(merged.summaryStatements.contains("Sam will order lunch."))
        // The earlier key point that only said "Thursday" is replaced in its place.
        #expect(merged.keyPoints.first == "The meeting is now on Friday.")
        #expect(!merged.keyPoints.contains("The team meeting is on Thursday."))
        #expect(merged.corrections.contains(ReasonCode.replacedOutdatedStatement.rawValue))
        // The earlier sentence also holds the time and the room: it is not lost; it is kept and
        // marked, and the change follows it.
        #expect(merged.summary.contains("room 204"))
        #expect(merged.corrections.contains(ReasonCode.earlierOutdatedKept.rawValue))
        // A shorter key point is a digest, not a repeat.
        #expect(merged.keyPoints.contains("Sam orders lunch."))
        #expect(merged.title == "Team meeting")
        #expect(merged.removedCount == 0)
    }

    @Test func aChangeTheAdditionDidNotStateLeavesTheEarlierStatementMarkedNotDeleted() {
        let newLines = ["actually let's move the team meeting to Friday", "and Sam will order lunch"]
        let addition = DraftText(title: "", summary: "Sam will order lunch.")
        let merged = postprocessor.merge(earlier: earlier, addition: addition, newLines: newLines, earlierLines: earlierLines)
        #expect(merged.keyPoints.contains("Superseded: The team meeting is on Thursday."))
        #expect(merged.uncertainStatements.contains("Superseded: The team meeting is on Thursday."))
        #expect(merged.corrections.contains(ReasonCode.outdatedByNewSpeech.rawValue))
        #expect(merged.summaryStatements.contains("Sam will order lunch."))
    }

    @Test func anUpdateMayRestateTheEarlierRecapWithoutItsTranscript() {
        // The earlier speech is gone from memory; the earlier recap still supports a repeat of it.
        let newLines = ["and Sam will order lunch for everyone"]
        let addition = DraftText(title: "", summary: "Sam will order lunch for the meeting in room 204.")
        let merged = postprocessor.merge(earlier: earlier, addition: addition, newLines: newLines, earlierLines: [])
        #expect(merged.summaryStatements.contains("Sam will order lunch for the meeting in room 204."))
        #expect(merged.removedCount == 0)
    }

    @Test func anInventedValueInAnUpdateIsRemovedAndTheEarlierRecapStays() {
        let newLines = ["and Sam will order lunch"]
        let addition = DraftText(title: "", summary: "Sam will order lunch for $40.")
        let merged = postprocessor.merge(earlier: earlier, addition: addition, newLines: newLines, earlierLines: earlierLines)
        #expect(merged.summaryStatements == ["The team meeting is on Thursday at 3 PM in room 204.", "Priya will bring the slides."])
        #expect(merged.keyPoints == earlier.keyPoints)
        #expect(merged.removedCount == 1)
        #expect(merged.statementCount == 1)
    }

    @Test func anUpdateThatCopiesTheNewSpeechIsHeldToTheCopyLimits() {
        let newLines = ["One more thing, the report is due next Wednesday, not Monday.", "And the teacher said it has to be at least six pages.",
                        "Fine, then let's split it, three pages each."]
        let addition = DraftText(title: "", summary: newLines.joined(separator: " "))
        let merged = postprocessor.merge(earlier: earlier, addition: addition, newLines: newLines, earlierLines: earlierLines)
        // Three spoken sentences in a row are never all kept.
        #expect(newLines.filter { merged.summaryStatements.contains($0) }.count <= 1)
        #expect(!merged.copiedNeedingRestatement.isEmpty)
    }

    @Test func replacingADayDoesNotSilentlyDeleteANonnumericTask() {
        let prior = DraftText(title: "Meeting", summary: "The meeting is Friday and Priya will bring slides.")
        let result = postprocessor.merge(earlier: prior, addition: DraftText(title: "", summary: "The meeting moved to Saturday."),
                                         newLines: ["move the meeting to Saturday"],
                                         earlierLines: ["the meeting is Friday and Priya will bring slides"])
        #expect(result.summary.contains("Priya will bring slides"))
        #expect(result.corrections.contains(ReasonCode.earlierOutdatedKept.rawValue))
    }

    @Test func anUnrelatedStatementWithTheCorrectedDayIsNoReplacement() {
        let prior = DraftText(title: "Meeting", summary: "The meeting is Friday.")
        let result = postprocessor.merge(earlier: prior, addition: DraftText(title: "", summary: "The rehearsal is Saturday."),
                                         newLines: ["move the meeting to Saturday", "the rehearsal is Saturday"],
                                         earlierLines: ["the meeting is Friday"])
        #expect(result.summary.contains("Superseded: The meeting is Friday."))
        #expect(result.uncertainStatements.contains("Superseded: The meeting is Friday."))
        #expect(result.corrections.contains(ReasonCode.outdatedByNewSpeech.rawValue))
    }

    @Test func separateStaleKeyPointsSeeCorrectionsAlreadyInsertedIntoTheSummary() {
        let previous = DraftText(title: "Meeting", summary: "The team meeting is Friday at 7:45. Please bring $20 for the tickets.",
                                 keyPoints: ["the team meeting is Friday at 7:45", "$20 is requested for tickets", "the bus leaves at 3:30 PM"])
        let lines = ["the team meeting is Friday at seven forty five", "please bring twenty dollars for tickets",
                     "the bus leaves at three thirty p m"]
        let fresh = ["Sorry, make that Saturday instead of Friday for the team meeting.",
                     "Parking is behind the library and Dana will bring the programs.",
                     "The tickets are free now, so no need for the twenty dollars."]
        let addition = DraftText(title: "", summary: "The team meeting is Saturday at 7:45. Parking is behind the library. Dana will bring the programs. The tickets are free now.")
        let result = postprocessor.merge(earlier: previous, addition: addition, newLines: fresh, earlierLines: lines)
        #expect(result.summary.contains("Saturday at 7:45"))
        #expect(result.summary.contains("tickets are free"))
        #expect(!result.keyPoints.contains("the team meeting is Friday at 7:45"))
        #expect(!result.keyPoints.contains("$20 is requested for tickets"))
        #expect(result.keyPoints.contains("the bus leaves at 3:30 PM"))
        #expect(result.summary.contains("Dana will bring the programs"))
        #expect(result.keyPoints == ["the bus leaves at 3:30 PM"])
    }

    @Test func aRetainedCompoundStatementIsVisiblySupersededAndUnverified() {
        let old = "The meeting is Friday and Priya will bring slides."
        let result = postprocessor.merge(earlier: DraftText(title: "", summary: old),
                                         addition: DraftText(title: "", summary: "The meeting moved to Saturday."),
                                         newLines: ["move the meeting to Saturday"], earlierLines: [old])
        #expect(result.summaryStatements.contains("Superseded: " + old))
        #expect(result.unverifiedStatements.contains("Superseded: " + old))
        #expect(result.reports.contains { $0.text == "Superseded: " + old && $0.verdict == .uncertain })
        #expect(!result.reports.contains { $0.text == old && $0.verdict == .supported })
    }

    @Test func compoundVenueAndPriceCorrectionsCannotRemainUnmarkedAsCurrent() {
        let compound = "The recital is Saturday at 3:00 in the school auditorium, and tickets cost five dollars."
        let earlier = DraftText(title: "Recital", summary: compound,
                                keyPoints: ["the venue is the school auditorium", "tickets cost five dollars"])
        let result = postprocessor.merge(earlier: earlier,
                                         addition: DraftText(title: "", summary: "The recital moved to the cafeteria. Tickets are free now."),
                                         newLines: ["move the recital from the auditorium to the cafeteria", "tickets are free now"],
                                         earlierLines: [compound])
        #expect(result.summaryStatements.contains("Superseded: " + compound))
        #expect(!result.summaryStatements.contains(compound))
        #expect(!result.keyPoints.contains("the venue is the school auditorium"))
        #expect(!result.keyPoints.contains("tickets cost five dollars"))
        #expect(result.summary.contains("Saturday at 3:00"))
        #expect(result.summary.contains("cafeteria"))
        #expect(result.summary.contains("Tickets are free now"))
    }

    @Test func markedHistoryCannotGroundALaterCurrentClaimAfterTheSpeechExpires() {
        let history = "Superseded: The meeting is Friday at 7:45 and Priya brings slides."
        let oldPoint = "Superseded: The meeting is Friday at 7:45"
        let earlier = DraftText(title: "Meeting", summary: history + " The meeting is Saturday at 7:45.", keyPoints: [oldPoint])
        let result = postprocessor.merge(earlier: earlier,
                                         addition: DraftText(title: "", summary: "The meeting will be on Friday at 7:45. Parking is behind the library."),
                                         newLines: ["parking is behind the library"], earlierLines: [])
        #expect(result.summaryStatements.contains(history))
        #expect(result.keyPoints.contains(oldPoint))
        #expect(result.summary.contains("Saturday at 7:45"))
        #expect(!result.summary.contains("will be on Friday"))
        #expect(result.reports.contains { $0.text == "The meeting will be on Friday at 7:45." && $0.verdict == .unsupported })
        #expect(result.summary.contains("Parking is behind the library"))
        #expect(!result.summary.contains("Superseded: Superseded:"))
    }

    @Test func markedHistoryDoesNotProvideStrongDuplicateCoverageForNewSpeech() {
        let earlier = DraftText(title: "", summary: "Superseded: The meeting is Friday at 7:45 and Priya brings slides.")
        let result = postprocessor.merge(earlier: earlier,
                                         addition: DraftText(title: "", summary: "Priya brings slides."),
                                         newLines: ["Priya brings slides"], earlierLines: [])
        #expect(result.summaryStatements.contains("Priya brings slides."))
        #expect(result.duplicateCount == 0)
        #expect(result.summaryStatements.first == earlier.summary)
    }
}
