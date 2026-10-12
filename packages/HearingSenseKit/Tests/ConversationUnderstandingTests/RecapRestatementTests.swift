@testable import ConversationUnderstanding
import Foundation
import Testing

private let origin = Date(timeIntervalSince1970: 1_780_000_000)
private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

/// The announcement of evaluation scene h05, in which Window 7 first lost a fact: the model's
/// recap repeated "The lot reopens on Friday." as it was said, and the copy check deleted it.
private let announcement = [
    "Attention please, the north parking lot will be closed tomorrow from six a.m. for repaving.",
    "Please park in the south lot or on Elm Street.",
    "Cars left in the north lot after six will be towed at the owner's expense.",
    "The lot reopens on Friday.",
]

private func excerpt(of lines: [String]) -> ConversationExcerpt {
    var buffer = RollingConversationBuffer()
    buffer.begin(at: at(0))
    for (index, line) in lines.enumerated() {
        let start = 1 + Double(index) * 7
        buffer.append(BufferedUtterance(text: line, start: at(start), end: at(start + 5)), now: at(start + 5))
    }
    return buffer.excerpt(now: at(1 + Double(lines.count) * 7))
}

private let modelDraft = RecapDraft(
    title: "Parking lot closure",
    summary: "Someone said the north parking lot will be closed tomorrow from six a.m. for repaving and that cars left "
        + "after six will be towed at the owner's expense. People were asked to use the south lot or Elm Street instead. "
        + "The lot reopens on Friday.",
    keyPoints: ["The north lot is closed tomorrow from six for repaving.", "The lot reopens on Friday."])

/// Decision of 2026-10-11: a spoken sentence the draft repeats word for word is restated in
/// memory instead of being deleted, and the privacy rule stays as strict as it was.
@Suite struct RecapRestatementTests {
    private let transcript = announcement.joined(separator: "\n")

    @Test func aCopiedFactIsRestatedInsteadOfDeleted() async {
        let summarizer = ScriptedSummarizer(recap: modelDraft,
                                            restatements: ["The lot reopens on Friday.": "Someone said that the lot reopens on Friday."])
        let recap = await ConversationRecapEngine(summarizer: summarizer).recap(excerpt(of: announcement))
        #expect(recap.isSummary)
        #expect(recap.summary.hasSuffix("Someone said that the lot reopens on Friday."))
        #expect(recap.keyPoints.contains("Someone said that the lot reopens on Friday."))
        #expect(recap.corrections.filter { $0 == RecapValidator.restatedCorrection }.count == 2)
        #expect(!recap.corrections.contains("copied_from_transcript"))
        // One request for the sentence, although the draft has it twice.
        #expect(await summarizer.restateRequests == ["The lot reopens on Friday."])
        // No statement of the result is a spoken sentence as it was said.
        let statements = Set(RecapText.sentences(in: recap.summary) + recap.keyPoints)
        #expect(statements.isDisjoint(with: announcement))
    }

    @Test func withoutAnAcceptableRestatementTheCopyIsStillLeftOut() async {
        // The summarizer cannot restate at all.
        let none = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: modelDraft)).recap(excerpt(of: announcement))
        #expect(none.isSummary)
        #expect(!none.fullText.contains("reopens"))
        #expect(none.corrections.filter { $0 == "copied_from_transcript" }.count == 2)

        // The "restatement" is the sentence again, or the sentence with other punctuation.
        for answer in ["The lot reopens on Friday.", "the lot reopens on friday", "The lot — reopens on Friday!"] {
            let same = ScriptedSummarizer(recap: modelDraft, restatements: ["The lot reopens on Friday.": answer])
            let recap = await ConversationRecapEngine(summarizer: same).recap(excerpt(of: announcement))
            #expect(!recap.fullText.lowercased().contains("reopens"), "\(answer)")
        }
    }

    @Test func aRestatementMustCarryTheSameFactsAndNothingElse() {
        let validator = RecapValidator()
        let original = "The lot reopens on Friday."
        #expect(validator.restatementProblem("Someone said that the lot reopens on Friday.", of: original) == nil)
        #expect(validator.restatementProblem("It was announced that the lot will reopen on Friday.", of: original) == nil)
        #expect(validator.restatementProblem("Someone said that the lot reopens on Monday.", of: original) == "restatement_changed_number_or_time")
        #expect(validator.restatementProblem("Someone said that the lot reopens.", of: original) == "restatement_changed_number_or_time")
        #expect(validator.restatementProblem("Someone said that the lot does not reopen on Friday.", of: original) == "restatement_changed_negation")
        #expect(validator.restatementProblem("Someone told Maria that the lot reopens on Friday.", of: original) == "restatement_added_name")
        #expect(validator.restatementProblem("Someone said something about Friday.", of: original) == "restatement_lost_content")
        #expect(validator.restatementProblem("Someone said that the lot reopens on Friday. Everyone was relieved.", of: original)
            == "restatement_not_one_sentence")
        #expect(validator.restatementProblem(
            "Someone said that the lot reopens on Friday and that everybody should be careful when they drive in again that morning.",
            of: original) == "restatement_too_long")
        #expect(validator.restatementProblem("The lot reopens on Friday.", of: original) == "restatement_unchanged")

        // A negation and a name in the spoken sentence have to survive.
        let refusal = "Maria can't come before nine on Tuesday."
        #expect(validator.restatementProblem("Someone said that Maria can't come before nine on Tuesday.", of: refusal) == nil)
        #expect(validator.restatementProblem("Someone said that Maria can come before nine on Tuesday.", of: refusal) == "restatement_changed_negation")
    }

    @Test func aRestatementThatFailsTheOrdinaryChecksIsRefused() {
        // Accepted as a restatement of the sentence, but the day was never said in this transcript.
        let draft = RecapDraft(title: "", summary: "Bring the forms to the office before lunch.", keyPoints: [])
        let result = RecapValidator().validate(
            draft, transcript: "Bring the forms to the office before lunch.",
            restatements: ["Bring the forms to the office before lunch.": "Someone asked that the signed forms be brought to the head office before lunch."])
        #expect(result.restated == 1)
        let wrong = RecapValidator().validate(
            draft, transcript: "Bring the forms to the office before lunch.",
            restatements: ["Bring the forms to the office before lunch.": "Zoe asked that the forms reach the office before lunch."])
        #expect(wrong.restated == 0)
        #expect(wrong.summary.isEmpty)
        #expect(wrong.corrections == ["copied_from_transcript"])
    }

    @Test func onlyAFewStatementsAreRestatedPerDraft() async {
        let lines = (1...6).map { "Item number \($0) on the list is still open today." }
        let draft = RecapDraft(title: "", summary: "Someone went through a list of open items. " + lines.joined(separator: " "), keyPoints: [])
        let answers = Dictionary(uniqueKeysWithValues: lines.map { ($0, "Someone said that " + $0.prefix(1).lowercased() + $0.dropFirst()) })
        let summarizer = ScriptedSummarizer(recap: draft, restatements: answers)
        _ = await ConversationRecapEngine(summarizer: summarizer).recap(excerpt(of: lines))
        #expect(await summarizer.restateRequests.count == 3)
    }

    @Test func anUpdateRestatesWhatItCopied() async {
        let earlier = "A Saturday meeting at ten in room 204 was agreed."
        let previous = ConversationRecap(title: "Project", summary: earlier, source: .languageModel, coveredTo: at(10))
        let spoken = "And the teacher said it has to be at least six pages."
        let summarizer = ScriptedSummarizer(
            update: RecapDraft(title: "Project", summary: earlier + " " + spoken, keyPoints: []),
            restatements: [spoken: "Someone added that the teacher said it has to be at least six pages."])
        let new = [BufferedUtterance(text: spoken, start: at(20), end: at(24))]
        let updated = await ConversationRecapEngine(summarizer: summarizer)
            .update(previous, earlierTranscript: "we meet on saturday at ten in room 204", new: new)
        #expect(updated?.summary == earlier + " Someone added that the teacher said it has to be at least six pages.")
        #expect(updated?.corrections.contains(RecapValidator.restatedCorrection) == true)
    }
}

/// A saved summary must not be an extended transcript, however it was produced.
@Suite struct RecapVerbatimShareTests {
    private let transcript = announcement.joined(separator: "\n")
    private let validator = RecapValidator()

    @Test func theShareIsZeroForOwnWordsAndOneForTheTranscript() {
        #expect(validator.verbatimShare(of: "An announcement about parking: one lot closes for a day and cars may be towed.",
                                        transcript: transcript) == 0)
        #expect(validator.verbatimShare(of: announcement.prefix(3).joined(separator: " "), transcript: transcript) == 1)
        // An utterance shorter than a run (five words here) is too short to count.
        #expect(validator.verbatimShare(of: announcement.joined(separator: " "), transcript: transcript) == 41.0 / 46.0)
        #expect(validator.verbatimShare(of: "", transcript: transcript) == 0)
        // A run has to come from one utterance: the end of one and the start of the next do not count.
        #expect(validator.verbatimShare(of: "On Elm Street cars left in the lot.", transcript: transcript) == 0)
    }

    @Test func anOrdinarySummaryOfPlainFactsStaysUnderTheLimit() {
        let share = validator.verbatimShare(of: modelDraft.summary.replacingOccurrences(of: " The lot reopens on Friday.", with: ""),
                                            transcript: transcript)
        #expect(share > 0.3)
        #expect(share < ConversationRecapEngine.Policy().maximumVerbatimShare)
    }

    /// Whole utterances glued together are no spoken sentence each, so the sentence check passes
    /// them; the share does not.
    @Test func aTranscriptGluedIntoSentencesIsNotASummary() async {
        let glued = "Someone said attention please, the north parking lot will be closed tomorrow from six a.m. for repaving, "
            + "and please park in the south lot or on Elm Street. They said cars left in the north lot after six will be "
            + "towed at the owner's expense and the lot reopens on Friday."
        let first = validator.validate(RecapDraft(title: "Parking", summary: glued, keyPoints: []), transcript: transcript)
        #expect(!first.corrections.contains("copied_from_transcript"))
        #expect(first.verbatimShare > 0.7)

        let engine = ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: RecapDraft(title: "Parking", summary: glued, keyPoints: [])))
        let recap = await engine.recap(excerpt(of: announcement))
        #expect(!recap.isSummary)
        #expect(recap.corrections.contains("too_much_verbatim"))
        #expect(!recap.summary.contains("Elm Street"))
    }

    @Test func theLastCheckBeforeSavingRefusesATranscript() {
        let engine = ConversationRecapEngine(summarizer: ScriptedSummarizer())
        let summary = ConversationRecap(title: "Parking", summary: "Someone announced that one parking lot closes for repaving and reopens on Friday.",
                                        source: .languageModel)
        #expect(engine.maySave(summary, transcript: transcript))
        let dressed = ConversationRecap(title: "Parking", summary: announcement.joined(separator: " "), source: .languageModel)
        #expect(!engine.maySave(dressed, transcript: transcript))
        var note = dressed
        note.source = .unavailable
        #expect(!engine.maySave(note, transcript: ""))
        // Nothing left to compare with: the checks made when it was written stand.
        #expect(engine.maySave(summary, transcript: ""))
    }

    @Test func anUpdateThatIsMostlyTranscriptIsNotTaken() async {
        let previous = ConversationRecap(title: "Parking", summary: "An announcement about parking was made.", source: .languageModel,
                                         coveredTo: at(1))
        let glued = "Someone said the north parking lot will be closed tomorrow from six a.m. for repaving and cars left in "
            + "the north lot after six will be towed at the owner's expense."
        let summarizer = ScriptedSummarizer(update: RecapDraft(title: "Parking", summary: previous.summary + " " + glued, keyPoints: []))
        let new = [announcement[0], announcement[2]].enumerated().map {
            BufferedUtterance(text: $0.element, start: at(20 + Double($0.offset) * 6), end: at(24 + Double($0.offset) * 6))
        }
        let updated = await ConversationRecapEngine(summarizer: summarizer).update(previous, earlierTranscript: "", new: new)
        #expect(updated == nil)
    }
}
