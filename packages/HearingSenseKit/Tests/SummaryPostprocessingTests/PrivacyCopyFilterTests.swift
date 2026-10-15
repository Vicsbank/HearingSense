import Testing
@testable import SummaryPostprocessing

/// A synthetic parking announcement (the scene in which Window 7 first lost a copied fact).
let parkingAnnouncement = [
    "Attention please, the north parking lot will be closed tomorrow from six a.m. for repaving.",
    "Please park in the south lot or on Elm Street.",
    "Cars left in the north lot after six will be towed at the owner's expense.",
    "The lot reopens on Friday.",
]

/// Component D: the approved copy rule, independent of grounding.
@Suite struct PrivacyCopyFilterTests {
    let postprocessor = SummaryPostprocessor()

    @Test func aShortExactSentenceWithAnImportantFactStaysAsItWasSaid() {
        let lines = ["The lot reopens on Friday.", "Please park in the south lot or on Elm Street."]
        let output = postprocessor.process(DraftText(title: "Parking", summary: "The lot reopens on Friday. Parking is possible in the south lot."),
                                           transcriptLines: lines)
        #expect(output.summary.hasPrefix("The lot reopens on Friday."))
        #expect(output.removedCount == 0)
        #expect(output.reports.first?.verdict == .keptShortCopy)
        #expect(output.corrections.contains(ReasonCode.keptShortCopy.rawValue))
        #expect(output.copiedNeedingRestatement.isEmpty)
    }

    @Test func aLongCopyIsRestatedOrLeftOut() {
        let long = parkingAnnouncement[0]
        let left = postprocessor.process(DraftText(title: "", summary: long), transcriptLines: [long])
        #expect(left.summary.isEmpty)
        #expect(left.copiedNeedingRestatement == [long])
        #expect(left.corrections == [ReasonCode.copiedFromTranscript.rawValue])
        #expect(left.reports.first?.verdict == .copied)

        let restatement = "Someone announced that the north parking lot closes tomorrow from six a.m. for repaving."
        let restated = postprocessor.process(DraftText(title: "", summary: long), transcriptLines: [long], restatements: [long: restatement])
        #expect(restated.summary == restatement)
        #expect(restated.restatedCount == 1)
        #expect(restated.corrections.contains(ReasonCode.restatedCopy.rawValue))
    }

    @Test func withTheShortCopyRuleOffEveryCopyIsRestatedOrLeftOut() {
        let strict = SummaryPostprocessor(configuration: PostprocessingConfiguration(keptCopyMaximumWords: 0))
        let output = strict.process(DraftText(title: "", summary: "The lot reopens on Friday."), transcriptLines: parkingAnnouncement)
        #expect(output.summary.isEmpty)
        #expect(output.copiedNeedingRestatement == ["The lot reopens on Friday."])
    }

    @Test func twoCopiesNextToEachOtherAreNotBothKept() {
        let lines = ["The lot reopens on Friday.", "The gate opens at six.", "The fee is five dollars."]
        let output = postprocessor.process(DraftText(title: "", summary: lines.joined(separator: " ")), transcriptLines: lines)
        #expect(output.summaryStatements.contains("The lot reopens on Friday."))
        #expect(!output.summaryStatements.contains("The gate opens at six."))
        #expect(!output.summaryStatements.contains("The fee is five dollars."))
        #expect(output.copiedNeedingRestatement == ["The gate opens at six.", "The fee is five dollars."])
    }

    @Test func atMostThreeCopiesAreKeptInOneRecap() {
        let lines = ["The lot reopens on Friday.", "The gate opens at six.", "The fee is five dollars.", "Dogs are not allowed here.", "Bring your own folding chair."]
        let fillers = ["The notice has five parts.", "Entry is regulated.", "Costs are listed.", "Pets are covered.", "Seating is covered."]
        let transcript = lines + ["The notice has five parts and entry is regulated and costs are listed and pets are covered and seating is covered."]
        let summary = zip(lines, fillers).map { "\($0) \($1)" }.joined(separator: " ")
        let output = postprocessor.process(DraftText(title: "", summary: summary), transcriptLines: transcript)
        #expect(lines.filter { output.summaryStatements.contains($0) }.count == 3)
        #expect(fillers.allSatisfy { output.summaryStatements.contains($0) })
    }

    @Test func theVerbatimShareIsTheWindow7Measure() {
        let filter = PrivacyCopyFilter()
        #expect(filter.verbatimShare(of: "An announcement about parking: one lot closes for a day and cars may be towed.",
                                     transcriptLines: parkingAnnouncement) == 0)
        #expect(filter.verbatimShare(of: parkingAnnouncement.prefix(3).joined(separator: " "), transcriptLines: parkingAnnouncement) == 1)
        #expect(filter.verbatimShare(of: parkingAnnouncement.joined(separator: " "), transcriptLines: parkingAnnouncement) == 41.0 / 46.0)
        #expect(filter.verbatimShare(of: "On Elm Street cars left in the lot.", transcriptLines: parkingAnnouncement) == 0)
        // The postprocessor reports it for what it keeps, and says when it is too much.
        let glued = "Someone said attention please, the north parking lot will be closed tomorrow from six a.m. for repaving, "
            + "and please park in the south lot or on Elm Street."
        let output = SummaryPostprocessor().process(DraftText(title: "", summary: glued), transcriptLines: parkingAnnouncement)
        #expect(filter.verbatimShare(of: glued, transcriptLines: parkingAnnouncement) > 0.65)
        // The aggregate measure is unchanged, but an embedded overlong run can no longer
        // remain in the saved output while waiting for that aggregate rejection.
        #expect(output.summary.isEmpty)
        #expect(output.copiedNeedingRestatement == [SummaryQualityEditor.tidied(glued)])
        #expect(output.reports.first?.verdict == .copied)
    }

    @Test func aRestatementMustCarryTheSameFactsAndNothingElse() {
        let filter = PrivacyCopyFilter()
        let original = "The lot reopens on Friday."
        #expect(filter.restatementProblem("Someone said that the lot reopens on Friday.", of: original) == nil)
        #expect(filter.restatementProblem("It was announced that the lot will reopen on Friday.", of: original) == nil)
        #expect(filter.restatementProblem("Someone said that the lot reopens on Monday.", of: original) == .restatementChangedNumberOrTime)
        #expect(filter.restatementProblem("Someone said that the lot reopens.", of: original) == .restatementChangedNumberOrTime)
        #expect(filter.restatementProblem("Someone said that the lot does not reopen on Friday.", of: original) == .restatementChangedNegation)
        #expect(filter.restatementProblem("Someone told Maria that the lot reopens on Friday.", of: original) == .restatementAddedName)
        #expect(filter.restatementProblem("Someone said something about Friday.", of: original) == .restatementLostContent)
        #expect(filter.restatementProblem("Someone said that the lot reopens on Friday. Everyone was relieved.", of: original) == .restatementNotOneSentence)
        #expect(filter.restatementProblem(
            "Someone said that the lot reopens on Friday and that everybody should be careful when they drive in again that morning.",
            of: original) == .restatementTooLong)
        #expect(filter.restatementProblem("The lot reopens on Friday.", of: original) == .restatementUnchanged)
        // Values are compared as values: "6 a.m." restates "six a.m.".
        #expect(filter.restatementProblem("Someone said the gate opens at 6 a.m. tomorrow.", of: "The gate opens tomorrow at six a.m.") == nil)
    }

    @Test func aLegitimateShortSentenceIsNeverRemovedForMatchingTheSource() {
        // Four words: below the copy length; it is a fact, and it stays.
        let output = postprocessor.process(DraftText(title: "", summary: "The fee is $5."), transcriptLines: ["The fee is five dollars."])
        #expect(output.summary == "The fee is $5.")
        #expect(output.removedCount == 0)
    }
}
