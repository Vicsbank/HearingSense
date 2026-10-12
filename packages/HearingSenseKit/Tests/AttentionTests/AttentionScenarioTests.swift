import Attention
import AttentionReplay
import Foundation
import HearingSenseDomain
import Testing

/// The eighteen scripted scenes of the Window 4 test plan, replayed through the production
/// engine. Expectations are stated per mode.
@Suite struct AttentionScenarioTests {
    // 1
    @Test(arguments: AttentionMode.allCases)
    func continuousRainNeverAlertsTwice(mode: AttentionMode) {
        let result = run(ScenarioLibrary.continuousRain, mode)
        #expect(result.alerts.count == (mode == .sensitive ? 1 : 0))
        #expect(result.alerts(for: result.key(named: "rain resumes after 17 s")).isEmpty)
        if mode == .sensitive {
            let show = result.alerts[0].decision
            #expect(show.event.priority == .low)
            #expect(show.intent?.interruption == PresentationInterruption.none)
            // Shown for a while, then taken down although the rain goes on; never shown again.
            #expect(result.decisions.contains { $0.decision.action == .expire && $0.decision.reasons == [.presentationTimeout] })
        } else {
            #expect(result.decisions.allSatisfy { $0.decision.action == .suppress })
            #expect(result.decisions.allSatisfy { $0.decision.reasons.contains(.ambientSound) })
        }
    }

    // 2
    @Test(arguments: AttentionMode.allCases)
    func repeatedMusicAndItsLyricsStaySilent(mode: AttentionMode) {
        let result = run(ScenarioLibrary.repeatedMusic, mode)
        #expect(result.alerts.isEmpty)
        #expect(result.intents.isEmpty)
        let music = result.decisions(for: "sound-1")
        #expect(music.first?.decision.reasons == [.musicContext, .lowRelevance])
        #expect(music.first?.decision.event.priority == .ambient)
        // "watch out for my love" was sung: lyrics, not a warning.
        let lyrics = result.decisions(for: result.key(named: "lyrics in song 1"))
        #expect(lyrics.allSatisfy { $0.decision.action == .suppress })
        #expect(lyrics.last?.decision.reasons.contains(.possiblyLyrics) == true)
    }

    // 3
    @Test(arguments: AttentionMode.allCases)
    func carHornDuringRainIsShown(mode: AttentionMode) throws {
        let result = run(ScenarioLibrary.carHornDuringRain, mode)
        let horn = try #require(result.alerts(for: result.key(named: "car horn")).first)
        #expect(horn.decision.action == .show)
        #expect(horn.decision.event.priority == .high)
        #expect(horn.decision.reasons.contains(.safetyRelevant))
        #expect(horn.decision.reasons.contains(.newEvent))
        #expect(horn.engineDelay == 0)
        #expect(result.alerts(for: result.key(named: "rain")).count == (mode == .sensitive ? 1 : 0))
    }

    // 4
    @Test(arguments: AttentionMode.allCases)
    func repeatedHornsUpdateAndIndependentHornsAlert(mode: AttentionMode) {
        let result = run(ScenarioLibrary.repeatedAndIndependentHorns, mode)
        #expect(result.metrics.importantRetained == 3)
        #expect(result.metrics.duplicatesSuppressed == 3)
        #expect(result.alerts.count == 3)
        // Three bursts, three episodes.
        #expect(Set(result.alerts.map(\.decision.event.id)).count == 3)
        let repeated = result.decisions(for: result.key(named: "same burst, 4 s later"))
        #expect(repeated.first?.decision.action == .update)
        #expect(repeated.first?.decision.intent?.interruption == PresentationInterruption.none)
        #expect(repeated.first?.decision.reasons.contains(.repeatedEvent) == true)
        #expect(repeated.first?.decision.event.subtitle == "Repeated 2 times")
        #expect(repeated.first?.decision.event.id == result.alerts[0].decision.event.id)
    }

    // 5
    @Test(arguments: AttentionMode.allCases)
    func sirensAreNeverHeldBack(mode: AttentionMode) throws {
        let result = run(ScenarioLibrary.sirenDuringCooldown, mode)
        for name in ["siren 1", "siren 2, a minute after the first ended"] {
            let siren = try #require(result.alerts(for: result.key(named: name)).first)
            #expect(siren.decision.event.priority == .urgent)
            #expect(siren.decision.intent?.interruption == .timeSensitive)
            #expect(siren.engineDelay == 0)
        }
        #expect(Set(result.alerts.filter { $0.decision.event.kindID == "siren" }.map(\.decision.event.id)).count == 2)
        if mode == .quiet {
            // The budget of two was used up by the phone and the knock.
            let first = try #require(result.alerts(for: result.key(named: "siren 1")).first)
            #expect(first.decision.reasons.contains(.rateLimitBypassed))
            #expect(result.alerts(for: result.key(named: "bicycle bell")).first?.decision.reasons.contains(.rateLimitBypassed) == true)
        }
        // The second dog comes during the first one's cooldown (or dogs are ambient in Quiet).
        #expect(result.alerts(for: result.key(named: "dog again within its cooldown")).isEmpty)
        if mode == .sensitive {
            let dog = result.decisions(for: result.key(named: "dog again within its cooldown"))
            #expect(dog.first?.decision.reasons.contains(.cooldownActive) == true)
        }
    }

    // 6
    @Test(arguments: AttentionMode.allCases)
    func knockThenSpeechIsOneEvolvingEpisode(mode: AttentionMode) throws {
        let result = run(ScenarioLibrary.knockFollowedBySpeech, mode)
        #expect(result.alerts.count == 1)
        #expect(Set(result.intents.map(\.id)).count == 1)
        #expect(result.intents.map(\.action) == [.present, .update, .update, .dismiss, .dismiss])
        #expect(result.metrics.fusions == 1)

        let summary = try #require(result.decisions.last { $0.decision.action == .update }?.decision)
        #expect(summary.event.isFused)
        #expect(summary.event.title == "Door or knock")
        #expect(summary.event.subtitle == "Nearby speech afterwards")
        #expect(summary.reasons.contains(.temporalFusion))
        #expect(summary.reasons.contains(.summaryAdded))
        #expect(summary.intent?.interruption == PresentationInterruption.none)
        // The summary is carried separately from the lock-screen text.
        #expect(summary.intent?.privateDetail == "Package Arrived")
        #expect(summary.intent?.hasPrivateDetail == true)
        #expect(!(summary.event.title + (summary.event.subtitle ?? "")).contains("Package"))
        // Both source events keep their own timestamps.
        #expect(summary.event.sources.count == 2)
        #expect(summary.event.sources[0].firstObserved < summary.event.sources[1].firstObserved)
    }

    // 7
    @Test(arguments: AttentionMode.allCases)
    func speechThatWasAlreadyGoingOnIsNotAttachedToAKnock(mode: AttentionMode) throws {
        let result = run(ScenarioLibrary.unrelatedSpeechNearKnock, mode)
        #expect(result.metrics.fusions == 0)
        let knock = try #require(result.alerts(for: result.key(named: "door knock")).first?.decision)
        #expect(knock.action == .show)
        #expect(!knock.event.isFused)
        #expect(knock.event.subtitle == nil)
        let last = try #require(result.decisions(for: result.key(named: "door knock")).last?.decision)
        #expect(last.event.sources.count == 1)
        if mode != .quiet {
            #expect(Set(result.alerts.map(\.decision.event.id)).count == 2)
        }
    }

    // 8
    @Test(arguments: AttentionMode.allCases)
    func withTranscriptionOffSpeechIsNeverAnEpisode(mode: AttentionMode) {
        // Changed after the Window 5 device session (was: two generic "Nearby Speech" alerts in
        // Balanced and Sensitive). Speech with nothing to read is an ordinary sound; the island
        // shows the classifier's speech event as an icon.
        let result = run(ScenarioLibrary.transcriptionDisabled, mode)
        #expect(result.alerts.isEmpty)
        #expect(result.intents.isEmpty)
        #expect(result.metrics.duplicatesSuppressed == result.metrics.duplicateSources)
        let explained = result.decisions.map(\.decision).filter { $0.action == .suppress }
        #expect(!explained.isEmpty)
        for decision in explained {
            #expect(decision.event.title == "Nearby Speech")
            #expect(decision.event.priority == .ambient)
            #expect(decision.reasons.contains(.speechWithoutSummary))
        }
        #expect(explained.contains { $0.reasons.contains(.transcriptionOff) })
        #expect(result.decisions.allSatisfy { $0.decision.event.privateContent == nil })
    }

    // 9
    @Test(arguments: AttentionMode.allCases)
    func lyricsAreNotWarningsButASpokenWarningOverMusicIs(mode: AttentionMode) throws {
        let result = run(ScenarioLibrary.possibleLyrics, mode)
        #expect(result.alerts(for: result.key(named: "sung: watch out")).isEmpty)
        #expect(result.alerts(for: result.key(named: "sung: fire")).isEmpty)
        let spoken = try #require(result.alerts(for: result.key(named: "spoken over music: watch out")).first?.decision)
        #expect(spoken.event.title == "Possible Spoken Warning")
        // Over music the reading is less certain: shown, one level lower, marked uncertain.
        #expect(spoken.event.priority == .normal)
        #expect(spoken.event.isUncertain)
        #expect(spoken.reasons.contains(.musicAmbiguity))
        #expect(spoken.reasons.contains(.importantSpeech))
        #expect(result.alerts.count == 1)
    }

    // 10
    @Test(arguments: [AttentionMode.balanced, .sensitive])
    func aLateSummaryIsWhatPresentsTheSpeech(mode: AttentionMode) throws {
        // Changed after the Window 5 device session (was: a text-less "Nearby Speech" shown at
        // once, the summary added by a quiet update). Nothing is presented until there is
        // something to read; the episode then starts with its summary.
        let result = run(ScenarioLibrary.lateSummary, mode)
        #expect(result.alerts.count == 1)
        #expect(result.count(.show) == 1)
        #expect(result.count(.update) == 0)
        let shown = try #require(result.decisions.first { $0.decision.action == .show })
        #expect(result.seconds(shown) == 7.5)
        let show = shown.decision
        #expect(show.reasons.contains(.relevantSpeech))
        #expect(show.reasons.contains(.mentionsTimeOrNumber))
        #expect(show.intent?.action == .present)
        #expect(show.intent?.privateDetail == "Biology Test Tomorrow")
        #expect(show.intent?.interruption == .passive)
        #expect(result.intents.first?.action == .present)
        #expect(result.intents.count { $0.action == .present } == 1)
    }

    @Test func lateSummaryInQuietStaysBelowTheThreshold() {
        let result = run(ScenarioLibrary.lateSummary, .quiet)
        #expect(result.alerts.isEmpty)
        #expect(result.intents.isEmpty)
    }

    // 11
    @Test func summaryRevisionsAreComparedByMeaning() throws {
        let result = run(ScenarioLibrary.summaryRevisions, .balanced)
        #expect(result.decisions.map(\.decision.action)
            == [.suppress, .show, .suppress, .update, .defer, .update, .resolve, .expire])
        #expect(Set(result.decisions.map(\.decision.event.id)).count == 1)
        let decisions = result.decisions.map(\.decision)
        // Nothing to read yet.
        #expect(decisions[0].reasons.contains(.speechWithoutSummary))
        #expect(decisions[0].intent == nil)
        // First summary: the episode starts with it.
        #expect(decisions[1].reasons.contains(.negatedStatement))
        #expect(decisions[1].intent?.privateDetail == "Package Has Not Arrived")
        // Reworded: no update, the shown text stays.
        #expect(decisions[2].reasons.contains(.cosmeticRevision))
        #expect(decisions[2].intent == nil)
        #expect(decisions[2].event.privateContent?.text == "Package Has Not Arrived")
        // Reversed: shown at once, with an interruption.
        #expect(decisions[3].reasons.contains(.negationChanged))
        #expect(decisions[3].intent?.privateDetail == "Package Has Now Arrived")
        #expect(decisions[3].intent?.interruption == .passive)
        #expect(result.seconds(result.decisions[3]) == 14)
        // Extended three seconds later: held back, then applied quietly.
        #expect(decisions[4].reasons.contains(.updateRateLimited))
        #expect(decisions[5].intent?.privateDetail == "Package Arrived At Front Door")
        #expect(decisions[5].intent?.interruption == PresentationInterruption.none)
        #expect(result.seconds(result.decisions[5]) == 22)
        #expect(result.alerts.count == 2)
    }

    // 12
    @Test(arguments: AttentionMode.allCases)
    func simultaneousHighPriorityEventsAreAllKept(mode: AttentionMode) {
        let result = run(ScenarioLibrary.simultaneousHighPriority, mode)
        let shows = result.decisions.filter { $0.decision.action == .show }.map(\.decision)
        #expect(shows.map(\.event.kindID) == ["siren", "glass_breaking", "vehicle_horn"])
        #expect(Set(shows.map(\.event.id)).count == 3)
        #expect(shows.allSatisfy { $0.event.priority >= .high })
        // All three within half a second of each other, none deferred.
        #expect(shows.last!.decidedAt.timeIntervalSince(shows.first!.decidedAt) <= 0.5)
        #expect(result.count(.defer) == 0)
        #expect(result.alerts(for: result.key(named: "music")).isEmpty)
    }

    // 13
    @Test(arguments: AttentionMode.allCases)
    func everythingExpiresAndIsCleanedUp(mode: AttentionMode) throws {
        let result = run(ScenarioLibrary.expirationAndCleanup, mode)
        #expect(result.metrics.finalEpisodes == 0)
        #expect(result.snapshot.presented.isEmpty && result.snapshot.tracked.isEmpty && result.snapshot.deferred.isEmpty)
        // The knock: shown, resolved when it ended, expired after its linger.
        #expect(result.actions(for: result.key(named: "door knock")) == [.show, .resolve, .expire])
        // The siren never reported its end: resolved as stale.
        let siren = result.decisions(for: result.key(named: "siren without an end event")).map(\.decision)
        #expect(siren.map(\.action) == [.show, .resolve, .expire])
        #expect(siren[1].reasons == [.sourceStale])
        // The alarm: escalated once, taken down while still sounding, not shown again.
        let alarm = result.decisions(for: result.key(named: "alarm for 150 s")).map(\.decision)
        let escalation = try #require(alarm.first { $0.action == .update })
        #expect(escalation.event.priority == .urgent)
        #expect(escalation.reasons.contains(.persistentSound) && escalation.reasons.contains(.escalated))
        #expect(alarm.filter { $0.action == .show }.count == 1)
        #expect(alarm.contains { $0.action == .expire && $0.reasons == [.presentationTimeout] })
        // Every presented episode got a final dismissal.
        for id in Set(result.intents.map(\.id)) {
            #expect(result.intents.last { $0.id == id }?.action == .dismiss)
        }
    }

    // 14
    @Test(arguments: AttentionMode.allCases)
    func rapidBurstKeepsImportantEventsAndStaysBounded(mode: AttentionMode) {
        let result = run(ScenarioLibrary.rapidBurst, mode)
        #expect(result.metrics.importantRetained == 3)
        #expect(result.metrics.engineAlertsByLabel["irrelevant"] == nil)
        #expect(result.metrics.maximumEpisodes <= AttentionConfiguration.standard.maximumEpisodes)
        #expect(result.metrics.finalEpisodes == 0)
        #expect(result.metrics.engineAlerts < result.metrics.baselineAlerts / 3)
        for name in ["door knock", "horn", "breaking glass"] {
            #expect(result.alerts(for: result.key(named: name)).first?.engineDelay == 0)
        }
    }

    // 15
    @Test func theThreeModesDiffer() {
        let runs = Dictionary(uniqueKeysWithValues: AttentionMode.allCases.map { ($0, run(ScenarioLibrary.modeComparison, $0)) })
        let quiet = runs[.quiet]!, balanced = runs[.balanced]!, sensitive = runs[.sensitive]!
        for result in runs.values { #expect(result.metrics.importantRetained == 5) }
        #expect(quiet.alerts.count < balanced.alerts.count)
        #expect(balanced.alerts.count < sensitive.alerts.count)

        func shown(_ result: ScenarioRun, _ name: String) -> Bool { !result.alerts(for: result.key(named: name)).isEmpty }
        func priority(_ result: ScenarioRun, _ name: String) -> AttentionPriority? {
            result.decisions(for: result.key(named: name)).map(\.decision.event.priority).max()
        }
        // The policy table of the brief.
        #expect([quiet, balanced, sensitive].map { shown($0, "rain") } == [false, false, true])
        #expect([quiet, balanced, sensitive].map { shown($0, "wind") } == [false, false, true])
        #expect([quiet, balanced, sensitive].map { shown($0, "music") } == [false, false, false])
        #expect([quiet, balanced, sensitive].map { shown($0, "dog barking") } == [false, true, true])
        #expect([quiet, balanced, sensitive].map { shown($0, "ordinary speech") } == [false, true, true])
        #expect([quiet, balanced, sensitive].map { priority($0, "door knock") } == [.normal, .high, .high])
        #expect([quiet, balanced, sensitive].map { priority($0, "car horn") } == [.high, .high, .high])
        #expect([quiet, balanced, sensitive].map { priority($0, "emergency siren") } == [.urgent, .urgent, .urgent])
        #expect([quiet, balanced, sensitive].map { priority($0, "glass breaking") } == [.high, .high, .high])
        #expect([quiet, balanced, sensitive].map { priority($0, "important speech") } == [.high, .high, .high])
        #expect([quiet, balanced, sensitive].map { priority($0, "rain") } == [.ambient, .ambient, .low])
    }

    // 16
    @Test func preferenceChangesApplyAtOnce() throws {
        let result = run(ScenarioLibrary.preferenceChanges, .balanced)
        let rain = result.decisions(for: result.key(named: "rain"))
        // Switching to Sensitive at 20 s shows the rain that was already falling.
        let shown = try #require(rain.first { $0.decision.action == .show })
        #expect(result.seconds(shown) == 20)
        #expect(shown.decision.reasons.contains(.preferencesChanged))
        // Muting weather at 30 s takes it down.
        let muted = try #require(rain.first { $0.decision.reasons.contains(.userMuted) })
        #expect(result.seconds(muted) == 30)
        #expect(muted.decision.action == .suppress)
        #expect(muted.decision.intent?.action == .dismiss)

        #expect(result.alerts(for: result.key(named: "dog (Sensitive)")).count == 1)
        let mutedDog = result.decisions(for: result.key(named: "dog while animals are muted"))
        #expect(mutedDog.allSatisfy { $0.decision.action == .suppress && $0.decision.reasons.contains(.userMuted) })
        #expect(result.alerts(for: result.key(named: "door knock (defaults)")).first?.decision.event.priority == .high)
        let warning = result.decisions(for: result.key(named: "warning while speech attention is off"))
        #expect(warning.allSatisfy { $0.decision.action == .suppress })
        #expect(warning.first?.decision.reasons == [.speechAttentionOff])
        let cat = try #require(result.alerts(for: result.key(named: "cat while animals are set to High")).first?.decision)
        #expect(cat.event.priority == .high)
        #expect(cat.reasons.contains(.userPriorityOverride))
    }

    // 17
    @Test(arguments: AttentionMode.allCases)
    func lifecycleTransitionsLeaveNoStaleState(mode: AttentionMode) throws {
        let result = run(ScenarioLibrary.backgroundLifecycle, mode)
        #expect(result.metrics.importantRetained == 4)
        // The classifier stalled: the siren is resolved after the stale timeout, not left forever.
        let stalled = result.decisions(for: result.key(named: "siren when the classifier stalls")).map(\.decision)
        #expect(stalled.map(\.action) == [.show, .resolve, .expire])
        #expect(stalled[1].reasons == [.sourceStale])
        #expect(abs(stalled[1].decidedAt.timeIntervalSince(result.scenario.start) - (11.6 + 20)) < 0.001)
        // The session ended while rain was active.
        let rain = result.decisions(for: result.key(named: "rain until the interruption"))
        if mode == .sensitive {
            let ended = try #require(rain.last?.decision)
            #expect(ended.action == .expire && ended.reasons == [.sessionEnded])
            #expect(ended.intent?.action == .dismiss)
        } else {
            #expect(rain.allSatisfy { $0.decision.action == .suppress })
        }
        // After the restart events are handled as in a fresh session.
        let horn = try #require(result.alerts(for: result.key(named: "horn after the restart")).first?.decision)
        #expect(horn.reasons.contains(.newEvent))
        #expect(result.metrics.finalEpisodes == 0)
    }

    // 18
    @Test(arguments: AttentionMode.allCases)
    func unavailableModelsDegradeGracefully(mode: AttentionMode) throws {
        let result = run(ScenarioLibrary.unavailableModels, mode)
        // No transcriber: generic speech with the reason recorded.
        let noTranscriber = result.decisions(for: result.key(named: "speech, transcriber not supported"))
        #expect(noTranscriber.first?.decision.reasons.contains(.modelUnavailable) == true)
        #expect(noTranscriber.allSatisfy { $0.decision.event.title == "Nearby Speech" })
        // No language model: the phrase rule still works on the transcript, without a summary.
        let warning = try #require(result.alerts(for: result.key(named: "warning, language model unavailable")).last?.decision)
        #expect(warning.event.priority == .high)
        #expect(warning.event.title == "Possible Spoken Warning")
        #expect(warning.reasons.contains(.urgentPhrase))
        #expect(warning.reasons.contains(.modelUnavailable))
        #expect(warning.event.privateContent == nil)
        // The classifier's speech event alone is tracked as speech and explained, not presented.
        let soundOnly = result.decisions(for: result.key(named: "classifier's speech event only"))
        #expect(soundOnly.first?.decision.event.title == "Nearby Speech")
        #expect(soundOnly.first?.decision.event.category == .speech)
        // Without a summary only the possible warning is an episode, in every mode (changed after
        // the Window 5 device session; was 1 / 4 / 5 with text-less "Nearby Speech" episodes).
        #expect(result.alerts.count == 1)
        #expect(result.metrics.finalEpisodes == 0)
    }

    // Baseline, determinism, stability

    @Test func everySceneIsDeterministic() {
        for scenario in ScenarioLibrary.all + [ScenarioLibrary.soak(hours: 0.25)] {
            for mode in AttentionMode.allCases {
                let first = run(scenario, mode).decisions.map(\.decision)
                let second = run(scenario, mode).decisions.map(\.decision)
                #expect(first == second, "\(scenario.id) \(mode.rawValue)")
            }
        }
    }

    @Test(arguments: AttentionMode.allCases)
    func generatedHourKeepsImportantEventsAndBoundedState(mode: AttentionMode) {
        let result = run(ScenarioLibrary.soak(hours: 1), mode)
        let metrics = result.metrics
        #expect(metrics.importantSources >= 10)
        #expect(metrics.importantRetained == metrics.importantSources)
        #expect(metrics.duplicatesSuppressed == metrics.duplicateSources)
        #expect(metrics.engineAlertsByLabel["irrelevant"] == nil)
        #expect(metrics.engineAlertsByLabel["duplicate"] == nil)
        #expect(metrics.engineAlerts < metrics.baselineAlerts)
        #expect(metrics.maximumEpisodes <= 16)
        #expect(metrics.finalEpisodes == 0)
        if mode != .sensitive { #expect(metrics.unnecessaryAlerts == 0) }
    }

    @Test func baselineAlertsOnEveryConfirmedEvent() {
        let result = run(ScenarioLibrary.repeatedAndIndependentHorns, .balanced)
        #expect(result.baseline.count == 6)
        #expect(result.metrics.baselineUnnecessaryAlerts == 3)
        #expect(result.metrics.unnecessaryAlertReduction == 1)
    }
}
