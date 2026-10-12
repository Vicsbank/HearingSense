@testable import ConversationUnderstanding
import Foundation
import Testing

private let origin = Date(timeIntervalSince1970: 1_780_000_000)
private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }
private func said(_ text: String, _ start: TimeInterval, _ end: TimeInterval, lowQuality: Bool = false) -> BufferedUtterance {
    BufferedUtterance(text: text, start: at(start), end: at(end), isLowQuality: lowQuality)
}

/// A summarizer with scripted answers. Test-only.
actor ScriptedSummarizer: ConversationSummarizing {
    var recapDraft: RecapDraft?
    var updateDraft: RecapDraft?
    var available = true
    private(set) var recapRequests: [String] = []
    private(set) var updateRequests: [String] = []

    /// Answers to "restate this sentence"; a sentence without one cannot be restated.
    var restatements: [String: String] = [:]
    private(set) var restateRequests: [String] = []

    init(recap: RecapDraft? = nil, update: RecapDraft? = nil, available: Bool = true, restatements: [String: String] = [:]) {
        recapDraft = recap
        updateDraft = update
        self.available = available
        self.restatements = restatements
    }

    func restate(_ statement: String) async throws -> String {
        restateRequests.append(statement)
        guard let answer = restatements[statement] else { throw RecapError.restatementUnsupported }
        return answer
    }

    func isAvailable() async -> Bool { available }
    nonisolated func prewarm() async {}

    func recap(transcript: String, notes: [String]) async throws -> RecapDraft {
        recapRequests.append(transcript)
        guard let recapDraft else { throw RecapError.modelFailure("scripted") }
        return recapDraft
    }

    func update(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft {
        updateRequests.append(newTranscript)
        guard let updateDraft else { throw RecapError.modelFailure("scripted") }
        return updateDraft
    }
}

@Suite struct RollingConversationBufferTests {
    @Test func nothingIsKeptUntilCollectionBegins() {
        var buffer = RollingConversationBuffer()
        buffer.append(said("Hello there", 0, 2), now: at(2))
        buffer.setTentative("and then")
        #expect(buffer.isEmpty)
        buffer.begin(at: at(3))
        buffer.append(said("Hello again", 4, 6), now: at(6))
        #expect(buffer.utterances.count == 1)
    }

    @Test func textExpiresAfterTheRetentionTime() {
        var buffer = RollingConversationBuffer(policy: ConversationBufferPolicy(lookBack: 120))
        buffer.begin(at: at(0))
        buffer.append(said("The meeting is at ten.", 1, 4), now: at(4))
        buffer.append(said("Bring the report.", 100, 103), now: at(103))
        #expect(buffer.utterances.count == 2)
        #expect(buffer.nextExpiry == at(4 + 135))
        buffer.prune(now: at(140))
        #expect(buffer.utterances.map(\.text) == ["Bring the report."])
        #expect(buffer.expiredUtterances == 1)
        buffer.prune(now: at(400))
        #expect(buffer.utterances.isEmpty)
        #expect(buffer.nextExpiry == nil)
    }

    @Test func theBufferIsBoundedInCountAndSize() {
        var buffer = RollingConversationBuffer(policy: ConversationBufferPolicy(maximumUtterances: 5, maximumCharacters: 60))
        buffer.begin(at: at(0))
        for index in 0 ..< 20 {
            buffer.append(said("Sentence number \(index) here.", Double(index), Double(index) + 0.5), now: at(Double(index) + 1))
        }
        #expect(buffer.utterances.count <= 5)
        #expect(buffer.characterCount <= 60)
        #expect(buffer.utterances.last?.text == "Sentence number 19 here.")
    }

    @Test func aDuplicateFinalResultIsStoredOnce() {
        var buffer = RollingConversationBuffer()
        buffer.begin(at: at(0))
        buffer.append(said("See you at noon.", 1, 3), now: at(3))
        buffer.append(said("See you at noon.", 3.5, 4), now: at(4))
        #expect(buffer.utterances.count == 1)
    }

    @Test func anExcerptStopsAtTheLastLongPause() {
        var buffer = RollingConversationBuffer()
        buffer.begin(at: at(-200))
        buffer.append(said("Earlier conversation about lunch.", 0, 4), now: at(4))
        buffer.append(said("Pizza again, I think.", 5, 8), now: at(8))
        // 40 seconds of silence: another conversation begins.
        buffer.append(said("Did you get the tickets?", 48, 51), now: at(51))
        buffer.append(said("Yes, two for Saturday.", 52, 55), now: at(55))
        let excerpt = buffer.excerpt(now: at(60))
        #expect(excerpt.utterances.map(\.text) == ["Did you get the tickets?", "Yes, two for Saturday."])
        #expect(excerpt.startsAtBoundary)
        #expect(!excerpt.isTruncatedAtStart)
        #expect(buffer.boundaries() == [at(48)])
    }

    @Test func anExcerptLooksBackNoFurtherThanTheWindow() {
        var buffer = RollingConversationBuffer(policy: ConversationBufferPolicy(lookBack: 60, retention: 600))
        buffer.begin(at: at(-10))
        for index in 0 ..< 12 { buffer.append(said("Line \(index) of a long talk.", Double(index) * 10, Double(index) * 10 + 5), now: at(Double(index) * 10 + 5)) }
        let excerpt = buffer.excerpt(now: at(120))
        #expect(excerpt.utterances.first?.text == "Line 6 of a long talk.")
        #expect(excerpt.windowStart == at(60))
        // A longer look-back can be asked for per request.
        #expect(buffer.excerpt(now: at(120), lookBack: 200).utterances.count == 12)
    }

    @Test func aConversationThatWasGoingOnWhenListeningBeganIsMarkedTruncated() {
        var buffer = RollingConversationBuffer()
        buffer.begin(at: at(0))
        buffer.append(said("so that is why we moved it to Friday.", 1, 4), now: at(4))
        buffer.append(said("Friday works.", 5, 6), now: at(6))
        #expect(buffer.excerpt(now: at(10)).isTruncatedAtStart)
        // Listening since long before the window: not truncated.
        var settled = RollingConversationBuffer()
        settled.begin(at: at(-500))
        settled.append(said("Shall we move it to Friday?", 1, 4), now: at(4))
        #expect(!settled.excerpt(now: at(10)).isTruncatedAtStart)
    }

    @Test func tentativeWordsAreForCaptionsOnly() {
        var buffer = RollingConversationBuffer()
        buffer.begin(at: at(0))
        buffer.setTentative("the deadline is")
        #expect(buffer.tentative == "the deadline is")
        #expect(buffer.excerpt(now: at(5)).utterances.isEmpty)
        buffer.append(said("The deadline is Monday.", 1, 3), now: at(3))
        #expect(buffer.tentative == nil)
    }

    @Test func missingSpeechIsRememberedAndReported() {
        var buffer = RollingConversationBuffer()
        buffer.begin(at: at(-300))
        buffer.append(said("The bus leaves at nine.", 0, 3), now: at(3))
        buffer.noteMissingSpeech(from: at(4), to: at(9), now: at(9))
        buffer.noteMissingSpeech(from: at(9.5), to: at(14), now: at(14))
        buffer.append(said("Be on time.", 15, 17), now: at(17))
        let excerpt = buffer.excerpt(now: at(20))
        #expect(excerpt.missing.count == 1)
        #expect(excerpt.missingDuration == 10)
    }

    @Test func clearDeletesEverythingAndStopsCollecting() {
        var buffer = RollingConversationBuffer()
        buffer.begin(at: at(0))
        buffer.append(said("Private words.", 1, 2), now: at(2))
        buffer.setTentative("more")
        buffer.noteMissingSpeech(from: at(3), to: at(8), now: at(8))
        buffer.clear()
        #expect(buffer.isEmpty)
        #expect(buffer.missing.isEmpty)
        #expect(buffer.collectingSince == nil)
        buffer.append(said("After clearing.", 10, 11), now: at(11))
        #expect(buffer.isEmpty)
    }
}

@Suite struct RecapValidatorTests {
    let transcript = """
    The plumber is coming on Tuesday between eight and noon to fix the kitchen sink.
    I can't be there Tuesday, I'll leave the key with the neighbor in apartment 3B.
    No, the repair is covered, you don't pay anything.
    """
    let validator = RecapValidator()

    @Test func supportedStatementsPass() {
        let draft = RecapDraft(title: "Plumber visit on Tuesday",
                               summary: "A plumber is coming on Tuesday between eight and noon to fix the kitchen sink. The key will be left with the neighbor in apartment 3B. The repair is covered and nothing has to be paid.",
                               keyPoints: ["Plumber Tuesday between 8 and noon", "Key with the neighbor in 3B"])
        let result = validator.validate(draft, transcript: transcript)
        #expect(result.removed == 0)
        #expect(result.corrections.isEmpty)
        #expect(result.title == "Plumber visit on Tuesday")
        #expect(result.keyPoints.count == 2)
    }

    @Test func aNumberDayOrNameThatWasNotSaidIsRemoved() {
        let draft = RecapDraft(title: "Plumber visit",
                               summary: "A plumber is coming on Wednesday to fix the kitchen sink. The repair costs 200 dollars. Then Henderson will let him in. The key will be left with the neighbor.",
                               keyPoints: ["Arrives at nine", "Key with the neighbor"])
        let result = validator.validate(draft, transcript: transcript)
        #expect(result.summary == "The key will be left with the neighbor.")
        #expect(result.keyPoints == ["Key with the neighbor"])
        #expect(result.removed == 4)
        #expect(result.corrections.contains("unsupported_number_or_time"))
        #expect(result.corrections.contains("unsupported_name"))
    }

    @Test func aSentenceMadeOfOtherWordsIsRemoved() {
        let draft = RecapDraft(title: "", summary: "The landlord promised to renovate the whole bathroom soon. The plumber will fix the kitchen sink.")
        let result = validator.validate(draft, transcript: transcript)
        #expect(result.summary == "The plumber will fix the kitchen sink.")
        #expect(result.corrections == ["unsupported_statement"])
    }

    @Test func numbersAsWordsAndDigitsAgree() {
        #expect(RecapText.quantities(in: "between eight and noon") == RecapText.quantities(in: "between 8 and noon"))
        #expect(RecapText.quantities(in: "one of them said") .isEmpty)
        #expect(RecapText.names(in: "Then Priya will do the demo.") == ["priya"])
        #expect(RecapText.names(in: "Someone will do the demo on Friday.").isEmpty)
    }
}

@Suite struct ConversationRecapEngineTests {
    private func excerpt(_ lines: [String], missing: Bool = false) -> ConversationExcerpt {
        var buffer = RollingConversationBuffer()
        buffer.begin(at: at(-300))
        for (index, line) in lines.enumerated() {
            buffer.append(said(line, Double(index) * 5, Double(index) * 5 + 4), now: at(Double(index) * 5 + 4))
        }
        if missing { buffer.noteMissingSpeech(from: at(100), to: at(112), now: at(112)) }
        return buffer.excerpt(now: at(missing ? 115 : Double(lines.count) * 5 + 1))
    }

    let lines = ["The client meeting moved from Monday to Thursday at two.", "It is in conference room B.",
                 "The slides have to be ready by Wednesday noon."]

    @Test func aCheckedRecapIsReturnedWithItsCoverage() async {
        let summarizer = ScriptedSummarizer(recap: RecapDraft(
            title: "Client meeting moved", summary: "Someone said the client meeting moved from Monday to Thursday at two, in conference room B.",
            keyPoints: ["Slides ready by Wednesday noon"]))
        let engine = ConversationRecapEngine(summarizer: summarizer)
        let recap = await engine.recap(excerpt(lines))
        #expect(recap.source == .languageModel)
        #expect(recap.isSummary)
        #expect(recap.title == "Client meeting moved")
        #expect(recap.utteranceCount == 3)
        #expect(recap.coveredFrom == at(0))
        #expect(recap.coveredTo == at(14))
        // The model saw the utterances, one per line, without speaker labels.
        #expect(await summarizer.recapRequests == [lines.joined(separator: "\n")])
    }

    @Test func tooLittleSpeechIsSaidPlainlyAndTheModelIsNotAsked() async {
        let summarizer = ScriptedSummarizer(recap: RecapDraft(title: "x", summary: "y"))
        let engine = ConversationRecapEngine(summarizer: summarizer)
        let few = await engine.recap(excerpt(["Okay then."]))
        #expect(few.source == .insufficientContext)
        #expect(few.summary.contains("not enough for a summary"))
        let none = await engine.recap(excerpt([]))
        #expect(none.source == .insufficientContext)
        #expect(none.summary.contains("Nothing was transcribed in the last 2 minutes"))
        #expect(await summarizer.recapRequests.isEmpty)
    }

    @Test func withoutAModelNoSummaryIsInventedAndNoTranscriptIsPutInItsPlace() async {
        let engine = ConversationRecapEngine(summarizer: ScriptedSummarizer(available: false))
        let recap = await engine.recap(excerpt(lines))
        #expect(recap.source == .unavailable)
        #expect(!recap.isSummary)
        for word in ["client", "Thursday", "conference", "slides"] {
            #expect(!recap.fullText.localizedCaseInsensitiveContains(word))
        }
    }

    @Test func aRecapThatMostlyFailsTheChecksIsNotShownAsASummary() async {
        let summarizer = ScriptedSummarizer(recap: RecapDraft(
            title: "Budget", summary: "The budget is 90 thousand dollars. Then Tanaka approved it on Sunday. The meeting moved to Thursday."))
        let recap = await ConversationRecapEngine(summarizer: summarizer).recap(excerpt(lines))
        #expect(recap.source == .unavailable)
        // Window 7: the names of the checks that failed follow (for diagnostics; never text).
        #expect(recap.corrections.first == "summary_failed_checks")
        #expect(recap.corrections.count > 1)
    }

    @Test func missingSpeechAndPoorRecognitionBecomeCaveats() async {
        let summarizer = ScriptedSummarizer(recap: RecapDraft(title: "", summary: "The client meeting moved to Thursday at two."))
        let engine = ConversationRecapEngine(summarizer: summarizer)
        let recap = await engine.recap(excerpt(lines, missing: true))
        #expect(recap.caveats.contains { $0.contains("12 seconds of speech could not be transcribed") })
        #expect(recap.title == ConversationRecapEngine.untitled)
        #expect(await summarizer.recapRequests.first?.contains("[some speech here could not be transcribed]") == true)
    }

    @Test func anUpdateKeepsEarlierKeyPointsAndAddsNewOnes() async {
        let first = ConversationRecap(title: "Client meeting", summary: "The client meeting moved to Thursday at two.",
                                      keyPoints: ["Meeting Thursday at two"], source: .languageModel, coveredFrom: at(0),
                                      coveredTo: at(14), utteranceCount: 3)
        let summarizer = ScriptedSummarizer(update: RecapDraft(
            title: "Client meeting", summary: "The client meeting moved to Thursday at two. The budget total is forty thousand.",
            keyPoints: ["Budget total forty thousand"]))
        let engine = ConversationRecapEngine(summarizer: summarizer)
        let new = [said("The budget total is forty thousand, not thirty-five.", 30, 34)]
        let updated = await engine.update(first, earlierTranscript: lines.joined(separator: "\n"), new: new)
        #expect(updated?.keyPoints == ["Meeting Thursday at two", "Budget total forty thousand"])
        #expect(updated?.summary.contains("forty thousand") == true)
        #expect(updated?.coveredTo == at(34))
        #expect(updated?.utteranceCount == 4)
    }

    @Test func nothingNewOrAFailedUpdateLeavesTheRecapAlone() async {
        let first = ConversationRecap(title: "T", summary: "The client meeting moved to Thursday at two.", source: .languageModel)
        let failing = ConversationRecapEngine(summarizer: ScriptedSummarizer())
        #expect(await failing.update(first, earlierTranscript: "", new: [said("The budget total is forty thousand now.", 1, 3)]) == nil)
        let summarizer = ScriptedSummarizer(update: RecapDraft(title: "T", summary: "x"))
        let engine = ConversationRecapEngine(summarizer: summarizer)
        #expect(await engine.update(first, earlierTranscript: "", new: [said("Yeah okay.", 1, 2)]) == nil)
        #expect(await summarizer.updateRequests.isEmpty)
    }
}

@Suite struct ConversationSessionMachineTests {
    private func ready() -> ConversationSessionMachine {
        var machine = ConversationSessionMachine()
        machine.setListening(true)
        machine.setContextAllowed(true)
        return machine
    }

    private let recap = ConversationRecap(title: "Plans", summary: "They agreed to meet on Saturday at ten.", source: .languageModel,
                                          coveredTo: at(10))

    @Test func theFirstPressWritesARecapAndSavesIt() {
        var machine = ready()
        #expect(machine.process(.actionInvoked(at: at(10))) == [.status(.preparingRecap, until: nil), .generateRecap])
        #expect(machine.phase == .preparing)
        #expect(machine.process(.excerptReady(at: at(10.1))) == [.status(.summarizing, until: nil)])
        // A second press while it is being written does nothing.
        #expect(machine.process(.actionInvoked(at: at(11))).isEmpty)
        let effects = machine.process(.recapReady(recap, at: at(14)))
        #expect(effects == [.save(recap, isContinuing: false), .status(.summarySaved, until: at(22))])
        #expect(machine.phase == .summaryAvailable)
        // "Saved" turns into "available", and the offer ends by itself.
        #expect(machine.nextDeadline == at(22))
        #expect(machine.process(.tick(at: at(22))) == [.status(.summaryAvailable, until: at(104))])
        #expect(machine.process(.tick(at: at(104))) == [.status(nil, until: nil)])
        #expect(machine.phase == .idle)
    }

    @Test func aRecapNeedsListeningAndPermission() {
        var machine = ConversationSessionMachine()
        #expect(machine.process(.actionInvoked(at: at(1))).first == .unavailable(.notListening))
        machine.setListening(true)
        #expect(machine.process(.actionInvoked(at: at(2))).first == .unavailable(.contextNotAllowed))
        #expect(machine.phase == .idle)
    }

    @Test func continuingAsksForUpdatesOnlyWhenSomethingNewWasSaidAndThePausedCame() {
        var machine = ready()
        machine.process(.actionInvoked(at: at(10)))
        machine.process(.recapReady(recap, at: at(14)))
        #expect(machine.process(.continueSelected(at: at(20))) == [.save(recap, isContinuing: true), .status(.continuing, until: nil)])
        #expect(machine.phase == .continuing)
        // Nothing said: no update, however long it takes.
        #expect(machine.process(.tick(at: at(200))).isEmpty)
        // Backchannel has no meaningful words.
        #expect(machine.process(.utterance(meaningfulWords: 0, end: at(201))).isEmpty)
        // New content, but people are still talking.
        #expect(machine.process(.utterance(meaningfulWords: 9, end: at(205))).isEmpty)
        #expect(machine.process(.utterance(meaningfulWords: 7, end: at(209))).isEmpty)
        #expect(machine.nextDeadline == at(215))
        // A pause: one update, from where the recap ended.
        #expect(machine.process(.tick(at: at(215))) == [.requestUpdate(since: at(10))])
        #expect(machine.isUpdateInFlight)
        // While it is being written, new speech waits.
        #expect(machine.process(.utterance(meaningfulWords: 12, end: at(218))).isEmpty)
        var updated = recap
        updated.summary += " Someone will bring the data."
        updated.coveredTo = at(209)
        #expect(machine.process(.updateFinished(updated, at: at(219))) == [.save(updated, isContinuing: true)])
        // The next update keeps its distance from the last one.
        #expect(machine.process(.tick(at: at(226))).isEmpty)
        #expect(machine.process(.tick(at: at(235))) == [.requestUpdate(since: at(209))])
        #expect(machine.updatesMade == 1)
    }

    @Test func speechThatNeverPausesIsSummarizedBeforeItExpires() {
        var machine = ready()
        machine.process(.actionInvoked(at: at(0)))
        machine.process(.recapReady(recap, at: at(2)))
        machine.process(.continueSelected(at: at(3)))
        var effects: [ConversationEffect] = []
        for second in stride(from: 5.0, through: 90, by: 3) {
            effects += machine.process(.utterance(meaningfulWords: 5, end: at(second)))
        }
        #expect(effects.count == 1)
        guard case .requestUpdate = effects.first else {
            Issue.record("expected an update")
            return
        }
    }

    @Test func theNextPressStopsFinalizesAndDeletesTheTemporaryContext() {
        var machine = ready()
        machine.process(.actionInvoked(at: at(0)))
        machine.process(.recapReady(recap, at: at(2)))
        machine.process(.continueSelected(at: at(3)))
        let effects = machine.process(.actionInvoked(at: at(60)))
        #expect(effects == [.finalize, .clearTemporaryContext, .status(.stopped, until: at(68))])
        #expect(machine.phase == .idle)
        #expect(machine.process(.tick(at: at(68))) == [.status(nil, until: nil)])
        // And the press after that is a new recap.
        #expect(machine.process(.actionInvoked(at: at(70))).contains(.generateRecap))
    }

    @Test func stoppingListeningOrWithdrawingPermissionEndsEverything() {
        var machine = ready()
        machine.process(.actionInvoked(at: at(0)))
        #expect(machine.process(.listeningStopped(at: at(1))) == [.cancelWork, .clearTemporaryContext, .status(nil, until: nil)])
        #expect(machine.phase == .idle)
        // A recap that arrives afterwards is ignored.
        #expect(machine.process(.recapReady(recap, at: at(3))).isEmpty)

        var following = ready()
        following.process(.actionInvoked(at: at(0)))
        following.process(.recapReady(recap, at: at(2)))
        following.process(.continueSelected(at: at(3)))
        following.process(.utterance(meaningfulWords: 10, end: at(5)))
        let effects = following.process(.contextRevoked(at: at(6)))
        #expect(effects.contains(.finalize))
        #expect(effects.contains(.clearTemporaryContext))
        #expect(following.phase == .idle)
        #expect(following.process(.actionInvoked(at: at(8))).first == .unavailable(.contextNotAllowed))
    }

    @Test func aContinuedSessionEndsByItselfAfterTheLimit() {
        var machine = ready()
        machine.process(.actionInvoked(at: at(0)))
        machine.process(.recapReady(recap, at: at(2)))
        machine.process(.continueSelected(at: at(3)))
        #expect(machine.nextDeadline == at(3 + 1800))
        #expect(machine.process(.tick(at: at(3 + 1800))).contains(.finalize))
        #expect(machine.phase == .idle)
    }

    @Test func fillersAreNotMeaningfulWords() {
        #expect(MeaningfulWords.count(in: "Yeah, okay, mm-hm.") == 0)
        #expect(MeaningfulWords.count(in: "The report is due Wednesday.") == 3)
    }

    @Test func statusTitlesAreGenericAndHaveSymbols() {
        for status in ConversationStatus.allCases {
            #expect(!status.title.isEmpty)
            #expect(!status.symbolName.isEmpty)
        }
    }
}

@Suite struct ConversationRecordTests {
    let recap = ConversationRecap(title: "Plumber visit", summary: "A plumber comes on Tuesday between eight and noon.",
                                  keyPoints: ["Key with the neighbor in 3B"], source: .languageModel,
                                  caveats: ["The beginning is missing."], coveredFrom: at(0), coveredTo: at(40))

    @Test func aRecordIsSearchableByAnyOfItsWords() {
        let record = ConversationRecord(recap: recap, at: at(50), status: .completed)
        #expect(record.matches("plumber"))
        #expect(record.matches("TUESDAY noon"))
        #expect(record.matches("3b"))
        #expect(record.matches("  "))
        #expect(!record.matches("plumber wednesday"))
        #expect(record.fullText.contains("• Key with the neighbor in 3B"))
    }

    @Test func aNewerRecapReplacesTheTextUnlessTheUserEditedIt() {
        var record = ConversationRecord(recap: recap, at: at(50), status: .continuing)
        var later = recap
        later.summary += " The water is off for an hour."
        later.keyPoints.append("Water off for an hour")
        later.coveredTo = at(90)
        record.apply(later, at: at(95), status: .continuing)
        #expect(record.summary.hasSuffix("for an hour."))
        #expect(record.updatedAt == at(95))
        #expect(record.createdAt == at(50))
        #expect(record.coveredTo == at(90))

        record.edit(title: "Tuesday plumber", summary: "My own notes.", at: at(100))
        #expect(record.isUserEdited)
        var latest = later
        latest.summary = "Rewritten by the model."
        latest.keyPoints.append("Repair is covered")
        record.apply(latest, at: at(120), status: .completed)
        #expect(record.title == "Tuesday plumber")
        #expect(record.summary == "My own notes.")
        #expect(record.keyPoints.contains("Repair is covered"))
        #expect(record.status == .completed)
    }

    @Test func theInMemoryStoreSavesFindsAndDeletes() throws {
        let store = InMemoryConversationHistory()
        let first = ConversationRecord(recap: recap, at: at(50), status: .completed)
        var second = ConversationRecord(title: "Lake trip", summary: "Leaving Sunday at seven thirty.", createdAt: at(500),
                                        status: .continuing)
        store.save(first)
        store.save(second)
        #expect(store.all().map(\.title) == ["Lake trip", "Plumber visit"])
        #expect(try store.search("sunday").map(\.id) == [second.id])
        try store.completeInterrupted(at: at(600))
        #expect(store.record(second.id)?.status == .completed)
        second.title = "Lake"
        store.save(second)
        #expect(store.all().count == 2)
        store.delete(first.id)
        #expect(store.all().count == 1)
        store.deleteAll()
        #expect(store.all().isEmpty)
    }

    @Test func aRecordSurvivesEncoding() throws {
        let record = ConversationRecord(recap: recap, at: at(50), status: .continuing)
        let decoded = try JSONDecoder().decode(ConversationRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }
}
