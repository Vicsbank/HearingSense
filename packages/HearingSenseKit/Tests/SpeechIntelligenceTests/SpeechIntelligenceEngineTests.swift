import Foundation
import HearingSenseDomain
import SemanticSummary
import SpeechPipeline
import Testing
@testable import SpeechIntelligence

/// Pipeline logic on a scripted timeline (see TestSupport.swift): synthetic speech, a scripted
/// recognizer and a scripted language model. Deterministic; no real recognition.
@Suite struct SpeechIntelligenceEngineTests {
    static func states(_ results: [SpeechSemanticResult]) -> [SpeechProcessingState] {
        results.map(\.state).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }

    // MARK: - Activation, pre-roll, lifecycle

    @Test func aShortUtteranceIsTranscribedFromItsFirstWordAndSummarized() async throws {
        // Four words from 2.0 s to 3.2 s. The classifier window that first shows speech ends at
        // 2.25 s; the sound detector would confirm the event even later.
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)])
        await harness.start()
        await harness.run(until: 13)
        await harness.stop()

        let results = harness.recorder.results
        let final = try #require(harness.recorder.latestResults.first)
        #expect(harness.recorder.latestResults.count == 1)
        #expect(final.state == .completed && final.level == .summary)
        #expect(final.transcript?.text == "your package has arrived." && final.transcript?.isFinal == true)
        #expect(final.transcript?.quality.rating == .good && final.transcript?.language == "en-US")
        #expect(final.summary?.text == "Your Package Has Arrived" && final.headline == "Your Package Has Arrived")
        #expect(final.utteranceCount == 1 && final.summaryRevision == 1)
        #expect(final.transcriptionAvailability == .available && final.modelAvailability == .available)

        // Transcription started from buffered audio before the trigger, not from "now".
        #expect(harness.transcriber.count.sessionStarts.first == 0)
        #expect(final.latency.preRollUsed == 2.25)
        #expect(final.audioTime.start == 0.75 && final.audioTime.end == 3.2)

        // Lifecycle and partial results.
        #expect(Self.states(results) == [.transcribing, .processing, .summarized, .completed])
        let partials = results.compactMap(\.transcript).filter { !$0.isFinal }.map(\.text)
        #expect(partials.first == "your" && partials.contains("your package has"))
        #expect(zip(results, results.dropFirst()).allSatisfy { $0.revision < $1.revision })
        #expect(Set(results.map(\.id)).count == 1)

        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        #expect(diagnostics.activations == 1 && diagnostics.utterancesEndedByEndpoint == 1)
        #expect(diagnostics.utterancesStarted == 2 && diagnostics.utterancesFinished == 2 && diagnostics.emptyUtterances == 1)
        #expect(diagnostics.finalSegments == 1 && diagnostics.summariesProduced == 1)
        #expect(diagnostics.conversationsStarted == 1 && diagnostics.conversationsCompleted == 1)
        #expect(diagnostics.preRollShortfalls == 0 && diagnostics.overrunFrames == 0)
        #expect(harness.interpreter.requests.map(\.transcript) == ["your package has arrived."])
    }

    @Test func withoutEnoughPreRollTheBeginningOfTheSentenceIsLost() async throws {
        let speech = [SpokenUtterance("your package has arrived", at: 1.6)]
        var tiny = SpeechIntelligenceConfiguration()
        tiny.preRollSeconds = 0.25  // roughly "start transcribing when speech is detected"
        var transcripts: [String] = []
        var shortfalls: [Int] = []
        for configuration in [tiny, .standard] {
            let harness = Harness(speech: speech, configuration: configuration)
            await harness.start()
            await harness.run(until: 12)
            await harness.stop()
            transcripts.append(harness.recorder.latestResults.first?.transcript?.text ?? "")
            shortfalls.append(harness.recorder.sessionDiagnostics.first?.preRollShortfalls ?? -1)
        }
        #expect(transcripts == ["has arrived.", "your package has arrived."])
        #expect(shortfalls == [1, 0])
    }

    @Test func consecutiveUtterancesShareOneSpeechEventAndALongPauseStartsANewOne() async throws {
        let harness = Harness(speech: [
            SpokenUtterance("your package arrived", at: 2.0),
            SpokenUtterance("can you sign here", at: 8.0),
            SpokenUtterance("class starts at noon", at: 40.0),
        ])
        await harness.start()
        await harness.run(until: 60)
        await harness.stop()

        let events = harness.recorder.latestResults
        #expect(events.count == 2 && events[0].id != events[1].id)
        #expect(events.allSatisfy { $0.state == .completed })
        #expect(events[0].utteranceCount == 2 && events[0].summaryRevision == 2)
        #expect(events[0].transcript?.text == "your package arrived. can you sign here.")
        #expect(events[0].summary?.text == "Can You Sign Here")
        #expect(events[1].utteranceCount == 1 && events[1].summary?.text == "Class Starts At Noon")
        // The second utterance is summarized on its own, with the first as context only.
        let requests = harness.interpreter.requests
        #expect(requests.map(\.transcript) == ["your package arrived.", "can you sign here.", "class starts at noon."])
        #expect(requests.map(\.context) == [[], ["your package arrived."], []])
        // No audio is transcribed twice: every recognizer session starts where the previous one stopped.
        let starts = harness.transcriber.count.sessionStarts
        #expect(starts == starts.sorted() && Set(starts).count == starts.count)
    }

    @Test func longSpeechIsSplitIntoBoundedUtterancesWithoutLosingOrRepeatingWords() async throws {
        var configuration = SpeechIntelligenceConfiguration()
        configuration.maximumUtteranceDuration = 2
        configuration.minimumSummaryInterval = 6
        let words = (0 ..< 48).map { "w\($0)" }
        let harness = Harness(speech: [SpokenUtterance(words.joined(separator: " "), at: 2.0, wordDuration: 0.25)],
                              configuration: configuration)
        await harness.start()
        await harness.run(until: 30)
        await harness.stop()

        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        #expect(diagnostics.utterancesEndedByDuration >= 5)
        // Every word reached the language model exactly once, in order.
        let interpreted = harness.interpreter.requests.flatMap { TranscriptText.words(in: $0.transcript) }
        #expect(interpreted == words)
        // Requests closer together than the minimum interval were merged: fewer model calls
        // than recognized segments, and still one speech event.
        #expect(harness.interpreter.requests.count < diagnostics.finalSegments)
        let events = harness.recorder.latestResults
        #expect(events.count == 1 && events[0].state == .completed)
        #expect(events[0].utteranceCount == diagnostics.finalSegments)
        // The transcript kept in the result is bounded.
        #expect(TranscriptText.words(in: events[0].transcript?.text ?? "").count <= 16)
    }

    @Test func aConversationThatRunsTooLongIsCompletedAndANewSpeechEventStarts() async throws {
        var configuration = SpeechIntelligenceConfiguration()
        configuration.maximumUtteranceDuration = 4
        configuration.maximumConversationDuration = 9
        let words = (0 ..< 48).map { "w\($0)" }
        let harness = Harness(speech: [SpokenUtterance(words.joined(separator: " "), at: 2.0, wordDuration: 0.25)],
                              configuration: configuration)
        await harness.start()
        await harness.run(until: 30)
        await harness.stop()

        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        let events = harness.recorder.latestResults
        #expect(events.count == 2 && events.allSatisfy { $0.state == .completed && $0.summary != nil })
        #expect(events.map(\.utteranceCount).reduce(0, +) == diagnostics.finalSegments)
        #expect(harness.interpreter.requests.flatMap { TranscriptText.words(in: $0.transcript) } == words)
        #expect(diagnostics.conversationsStarted == 2 && diagnostics.conversationsCompleted == 2)
    }

    // MARK: - Layered fallback

    @Test func withTranscriptionOffSpeechIsOnlyReportedAsNearbySpeechAndNoAudioIsBuffered() async throws {
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)], transcriptionEnabled: false)
        await harness.start()
        await harness.run(until: 13)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(Self.states(harness.recorder.results) == [.detected, .completed])
        #expect(final.level == .detection && final.headline == "Nearby Speech")
        #expect(final.transcript == nil && final.summary == nil && final.category == .unknown)
        #expect(final.transcriptionAvailability == .disabledByUser)
        #expect(harness.transcriber.count.begins == 0 && harness.interpreter.requests.isEmpty)
        #expect(harness.recorder.capabilities.first?.level == .detection)
        #expect(harness.recorder.activity.allSatisfy { $0.preRoll.framesWritten == 0 && !$0.preRoll.isEnabled })
    }

    @Test func anUnavailableRecognizerFallsBackToDetectionOnly() async throws {
        for availability in [TranscriptionAvailability.unsupportedDevice, .modelNotInstalled("en-US"),
                             .unsupportedLocale("en-US"), .modelDownloading("en-US")]
        {
            var behaviour = ScriptedTranscriber.Behaviour()
            behaviour.availability = availability
            let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)], behaviour: behaviour)
            await harness.start()
            await harness.run(until: 13)
            await harness.stop()
            let final = try #require(harness.recorder.latestResults.first)
            #expect(final.state == .completed && final.level == .detection && final.headline == "Nearby Speech")
            #expect(final.transcriptionAvailability == availability)
            #expect(harness.transcriber.count.begins == 0 && harness.transcriber.count.prepares == 0)
            #expect(harness.recorder.capabilities.first?.transcription == availability)
        }
    }

    @Test func withoutTheLanguageModelTheTranscriptIsTheResult() async throws {
        let interpreter = ScriptedInterpreter(availability: .appleIntelligenceNotEnabled) { _ in
            Issue.record("the model must not be called")
            return ModelInterpretation(headline: "", category: .other)
        }
        let harness = Harness(speech: [SpokenUtterance("can you help me carry these boxes", at: 2.0)],
                              interpreter: interpreter)
        await harness.start()
        await harness.run(until: 14)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(final.state == .completed && final.level == .transcript)
        #expect(final.transcript?.text == "can you help me carry these boxes.")
        #expect(final.summary == nil && final.headline == "Speech Detected")
        #expect(final.category == .request && final.details?.source == .rules && final.details?.isQuestion == true)
        #expect(final.modelAvailability == .appleIntelligenceNotEnabled && final.failure == nil)
        #expect(harness.recorder.capabilities.last?.level == .transcript)
        #expect(Self.states(harness.recorder.results).contains(.summarized))
    }

    @Test func aSummaryThatReversesTheMeaningNeverReachesTheResult() async throws {
        let interpreter = ScriptedInterpreter { _ in ModelInterpretation(headline: "Package Arrived", category: .announcement) }
        let harness = Harness(speech: [SpokenUtterance("your package has not arrived", at: 2.0)], interpreter: interpreter)
        await harness.start()
        await harness.run(until: 14)
        await harness.stop()

        #expect(harness.recorder.results.allSatisfy { $0.summary == nil })
        let final = try #require(harness.recorder.latestResults.first)
        #expect(final.level == .transcript && final.headline == "Speech Detected")
        #expect(final.details?.isNegated == true)
        #expect(final.failure == "Summary rejected by faithfulness checks (negation dropped)")
        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        #expect(diagnostics.summaryFallbacks == 1 && diagnostics.summaryRejections == 2 && diagnostics.modelAttempts == 2)
        #expect(diagnostics.summariesProduced == 0)
    }

    @Test func poorlyRecognizedSpeechIsLabelledUnclearInsteadOfSummarized() async throws {
        var behaviour = ScriptedTranscriber.Behaviour()
        behaviour.confidence = 0.2
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)], behaviour: behaviour)
        await harness.start()
        await harness.run(until: 13)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(final.isUnclear && final.headline == "Speech Unclear" && final.summary == nil)
        #expect(final.transcript?.quality.rating == .poor && final.category == .unknown)
        #expect(harness.interpreter.requests.isEmpty)
        #expect(harness.recorder.sessionDiagnostics.first?.unclearTranscripts == 1)
    }

    // MARK: - Duplicates

    @Test func repeatedFinalsAndRepeatedHeadlinesAreNotPublishedTwice() async throws {
        var behaviour = ScriptedTranscriber.Behaviour()
        behaviour.duplicateFinals = true
        let interpreter = ScriptedInterpreter { _ in ModelInterpretation(headline: "Package Arrived", category: .announcement) }
        let harness = Harness(speech: [SpokenUtterance("your package arrived", at: 2.0),
                                       SpokenUtterance("the package arrived", at: 8.0)],
                              behaviour: behaviour, interpreter: interpreter)
        await harness.start()
        await harness.run(until: 20)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(harness.recorder.latestResults.count == 1)
        #expect(final.utteranceCount == 2 && final.transcript?.text == "your package arrived. the package arrived.")
        // Same headline twice in one conversation: one summary revision for consumers.
        #expect(final.summaryRevision == 1 && final.summary?.text == "Package Arrived")
        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        #expect(diagnostics.duplicateTranscriptsDropped == 2 && diagnostics.finalSegments == 2)
        #expect(diagnostics.duplicateSummariesSuppressed == 1 && diagnostics.summariesProduced == 1)
        #expect(harness.recorder.results.map(\.summaryRevision).max() == 1)
    }

    // MARK: - Sound event association

    @Test func soundDetectorSpeechEventsAreLinkedToTheSpeechEvent() async throws {
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)])
        await harness.start()
        let early = speechEvent(start: 0.75)
        await harness.send(.started(early))  // confirmed before the pipeline's conversation exists
        await harness.run(until: 3)
        #expect(harness.recorder.results.last?.sourceEventIDs == [early.id])

        let shouting = speechEvent(kind: "shouting", start: 2.25)
        await harness.send(.started(shouting))
        await harness.send(.updated(shouting))
        await harness.send(.started(speechEvent(kind: "dog", category: .animals, start: 2.25)))  // not speech
        await harness.send(.ended(early))
        await harness.run(until: 13)
        await harness.stop()
        let final = try #require(harness.recorder.latestResults.first)
        #expect(final.sourceEventIDs == [early.id, shouting.id] && final.state == .completed)
    }

    // MARK: - Music

    @Test func vocalsInMusicDoNotStartTranscriptionButSpeechOverMusicDoes() async throws {
        let harness = Harness(speech: [])
        harness.musicScore = 0.85
        harness.vocalScore = 0.6
        harness.forcedSpeechScore = 0.7
        await harness.start()
        await harness.run(until: 6)
        #expect(harness.transcriber.count.begins == 0 && harness.recorder.results.isEmpty)
        #expect((harness.recorder.activity.last?.diagnostics.windowsSuppressedByMusic ?? 0) > 0)
        #expect(harness.recorder.activity.allSatisfy { !$0.isSpeechActive && $0.evidence.suppressedByMusic })

        harness.forcedSpeechScore = 0.95
        await harness.run(until: 9)
        #expect(harness.transcriber.count.begins == 1 && harness.recorder.activity.last?.isTranscribing == true)
        #expect(harness.recorder.results.last?.state == .transcribing)
        await harness.stop()
    }

    @Test func sustainedSpeechOverMusicIsInterpretedAndFlagged() async throws {
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 6.0)])
        harness.musicScore = 0.8
        harness.speechScoreWhenSpeaking = 0.95
        await harness.start()
        await harness.run(until: 20)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(final.state == .completed && final.transcript?.text == "your package has arrived.")
        #expect(final.summary?.text == "Your Package Has Arrived")
        let context = try #require(final.acousticContext)
        #expect(context.relevance == .speechOverMusic && context.musicShare == 1 && context.strongSpeechShare >= 0.5)
        #expect(!final.isPossiblyMusic)
        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        #expect(diagnostics.utterancesOverMusic == 1 && diagnostics.utterancesPossiblyMusic == 0)
        #expect(diagnostics.modelCallsAvoidedForMusic == 0 && harness.interpreter.requests.count == 1)
    }

    @Test func wordsRecognizedInVocalMusicAreNotInterpretedAsAConversation() async throws {
        // One window scores as strong speech (enough to start transcribing), but over the whole
        // line the speech evidence is sporadic and the recognizer is unsure: probably lyrics.
        var behaviour = ScriptedTranscriber.Behaviour()
        behaviour.confidence = 0.62
        let harness = Harness(speech: [SpokenUtterance("we will rock you tonight baby yeah yeah", at: 6.0)],
                              behaviour: behaviour)
        harness.musicScore = 0.85
        harness.vocalScore = 0.5
        harness.speechScoreWhenSpeaking = 0.6
        await harness.start()
        await harness.run(until: 7.5)
        harness.speechScoreWhenSpeaking = 0.93  // a single strong window
        await harness.run(until: 8.25)
        harness.speechScoreWhenSpeaking = 0.6
        await harness.run(until: 24)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(final.state == .completed && final.level == .transcript)
        #expect(final.headline == "Speech Or Music" && final.isPossiblyMusic && final.summary == nil)
        #expect(final.category == .unknown && final.failure == nil)
        // The transcript is kept so the user can judge; nothing was sent to the language model.
        #expect(final.transcript?.text.isEmpty == false)
        #expect(harness.interpreter.requests.isEmpty)
        let context = try #require(final.acousticContext)
        #expect(context.relevance == .possiblyMusic && context.musicShare == 1 && context.strongSpeechShare < 0.34)
        #expect(context.vocalMusicShare == 1)
        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        #expect(diagnostics.utterancesPossiblyMusic == 1 && diagnostics.modelCallsAvoidedForMusic == 1)
        #expect(diagnostics.semanticRequests == 0 && diagnostics.summariesProduced == 0)
        #expect(Self.states(harness.recorder.results).contains(.summarized))
    }

    @Test func speechAfterLyricsInTheSameConversationIsStillSummarized() async throws {
        var behaviour = ScriptedTranscriber.Behaviour()
        behaviour.confidence = 0.9
        let harness = Harness(speech: [SpokenUtterance("we will rock you tonight", at: 6.0),
                                       SpokenUtterance("your package has arrived", at: 12.0)], behaviour: behaviour)
        harness.musicScore = 0.85
        harness.vocalScore = 0.5
        harness.speechScoreWhenSpeaking = 0.6
        await harness.start()
        await harness.run(until: 6.75)
        harness.speechScoreWhenSpeaking = 0.93
        await harness.run(until: 7.5)
        harness.speechScoreWhenSpeaking = 0.6
        await harness.run(until: 11.5)
        // Now someone really talks: strong speech scores throughout, no vocal label.
        harness.vocalScore = 0
        harness.speechScoreWhenSpeaking = 0.96
        await harness.run(until: 26)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(harness.recorder.latestResults.count == 1 && final.utteranceCount == 2)
        #expect(final.summary?.text == "Your Package Has Arrived")
        #expect(final.acousticContext?.relevance == .speechOverMusic)
        // Only the spoken sentence reached the language model; the lyric line is not even context.
        #expect(harness.interpreter.requests.map(\.transcript) == ["your package has arrived."])
        #expect(harness.interpreter.requests.map(\.context) == [[]])
        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        #expect(diagnostics.utterancesPossiblyMusic == 1 && diagnostics.utterancesOverMusic == 1)
    }

    @Test func aLyricLineAfterSpeechDoesNotReplaceTheSpeechSummary() async throws {
        var behaviour = ScriptedTranscriber.Behaviour()
        behaviour.confidence = 0.9
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 6.0),
                                       SpokenUtterance("we will rock you tonight", at: 12.0)], behaviour: behaviour)
        harness.musicScore = 0.85
        harness.speechScoreWhenSpeaking = 0.96  // someone talks over the music
        await harness.start()
        await harness.run(until: 11.5)
        // Then the song's vocals: one strong window, otherwise weak speech scores with a vocal label.
        harness.vocalScore = 0.5
        harness.speechScoreWhenSpeaking = 0.6
        await harness.run(until: 12.75)
        harness.speechScoreWhenSpeaking = 0.93
        await harness.run(until: 13.5)
        harness.speechScoreWhenSpeaking = 0.6
        await harness.run(until: 30)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(final.utteranceCount == 2 && final.state == .completed)
        // The summary, its transcript and its context still describe what was said.
        #expect(final.summary?.text == "Your Package Has Arrived" && final.summaryRevision == 1)
        #expect(final.transcript?.text == "your package has arrived.")
        #expect(final.acousticContext?.relevance == .speechOverMusic && !final.isPossiblyMusic)
        #expect(harness.interpreter.requests.map(\.transcript) == ["your package has arrived."])
        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        #expect(diagnostics.utterancesPossiblyMusic == 1 && diagnostics.modelCallsAvoidedForMusic == 1)
    }

    // MARK: - Cancellation, stale results, privacy cleanup

    @Test func stoppingDiscardsSpeechDataAndDropsResultsThatArriveLate() async throws {
        // A model call that takes 0.3 s and cannot be interrupted.
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)],
                              interpreter: .echo(delay: 0.3, isCancellable: false))
        await harness.start()
        await harness.run(until: 4.75)
        await harness.run(until: 5.0, draining: false)  // end of utterance: final transcript, model request starts
        let interpreter = harness.interpreter
        #expect(await harness.recorder.wait { _ in interpreter.requests.count == 1 })
        #expect(harness.recorder.results.last?.state == .processing)
        let firstID = try #require(harness.recorder.results.last?.id)

        await harness.stop()  // returns after the late model answer was processed (and dropped)
        let outputs = harness.recorder.all
        let endIndex = try #require(outputs.firstIndex { if case .sessionEnded = $0 { true } else { false } })
        #expect(endIndex == outputs.count - 1)
        #expect(harness.recorder.results.allSatisfy { $0.summary == nil && !$0.state.isTerminal })
        #expect(harness.recorder.sessionDiagnostics.first?.summariesProduced == 0)
        // Temporary speech data is gone.
        #expect(harness.engine.audioTap.buffer.status.bufferedSeconds == 0)
        #expect(harness.engine.audioTap.currentTime == 0)
        #expect(harness.transcriber.count.releases == 1 && harness.transcriber.count.cancels >= 1)

        // A new session is unaffected and never revives the old speech event.
        await harness.start()
        await harness.run(until: 13)
        await harness.stop()
        let second = harness.recorder.results.filter { $0.id != firstID }
        #expect(second.last?.state == .completed && second.last?.summary?.text == "Your Package Has Arrived")
        #expect(harness.recorder.results.filter { $0.id == firstID }.allSatisfy { $0.summary == nil })
        #expect(harness.recorder.sessionDiagnostics.count == 2)
    }

    @Test func aRunningModelRequestIsCancelledWhenListeningStops() async throws {
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)],
                              interpreter: .echo(delay: 30))
        await harness.start()
        await harness.run(until: 4.75)
        await harness.run(until: 5.0, draining: false)
        let interpreter = harness.interpreter
        #expect(await harness.recorder.wait { _ in interpreter.requests.count == 1 })
        let started = ContinuousClock.now
        await harness.stop()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(interpreter.cancellations == 1)
        #expect(harness.recorder.results.allSatisfy { $0.summary == nil })
    }

    @Test func switchingTranscriptionOffDiscardsTranscriptsAndStopsBuffering() async throws {
        let harness = Harness(speech: [SpokenUtterance("your package has arrived today", at: 2.0)])
        await harness.start()
        await harness.run(until: 3)
        let transcribing = try #require(harness.recorder.results.last)
        #expect(transcribing.transcript?.text.hasPrefix("your") == true)

        harness.engine.setTranscriptionEnabled(false)
        await harness.engine.drain()
        await harness.recorder.settle()
        #expect(harness.recorder.all.contains { if case .speechDataCleared = $0 { true } else { false } })
        #expect(harness.recorder.capabilities.last?.transcription == .disabledByUser)
        #expect(harness.engine.audioTap.buffer.status.isEnabled == false)
        #expect(harness.engine.audioTap.buffer.status.bufferedSeconds == 0)
        #expect(harness.transcriber.count.cancels == 1)

        // Speech continues: it is now reported as a new, detection-only speech event.
        await harness.run(until: 13)
        let after = try #require(harness.recorder.latestResults.last)
        #expect(after.id != transcribing.id && after.transcript == nil && after.headline == "Nearby Speech")
        #expect(harness.transcriber.count.begins == 1 && harness.interpreter.requests.isEmpty)

        harness.engine.setTranscriptionEnabled(true)
        await harness.engine.drain()
        await harness.recorder.settle()
        #expect(harness.recorder.capabilities.last?.level == .summary)
        await harness.stop()
    }

    @Test func switchingTranscriptionOnAfterSpeechEndedStillCompletesTheOpenSpeechEvent() async throws {
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)], transcriptionEnabled: false)
        await harness.start()
        await harness.run(until: 5)  // speech is over; the detection-only event is still open
        #expect(harness.recorder.results.last?.state == .detected)
        harness.engine.setTranscriptionEnabled(true)
        await harness.engine.drain()
        await harness.run(until: 14)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(harness.recorder.latestResults.count == 1)
        #expect(final.state == .completed && final.level == .detection && final.headline == "Nearby Speech")
        #expect(harness.recorder.capabilities.last?.isTranscriptionEnabled == true)
    }

    // MARK: - Error recovery

    @Test func aRecognizerFailureIsRecoveredWithinTheSameSpeech() async throws {
        var behaviour = ScriptedTranscriber.Behaviour()
        behaviour.failingSessions = [0]
        let harness = Harness(speech: [SpokenUtterance("your package arrived", at: 2.0),
                                       SpokenUtterance("can you sign here", at: 8.0)], behaviour: behaviour)
        await harness.start()
        await harness.run(until: 20)
        await harness.stop()

        let diagnostics = try #require(harness.recorder.sessionDiagnostics.first)
        #expect(diagnostics.transcriptionFailures == 1)
        #expect(diagnostics.lastTranscriptionFailure == "scripted recognizer failure")
        let final = try #require(harness.recorder.latestResults.first)
        // The words after the failure are still recognized by the restarted recognizer.
        #expect(final.state == .completed && final.transcript?.text == "arrived. can you sign here.")
        #expect(final.summary?.text == "Can You Sign Here" && final.failure == nil)
        #expect(harness.recorder.capabilities.allSatisfy { $0.transcription == .available })
    }

    @Test func repeatedRecognizerFailuresDegradeToDetectionOnlyUntilAvailabilityIsRefreshed() async throws {
        var behaviour = ScriptedTranscriber.Behaviour()
        behaviour.failingBegins = 100
        let harness = Harness(speech: [2.0, 30.0, 60.0, 90.0].map { SpokenUtterance("your package has arrived", at: $0) },
                              behaviour: behaviour)
        await harness.start()
        await harness.run(until: 105)

        let events = harness.recorder.latestResults
        #expect(events.count == 4)
        #expect(events.prefix(3).allSatisfy { $0.state == .failed && $0.failure?.hasPrefix("Transcription failed") == true })
        #expect(events.allSatisfy { $0.level == .detection && $0.headline == "Nearby Speech" })
        // After three failures in a row the recognizer is not tried again.
        #expect(harness.transcriber.count.begins == 3)
        #expect(events[3].state == .completed)
        guard case .failed = harness.recorder.capabilities.last?.transcription else {
            Issue.record("expected transcription to be marked failed")
            return
        }
        #expect(harness.recorder.capabilities.last?.level == .detection)

        harness.engine.refreshAvailability()
        await harness.engine.drain()
        await harness.recorder.settle()
        #expect(harness.recorder.capabilities.last?.transcription == .available)
        await harness.stop()
    }

    @Test func aRecognizerThatNeverFinalizesFallsBackToThePartialText() async throws {
        var behaviour = ScriptedTranscriber.Behaviour()
        behaviour.neverFinishes = true
        var configuration = SpeechIntelligenceConfiguration()
        configuration.finalizationTimeout = 0.05
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)], behaviour: behaviour,
                              configuration: configuration)
        await harness.start()
        await harness.run(until: 13)
        await harness.stop()

        let final = try #require(harness.recorder.latestResults.first)
        #expect(final.state == .completed && final.transcript?.text == "your package has arrived")
        #expect(final.transcript?.quality.rating == .unknown && final.summary?.text == "Your Package Has Arrived")
        // Both recognizer runs hang: the one with the sentence and the silent one after it.
        #expect(harness.recorder.sessionDiagnostics.first?.finalizationTimeouts == 2)
    }

    @Test func aModelFailureKeepsTheTranscriptAndThePipelineRunning() async throws {
        struct ModelCrash: Error {}
        let interpreter = ScriptedInterpreter { request in
            if request.transcript.contains("package") { throw ModelCrash() }
            return ModelInterpretation(headline: "Sign Here", category: .request)
        }
        let harness = Harness(speech: [SpokenUtterance("your package arrived", at: 2.0),
                                       SpokenUtterance("can you sign here", at: 30.0)], interpreter: interpreter)
        await harness.start()
        await harness.run(until: 45)
        await harness.stop()

        let events = harness.recorder.latestResults
        #expect(events.count == 2)
        #expect(events[0].state == .completed && events[0].level == .transcript)
        #expect(events[0].failure == "Language model error: ModelCrash")
        #expect(events[0].transcript?.text == "your package arrived.")
        #expect(events[1].summary?.text == "Sign Here" && events[1].category == .request)
        #expect(harness.recorder.sessionDiagnostics.first?.summaryFallbacks == 1)
    }

    @Test func inputsOutsideASessionAreIgnored() async {
        let harness = Harness(speech: [SpokenUtterance("your package has arrived", at: 2.0)])
        await harness.run(until: 6)  // no startSession()
        await harness.recorder.settle()
        #expect(harness.recorder.all.isEmpty && harness.transcriber.count.begins == 0)
        harness.engine.endSession()  // ending a session that never started emits nothing
        await harness.engine.drain()
        await harness.recorder.settle()
        #expect(harness.recorder.all.isEmpty)
    }
}
