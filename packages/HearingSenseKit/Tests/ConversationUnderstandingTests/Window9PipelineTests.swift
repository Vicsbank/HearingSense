@testable import ConversationUnderstanding
import Foundation
import Testing

/// Window 9: the default pipeline (summarizer → `SummaryPostprocessing` → recap), with scripted
/// (mock) summarizers: these tests prove the wiring and the policies, not any model.
private let origin = Date(timeIntervalSince1970: 1_780_000_000)
private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

private func excerpt(of lines: [String]) -> ConversationExcerpt {
    var buffer = RollingConversationBuffer()
    buffer.begin(at: at(0))
    for (index, line) in lines.enumerated() {
        let start = 1 + Double(index) * 7
        buffer.append(BufferedUtterance(text: line, start: at(start), end: at(start + 5)), now: at(start + 5))
    }
    return buffer.excerpt(now: at(1 + Double(lines.count) * 7))
}

private let qwen = SummarizationEngineIdentity(kind: .qwen, modelID: "mlx-community/Qwen3.5-4B-MLX-4bit", revision: "r",
                                               quantization: "4-bit", runtime: "mock")

@Suite("Window 9 pipeline (scripted summarizers)")
struct Window9PipelineTests {
    private let meeting = [
        "the team meeting is Thursday at seven forty five",
        "actually move it to Friday the same time works better for Dana",
        "please bring twenty dollars for the tickets",
        "the bus leaves at three thirty p m from the front entrance",
    ]

    @Test func defaultIsTheNewPipelineAndVerificationIsOff() {
        let policy = ConversationRecapEngine.Policy()
        #expect(policy.postprocessing == .window9)
        #expect(policy.verification == .off)
    }

    @Test func spokenAndWrittenNumbersAreNotRejected() async {
        let draft = RecapDraft(title: "Team meeting",
                               summary: "The team meeting was moved from Thursday to Friday at 7:45. Everyone should bring $20 for the tickets. The bus leaves at 3:30 PM from the front entrance.",
                               keyPoints: ["Meeting on Friday at 7:45.", "Bring $20."], engine: qwen)
        let recap = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: draft)).recap(excerpt(of: meeting))
        #expect(recap.isSummary)
        #expect(recap.summary.contains("7:45") && recap.summary.contains("$20") && recap.summary.contains("3:30 PM"))
        #expect(recap.keyPoints.count == 2)
        #expect(recap.engines == [qwen])
        #expect(recap.engineLabel == "Qwen (Qwen3.5-4B-MLX-4bit)")
    }

    @Test func aSupersededDayIsNotStatedAsCurrent() async {
        let draft = RecapDraft(title: "Team meeting",
                               summary: "The team meeting is on Thursday at 7:45. The meeting was moved to Friday. Bring $20 for the tickets.",
                               keyPoints: [])
        let recap = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: draft)).recap(excerpt(of: meeting))
        #expect(recap.isSummary)
        #expect(!recap.summary.contains("is on Thursday"))
        #expect(recap.summary.contains("moved to Friday"))
    }

    @Test func aMadeUpNumberIsRemoved() async {
        let draft = RecapDraft(title: "Team meeting",
                               summary: "The team meeting was moved to Friday. Everyone should bring $35 for the tickets. The bus leaves at 3:30 PM.",
                               keyPoints: [])
        let recap = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: draft)).recap(excerpt(of: meeting))
        #expect(recap.isSummary)
        #expect(!recap.summary.contains("$35"))
        #expect(recap.summary.contains("3:30 PM"))
        #expect(!recap.corrections.isEmpty)
    }

    @Test func fallbackReasonTravelsWithTheRecap() async {
        var draft = RecapDraft(title: "T", summary: "The team meeting was moved to Friday. Bring $20 for the tickets.", engine: .appleFoundationModels)
        draft.fallbackReason = "qwen_model_not_installed"
        let recap = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: draft)).recap(excerpt(of: meeting))
        #expect(recap.engineLabel == "Apple on-device model")
        #expect(recap.fallbackReason == "qwen_model_not_installed")
        var record = ConversationRecord(recap: recap, at: origin, status: .completed)
        #expect(record.engineLabel == "Apple on-device model" && record.fallbackReason == "qwen_model_not_installed")
        record.edit(title: "Mine", summary: "My words", at: origin)
        #expect(record.engineLabel == "Apple on-device model")
    }

    @Test func noModelVerificationRequestWhenOff() async {
        let draft = RecapDraft(title: "T", summary: "The meeting was moved to Friday. Bring $20 for the tickets.")
        let summarizer = ScriptedSummarizer(recap: draft, ungrounded: [])
        _ = await ConversationRecapEngine(summarizer: summarizer).recap(excerpt(of: meeting))
        #expect(await summarizer.evidenceRequests == 0)
    }

    @Test func verificationCoversOnlyUncertainStatements() async {
        // The second sentence has no lexical overlap with the speech: the checks cannot decide it.
        let draft = RecapDraft(title: "T", summary: "The meeting was moved to Friday. Dana's schedule is easier that way. Bring $20 for the tickets.")
        let summarizer = ScriptedSummarizer(recap: draft, ungrounded: ["Dana's schedule is easier that way."])
        var policy = ConversationRecapEngine.Policy()
        policy.verification = .uncertainOnly
        let recap = await ConversationRecapEngine(summarizer: summarizer, policy: policy).recap(excerpt(of: meeting))
        #expect(recap.isSummary)
        #expect(await summarizer.evidenceRequests <= 1)
        if await summarizer.evidenceRequests == 1 { #expect(!recap.summary.contains("easier that way")) }
    }

    @Test func updateMergesTheAdditionAndReplacesAnOutdatedDay() async {
        let first = RecapDraft(title: "T", summary: "The team meeting is on Friday at 7:45. Bring $20 for the tickets.", engine: qwen)
        let summarizer = ScriptedSummarizer(recap: first)
        let engine = ConversationRecapEngine(summarizer: summarizer)
        let lines = ["the team meeting is Friday at seven forty five", "please bring twenty dollars for the tickets"]
        let excerpt = excerpt(of: lines)
        let recap = await engine.recap(excerpt)
        #expect(recap.isSummary)
        let later = [BufferedUtterance(text: "sorry make that Saturday instead of Friday for the team meeting", start: at(40), end: at(44)),
                     BufferedUtterance(text: "parking is behind the library", start: at(45), end: at(48))]
        await summarizer.setUpdate(RecapDraft(title: "T", summary: "The team meeting was moved from Friday to Saturday. Parking is behind the library.",
                                              keyPoints: [], engine: qwen))
        // Cannot rewrite: the merge keeps the outdated statement because its time is said nowhere else.
        let merged = await engine.update(recap, earlierTranscript: engine.transcript(of: excerpt), new: later)
        #expect(merged?.corrections.contains("earlier_outdated_kept") == true)
        // Can rewrite: the complete updated recap replaces it, with the time kept.
        await summarizer.setRewrite(RecapDraft(title: "T", summary: "The team meeting was moved from Friday to Saturday at 7:45. Bring $20 for the tickets. Parking is behind the library.",
                                               engine: qwen))
        let updated = await engine.update(recap, earlierTranscript: engine.transcript(of: excerpt), new: later)
        let result = updated ?? recap
        #expect(updated != nil)
        #expect(updated?.corrections.contains("rewritten_for_correction") == true)
        #expect(await summarizer.rewriteRequests == 2) // the first attempt (unsupported) and this one
        #expect(result.summary.contains("Saturday") && result.summary.contains("Parking is behind the library"))
        #expect(result.summary.contains("$20"))
        // The earlier statement that gave Friday as the current day does not stay beside the correction.
        #expect(!result.summary.contains("meeting is on Friday"))
    }

    @Test func anUpdateThatAddsNothingNewChangesNothing() async {
        let first = RecapDraft(title: "T", summary: "The team meeting was moved to Friday. Bring $20 for the tickets.")
        let summarizer = ScriptedSummarizer(recap: first)
        let engine = ConversationRecapEngine(summarizer: summarizer)
        let excerpt = excerpt(of: meeting)
        let recap = await engine.recap(excerpt)
        let later = [BufferedUtterance(text: "yes okay that sounds good to me then", start: at(40), end: at(43))]
        await summarizer.setUpdate(RecapDraft(title: "T", summary: "Bring $20 for the tickets."))
        let updated = await engine.update(recap, earlierTranscript: engine.transcript(of: excerpt), new: later)
        #expect(updated == nil)
    }

    @Test func aRewriteCannotDropAnUnrelatedTask() async {
        let previous = ConversationRecap(title: "T", summary: "The team meeting is on Friday at 7:45. Dana brings the programs.", source: .languageModel)
        let lines = ["the team meeting is Friday at seven forty five", "Dana brings the programs"]
        let later = [BufferedUtterance(text: "move the team meeting to Saturday", start: at(40), end: at(44))]
        let summarizer = ScriptedSummarizer(update: RecapDraft(title: "T", summary: "The team meeting moved to Saturday."))
        await summarizer.setRewrite(RecapDraft(title: "T", summary: "The team meeting moved to Saturday at 7:45."))
        let updated = await ConversationRecapEngine(summarizer: summarizer).update(previous, earlierTranscript: lines.joined(separator: "\n"), new: later)
        #expect(updated?.summary.contains("Dana brings the programs.") == true)
        #expect(updated?.corrections.contains("rewritten_for_correction") == false)
    }

    @Test func aRewriteCannotDropAnotherSlotsWeekday() async {
        let previous = ConversationRecap(title: "T", summary: "The team meeting is on Friday at 7:45. The dentist appointment is Friday at 9:00 AM.", source: .languageModel)
        let lines = ["the team meeting is Friday at seven forty five", "the dentist appointment is Friday at nine a m"]
        let later = [BufferedUtterance(text: "move the team meeting to Saturday", start: at(40), end: at(44))]
        let summarizer = ScriptedSummarizer(update: RecapDraft(title: "T", summary: "The team meeting moved to Saturday."))
        await summarizer.setRewrite(RecapDraft(title: "T", summary: "The team meeting moved to Saturday at 7:45. The dentist appointment is at 9:00 AM."))
        let updated = await ConversationRecapEngine(summarizer: summarizer).update(previous, earlierTranscript: lines.joined(separator: "\n"), new: later)
        #expect(updated?.summary.contains("dentist appointment is Friday") == true)
        #expect(updated?.corrections.contains("rewritten_for_correction") == false)
    }

    @Test func optionalVerificationAlsoChecksUpdates() async {
        let previous = ConversationRecap(title: "T", summary: "The team meeting is on Friday.", source: .languageModel)
        let uncertain = "Dana's schedule is easier that way."
        let summarizer = ScriptedSummarizer(update: RecapDraft(title: "T", summary: "The meeting moved to Saturday. " + uncertain), ungrounded: [uncertain])
        var policy = ConversationRecapEngine.Policy()
        policy.verification = .uncertainOnly
        policy.rewriteTimeout = 0
        let later = [BufferedUtterance(text: "the meeting moved to Saturday for Dana", start: at(40), end: at(44))]
        let updated = await ConversationRecapEngine(summarizer: summarizer, policy: policy).update(previous, earlierTranscript: "the team meeting is Friday", new: later)
        #expect(await summarizer.evidenceRequests == 1)
        #expect(updated?.summary.contains(uncertain) == false)
    }

    @Test func aRewriteCannotReverseAnEarlierProhibitionWhenItsSourceExpired() async {
        let previous = ConversationRecap(title: "T", summary: "The team meeting is Friday at 7:45. Dana must not bring the programs.", source: .languageModel)
        let later = [BufferedUtterance(text: "move the team meeting to Saturday", start: at(40), end: at(44))]
        let summarizer = ScriptedSummarizer(update: RecapDraft(title: "T", summary: "The team meeting moved to Saturday."))
        await summarizer.setRewrite(RecapDraft(title: "T", summary: "The team meeting moved to Saturday at 7:45. Dana must bring the programs."))
        // The bounded earlier transcript no longer includes the prohibition; its saved fact still matters.
        let updated = await ConversationRecapEngine(summarizer: summarizer).update(previous, earlierTranscript: "the team meeting is Friday at seven forty five", new: later)
        #expect(updated?.summary.contains("Dana must not bring the programs.") == true)
        #expect(updated?.corrections.contains("rewritten_for_correction") == false)
    }
}

extension ScriptedSummarizer {
    func setUpdate(_ draft: RecapDraft) { updateDraft = draft }
    func setRewrite(_ draft: RecapDraft) { rewriteDraft = draft }
}
