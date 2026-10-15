import Testing
@testable import SummaryPostprocessing

@Suite struct CardinalFormatRestatementTests {
    let normalizer = EnglishNormalizer()
    let processor = SummaryPostprocessor()

    @Test func aKnownCardinalChangesOnlyItsSpellingAndNeedsNoModelRestatement() {
        for (words, digits) in [("twenty four", "24"), ("thirty-seven", "37")] {
            let original = "The cupcake order for the party is \(words), delivered by noon on Saturday."
            let expected = "The cupcake order for the party is \(digits), delivered by noon on Saturday."
            #expect(CardinalFormatRestatement.candidates(for: original, normalizer: normalizer) == [expected])
            #expect(PrivacyCopyFilter().restatementProblem(expected, of: original) == nil)
            let output = processor.process(DraftText(title: "", summary: original), transcriptLines: [original])
            #expect(output.summary == expected)
            #expect(output.copiedNeedingRestatement.isEmpty)
            #expect(output.corrections == [ReasonCode.formattedCardinal.rawValue])
            #expect(!output.hasOverlongSourceRun)
            #expect(normalizer.areEquivalent(original, expected))
        }
    }

    @Test func ambiguousOrTypedValuesAndLiteralIdentifiersAreNotReformatted() {
        let cases = ["The pickup time is three thirty in the afternoon.",
                     "The price is twenty four dollars.", "The date is October twenty four.",
                     "The race ended in twenty fourth place.", "The trip lasts twenty four hours.",
                     "The code is twenty four.", "The passcodes are twenty four.",
                     "The instruction literally says 'twenty four'.", "The label reads “twenty four”.",
                     "At twenty four the meeting begins.", "Twenty Four is the name of the shop.",
                     "The order is twenty four and the reserve is twenty four.",
                     "The code is two four seven nine."]
        for text in cases {
            #expect(CardinalFormatRestatement.candidates(for: text, normalizer: normalizer).isEmpty, "\(text)")
        }
    }

    @Test func aNegatedFactStaysNegatedAndFormattingCannotLaunderItsOpposite() {
        let original = "Do not change the cupcake order for the party from twenty four before delivery by noon on Saturday."
        // The temporal preposition deliberately makes this span ineligible for formatting.
        #expect(CardinalFormatRestatement.candidates(for: original, normalizer: normalizer).isEmpty)
        let supported = "Do not deliver the cupcake order for the party with twenty four items by noon on Saturday."
        let expected = "Do not deliver the cupcake order for the party with 24 items by noon on Saturday."
        let kept = processor.process(DraftText(title: "", summary: supported), transcriptLines: [supported])
        #expect(kept.summary == expected)
        #expect(kept.summary.contains("not deliver") && kept.summary.contains("24 items"))
        #expect(!kept.hasOverlongSourceRun)
        let opposite = supported.replacingOccurrences(of: "not ", with: "")
        let rejected = processor.process(DraftText(title: "", summary: opposite), transcriptLines: [supported])
        #expect(rejected.summary.isEmpty)
        #expect(!rejected.corrections.contains(ReasonCode.formattedCardinal.rawValue))
    }

    @Test func formattingDoesNotAuthorizeANewWholeCopyOrAnUnbrokenLongRun() {
        let original = "The cupcake order for the party is twenty four, delivered by noon on Saturday."
        let digits = "The cupcake order for the party is 24, delivered by noon on Saturday."
        let output = processor.process(DraftText(title: "", summary: original), transcriptLines: [original, digits])
        #expect(output.summary.isEmpty)
        #expect(output.copiedNeedingRestatement == [original])
        #expect(!output.corrections.contains(ReasonCode.formattedCardinal.rawValue))
        let long = original + " The bus leaves at three thirty p m from the front entrance."
        let valueCandidate = CardinalFormatRestatement.candidates(for: long, normalizer: normalizer).first
        #expect(valueCandidate != nil)
        // A longer independent source run still invalidates a numeric candidate.
        let longerSource = "The bus leaves from the front entrance behind the library where Dana will bring the programs."
        let combined = original + " " + longerSource
        let candidate = CardinalFormatRestatement.candidates(for: combined, normalizer: normalizer).first
        #expect(candidate != nil)
        if let candidate {
            #expect(PrivacyCopyFilter().hasOverlongSourceRun(in: candidate, transcriptLines: [original, longerSource]))
        }
    }

    @Test func anActualAppleEchoCannotDeleteTheKnownCupcakeFact() {
        let original = "the cupcake order for the party is twenty four, delivered by noon on Saturday."
        let echoed = "The cupcake order for the party is twenty four, delivered by noon on Saturday."
        let output = processor.process(DraftText(title: "", summary: original), transcriptLines: [original],
                                       restatements: [original: echoed])
        #expect(output.summary == "the cupcake order for the party is 24, delivered by noon on Saturday.")
        #expect(output.copiedNeedingRestatement.isEmpty)
        #expect(output.reports.first?.reason == ReasonCode.formattedCardinal.rawValue)
        #expect(!output.hasOverlongSourceRun)
    }

    @Test func shortNumericCopiesStillObeyBothAdjacencyAndCountCaps() {
        let first = "Deliver fresh chocolate cupcakes for twenty four guests before Saturday noon."
        let second = "Deliver fresh vanilla cupcakes for thirty seven guests before Friday noon."
        let middle = "The orders are pending."
        let lines = [first, second, middle]
        // A spelling variant would otherwise pass equivalence, so these checks exercise
        // the short-copy policy rather than accidental failure of the restatement validator.
        let variant = CardinalFormatRestatement.candidates(for: second, normalizer: normalizer).first
        #expect(variant != nil)
        if let variant { #expect(PrivacyCopyFilter().restatementProblem(variant, of: second) == nil) }
        let adjacent = processor.process(DraftText(title: "", summary: first + " " + second), transcriptLines: lines)
        let limited = SummaryPostprocessor(configuration: PostprocessingConfiguration(maximumKeptCopies: 1)).process(
            DraftText(title: "", summary: first + " " + middle + " " + second), transcriptLines: lines)
        for output in [adjacent, limited] {
            #expect(output.summaryStatements.contains(first))
            #expect(!output.summaryStatements.contains(second))
            #expect(!output.summary.contains("37"))
            #expect(output.copiedNeedingRestatement == [second])
            #expect(!output.corrections.contains(ReasonCode.formattedCardinal.rawValue))
        }
    }
}
