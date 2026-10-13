import Testing
@testable import SummaryPostprocessing

/// Synthetic school announcement, spoken numbers as a recognizer writes them, no punctuation.
let schoolLines = [
    "okay a few announcements before we start",
    "the science quiz is now on Thursday the sixteenth in room two twelve",
    "it starts at nine fifteen so please be on time",
    "lab reports are due Monday by four p.m.",
    "can we email the lab report",
    "no paper copies only and please staple them",
    "the museum trip costs eighteen dollars and the bus leaves at seven forty five sharp",
    "what time do we get back",
    "around three thirty maybe a little later",
    "there is no cafeteria at the museum so bring a packed lunch",
    "Priya is leading the study group on Wednesday in the library",
]

/// Component B: claim-level grounding with local evidence.
@Suite struct ClaimGrounderTests {
    let grounder = ClaimGrounder(lines: schoolLines)

    @Test func aParaphraseWithWrittenNumbersIsSupportedWithItsLines() {
        let result = grounder.ground("The science quiz is on Thursday the 16th in Room 212 at 9:15.")
        #expect(result.verdict == .supported)
        #expect(result.evidenceLines.contains(1))
        #expect(grounder.ground("The museum trip costs $18 and the bus leaves at 7:45.").verdict == .supported)
        #expect(grounder.ground("Lab reports are due Monday by 4 PM.").verdict == .supported)
    }

    @Test func anInventedValueOrNameIsUnsupported() {
        #expect(grounder.ground("The science quiz starts at 10:15.").reason == .inventedValue)
        #expect(grounder.ground("The museum trip costs $20.").reason == .inventedValue)
        #expect(grounder.ground("The study group is led by Marcus on Wednesday.").reason == .inventedName)
        #expect(grounder.ground("The science quiz is on Friday.").verdict == .unsupported)
    }

    @Test func aFlippedNegationIsUnsupported() {
        // "Can we email it?" — "No, paper copies only."
        let emailed = grounder.ground("Lab reports can be emailed.")
        #expect(emailed.verdict == .unsupported)
        #expect(emailed.reason == .deniedQuestion)
        let noPaper = grounder.ground("No paper copies are accepted.")
        #expect(noPaper.verdict == .unsupported)
        #expect(noPaper.reason == .negationFlip)
        // A dropped "no": the museum has no cafeteria.
        #expect(grounder.ground("Lunch is available at the museum cafeteria.").reason == .negationFlip)
        // The faithful versions stay.
        #expect(grounder.ground("Only stapled paper copies are accepted, not email.").verdict != .unsupported)
        #expect(grounder.ground("There is no cafeteria at the museum, so a packed lunch is needed.").verdict == .supported)
    }

    @Test func aHedgedValueMayNotBecomeExact() {
        #expect(grounder.ground("The bus should be back around 3:30.").verdict == .supported)
        let exact = grounder.ground("The bus is back at 3:30 exactly.")
        #expect(exact.verdict == .unsupported)
        #expect(exact.reason == .certaintyAdded)
        let dropped = grounder.ground("The bus is back at 3:30.")
        #expect(dropped.verdict == .uncertain)
        #expect(dropped.reason == .hedgeDropped)
    }

    @Test func aSentenceJoiningTwoMattersIsNotSupported() {
        let errands = ClaimGrounder(lines: [
            "Maya has a dentist appointment on Tuesday at nine",
            "the soccer game is on Saturday at ten at Riverside field",
            "Leo needs new cleats before the game",
        ])
        let mixed = errands.ground("The soccer game is on Tuesday.")
        #expect(mixed.verdict == .unsupported)
        #expect(mixed.reason == .valueMismatch)
        #expect(errands.ground("The dentist appointment for Maya is on Saturday.").reason == .valueMismatch)
        // Each matter on its own is fine, and so is a true link between two lines.
        #expect(errands.ground("Maya's dentist appointment is on Tuesday at nine.").verdict == .supported)
        #expect(errands.ground("The soccer game is on Saturday at ten at Riverside field.").verdict == .supported)
        #expect(errands.ground("Leo needs new cleats before the Saturday game.").verdict != .unsupported)
    }

    @Test func aPronounInTheTranscriptDoesNotRejectAName() {
        let draft = ClaimGrounder(lines: ["Priya said she would send the final draft", "she will send it by Friday"])
        #expect(draft.ground("The final draft will come from Priya by Friday.").verdict == .supported)
    }

    /// Round 2: the app has no speaker labels and people are often named away from their words,
    /// so an attribution to a name that was said, but not near the words, is uncertain (kept,
    /// listed for a verifier), not removed. A name never said is still removed.
    @Test func wordsAttributedToSomeoneNamedFarAwayAreUncertain() {
        let call = ClaimGrounder(lines: [
            "Maya called this morning about the car",
            "we talked about the weather for a bit",
            "the rain should stop tomorrow",
            "my brother is visiting next month",
            "he wants to see the old harbor",
            "anyway the mechanic looked at it",
            "the repair will cost three hundred dollars",
        ])
        let attributed = call.ground("Later Maya said the repair will cost $300.")
        #expect(attributed.verdict == .uncertain)
        #expect(attributed.reason == .attributionUnclear)
        #expect(call.ground("The repair will cost $300.").verdict == .supported)
        #expect(call.ground("Later Priya said the repair will cost $300.").reason == .inventedName)
    }

    @Test func aParaphraseWithoutSharedWordsIsUncertainNotRemoved() {
        let result = grounder.ground("Pupils were reminded about punctuality.")
        #expect(result.verdict == .uncertain)
    }

    @Test func aClaimOfAbsenceIsUncertain() {
        #expect(grounder.ground("No return time was given.").verdict == .uncertain)
        #expect(grounder.ground("The location of the study group is unclear.").reason == .absenceClaim)
    }

    @Test func missingSpeechIsSupportedByTheMarker() {
        let gap = ClaimGrounder(lines: ["the bus leaves at nine", "[some speech here could not be transcribed]", "bring a coat"])
        #expect(gap.ground("Part of the speech could not be transcribed.").reason == .missingSpeechMarker)
        #expect(ClaimGrounder(lines: ["the bus leaves at nine"]).ground("Part of the speech could not be transcribed.").verdict == .uncertain)
    }
}
