import Testing
@testable import SummaryPostprocessing

/// Fixed synthetic speech from Window9SelfTest; no ordinary phone conversation is a fixture.
@Suite struct PhoneFallbackRegressionTests {
    let processor = SummaryPostprocessor()
    let firstPart = [
        "The team meeting is Thursday at seven forty five.",
        "Actually, move it to Friday, the same time works better.",
        "Please bring twenty dollars for the tickets.",
        "The bus leaves at three thirty p m from the front entrance.",
        "Maria's flight was cancelled so she rebooks for Tuesday morning.",
        "The cupcake order for the party is twenty four, delivered by noon on Saturday.",
        "I'm not sure whether the blue sofa or the grey one arrives first.",
        "The north lot is closed tomorrow for repaving.",
        "The lot reopens on Friday.",
    ]
    let laterPart = [
        "Sorry, make that Saturday instead of Friday for the team meeting.",
        "Parking is behind the library and Dana will bring the programs.",
        "The tickets are free now, so no need for the twenty dollars.",
    ]
    let cupcake = "The cupcake order for the party is twenty four, delivered by noon on Saturday."
    let restatedCupcake = "The cupcake order for the party is 24, delivered by noon on Saturday."

    @Test func lowercaseStopsDoNotLetMeetingHistoryHideTheOldPayment() {
        let summary = "the team meeting is on Thursday at 7:45, but it was moved to Friday at the same time. please bring twenty dollars for the tickets. the bus leaves at 3:30 p.m. from the front entrance. maria rebooks for Tuesday morning because her flight was cancelled. the cupcake order for the party is twenty four, delivered by noon on Saturday. it is not sure whether the blue sofa or the grey one arrives first. the north lot is closed tomorrow for repaving. the lot reopens on Friday. the team meeting is now on Saturday at 7:45"
        let payment = "please bring twenty dollars for the tickets."
        #expect(SummaryText.sentences(in: summary).contains(payment))
        #expect(SummaryText.sentences(in: summary).contains("the bus leaves at 3:30 p.m. from the front entrance."))
        let grounding = ClaimGrounder(lines: firstPart + laterPart).ground(payment)
        #expect(grounding.verdict == .unsupported)
        #expect(grounding.reason == .supersededValue)
        let lowerCupcake = cupcake.prefix(1).lowercased() + cupcake.dropFirst()
        let output = processor.process(
            DraftText(title: "", summary: summary,
                      keyPoints: ["Someone said that the tickets are free now, so no need for the twenty dollars.",
                                  "Someone said that the cupcake order for the party is twenty four, delivered by noon on Saturday.",
                                  "Parking is behind the library and Dana will bring the programs"]),
            transcriptLines: firstPart + laterPart,
            restatements: [String(lowerCupcake): restatedCupcake, cupcake: restatedCupcake,
                           "The lot reopens on Friday.": "The lot will reopen on Friday.",
                           "the lot reopens on Friday.": "The lot will reopen on Friday."])
        #expect(!output.summaryStatements.contains(payment))
        #expect(output.reports.contains { $0.text == payment && $0.reason == ReasonCode.supersededValue.rawValue })
        let text = (output.summaryStatements + output.keyPoints).joined(separator: "\n").lowercased()
        #expect(text.contains("free"))
        #expect(text.contains("maria") && text.contains("tuesday"))
        #expect(text.contains("3:30"))
        #expect(text.contains("24") && text.contains("noon") && text.contains("saturday"))
        #expect(text.contains("not sure") && text.contains("blue") && text.contains("grey"))
        #expect(text.contains("north lot") && text.contains("repaving"))
        #expect(!output.hasOverlongSourceRun)
    }

    @Test func aNarrationWrapperCannotHideFourteenCopiedCupcakeWords() {
        let wrapped = "It was announced that " + cupcake.prefix(1).lowercased() + cupcake.dropFirst()
        let filter = PrivacyCopyFilter()
        #expect(!filter.isCopy(wrapped, spoken: PrivacyCopyFilter.spokenSentences(lines: firstPart)))
        #expect(filter.hasOverlongSourceRun(in: wrapped, transcriptLines: firstPart))
        let formatted = processor.process(DraftText(title: "", summary: wrapped), transcriptLines: firstPart)
        let safe = "It was announced that " + restatedCupcake.prefix(1).lowercased() + restatedCupcake.dropFirst()
        #expect(formatted.summary == safe)
        #expect(formatted.copiedNeedingRestatement.isEmpty)
        #expect(formatted.corrections.contains(ReasonCode.formattedCardinal.rawValue))
        #expect(!formatted.hasOverlongSourceRun)
        let output = processor.process(DraftText(title: "", summary: wrapped), transcriptLines: firstPart,
                                       restatements: [wrapped: safe])
        #expect(output.summary == safe)
        #expect(output.restatedCount == 1)
        #expect(!output.hasOverlongSourceRun)
        #expect(EnglishNormalizer().areEquivalent(output.summary, cupcake))
    }

    @Test func aRestatementThatStillEmbedsTheLongCopyIsNotAccepted() {
        let unsafe = "It was announced that " + cupcake.prefix(1).lowercased() + cupcake.dropFirst()
        let output = processor.process(DraftText(title: "", summary: cupcake), transcriptLines: firstPart,
                                       restatements: [cupcake: unsafe])
        #expect(output.summary == restatedCupcake)
        #expect(output.summary != unsafe)
        #expect(output.copiedNeedingRestatement.isEmpty)
        #expect(output.corrections == [ReasonCode.formattedCardinal.rawValue])
        #expect(!output.hasOverlongSourceRun)
    }

    @Test func anInheritedCardinalCopyIsFormattedWithoutModelRetryOrFactLoss() {
        let earlier = DraftText(title: "Party", summary: cupcake, keyPoints: [cupcake])
        let added = DraftText(title: "", summary: "Parking is behind the library and Dana brings the programs.")
        let pending = processor.merge(earlier: earlier, addition: added, newLines: laterPart, earlierLines: firstPart)
        #expect(pending.summaryStatements.contains(restatedCupcake))
        #expect(pending.keyPoints.contains(restatedCupcake))
        #expect(pending.copiedNeedingRestatement.isEmpty)
        #expect(!pending.hasOverlongSourceRun)
        let output = processor.merge(earlier: earlier, addition: added, newLines: laterPart, earlierLines: firstPart,
                                     restatements: [cupcake: restatedCupcake])
        #expect(output.summaryStatements.contains(restatedCupcake))
        #expect(output.keyPoints.contains(restatedCupcake))
        #expect(!output.hasOverlongSourceRun)
        #expect(EnglishNormalizer().areEquivalent(restatedCupcake, cupcake))
        #expect(output.summary.contains("Dana"))
    }

    @Test func aTicketUpdatePreservesTheBusAndCupcakesButNotTheOldInstruction() {
        let payment = firstPart[2]
        let ticketCorrection = laterPart[2]
        let restatedTicket = "Tickets are now free, so the twenty dollars are not needed."
        let earlier = DraftText(title: "Plans", summary: payment + " The bus leaves at 3:30 PM. " + cupcake,
                               keyPoints: ["Bring $20 for tickets.", cupcake])
        let output = processor.merge(
            earlier: earlier,
            addition: DraftText(title: "", summary: "The team meeting is Saturday at 7:45. Parking is behind the library and Dana brings the programs.",
                                keyPoints: [ticketCorrection]),
            newLines: laterPart, earlierLines: firstPart,
            restatements: [cupcake: restatedCupcake, ticketCorrection: restatedTicket])
        #expect(!output.summaryStatements.contains(payment))
        #expect(!output.keyPoints.contains("Bring $20 for tickets."))
        #expect(output.summary.contains("3:30 PM"))
        #expect((output.summaryStatements + output.keyPoints).contains(restatedCupcake))
        #expect((output.summary + output.keyPoints.joined()).contains("free"))
        #expect(output.reports.contains { $0.text == restatedTicket && $0.verdict == .restated })
        #expect(!output.hasOverlongSourceRun)
    }

    @Test func sentenceBoundariesCannotEvadeTheConsecutiveWordLimit() {
        let split = "The cupcake order for the party is twenty four. Delivered by noon on Saturday."
        let output = processor.process(DraftText(title: "", summary: split), transcriptLines: [cupcake])
        #expect(output.summaryStatements.count == 2)
        #expect(!output.exceedsVerbatimShare)
        #expect(output.hasOverlongSourceRun && output.exceedsPrivacyLimits)
        let separated = "The cupcake order for the party is twenty four. The party has an undecided theme. Delivered by noon on Saturday."
        let pending = processor.process(DraftText(title: "", summary: separated), transcriptLines: [cupcake])
        #expect(!pending.hasOverlongSourceRun)
        let verified = pending.applying(verifierVerdicts: ["The party has an undecided theme.": false])
        #expect(verified.hasOverlongSourceRun && verified.exceedsPrivacyLimits)
    }
}
