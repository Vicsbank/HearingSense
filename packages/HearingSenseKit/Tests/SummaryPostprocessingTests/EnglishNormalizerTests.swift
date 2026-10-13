import Testing
@testable import SummaryPostprocessing

/// Component A: spoken and written forms of the same value are equal; ambiguous ones keep every
/// reading; nothing is equated that is not the same value.
@Suite struct EnglishNormalizerTests {
    let normalizer = EnglishNormalizer()

    @Test func spokenAndWrittenClockTimesAreEqual() {
        #expect(normalizer.areEquivalent("seven forty-five", "7:45"))
        #expect(normalizer.areEquivalent("seven forty five", "7:45"))
        #expect(normalizer.areEquivalent("three thirty PM", "3:30 PM"))
        #expect(normalizer.areEquivalent("three thirty p.m.", "3:30 pm"))
        #expect(normalizer.areEquivalent("a quarter past nine", "9:15"))
        #expect(normalizer.areEquivalent("half past six", "6:30"))
        #expect(normalizer.areEquivalent("quarter to ten", "9:45"))
        #expect(normalizer.areEquivalent("noon", "12 PM"))
        #expect(normalizer.areEquivalent("noon", "12:00 p.m."))
        #expect(normalizer.areEquivalent("four o'clock", "4:00"))
        #expect(normalizer.areEquivalent("between ten and noon", "between 10 AM and noon"))
        #expect(!normalizer.areEquivalent("three thirty PM", "3:30 AM"))
        #expect(!normalizer.areEquivalent("seven forty five", "7:15"))
    }

    @Test func spokenAndWrittenMoneyPercentagesAndCountsAreEqual() {
        #expect(normalizer.areEquivalent("twenty dollars", "$20"))
        #expect(normalizer.areEquivalent("eighteen dollars", "$18"))
        #expect(normalizer.areEquivalent("an eighteen-dollar fee", "a fee of $18"))
        #expect(normalizer.areEquivalent("sixty percent", "60%"))
        #expect(normalizer.areEquivalent("sixty percent", "60 percent"))
        #expect(normalizer.areEquivalent("twenty eight", "28"))
        #expect(normalizer.areEquivalent("twenty-eight", "28"))
        #expect(normalizer.areEquivalent("one hundred and forty", "140"))
        #expect(normalizer.areEquivalent("twelve hundred", "1,200"))
        #expect(normalizer.areEquivalent("two thousand nineteen", "2019"))
        #expect(normalizer.areEquivalent("three point five", "3.5"))
        #expect(normalizer.areEquivalent("two extra days", "2 days"))
        #expect(normalizer.areEquivalent("twenty four hours", "24 hours"))
        #expect(!normalizer.areEquivalent("sixty percent", "60"))
        #expect(!normalizer.areEquivalent("eighteen dollars", "$80"))
        #expect(!normalizer.areEquivalent("two days", "two hours"))
    }

    @Test func datesInEitherOrderAreEqual() {
        #expect(normalizer.areEquivalent("the twelfth of October", "October 12"))
        #expect(normalizer.areEquivalent("October twenty eighth", "October 28th"))
        #expect(normalizer.areEquivalent("Thursday the sixteenth", "Thursday, the 16th"))
        #expect(normalizer.areEquivalent("28 October", "October 28"))
        #expect(!normalizer.areEquivalent("the twelfth of October", "October 13"))
        #expect(!normalizer.areEquivalent("the twelfth of October", "November 12"))
    }

    @Test func relativeDaysStayRelative() {
        let values = normalizer.values(in: "next Friday")
        #expect(values.count == 1)
        #expect(values.first?.readings == [.weekday(5, .next)])
        #expect(normalizer.areEquivalent("the following Tuesday", "next Tuesday"))
        // Saying less is compatible; saying something else is not.
        #expect(normalizer.areEquivalent("next Friday", "Friday"))
        #expect(!normalizer.areEquivalent("next Friday", "this Friday"))
        #expect(!normalizer.areEquivalent("tomorrow", "today"))
        #expect(normalizer.areEquivalent("tonight", "this evening"))
    }

    @Test func ambiguousValuesKeepEveryReadingAndNeedACompatibleOne() {
        let readings = normalizer.values(in: "room two twelve").first?.readings ?? []
        #expect(readings.contains(.number(21_200)))
        #expect(readings.contains(.time(2, 12, nil)))
        #expect(normalizer.areEquivalent("room two twelve", "room 212"))
        #expect(normalizer.areEquivalent("two twelve", "2:12"))
        #expect(!normalizer.areEquivalent("212", "2:12"))
        #expect(!normalizer.areEquivalent("two twelve", "12"))
        // A cardinal is never an ordinal.
        #expect(!normalizer.areEquivalent("ten", "tenth"))
        #expect(!normalizer.areEquivalent("the 10th", "10"))
        #expect(normalizer.areEquivalent("the tenth", "the 10th"))
    }

    @Test func digitsSaidOneByOneMatchAWrittenNumber() {
        #expect(normalizer.areEquivalent("five five five oh one four two", "555-0142"))
        #expect(normalizer.areEquivalent("four four seven one", "4471"))
        #expect(!normalizer.areEquivalent("five five five oh one four two", "555-0143"))
    }

    @Test func abbreviationsPunctuationAndCaseAreNormalized() {
        let tokens = normalizer.tokens(in: "Dr. Lee meets Ms. Wang at 4 p.m. on Elm St.")
        #expect(tokens.contains { $0.text == "dr" })
        // "Dr." and "Ms." do not end the sentence.
        #expect(tokens.filter(\.startsSentence).count == 1)
        #expect(normalizer.areEquivalent("4 p.m.", "4 PM"))
        #expect(normalizer.tokens(in: "Elm Street").map(\.text) == normalizer.tokens(in: "Elm St").map(\.text))
        #expect(normalizer.tokens(in: "can't").map(\.text) == ["can", "not"])
        #expect(normalizer.tokens(in: "Doesn't").map(\.text) == ["does", "not"])
    }

    @Test func wordsThatOnlyLookLikeNumbersGiveNoValue() {
        #expect(normalizer.values(in: "one of them said the first item was done").isEmpty)
        #expect(normalizer.values(in: "the two of them talked").isEmpty)
        let date = normalizer.values(in: "on the first of May")
        #expect(date.first?.readings == [.date(5, 1)])
    }

    @Test func hedgesAndCertaintyAreMarked() {
        let hedged = normalizer.values(in: "around three thirty maybe a little later")
        #expect(hedged.first?.isHedged == true)
        let exact = normalizer.values(in: "the bus leaves at seven forty five sharp")
        #expect(exact.first?.isCertain == true)
        #expect(exact.first?.isHedged == false)
    }

    @Test func textsWithoutValuesAreNotEquivalent() {
        #expect(!normalizer.areEquivalent("the meeting", "the meeting"))
        #expect(normalizer.values(in: "").isEmpty)
    }
}
