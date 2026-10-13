import Testing
@testable import SummaryPostprocessing

/// Component C: explicit corrections in speech, the current value of a slot, and statements
/// that present a superseded value as current.
@Suite struct CorrectionResolverTests {
    let resolver = CorrectionResolver()

    @Test func anActuallyMovesTheValue() {
        let lines = ["The meeting is Thursday.", "Actually, move it to Friday."]
        let corrections = resolver.corrections(in: lines)
        #expect(corrections.count == 1)
        #expect(corrections.first?.oldValue?.readings == [.weekday(4, nil)])
        #expect(corrections.first?.newValue.readings == [.weekday(5, nil)])
        #expect(corrections.first?.topic.contains("meet") == true)

        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.ground("The meeting was moved to Friday.").verdict == .supported)
        let outdated = grounder.ground("The meeting is on Thursday.")
        #expect(outdated.verdict == .unsupported)
        #expect(outdated.reason == .supersededValue)
        #expect(grounder.ground("The meeting moved from Thursday to Friday.").verdict == .supported)
        #expect(grounder.ground("The meeting was originally on Thursday.").verdict != .unsupported)
    }

    @Test func repeatedCorrectionsOfOneSlotEndAtTheLastValue() {
        let lines = ["The team meeting is on Thursday.", "Actually, let's move it to Friday.", "No wait, Monday works better for everyone."]
        let corrections = resolver.corrections(in: lines)
        #expect(corrections.count == 2)
        if let first = corrections.first {
            #expect(resolver.finalValue(of: first, in: corrections).readings == [.weekday(1, nil)])
        }
        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.ground("The team meeting is on Friday.").reason == .supersededValue)
        #expect(grounder.ground("The team meeting is on Thursday.").reason == .supersededValue)
        #expect(grounder.ground("The team meeting was moved to Monday.").verdict == .supported)
        #expect(grounder.ground("The team meeting moved from Thursday to Friday and then to Monday.").verdict != .unsupported)
    }

    @Test func anInLineRejectionSupersedesTheRejectedValue() {
        let grounder = ClaimGrounder(lines: ["One more thing, the report is due next Wednesday, not Monday."])
        #expect(grounder.ground("The report is due Monday.").reason == .supersededValue)
        #expect(grounder.ground("The report is due next Wednesday.").verdict == .supported)
        #expect(grounder.ground("The report is due next Wednesday, not Monday.").verdict == .supported)
    }

    @Test func aChangeOfAnotherMatterDoesNotTouchAStatement() {
        let lines = ["The plumber comes on Thursday.", "The dentist appointment is on Tuesday.", "Actually the dentist moved it to Friday."]
        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.ground("The plumber comes on Thursday.").verdict == .supported)
        #expect(grounder.ground("The dentist appointment is on Tuesday.").reason == .supersededValue)
    }

    @Test func aQuestionIsNotACorrection() {
        let lines = ["The meeting is on Thursday.", "Can we move it to Friday?"]
        #expect(resolver.corrections(in: lines).isEmpty)
        #expect(ClaimGrounder(lines: lines).ground("The meeting is on Thursday.").verdict == .supported)
    }

    @Test func aValueSaidAgainForAnotherMatterIsNotSuperseded() {
        let lines = ["so three minutes each", "no it's four minutes each the rubric says twelve total",
                     "oh four okay I thought it was three because of the other class", "that class gave three minutes each"]
        let corrections = resolver.corrections(in: lines)
        #expect(corrections.contains { $0.cue == .answerNo })
        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.ground("Each person speaks for four minutes.").verdict != .unsupported)
        #expect(grounder.ground("The other class gave three minutes each.").verdict != .unsupported)
    }

    @Test func anImplicitMoveMayAddARationaleWithoutLosingItsAdjacentSlot() {
        let lines = ["the team meeting is Thursday at seven forty five",
                     "actually move it to Friday the same time works better for Dana"]
        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.corrections.count == 1)
        #expect(grounder.ground("The team meeting is Thursday at 7:45.").reason == .supersededValue)
        #expect(grounder.ground("The team meeting is Friday at 7:45.").verdict != .unsupported)
    }

    @Test func anExplicitInsteadPairOverridesAnEarlierGenericRepairCue() {
        let lines = ["the team meeting is on Friday",
                     "sorry make that Saturday instead of Friday for the team meeting"]
        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.corrections.count == 1)
        #expect(grounder.corrections.first?.cue == .instead)
        #expect(grounder.ground("The team meeting is Friday.").reason == .supersededValue)
        #expect(grounder.ground("The team meeting is Saturday.").verdict != .unsupported)
    }

    @Test func independentSlotsThatShareAValueDoNotFormOneCorrectionChain() {
        let lines = ["the team meeting is Thursday", "move the team meeting to Friday",
                     "the dentist appointment is Friday", "move the dentist appointment to Saturday"]
        let corrections = resolver.corrections(in: lines)
        #expect(corrections.count == 2)
        if let first = corrections.first {
            #expect(resolver.finalValue(of: first, in: corrections).readings == [.weekday(5, nil)])
        }
        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.ground("The team meeting is Friday.").verdict != .unsupported)
        #expect(grounder.ground("The dentist appointment is Friday.").reason == .supersededValue)
    }

    @Test func anImplicitMoveWithMultipleAdjacentSlotsStaysUnresolved() {
        let lines = ["the meeting is Thursday and the rehearsal is Saturday", "actually move it to Friday for Dana"]
        #expect(resolver.corrections(in: lines).isEmpty)
    }

    @Test func anExplicitVenueChangeSupersedesTheOldCurrentLocation() {
        let lines = ["the recital is Saturday at three in the school auditorium", "move the recital from the auditorium to the cafeteria"]
        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.corrections.count == 1)
        #expect(grounder.ground("The recital is in the school auditorium.").reason == .supersededValue)
        #expect(grounder.ground("The recital moved from the auditorium to the cafeteria.").verdict != .unsupported)
        #expect(grounder.ground("The recital is in the cafeteria.").verdict != .unsupported)
        #expect(grounder.ground("The event location is the school auditorium.").reason == .supersededValue)
    }

    @Test func aTicketPriceExplicitlyChangedToFreeSupersedesItsOldPrice() {
        let grounder = ClaimGrounder(lines: ["recital tickets cost five dollars", "actually the recital tickets are now free"])
        #expect(grounder.corrections.count == 1)
        #expect(grounder.ground("Recital tickets cost $5.").reason == .supersededValue)
        #expect(grounder.ground("Recital tickets are free.").verdict != .unsupported)
        #expect(grounder.ground("Recital tickets are now $0.").verdict != .unsupported)
        let reply = ClaimGrounder(lines: ["the ticket costs five dollars", "no it's free"])
        #expect(reply.ground("The ticket costs $5.").reason == .supersededValue)
        #expect(reply.ground("The ticket is free.").verdict != .unsupported)
    }

    @Test func freeForAnUnrelatedItemDoesNotChangeAnotherPrice() {
        let grounder = ClaimGrounder(lines: ["recital tickets cost five dollars", "parking is now free"])
        #expect(grounder.corrections.isEmpty)
        #expect(grounder.ground("Recital tickets cost $5.").verdict != .unsupported)
        #expect(EnglishNormalizer().values(in: "feel free to call during your free time").isEmpty)
    }

    @Test func withdrawingACashInstructionDoesNotInventAZeroTicketPrice() {
        let grounder = ClaimGrounder(lines: ["tickets cost twenty dollars so bring twenty dollars for tickets",
                                             "no need to bring twenty dollars for tickets we can pay by card"])
        #expect(grounder.ground("Bring $20 for tickets.").reason == .supersededValue)
        #expect(grounder.ground("Tickets cost $20.").verdict != .unsupported)
        #expect(grounder.ground("No need to bring $20 for tickets.").verdict != .unsupported)
        #expect(grounder.ground("Tickets are free.").reason == .inventedValue)
        let brief = ClaimGrounder(lines: ["bring twenty dollars", "no need for twenty dollars"])
        #expect(brief.ground("Bring $20.").reason == .supersededValue)
        #expect(brief.ground("No need for $20.").verdict != .unsupported)
    }

    @Test func aVenueAndPriceCanChangeInTheSameUtteranceWithoutLosingOtherFacts() {
        let lines = ["the recital is Saturday at three in the auditorium and tickets cost five dollars",
                     "actually move the recital from the auditorium to the cafeteria and tickets are now free"]
        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.corrections.count == 2)
        #expect(grounder.ground("Tickets cost $5.").reason == .supersededValue)
        #expect(grounder.ground("The recital is in the auditorium.").reason == .supersededValue)
        #expect(grounder.ground("The recital is Saturday at three in the cafeteria and tickets are free.").verdict != .unsupported)
        #expect(grounder.ground("The auditorium is being painted.").reason != .supersededValue)
    }

    @Test func mentioningTheOldBuildingDoesNotMakeItTheCurrentEventVenueAgain() {
        let lines = ["the recital is in the auditorium", "actually move the recital to the cafeteria",
                     "the auditorium is being painted", "the workshop is at the auditorium"]
        let grounder = ClaimGrounder(lines: lines)
        #expect(grounder.ground("The recital is in the auditorium.").reason == .supersededValue)
        #expect(grounder.ground("The workshop is at the auditorium.").verdict != .unsupported)
        #expect(grounder.ground("The auditorium is being painted.").verdict != .unsupported)
    }

    @Test func independentVenueChangesDoNotChainThroughGenericLocationLabels() {
        let lines = ["the recital is in the auditorium", "move the recital to the cafeteria",
                     "the workshop is in the cafeteria", "move the workshop to the library"]
        let corrections = resolver.corrections(in: lines)
        #expect(corrections.count == 2)
        if let first = corrections.first {
            #expect(resolver.finalValue(of: first, in: corrections).readings == [.place("cafeteria")])
        }
        #expect(ClaimGrounder(lines: lines).ground("The recital is in the cafeteria.").verdict != .unsupported)
    }
}
