import Foundation
import IslandPresentation
import Testing

/// The Dynamic Island preview of a summary: whole sentences from the summary, never a fragment,
/// and the full summary untouched.
@Suite struct IslandSummaryPreviewTests {
    @Test func lowercaseSentenceStopsKeepAbbreviationsDecimalsAndSupersededFraming() {
        let text = "Ms. Wang arrives at 3 p.m. on Friday. tickets cost 2.50 dollars. Superseded: the meeting was Thursday. the meeting is Friday."
        #expect(IslandSummaryPreview.sentences(in: text) == [
            "Ms. Wang arrives at 3 p.m. on Friday.", "tickets cost 2.50 dollars.",
            "Superseded: the meeting was Thursday.", "the meeting is Friday."
        ])
        let preview = IslandSummaryPreview.body(summary: "Superseded: the meeting was Thursday. the meeting is Friday.", keyPoints: [], limit: 40)
        #expect(!preview.contains("Thursday") || preview.contains("Superseded:"))
    }
    private let summary = "The conversation was about a meeting. The meeting with Ms. Wang is tomorrow at 3 p.m. in room 204. "
        + "The slides have to be finished tonight. Parking is free after five."
    private let points = ["The meeting with Ms. Wang is tomorrow at 3 p.m. in room 204.", "The slides must be finished tonight"]

    @Test func splitsSentencesWithoutBreakingTitlesTimesAndDecimals() {
        #expect(IslandSummaryPreview.sentences(in: summary).count == 4)
        #expect(IslandSummaryPreview.sentences(in: "Dr. Lee moved it to 12.30. Bring ID.") == ["Dr. Lee moved it to 12.30.", "Bring ID."])
        #expect(IslandSummaryPreview.sentences(in: "It starts at 9 a.m. tomorrow") == ["It starts at 9 a.m. tomorrow."])
    }

    @Test func choosesWholeSentencesThatFit() {
        let preview = IslandSummaryPreview.body(summary: summary, keyPoints: points, limit: 104)
        #expect(preview == "The meeting with Ms. Wang is tomorrow at 3 p.m. in room 204. The slides must be finished tonight.")
        #expect(preview.count <= 104)
        #expect(!preview.contains("…"))
    }

    @Test func oneSentenceWhenTwoDoNotFit() {
        let preview = IslandSummaryPreview.body(summary: summary, keyPoints: points, limit: 66)
        #expect(preview == "The meeting with Ms. Wang is tomorrow at 3 p.m. in room 204.")
        // With the default limit a second fact fits beside it.
        let standard = IslandSummaryPreview.body(summary: summary, keyPoints: points)
        #expect(standard == "The meeting with Ms. Wang is tomorrow at 3 p.m. in room 204. The slides must be finished tonight.")
        #expect(standard.count <= IslandSummaryPreview.Limits.standard.body)
    }

    @Test func prefersFactsOverATopicAnnouncement() {
        let preview = IslandSummaryPreview.body(summary: summary, keyPoints: [], limit: 70)
        #expect(preview == "The meeting with Ms. Wang is tomorrow at 3 p.m. in room 204.")
        // Nothing but the announcement: it is shown rather than nothing.
        #expect(IslandSummaryPreview.body(summary: "The conversation was about lunch.", keyPoints: []) == "The conversation was about lunch.")
    }

    @Test func aSentenceThatIsTooLongEndsAtAClauseOrADetail() {
        let long = "The group meets on Saturday at ten in study room 204 of the science building, because the library is closed on weekends and nobody has a key."
        #expect(IslandSummaryPreview.body(summary: long, keyPoints: [], limit: 104)
            == "The group meets on Saturday at ten in study room 204 of the science building.")
        // No clause in reach, nothing delicate: the last detail is left out, the sentence stays whole.
        let plain = "The group meets on Saturday at ten in study room 204 of the science building for the report."
        #expect(IslandSummaryPreview.body(summary: plain, keyPoints: [], limit: 66) == "The group meets on Saturday at ten.")
    }

    @Test func aNegatedOrConditionalSentenceIsNeverShortenedIntoAnotherMeaning() {
        let negated = "The store does not open until ten on Saturday morning because of the inventory count"
        // A whole clause is in reach: the sentence ends there, with its "not … until".
        #expect(IslandSummaryPreview.body(summary: negated, keyPoints: [], limit: 60) == "The store does not open until ten on Saturday morning.")
        // No clause in reach: cut at a word and marked, never at "… open." or "… until ten."
        let cut = IslandSummaryPreview.body(summary: negated, keyPoints: [], limit: 40)
        #expect(cut.hasSuffix("…") && cut.count <= 40 && !cut.hasSuffix(" …"))
    }

    @Test func newestFactsFirstWhileFollowing() {
        let preview = IslandSummaryPreview.body(summary: summary, keyPoints: points + ["Parking is free after five."], limit: 70,
                                                newestFirst: true)
        #expect(preview.contains("Parking is free after five."))
    }

    @Test func noDuplicatesAndNothingFromOutsideTheSummary() {
        let preview = IslandSummaryPreview.body(summary: "The exam is on Friday.", keyPoints: ["The exam is on Friday"], limit: 104)
        #expect(preview == "The exam is on Friday.")
        #expect(IslandSummaryPreview.body(summary: "", keyPoints: []) == "")
    }

    @Test func theBestFactIsAlwaysShownAndFurtherOnesFillTheSpace() {
        let points = ["The group meets on Saturday at ten in study room 204 of the science building.",
                      "The graphs have to be finished by Friday night.", "The exam was postponed until the Friday after.",
                      "Nobody has booked the projector yet."]
        // No second fact fits beside the first: one whole fact, not a cut second one.
        #expect(IslandSummaryPreview.body(summary: "", keyPoints: points, limit: 110) == points[0])
        // With room, as many further facts as fit, in the summary's order.
        #expect(IslandSummaryPreview.body(summary: "", keyPoints: points, limit: 130) == points[0] + " " + points[1])
        #expect(IslandSummaryPreview.body(summary: "", keyPoints: Array(points.dropFirst()), limit: 110)
            == points[1] + " " + points[2])
    }

    @Test func chineseSentencesAreSplitAndShortenedAtClauses() {
        #expect(IslandSummaryPreview.sentences(in: "会议在明天下午三点。地点是二零四教室！") == ["会议在明天下午三点。", "地点是二零四教室！"])
        let long = "明天下午三点我们在科学楼二零四教室开会，请大家务必带上签好字的表格，还要在星期五晚上之前把图表全部做完。"
        let preview = IslandSummaryPreview.body(summary: long, keyPoints: [], limit: 40)
        #expect(preview.hasSuffix("。") && preview.count <= 40 && preview.hasPrefix("明天下午三点"))
    }

    @Test func aDirectFactComesBeforeANarratedOne() {
        let preview = IslandSummaryPreview.body(
            summary: "Someone said they are playing a game right now, probably. The meeting with Ms. Wang is tomorrow.", keyPoints: [])
        #expect(preview == "The meeting with Ms. Wang is tomorrow.")
    }

    @Test func headingFitsOneLineWithoutAFragment() {
        #expect(IslandSummaryPreview.heading(for: "Lunch on Friday") == "Lunch on Friday")
        #expect(IslandSummaryPreview.heading(for: "Meeting with Ms. Wang about the science fair schedule") == "Meeting with Ms. Wang")
        #expect(IslandSummaryPreview.heading(for: "Group report and the graphs for the final presentation", limit: 30) == "Group report and the graphs")
        #expect(IslandSummaryPreview.heading(for: "Supercalifragilisticexpialidocious plans", limit: 20).hasSuffix("…"))
    }
}
