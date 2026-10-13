import Testing
@testable import SummaryPostprocessing

/// Round 2: the root causes of the false deletions found on the regression corpus, each with
/// synthetic sentences (no corpus text).
@Suite struct ValueReadingGapTests {
    let normalizer = EnglishNormalizer()

    @Test func digitByDigitTimesRoomsAndCodesMatchTheirWrittenForms() {
        #expect(normalizer.areEquivalent("departure moved to seven oh five", "departure moved to 7:05"))
        #expect(normalizer.areEquivalent("seven oh five a.m.", "7:05 AM"))
        #expect(normalizer.areEquivalent("room one fourteen", "room 1-14"))
        #expect(normalizer.areEquivalent("the code is four seven one nine", "the code is 4-7-1-9"))
    }

    @Test func aLoneOneIsAnHourInATimeRange() {
        #expect(normalizer.areEquivalent("the lab runs from one to four", "the lab runs from 1 to 4 p.m."))
        #expect(normalizer.areEquivalent("between one and five", "between 1:00 and 5:00 PM"))
        #expect(normalizer.values(in: "one of them left early").isEmpty)
    }

    @Test func dateRangesKeepTheirMonth() {
        #expect(normalizer.areEquivalent("October twenty first to the twenty fifth", "October 21 to 25"))
        #expect(normalizer.areEquivalent("October twenty first to the twenty fifth", "October 21-25"))
        #expect(normalizer.areEquivalent("the fourth through the sixth of December", "December 4 to 6"))
    }

    @Test func aPercentSaidOnceCoversTheNumbersSaidWithIt() {
        #expect(normalizer.areEquivalent("coverage is seventy one percent and we want eighty", "coverage is 71% and we want 80%"))
        #expect(!normalizer.areEquivalent("we have eighty people", "we have 80%"))
    }

    @Test func wordsThatAreNoValuesStayOut() {
        #expect(normalizer.values(in: "this may be later if traffic is bad").isEmpty)
        #expect(normalizer.values(in: "it is on the third floor").isEmpty)
        #expect(normalizer.values(in: "the two considered the plan").isEmpty)
        #expect(normalizer.values(in: "we meet in May").first?.readings == [.month(5)])
        #expect(normalizer.values(in: "on the third at noon").first?.readings == [.ordinal(3)])
        #expect(normalizer.areEquivalent("we are eighty sixed on the soup", "86"))
    }
}

@Suite struct GroundingRootCauseTests {
    @Test func aNumberWorkedOutFromSaidNumbersIsUncertainNotRemoved() {
        let grounder = ClaimGrounder(lines: ["the block weighs forty eight point five grams", "and the volume is twelve cubic centimeters"])
        let derived = grounder.ground("The calculated density is 4.04 grams per cubic centimeter.")
        #expect(derived.verdict == .uncertain)
        #expect(derived.reason == .derivedValue)
        #expect(grounder.ground("The block weighs 48.5 grams.").verdict == .supported)
        // Nothing says it was worked out: an unsaid number is still removed.
        #expect(grounder.ground("The block weighs 50 grams.").reason == .inventedValue)
        let room = ClaimGrounder(lines: ["the room is twelve by fourteen"])
        #expect(room.ground("The room is 12 by 14, about 168 square feet.").verdict == .uncertain)
    }

    @Test func lettersSaidOneByOneAndSplitWordsAreKnownNames() {
        let grounder = ClaimGrounder(lines: ["the confirmation number is K R seven nine two", "we moved to red wood street number twelve forty"])
        #expect(grounder.ground("The confirmation number is KR792.").verdict == .supported)
        #expect(grounder.ground("They moved to Redwood Street, number 1240.").verdict != .unsupported)
        let team = ClaimGrounder(lines: ["our team code is t eye ex"])
        #expect(team.ground("The team code is TIX.").verdict != .unsupported)
    }

    @Test func aMisspeltNameWithTheSameSoundIsUncertainNotRemoved() {
        let grounder = ClaimGrounder(lines: ["the crabs cycle happens in the mitochondria"])
        let result = grounder.ground("The Krebs cycle happens in the mitochondria.")
        #expect(result.verdict == .uncertain)
        #expect(result.reason == .nameSpellingDiffers)
        #expect(grounder.ground("The Calvin cycle happens in the mitochondria.").reason == .inventedName)
        #expect(ClaimGrounder(lines: ["we don't know the date yet"]).ground("The date is TBD.").verdict != .unsupported)
    }

    @Test func aSharedNumberAloneDoesNotMakeACorrection() {
        let grounder = ClaimGrounder(lines: ["we close at five today", "and now in sports the home team won by six"])
        #expect(grounder.corrections.isEmpty)
        #expect(grounder.ground("The shop closes at five.").verdict == .supported)
        let rooms = ClaimGrounder(lines: ["advisors will email codes by Friday November first", "the class is in room thirty one",
                                          "wait is it room thirty one or thirteen", "thirty one sorry it's on the third floor"])
        #expect(rooms.corrections.isEmpty)
        #expect(rooms.ground("Advisors will email the codes by Friday, November 1st.").verdict == .supported)
    }

    @Test func aRejectionAnsweringAnotherMatterLeavesOtherStatementsAlone() {
        let grounder = ClaimGrounder(lines: ["Ravi is out till Wednesday", "so we freeze the code on Thursday at noon", "Thursday noon not Wednesday"])
        #expect(grounder.ground("Ravi is out until Wednesday.").verdict == .supported)
        #expect(grounder.ground("The code freeze is on Wednesday.").reason == .supersededValue)
    }

    @Test func aReplyNoThatStartsAPhraseOrAnswersAnotherMatterIsNoCorrection() {
        let resolver = CorrectionResolver()
        #expect(resolver.corrections(in: ["the essay should be two pages", "no more than two pages please last year I got eight"]).isEmpty)
        #expect(resolver.corrections(in: ["the recital is Saturday", "isn't the recital on Sunday", "no Sunday is the rehearsal I'm pretty sure"]).isEmpty)
        let grounder = ClaimGrounder(lines: ["the recital is Saturday", "isn't the recital on Sunday", "no Sunday is the rehearsal I'm pretty sure"])
        #expect(grounder.ground("The recital is on Saturday.").verdict != .unsupported)
        #expect(grounder.ground("The rehearsal is on Sunday.").verdict != .unsupported)
    }

    @Test func aHedgeIsNotADenial() {
        let rumor = ClaimGrounder(lines: ["did you hear about the third floor", "no what happened", "I'm not sure someone said something about the elevator"])
        #expect(rumor.ground("There was a rumor about the elevator on the third floor.").verdict != .unsupported)
        let bus = ClaimGrounder(lines: ["is the bus always late", "I don't know traffic maybe"])
        #expect(bus.ground("The bus may be late because of traffic.").verdict != .unsupported)
    }

    @Test func aNegativeWordInTheSummaryMatchesANotInSpeech() {
        let pool = ClaimGrounder(lines: ["Nina's house has the pool", "she can't have kids near it"])
        #expect(pool.ground("Nina's pool is unsuitable for kids.").verdict != .unsupported)
        #expect(pool.ground("Kids can play near the pool at Nina's house.").reason == .negationFlip)
        let show = ClaimGrounder(lines: ["the new show is slow", "like nothing happens for a few episodes"])
        #expect(show.ground("Little happens for a few episodes.").verdict != .unsupported)
    }

    @Test func aNotDeniesOneThingNotEverythingAfterIt() {
        let invoices = ClaimGrounder(lines: ["open invoices went from nine hundred to three hundred and fifty",
                                             "vendors haven't sent purchase order numbers yet"])
        #expect(invoices.ground("The number of open invoices fell from 900 to 350.").verdict != .unsupported)
        #expect(invoices.ground("Vendors have sent their purchase order numbers.").reason == .negationFlip)
    }

    @Test func aNoToAQuestionAboutHearingOrWatchingDeniesNothing() {
        let game = ClaimGrounder(lines: ["did you watch the game last night", "no I fell asleep", "I think it went to overtime"])
        #expect(game.ground("Someone did not watch the game last night.").verdict != .unsupported)
        #expect(game.ground("The game went to overtime.").verdict != .unsupported)
        let laptop = ClaimGrounder(lines: ["do we need to bring a laptop", "no your phone is enough"])
        #expect(laptop.ground("Laptops are not needed; a phone is enough.").verdict != .unsupported)
        #expect(laptop.ground("A laptop is required.").reason == .deniedQuestion)
    }

    @Test func valuesInAListOrCommentedOnInTheNextUtteranceAreNotMismatched() {
        let dates = ClaimGrounder(lines: ["juniors on Tuesday the fifth and sophomores on Wednesday the sixth",
                                          "freshmen register on Thursday the seventh at noon"])
        #expect(dates.ground("Juniors, sophomores and freshmen register on the 5th, 6th and 7th respectively.").verdict != .unsupported)
        let release = ClaimGrounder(lines: ["so the launch is the twentieth", "that's the beta the full release is the twenty seventh"])
        #expect(release.ground("The beta release is on the twentieth.").verdict != .unsupported)
    }

    @Test func aStatementAboutMissingSpeechIsNeverRemovedForItsLength() {
        let grounder = ClaimGrounder(lines: ["the bus leaves at nine", "[some speech here could not be transcribed]", "bring a coat"])
        #expect(grounder.ground("About twelve seconds of speech could not be transcribed.").verdict == .uncertain)
        #expect(grounder.ground("Some speech could not be transcribed.").reason == .missingSpeechMarker)
    }
}
