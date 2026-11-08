@testable import ConversationUnderstanding
import Foundation
import Testing

private let origin = Date(timeIntervalSince1970: 1_790_000_000)
private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }
private func said(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> BufferedUtterance {
    BufferedUtterance(text: text, start: at(start), end: at(end))
}

/// Window 7: Summarize, Continue and Stop are three explicit controls.
@Suite struct Window7ConversationMachineTests {
    private let summary = ConversationRecap(title: "Plans", summary: "They agreed to meet on Saturday at ten.",
                                            source: .languageModel, coveredTo: at(10))

    private func ready() -> ConversationSessionMachine {
        var machine = ConversationSessionMachine(policy: .product)
        machine.setListening(true)
        machine.setContextAllowed(true)
        return machine
    }

    /// Acceptance tests 5 and 18: nothing is summarized unless the user asks.
    @Test func speechAloneNeverStartsASummary() {
        var machine = ready()
        var effects: [ConversationEffect] = []
        for second in stride(from: 0.0, to: 600, by: 4) {
            effects += machine.process(.utterance(meaningfulWords: 9, end: at(second)))
            effects += machine.process(.tick(at: at(second + 2)))
        }
        #expect(effects.isEmpty)
        #expect(machine.phase == .idle)
        #expect(machine.nextDeadline == nil)
    }

    @Test func summarizeWritesSavesAndOffersContinue() {
        var machine = ready()
        #expect(machine.process(.summarizeRequested(at: at(10))) == [.status(.preparingRecap, until: nil), .generateRecap])
        machine.process(.excerptReady(at: at(10.1)))
        #expect(machine.process(.recapReady(summary, at: at(16))) == [.save(summary, isContinuing: false),
                                                                    .status(.summarySaved, until: at(24))])
        #expect(machine.phase == .summaryAvailable)
    }

    /// Summarize is not a toggle: it never stops a followed conversation and never restarts a
    /// summary that is being written.
    @Test func summarizeNeverStopsAnything() {
        var machine = ready()
        machine.process(.summarizeRequested(at: at(10)))
        #expect(machine.process(.summarizeRequested(at: at(10.5))).isEmpty)
        machine.process(.excerptReady(at: at(10.6)))
        #expect(machine.process(.summarizeRequested(at: at(11))).isEmpty)
        machine.process(.recapReady(summary, at: at(16)))
        machine.process(.continueSelected(at: at(20)))
        #expect(machine.phase == .continuing)
        #expect(machine.process(.summarizeRequested(at: at(30))).isEmpty)
        #expect(machine.phase == .continuing)
    }

    /// Acceptance tests 8, 9 and 10.
    @Test func continueFollowsAndStopEndsOnlyTheConversation() {
        var machine = ready()
        machine.process(.summarizeRequested(at: at(10)))
        machine.process(.recapReady(summary, at: at(16)))
        #expect(machine.process(.continueSelected(at: at(20))) == [.save(summary, isContinuing: true), .status(.continuing, until: nil)])
        #expect(machine.continuedSince == at(20))
        let stopped = machine.process(.stopSelected(at: at(90)))
        #expect(stopped == [.finalize, .clearTemporaryContext, .status(.stopped, until: at(98))])
        #expect(machine.phase == .idle)
        // The machine was not told that listening stopped: it still is, and a new summary can be asked for.
        #expect(machine.isListening)
        #expect(machine.process(.summarizeRequested(at: at(200))).contains(.generateRecap))
    }

    @Test func stopDoesNothingUnlessAConversationIsFollowed() {
        var machine = ready()
        #expect(machine.process(.stopSelected(at: at(1))).isEmpty)
        machine.process(.summarizeRequested(at: at(10)))
        #expect(machine.process(.stopSelected(at: at(11))).isEmpty)
        #expect(machine.phase == .preparing)
    }

    /// Acceptance test 11: the listening switch ends everything and keeps what was saved.
    @Test func turningListeningOffFinalizesAFollowedConversation() {
        var machine = ready()
        machine.process(.summarizeRequested(at: at(10)))
        machine.process(.recapReady(summary, at: at(16)))
        machine.process(.continueSelected(at: at(20)))
        let effects = machine.process(.listeningStopped(at: at(60)))
        #expect(effects.contains(.finalize))
        #expect(effects.contains(.clearTemporaryContext))
        #expect(machine.phase == .idle)
        #expect(!machine.isListening)
    }

    @Test func withoutTranscriptionTheRequestExplainsThatPastSpeechIsGone() {
        var machine = ConversationSessionMachine(policy: .product)
        machine.setListening(true)
        let effects = machine.process(.summarizeRequested(at: at(5)))
        #expect(effects == [.unavailable(.contextNotAllowed), .status(.unavailable, until: at(13))])
        #expect(RecapUnavailableReason.contextNotAllowed.message.contains("cannot be recovered"))
        #expect(machine.phase == .idle)
        // The notice ends by itself.
        #expect(machine.nextDeadline == at(13))
        #expect(machine.process(.tick(at: at(13))) == [.status(nil, until: nil)])
    }

    /// Too little was said, or the model could not write a summary: nothing is invented and
    /// nothing is saved.
    @Test func aRequestWithoutASummaryIsNotSavedAndNotContinued() {
        for source in [ConversationRecap.Source.insufficientContext, .unavailable] {
            var machine = ready()
            machine.process(.summarizeRequested(at: at(10)))
            let note = ConversationRecap(title: "", summary: "Not enough was said.", source: source)
            let effects = machine.process(.recapReady(note, at: at(12)))
            #expect(effects == [.noSummary(note), .status(.unavailable, until: at(20))])
            #expect(machine.phase == .idle)
            #expect(machine.recap == nil)
            #expect(machine.process(.continueSelected(at: at(13))).isEmpty)
        }
    }
}

/// Acceptance tests 7 and 17: the summary's input is the authorized last two minutes, held in memory.
@Suite struct Window7BufferTests {
    @Test func theProductBufferLooksBackTwoMinutes() {
        #expect(ConversationBufferPolicy.standard.lookBack == 120)
        #expect(ConversationBufferPolicy.standard.retention <= 135)
        #expect(ConversationBufferPolicy.standard.maximumUtterances <= 80)
        #expect(ConversationBufferPolicy.standard.maximumCharacters <= 6000)
    }

    @Test func anExcerptHoldsOnlyWhatWasSaidInTheLastTwoMinutes() {
        var buffer = RollingConversationBuffer(policy: .standard)
        buffer.begin(at: at(0))
        // One sentence every 10 s for five minutes, each one numbered.
        for index in 0 ..< 30 {
            let start = Double(index) * 10
            buffer.append(said("Sentence number \(index) of the talk.", start, start + 4), now: at(start + 4))
        }
        let now = at(300)
        buffer.prune(now: now)
        let excerpt = buffer.excerpt(now: now)
        #expect(!excerpt.utterances.isEmpty)
        for utterance in excerpt.utterances {
            #expect(utterance.end >= now.addingTimeInterval(-120))
        }
        #expect(excerpt.utterances.first?.text == "Sentence number 18 of the talk.")
        // Older text is not only left out of the excerpt: it is gone from memory.
        #expect(buffer.utterances.allSatisfy { $0.end >= now.addingTimeInterval(-135) })
        #expect(buffer.expiredUtterances >= 16)
    }

    @Test func nothingIsKeptBeforeTranscriptionWasAllowed() {
        var buffer = RollingConversationBuffer(policy: .standard)
        // Not begun: the user has not allowed it.
        buffer.append(said("This was said before the switch was turned on.", 0, 4), now: at(4))
        buffer.setTentative("and this too")
        #expect(buffer.isEmpty)
        buffer.begin(at: at(60))
        buffer.append(said("This was said after it was turned on.", 61, 65), now: at(65))
        let excerpt = buffer.excerpt(now: at(70))
        #expect(excerpt.utterances.map(\.text) == ["This was said after it was turned on."])
    }

    @Test func itEmptiesItselfWhenNobodySpeaksAndWhenCleared() {
        var buffer = RollingConversationBuffer(policy: .standard)
        buffer.begin(at: at(0))
        buffer.append(said("We meet on Saturday at ten.", 1, 4), now: at(4))
        #expect(buffer.nextExpiry == at(4 + 135))
        buffer.prune(now: at(140))
        #expect(buffer.utterances.isEmpty)
        buffer.append(said("Another sentence.", 150, 152), now: at(152))
        buffer.clear()
        #expect(buffer.isEmpty)
        #expect(buffer.collectingSince == nil)
    }

    @Test func theBoundsHoldWhateverIsSaid() {
        var buffer = RollingConversationBuffer(policy: .standard)
        buffer.begin(at: at(0))
        let long = String(repeating: "word ", count: 60)
        for index in 0 ..< 400 {
            let start = Double(index) * 0.25
            buffer.append(said("\(index) \(long)", start, start + 0.2), now: at(start + 0.2))
        }
        #expect(buffer.utterances.count <= 80)
        #expect(buffer.characterCount <= 6000)
    }
}

/// Acceptance test 17: a saved summary never becomes a saved transcript.
@Suite struct Window7VerbatimTests {
    private let spoken = [
        "One more thing, the report is due next Wednesday, not Monday.",
        "And the teacher said it has to be at least six pages.",
        "Fine, then let's split it, three pages each.",
    ]

    @Test func sentencesCopiedFromTheTranscriptAreRemovedFromASummary() {
        let draft = RecapDraft(title: "Report deadline",
                               summary: "Someone said the report is due next Wednesday and not Monday. "
                                   + "And the teacher said it has to be at least six pages. Fine, then let's split it, three pages each.",
                               keyPoints: ["The report is due next Wednesday.", "One more thing, the report is due next Wednesday, not Monday."])
        // The rule of Window 7, with short copies switched off (the default keeps them: `ShortCopyTests`).
        let result = RecapValidator(keptCopyMaximumWords: 0).validate(draft, transcript: spoken.joined(separator: "\n"))
        #expect(result.summary == "Someone said the report is due next Wednesday and not Monday.")
        #expect(result.keyPoints == ["The report is due next Wednesday."])
        #expect(result.corrections.filter { $0 == "copied_from_transcript" }.count == 3)
        for sentence in spoken {
            #expect(!result.summary.contains(sentence))
        }
    }

    @Test func restatingTheEarlierRecapIsNotACopy() {
        let earlier = "They agreed to meet on Saturday at ten in room 204."
        let draft = RecapDraft(title: "Plans", summary: earlier + " Someone said the report is due next Wednesday.", keyPoints: [])
        let result = RecapValidator().validate(draft, transcript: spoken.joined(separator: "\n"), earlierText: earlier)
        #expect(result.summary == draft.summary)
        #expect(result.corrections.isEmpty)
    }

    /// What the on-device model did in the Simulator: the new utterances appended unchanged.
    @Test func anUpdateThatOnlyAppendsTheTranscriptChangesNothing() async {
        let earlier = "They agreed to meet on Saturday at ten in room 204. The graphs have to be finished by Friday night."
        let previous = ConversationRecap(title: "Chemistry project", summary: earlier, source: .languageModel, coveredTo: at(10))
        let copying = ScriptedSummarizer(update: RecapDraft(title: "Chemistry project",
                                                            summary: earlier + " " + spoken.joined(separator: " "), keyPoints: []))
        let new = spoken.enumerated().map { said($0.element, 20 + Double($0.offset) * 5, 23 + Double($0.offset) * 5) }
        // Short copies off (Window 7): nothing is added.
        let strict = ConversationRecapEngine(summarizer: copying, validator: RecapValidator(keptCopyMaximumWords: 0))
        #expect(await strict.update(previous, earlierTranscript: "we meet on saturday at ten in room 204", new: new) == nil)
        // Short copies on (2026-10-12): three spoken sentences in a row are never all kept.
        let engine = ConversationRecapEngine(summarizer: copying)
        let updated = await engine.update(previous, earlierTranscript: "we meet on saturday at ten in room 204", new: new)
        #expect(spoken.filter { (updated?.summary ?? "").contains($0) }.count <= 1)

        // The same new speech, restated: the update is kept and holds no utterance word for word.
        let restating = ScriptedSummarizer(update: RecapDraft(
            title: "Chemistry project",
            summary: earlier + " Someone said the report is due next Wednesday, not Monday, and must be at least six pages.",
            keyPoints: []))
        let better = await ConversationRecapEngine(summarizer: restating)
            .update(previous, earlierTranscript: "we meet on saturday at ten in room 204", new: new)
        #expect(better?.summary.contains("at least six pages") == true)
        for sentence in spoken {
            #expect(better?.fullText.contains(sentence) == false)
        }
    }
}
