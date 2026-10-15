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
    summary: "The north parking lot will close tomorrow from six a.m. for repaving. Cars left after six in the north lot "
        + "will be towed at the owner's expense. Use the south lot or Elm Street for parking instead. "
        + "The lot reopens on Friday.",
    keyPoints: ["The north lot is closed tomorrow from six for repaving.", "The lot reopens on Friday."])

/// Decision of 2026-10-11: a spoken sentence the draft repeats word for word is restated in
/// memory instead of being deleted, and the privacy rule stays as strict as it was.
@Suite struct RecapRestatementTests {
    private let transcript = announcement.joined(separator: "\n")

    @Test func aCopiedFactIsRestatedInsteadOfDeleted() async {
        let summarizer = ScriptedSummarizer(recap: modelDraft,
                                            restatements: ["The lot reopens on Friday.": "Someone said that the lot reopens on Friday."])
        let recap = await ConversationRecapEngine(summarizer: summarizer, validator: RecapValidator(keptCopyMaximumWords: 0)).recap(excerpt(of: announcement))
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
        let none = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: modelDraft), validator: RecapValidator(keptCopyMaximumWords: 0)).recap(excerpt(of: announcement))
        #expect(none.isSummary)
        #expect(!none.fullText.contains("reopens"))
        #expect(none.corrections.filter { $0 == "copied_from_transcript" }.count == 2)

        // The "restatement" is the sentence again, or the sentence with other punctuation.
        for answer in ["The lot reopens on Friday.", "the lot reopens on friday", "The lot — reopens on Friday!"] {
            let same = ScriptedSummarizer(recap: modelDraft, restatements: ["The lot reopens on Friday.": answer])
            let recap = await ConversationRecapEngine(summarizer: same, validator: RecapValidator(keptCopyMaximumWords: 0)).recap(excerpt(of: announcement))
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
        let result = RecapValidator(keptCopyMaximumWords: 0).validate(
            draft, transcript: "Bring the forms to the office before lunch.",
            restatements: ["Bring the forms to the office before lunch.": "Someone asked that the signed forms be brought to the head office before lunch."])
        #expect(result.restated == 1)
        let wrong = RecapValidator(keptCopyMaximumWords: 0).validate(
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
        // The rule of Window 7 (short copies off): the 12-word sentence is restated.
        let updated = await ConversationRecapEngine(summarizer: summarizer, validator: RecapValidator(keptCopyMaximumWords: 0))
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

    /// The legacy whole-sentence rule misses glued utterances; Window 9 can reject their
    /// embedded long copies before the aggregate-share guard is reached.
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
        #expect(recap.corrections.contains("too_much_verbatim") || recap.corrections.contains("copied_from_transcript"))
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

/// 2026-10-11, from a summary read on the iPhone ("Someone said tomorrow, tomorrow, they will
/// have the meeting …"): a recap states facts; it does not narrate the talking or keep stutters.
@Suite struct RecapTidyingTests {
    @Test func narrationOpenersThatNameNoOneAreRemoved() {
        #expect(RecapText.tidied("Someone said that the lot reopens on Friday.") == "The lot reopens on Friday.")
        #expect(RecapText.tidied("Someone said they are playing a game right now, probably.") == "They are playing a game right now, probably.")
        #expect(RecapText.tidied("The speaker also mentioned that the exam moved to Friday.") == "The exam moved to Friday.")
        #expect(RecapText.tidied("Someone said the lot is closed and that cars will be towed.") == "The lot is closed and cars will be towed.")
        // A named person, an announcement and a short remainder stay as they are.
        #expect(RecapText.tidied("Maya said that she is late.") == "Maya said that she is late.")
        #expect(RecapText.tidied("It was announced that the lot reopens on Friday.") == "It was announced that the lot reopens on Friday.")
        #expect(RecapText.tidied("Someone said no.") == "Someone said no.")
    }

    @Test func aWordSaidTwiceInARowIsWrittenOnce() {
        #expect(RecapText.tidied("Someone said tomorrow, tomorrow, they will have the meeting with Ms. Wang.")
            == "Tomorrow, they will have the meeting with Ms. Wang.")
        #expect(RecapText.tidied("The meeting meeting is on Friday.") == "The meeting is on Friday.")
        // Numbers, names and doubles that are meant stay.
        #expect(RecapText.tidied("The code is five five two.") == "The code is five five two.")
        #expect(RecapText.tidied("They drive to Walla Walla on Friday.") == "They drive to Walla Walla on Friday.")
        #expect(RecapText.tidied("It was very very late.") == "It was very very late.")
        #expect(RecapText.tidied("She had had enough.") == "She had had enough.")
    }

    @Test func theEngineKeepsFactsAndDropsTheNarration() async {
        let lines = ["They are playing the new game right now, probably.",
                     "Tomorrow, tomorrow we have the meeting with Ms. Wang at three in room 204.",
                     "Bring the signed forms, she wants them before the meeting."]
        let draft = RecapDraft(
            title: "Meeting with Ms. Wang",
            summary: "Someone said they are probably playing the new game right now. Someone said tomorrow, tomorrow, the meeting "
                + "with Ms. Wang takes place at three in room 204. The signed forms are wanted before the meeting.",
            keyPoints: ["The meeting with Ms. Wang is tomorrow at three in room 204."])
        let recap = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: draft)).recap(excerpt(of: lines))
        #expect(recap.isSummary)
        #expect(!recap.fullText.lowercased().contains("someone said"))
        #expect(!recap.fullText.contains("tomorrow, tomorrow"))
        #expect(recap.summary.contains("three in room 204"))
        #expect(recap.summary.contains("probably"))
        // The full summary is what is saved: nothing of it is shortened for the island.
        #expect(RecapText.sentences(in: recap.summary).count == 3)
    }

    @Test func aTitleBeforeANameDoesNotEndTheSentence() {
        #expect(RecapText.sentences(in: "Tomorrow, the meeting with Ms. Wang takes place at three. Dr. Lee joins.")
            == ["Tomorrow, the meeting with Ms. Wang takes place at three.", "Dr. Lee joins."])
    }

    @Test func aRestatementIsNotTidiedBackIntoTheSpokenSentence() {
        let spoken = RecapText.words(in: "And the teacher said it has to be at least six pages.")
        #expect(RecapText.isRun(RecapText.words(in: "The teacher said it has to be at least six pages."), in: spoken))
        #expect(!RecapText.isRun(RecapText.words(in: "At least six pages are required, the teacher said."), in: spoken))
    }
}

/// 2026-10-11, from a summary read on the iPhone ("Vic is a student in their family."): words
/// that were all said, but far apart, do not make a supported statement.
@Suite struct RecapProximityTests {
    private func filler(_ count: Int) -> String {
        (0 ..< count).map { "We walked along the river path for a while and looked at the boats \($0 % 7)." }.joined(separator: "\n")
    }

    @Test func wordsSaidFarApartDoNotSupportOneStatement() {
        let transcript = "Vic said hello to everybody at the door.\n" + filler(12) + "\nThe student council election is next month.\n"
            + filler(12) + "\nMy whole family is coming over for dinner."
        let draft = RecapDraft(title: "Day", summary: "Vic is a student in their family. The election of the student council takes place next month.",
                               keyPoints: [])
        let result = RecapValidator().validate(draft, transcript: transcript)
        #expect(result.summary == "The election of the student council takes place next month.")
        #expect(result.corrections.contains("unsupported_combination"))
    }

    @Test func aStatementAboutOneExchangeIsKeptWhateverTheLength() {
        let transcript = filler(14) + "\nVic is a student and his family lives in Denver.\n" + filler(14)
        let draft = RecapDraft(title: "Vic", summary: "Vic is a student whose family lives in Denver.", keyPoints: [])
        let result = RecapValidator().validate(draft, transcript: transcript)
        #expect(result.summary == "Vic is a student whose family lives in Denver.")
        // A short conversation is one stretch: nothing changes for it.
        let short = RecapValidator().validate(RecapDraft(title: "", summary: "Vic and the student met the family.", keyPoints: []),
                                              transcript: "Vic came.\nThe student left.\nThe family stayed.")
        #expect(short.removed == 0)
    }
}

/// Window 8: the model reads each statement against the transcript, and the optional rule for
/// short copies.
@Suite struct RecapGroundingTests {
    private let lines = ["Vic, are you coming down for dinner?", "My family is visiting on Sunday.",
                         "Tomorrow we have the meeting with Ms. Wang at three.", "The other student in my group has not answered yet."]

    private let draft = RecapDraft(
        title: "Evening",
        summary: "The meeting with Ms. Wang takes place tomorrow at three. Vic is a student in their family. A visit of the family is planned for Sunday.",
        keyPoints: ["Ms. Wang is met tomorrow at three."])

    /// Window 9: the Window 7/8 checks stay available as `.legacy` (to measure before/after); these
    /// tests describe that pipeline. The default pipeline is tested in `Window9PipelineTests`.
    private var legacy: ConversationRecapEngine.Policy {
        var policy = ConversationRecapEngine.Policy()
        policy.postprocessing = .legacy
        return policy
    }

    @Test func aStatementTheModelCannotFindInTheTranscriptIsLeftOut() async {
        let summarizer = ScriptedSummarizer(recap: draft, ungrounded: ["Vic is a student in their family."])
        let recap = await ConversationRecapEngine(summarizer: summarizer, policy: legacy).recap(excerpt(of: lines))
        #expect(recap.isSummary)
        #expect(!recap.fullText.contains("student in their family"))
        #expect(recap.summary.contains("tomorrow at three") && recap.summary.contains("Sunday"))
        #expect(recap.corrections.contains("ungrounded_statement"))
        // One request for the whole recap, each statement once.
        #expect(await summarizer.evidenceRequests == 1)
    }

    @Test func withoutAnAnswerNothingIsRemoved() async {
        // A summarizer that cannot judge (the default) leaves the recap to the other checks.
        let recap = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: draft)).recap(excerpt(of: lines))
        #expect(recap.fullText.contains("student in their family"))
    }

    @Test func aReadingThatRejectsNearlyEverythingIsNotBelieved() async {
        let all = RecapText.sentences(in: draft.summary) + draft.keyPoints
        let recap = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: draft, ungrounded: Set(all.dropLast())), policy: legacy)
            .recap(excerpt(of: lines))
        #expect(recap.isSummary)
        #expect(recap.corrections.contains("grounding_not_believed"))
        #expect(RecapText.sentences(in: recap.summary).count == 3)
    }

    @Test func shortCopiesAreLeftOutOnlyWhenTheOptionIsOff() {
        let transcript = "The lot reopens on Friday.\nPlease park in the south lot or on Elm Street."
        let copy = RecapDraft(title: "Parking", summary: "The lot reopens on Friday. Parking is possible in the south lot.", keyPoints: [])
        let strict = RecapValidator(keptCopyMaximumWords: 0).validate(copy, transcript: transcript)
        #expect(!strict.summary.contains("reopens"))
        let lenient = RecapValidator().validate(copy, transcript: transcript)
        #expect(lenient.summary.contains("The lot reopens on Friday."))
        #expect(lenient.corrections.contains(RecapValidator.keptCopyCorrection))
    }
}

/// 2026-10-12: the student approved keeping short exact sentences (up to 12 words) in a summary.
@Suite struct ShortCopyTests {
    private func validate(_ summary: String, _ points: [String] = [], transcript: String, _ validator: RecapValidator = RecapValidator()) -> RecapValidator.Result {
        validator.validate(RecapDraft(title: "", summary: summary, keyPoints: points), transcript: transcript)
    }

    @Test func aShortExactFactStaysWithoutAnyRewriting() {
        let t = "The lot reopens on Friday.\nPlease park in the south lot or on Elm Street."
        let r = validate("The lot reopens on Friday. Parking is possible in the south lot.", transcript: t)
        #expect(r.summary.hasPrefix("The lot reopens on Friday."))
        #expect(r.removed == 0)
    }

    @Test func aLongSentenceIsNeverKeptAsItWasSaid() {
        let long = "Attention please, the north parking lot will be closed tomorrow from six a.m. for repaving."
        let r = validate(long, transcript: long)
        #expect(r.summary.isEmpty)
        #expect(r.corrections.contains("copied_from_transcript"))
    }

    @Test func twoCopiedSentencesNextToEachOtherAreNotBothKept() {
        let t = "The lot reopens on Friday.\nThe gate opens at six.\nThe fee is five dollars."
        let r = validate("The lot reopens on Friday. The gate opens at six. The fee is five dollars.", transcript: t)
        let kept = RecapText.sentences(in: r.summary)
        #expect(kept.contains("The lot reopens on Friday."))
        // The others would stand beside it in the saved text: a piece of transcript.
        #expect(!kept.contains("The gate opens at six.") && !kept.contains("The fee is five dollars."))
    }

    @Test func atMostThreeCopiesAreKeptInOneRecap() {
        let lines = ["The lot reopens on Friday.", "The gate opens at six.", "The fee is five dollars.", "Dogs are not allowed here.", "Bring your own folding chair."]
        let fillers = ["The notice has five parts.", "Entry is regulated.", "Costs are listed.", "Pets are covered.", "Seating is covered."]
        // The model's own sentences stand between the copies; they are parts of a longer spoken line, not copies.
        let transcript = lines.joined(separator: "\n") + "\nThe notice has five parts and entry is regulated and costs are listed and pets are covered and seating is covered."
        let summary = zip(lines, fillers).map { "\($0) \($1)" }.joined(separator: " ")
        let r = validate(summary, transcript: transcript)
        #expect(lines.filter { r.summary.contains($0) }.count == 3)
        #expect(fillers.allSatisfy { r.summary.contains($0) })
    }

    @Test func aSummaryThatIsMostlyTranscriptIsStillRefused() async {
        let lines = ["The lot reopens on Friday.", "The gate opens at six.", "The fee is five dollars.", "Dogs are not allowed."]
        let draft = RecapDraft(title: "Notice", summary: lines.joined(separator: " "), keyPoints: lines)
        let recap = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: draft)).recap(excerpt(of: lines))
        #expect(!recap.isSummary || recap.verbatimShare <= ConversationRecapEngine.Policy().maximumVerbatimShare)
    }

    @Test func factsStayWhenTheModelUsedTheSpeakersWords() async {
        let lines = ["The meeting is moved to three on Thursday.", "Please bring the signed form.", "The room is still 204."]
        let draft = RecapDraft(title: "Meeting", summary: "The meeting is moved to three on Thursday. A signed form has to be brought. The room stays 204.", keyPoints: [])
        let recap = await ConversationRecapEngine(summarizer: ScriptedSummarizer(recap: draft)).recap(excerpt(of: lines))
        #expect(recap.isSummary)
        #expect(recap.summary.contains("moved to three on Thursday"))
        #expect(recap.summary.contains("204") && recap.summary.contains("signed form"))
    }

    @Test func theRollingTranscriptIsNotPartOfAnyRecapObject() {
        // A recap holds the summary, key points, caveats and counts: no utterance list.
        let mirror = Mirror(reflecting: ConversationRecap(title: "", summary: "", source: .languageModel))
        #expect(!mirror.children.contains { $0.label == "utterances" || $0.label == "transcript" })
    }
}

/// Chinese and mixed-language text: words are not separated by spaces.
@Suite struct UnspacedTextTests {
    @Test func chineseIsSegmentedIntoWords() {
        let words = RecapText.words(in: "明天下午三点和王老师开会")
        #expect(words.count >= 4)
        #expect(RecapText.words(in: "明天和 Ms. Wang 开会").contains("wang"))
    }

    @Test func aShortChineseSentenceIsKeptAndALongOneIsNot() {
        let short = "明天下午三点在二零四教室开会。"
        let r = RecapValidator().validate(RecapDraft(title: "", summary: short, keyPoints: []), transcript: short + "\n其他的事情下次再说。")
        #expect(r.summary == short)
        let long = "明天下午三点我们在科学楼二零四教室开会，请大家务必带上签好字的表格，还要把图表在星期五晚上之前全部做完，以便周六写报告。"
        let r2 = RecapValidator().validate(RecapDraft(title: "", summary: long, keyPoints: []), transcript: long)
        #expect(r2.summary.isEmpty)
    }

    @Test func numbersWrittenInChineseAndDigitsAgree() {
        #expect(RecapText.quantities(in: "三点") == RecapText.quantities(in: "3点"))
        #expect(RecapText.hanNumber("十二") == 12 && RecapText.hanNumber("二十") == 20 && RecapText.hanNumber("二十五") == 25)
        // An invented time is still caught in Chinese.
        let r = RecapValidator().validate(RecapDraft(title: "", summary: "会议在下午五点开始。", keyPoints: []), transcript: "会议在下午三点开始。\n大家准时到。")
        #expect(r.summary.isEmpty)
    }

    @Test func negationIsCountedInChinese() {
        #expect(RecapText.negations(in: "周六不行") == 1)
        #expect(RecapText.negations(in: "周六可以") == 0)
    }

    @Test func mixedTextKeepsNamesAndTimes() {
        let t = "明天和 Ms. Wang 在 room 204 开会。\n下午三点。"
        let r = RecapValidator().validate(RecapDraft(title: "", summary: "明天下午三点和 Ms. Wang 在 room 204 开会。", keyPoints: []), transcript: t)
        #expect(!r.summary.isEmpty)
    }

}
