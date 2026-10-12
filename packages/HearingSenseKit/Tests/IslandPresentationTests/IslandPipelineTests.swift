import Attention
import AttentionReplay
import Foundation
import HearingSenseDomain
import IslandPresentation
import Testing

@Suite struct IslandPipelineTests {
    // MARK: - Lifecycle

    @Test func aSessionStartsOneActivityAndItsEndEndsIt() {
        var driver = IslandDriver()
        #expect(driver.commands.map(\.command) == [.start(.listening(since: T.origin))])
        #expect(driver.pipeline.isLive)
        // A second start (resume) does not create a second activity.
        #expect(driver.send(.sessionStarted(at: T.date(5))).isEmpty)
        let end = driver.send(.sessionEnded(at: T.date(10)))
        #expect(end.count == 1)
        if case .end = end[0] {} else { Issue.record("expected an end command") }
        #expect(!driver.pipeline.isLive)
        #expect(driver.pipeline.nextDeadline == nil)
        // Nothing after the end.
        #expect(driver.send(.sound(sound("rain", 1, at: 11).started())).isEmpty)
        #expect(driver.send(.intent(intent(1, "Door or knock", priority: .high, at: 12))).isEmpty)
    }

    @Test func anInterruptionShowsPausedAndKeepsTheActivity() {
        var driver = IslandDriver()
        driver.send(.sound(sound("rain", 1, at: 2).started()))
        driver.send(.intent(intent(1, "Door or knock", priority: .high, at: 3)))
        let paused = driver.send(.sessionPaused(at: T.date(4)))
        #expect(paused == [.update(.paused(since: T.date(4)), alert: nil)])
        // Events that still arrive while paused change nothing.
        #expect(driver.send(.sound(sound("dog", 2, at: 5).started())).isEmpty)
        let resumed = driver.send(.sessionStarted(at: T.date(8)))
        #expect(resumed == [.update(.listening(since: T.origin), alert: nil)])
        #expect(driver.pipeline.statistics.starts == 1)
    }

    @Test func withTheActivityTurnedOffNothingIsSentUntilItIsTurnedOn() {
        var settings = IslandSettings.default
        settings.isEnabled = false
        var driver = IslandDriver(settings: settings)
        driver.send(.sound(sound("rain", 1, at: 1).started()))
        driver.advance(to: 10)
        #expect(driver.commands.isEmpty)
        settings.isEnabled = true
        let commands = driver.send(.settings(settings, at: T.date(11)))
        #expect(commands.count == 1)
        guard case .start(let content) = commands[0] else {
            Issue.record("expected a start command")
            return
        }
        // The sound that has been present is there from the first frame.
        #expect(content.mode == .ambient)
        #expect(content.symbolName == "cloud.rain")
        settings.isEnabled = false
        let off = driver.send(.settings(settings, at: T.date(20)))
        if case .end = off.first {} else { Issue.record("expected an end command") }
    }

    // MARK: - Ambient channel

    @Test func anOrdinarySoundIsAnIconWithoutAnyText() {
        var driver = IslandDriver()
        driver.send(.sound(sound("rain", 1, at: 5).started()))
        let content = driver.shown
        #expect(content?.mode == .ambient)
        #expect(content?.symbolName == "cloud.rain")
        #expect(content?.headline == nil)
        #expect(content?.caption == nil)
        #expect(content?.priority == nil)
        #expect(content?.spokenLabel == "Rain")
        #expect(driver.alerts.isEmpty)
    }

    @Test func ambientIconsCanBeTurnedOff() {
        var settings = IslandSettings.default
        settings.showsAmbientIcons = false
        var driver = IslandDriver(settings: settings)
        driver.send(.sound(sound("rain", 1, at: 5).started()))
        driver.advance(to: 10)
        #expect(driver.shown?.mode == .listening)
        #expect(driver.updates.isEmpty)
    }

    @Test func quietChangesCloseTogetherAreCoalesced() {
        var driver = IslandDriver()
        // 0.4 s after the activity started: too soon for another quiet update.
        #expect(driver.send(.sound(sound("rain", 1, at: 0.4).started())).isEmpty)
        #expect(driver.pipeline.nextDeadline == T.date(1))
        let flushed = driver.advance(to: 1)
        #expect(flushed.count == 1)
        #expect(driver.shown?.symbolName == "cloud.rain")
    }

    @Test func identicalContentIsNotSentAgainExceptAsKeepAlive() {
        var driver = IslandDriver()
        var rain = sound("rain", 1, at: 5)
        driver.send(.sound(rain.started()))
        for time in stride(from: 10.0, through: 590, by: 5) {
            driver.send(.sound(rain.updated(at: T.date(time))))
        }
        #expect(driver.updates.count == 1)
        // Ten minutes without a change: one keep-alive, so the stale date moves on.
        for time in stride(from: 595.0, through: 700, by: 5) {
            driver.send(.sound(rain.updated(at: T.date(time))))
        }
        #expect(driver.updates.count == 2)
        #expect(driver.pipeline.statistics.keepAlives == 1)
        #expect(driver.updates.last?.date == T.date(605))
    }

    // MARK: - Attention channel

    @Test func anAttentionEpisodeTakesTheIslandAndAmbientUpdatesCannotOverwriteIt() {
        var driver = IslandDriver()
        var rain = sound("rain", 1, at: 2)
        driver.send(.sound(rain.started()))
        driver.send(.intent(intent(1, "Door or knock", priority: .high, at: 10, subtitle: "Repeated 2 times")))
        var content = driver.shown
        #expect(content?.mode == .attention)
        #expect(content?.headline == "Door or knock")
        #expect(content?.caption == "Repeated 2 times")
        #expect(content?.priority == .high)
        #expect(content?.ambientSymbolName == "cloud.rain")
        #expect(content?.since == T.date(10))

        // Ordinary sounds come and go underneath.
        var dog = sound("dog", 2, at: 12)
        driver.send(.sound(dog.started()))
        driver.send(.sound(dog.ended(at: T.date(14))))
        driver.send(.sound(rain.updated(at: T.date(15))))
        driver.advance(to: 25)
        for update in driver.updates where update.date >= T.date(10) {
            #expect(update.content.mode == .attention)
            #expect(update.content.headline == "Door or knock")
            #expect(update.content.symbolName == AttentionCategory.doorAndKnock.systemImage)
        }
        #expect(driver.updates.filter { $0.date > T.date(10) }.isEmpty)

        // The episode ends: the island goes back to the ordinary sound that is still there.
        driver.send(.sound(rain.updated(at: T.date(26))))
        driver.send(.intent(intent(1, "Door or knock", priority: .high, action: .dismiss, at: 26)))
        #expect(driver.shown?.mode == .ambient)
        #expect(driver.shown?.symbolName == "cloud.rain")
        #expect(driver.shown?.headline == nil)
    }

    @Test func secondaryDetailsAloneAreNotWorthAnUpdate() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Siren", priority: .urgent, at: 5, category: .emergencySignals)))
        let before = driver.updates.count
        // Ordinary sounds change and a lower-priority episode joins: only the small ambient icon
        // and the "+N more" count of the expanded view would differ.
        var rain = sound("rain", 1, at: 6)
        driver.send(.sound(rain.started()))
        var dog = sound("dog", 2, at: 12)
        driver.send(.sound(dog.started()))
        driver.send(.sound(dog.ended(at: T.date(14))))
        driver.send(.intent(intent(2, "Dog", priority: .normal, at: 15, category: .animals)))
        driver.send(.sound(rain.updated(at: T.date(20))))
        driver.advance(to: 24)
        #expect(driver.updates.count == before)
        #expect(driver.pipeline.statistics.secondaryChangesNotSent > 0)
        #expect(driver.shown?.ambientSymbolName == nil)
        // The next update that is sent anyway carries the current values.
        driver.send(.intent(intent(1, "Siren", priority: .urgent, action: .update, interruption: PresentationInterruption.none,
                                   at: 25, category: .emergencySignals, subtitle: "Still going")))
        #expect(driver.updates.count == before + 1)
        #expect(driver.shown?.ambientSymbolName == "cloud.rain")
        #expect(driver.shown?.additionalCount == 1)
    }

    @Test func aResolvedEpisodeStaysUntilItsExpiryAndCanComeBack() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Siren", priority: .urgent, at: 5, category: .emergencySignals)))
        driver.send(.intent(intent(1, "Siren", priority: .urgent, action: .dismiss, at: 20, expires: 24,
                                   category: .emergencySignals)))
        driver.advance(to: 23.9)
        #expect(driver.shown?.mode == .attention)
        driver.advance(to: 24)
        #expect(driver.shown?.mode == .listening)

        driver.send(.intent(intent(2, "Siren", priority: .urgent, at: 30, category: .emergencySignals)))
        driver.send(.intent(intent(2, "Siren", priority: .urgent, action: .dismiss, at: 40, expires: 44,
                                   category: .emergencySignals)))
        driver.send(.intent(intent(2, "Siren", priority: .urgent, action: .update, interruption: PresentationInterruption.none,
                                   at: 42, category: .emergencySignals)))
        driver.advance(to: 60)
        #expect(driver.shown?.mode == .attention)
    }

    /// The two-channel rule as the student wrote it: ordinary sounds never overwrite "an active
    /// high-priority event or speech summary". A lower-priority episode without a summary is not
    /// protected.
    @Test func aLowerPriorityEpisodeGivesWayToANewerOrdinarySound() {
        var driver = IslandDriver()
        var rain = sound("rain", 1, at: 2)
        driver.send(.sound(rain.started()))
        driver.send(.intent(intent(1, "Dog", priority: .normal, at: 5, category: .animals)))
        #expect(driver.shown?.mode == .attention)
        var sneeze = sound("body_sounds", 2, at: 8)
        driver.send(.sound(sneeze.started()))
        #expect(driver.shown?.mode == .ambient)
        #expect(driver.shown?.symbolName == "lungs")
        #expect(driver.alerts.isEmpty)
        // The engine changes the episode: it is in front again.
        driver.send(.sound(sneeze.ended(at: T.date(9))))
        driver.send(.intent(intent(1, "Dog", priority: .normal, action: .update, at: 20, category: .animals,
                                   subtitle: "Still going")))
        #expect(driver.shown?.mode == .attention)

        // A summary protects an episode, and so does a high priority.
        driver.send(.intent(intent(2, "Nearby Speech", priority: .normal, at: 24, category: .speech,
                                   summary: "Biology Test Tomorrow")))
        driver.send(.sound(sound("bird", 3, at: 26).started()))
        #expect(driver.shown?.headline == "Biology Test Tomorrow")
        driver.send(.intent(intent(2, "Nearby Speech", priority: .normal, action: .dismiss, at: 30, category: .speech)))
        driver.send(.intent(intent(3, "Door or knock", priority: .high, at: 31)))
        driver.send(.sound(sound("cat", 4, at: 33).started()))
        #expect(driver.shown?.headline == "Door or knock")
        _ = rain.ended(at: T.date(40))
    }

    /// Retest on the iPhone: a door episode that the room's speech kept alive held the island for
    /// 48 s and hid a dog. A high-priority episode is protected for a limited time after the
    /// engine last changed it; an urgent one for as long as it is presented.
    @Test func aHighPriorityEpisodeIsProtectedForALimitedTimeAndAnUrgentOneThroughout() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Door or knock", priority: .high, at: 5)))
        driver.send(.sound(sound("dog", 1, at: 15).started()))
        #expect(driver.shown?.headline == "Door or knock")
        driver.advance(to: 26)   // 20 s after the episode's last change the newer dog shows
        #expect(driver.shown?.mode == .ambient)
        #expect(driver.shown?.symbolName == "dog")
        // The engine changes the episode: protected again.
        driver.send(.intent(intent(1, "Door or knock", priority: .high, action: .update, at: 30, subtitle: "Repeated 2 times")))
        driver.send(.sound(sound("bird", 2, at: 32).started()))
        #expect(driver.shown?.headline == "Door or knock")

        var urgent = IslandDriver()
        urgent.send(.intent(intent(1, "Siren", priority: .urgent, at: 5, category: .emergencySignals)))
        urgent.send(.sound(sound("dog", 1, at: 15).started()))
        urgent.advance(to: 120)
        #expect(urgent.shown?.headline == "Siren")
    }

    /// Seen on the iPhone: when an episode left, the icon that took over was replaced 1.0 s later.
    @Test func anIconThatTookOverFromAnEpisodeStaysForTheMinimumDisplayTime() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Door or knock", priority: .high, at: 5)))
        var laughter = sound("laughter", 1, at: 20)
        driver.send(.sound(laughter.started()))
        driver.send(.intent(intent(1, "Door or knock", priority: .high, action: .dismiss, at: 24)))
        #expect(driver.shown?.symbolName == "hs.laugh")
        driver.send(.sound(sound("farm_animal", 2, at: 25).started()))  // 1 s later, a newer sound
        #expect(driver.shown?.symbolName == "hs.laugh")
        driver.advance(to: 27.5)
        #expect(driver.shown?.symbolName == "pawprint")
        let ambientUpdates = driver.updates.filter { $0.date >= T.date(24) }.map { T.seconds($0.date) }
        #expect(ambientUpdates == [24, 27.5])
        _ = laughter.ended(at: T.date(40))
    }

    /// The student's decision after the device session: speech with nothing to read is an
    /// ordinary sound in every mode — an icon, never an episode, never an expansion.
    @Test func nearbySpeechWithoutASummaryIsOnlyAnIcon() {
        var driver = IslandDriver()
        driver.send(.sound(sound("speech", 1, at: 2).started()))
        #expect(driver.shown?.symbolName == "bubble.left.fill")
        let before = driver.commands.count
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, category: .speech)))
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, action: .update, at: 12, category: .speech,
                                   subtitle: "Still going")))
        driver.advance(to: 15)
        #expect(driver.commands.count == before)
        #expect(driver.shown?.mode == .ambient)
        #expect(driver.alerts.isEmpty)
        #expect(driver.pipeline.statistics.speechWithoutSummary == 1)
        #expect(driver.pipeline.presentedCount == 0)
        // A possible spoken warning is high priority: it is an episode and may ask for an expansion.
        driver.send(.intent(intent(2, "Possible Spoken Warning", priority: .high, at: 20, category: .speech, uncertain: true)))
        #expect(driver.shown?.mode == .attention)
        #expect(driver.shown?.headline == "Possible Spoken Warning")
        #expect(driver.alerts.count == 1)
    }

    @Test func aResolvedEpisodeDoesNotComeBackToTheFrontAfterAnotherOne() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Dog", priority: .normal, at: 5, category: .animals)))
        driver.send(.intent(intent(2, "Shouting", priority: .normal, at: 9, category: .distressSounds)))
        #expect(driver.shown?.headline == "Shouting")
        // The dog ended and lingers until 30 s; the shouting episode is gone at 20 s.
        driver.send(.intent(intent(1, "Dog", priority: .normal, action: .dismiss, at: 10, expires: 30, category: .animals)))
        driver.send(.intent(intent(2, "Shouting", priority: .normal, action: .dismiss, at: 20, category: .distressSounds)))
        #expect(driver.shown?.mode == .listening)
        driver.advance(to: 31)
        #expect(driver.commands.filter { $0.date > T.date(20) }.isEmpty)
        // An update of the resolved episode (the sound came back) does bring it to the front.
        driver.send(.intent(intent(3, "Horn", priority: .high, at: 40, category: .vehicleWarnings)))
        driver.send(.intent(intent(3, "Horn", priority: .high, action: .dismiss, at: 42, expires: 60, category: .vehicleWarnings)))
        driver.send(.intent(intent(4, "Nearby Speech", priority: .high, at: 43, category: .speech)))
        driver.advance(to: 47)
        #expect(driver.shown?.headline == "Nearby Speech")
        driver.send(.intent(intent(3, "Horn", priority: .high, action: .update, at: 50, category: .vehicleWarnings,
                                   subtitle: "Repeated 2 times")))
        driver.send(.intent(intent(4, "Nearby Speech", priority: .high, action: .dismiss, at: 51, category: .speech)))
        #expect(driver.shown?.headline == "Horn")
    }

    @Test func anEpisodeIsRemovedAtItsOwnExpiryEvenWithoutADismissal() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Door or knock", priority: .high, at: 5, expires: 17)))
        driver.advance(to: 17)
        #expect(driver.shown?.mode == .listening)
    }

    @Test func theHigherPriorityIsInFrontAndEqualPrioritiesWaitForTheMinimumHold() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Door or knock", priority: .high, at: 5)))
        // Same priority, 1 s later: the first one keeps the island for its minimum hold.
        driver.send(.intent(intent(2, "Breaking glass", priority: .high, at: 6, category: .impacts)))
        #expect(driver.shown?.headline == "Door or knock")
        driver.advance(to: 8)
        #expect(driver.shown?.headline == "Breaking glass")
        #expect(driver.shown?.additionalCount == 1)
        // A higher priority replaces it at once.
        driver.send(.intent(intent(3, "Siren", priority: .urgent, at: 8.5, category: .emergencySignals)))
        #expect(driver.shown?.headline == "Siren")
        #expect(driver.shown?.additionalCount == 2)
        // A lower priority never does.
        driver.send(.intent(intent(4, "Dog", priority: .normal, at: 20, category: .animals)))
        #expect(driver.shown?.headline == "Siren")
        driver.send(.intent(intent(3, "Siren", priority: .urgent, action: .dismiss, at: 30, category: .emergencySignals)))
        #expect(driver.shown?.headline == "Breaking glass")
    }

    @Test func anUncertainEpisodeIsMarkedAsSuch() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Possible Spoken Warning", priority: .high, at: 5, category: .speech, uncertain: true)))
        #expect(driver.shown?.isUncertain == true)
    }

    // MARK: - Speech summaries

    @Test func aSpeechSummaryIsTheHeadlineWhenTheSettingAllowsIt() {
        var driver = IslandDriver()
        // Without a summary the speech is not an episode in the island (see below).
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, category: .speech)))
        #expect(driver.shown?.mode == .listening)
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, action: .update, at: 9, category: .speech,
                                   summary: "Biology Test Tomorrow")))
        #expect(driver.shown?.headline == "Biology Test Tomorrow")
        #expect(driver.shown?.headlineIsSpeech == true)
        #expect(driver.shown?.caption == "Nearby Speech")
        #expect(driver.shown?.spokenLabel == "Nearby Speech")
        #expect(driver.shown?.redactedSummary.contains("Biology") == false)
    }

    @Test func withSummariesOffNoSpokenWordEntersTheContent() throws {
        var settings = IslandSettings.default
        settings.showsSpeechSummaries = false
        var driver = IslandDriver(settings: settings)
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, category: .speech,
                                   summary: "Biology Test Tomorrow")))
        driver.advance(to: 10)
        for command in driver.commands {
            let encoded = String(decoding: try JSONEncoder().encode(command.content), as: UTF8.self)
            #expect(!encoded.contains("Biology"))
            #expect(command.content.headlineIsSpeech == false)
        }
        #expect(driver.shown?.headline == "Nearby Speech")
        // Turning the setting on shows the summary of the episode that is in front.
        settings.showsSpeechSummaries = true
        driver.send(.settings(settings, at: T.date(11)))
        #expect(driver.shown?.headline == "Biology Test Tomorrow")
    }

    // MARK: - Expansion requests

    @Test func anExpansionIsRequestedOncePerEpisodeAndAgainWhenThePriorityRises() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Alarm", priority: .high, at: 5, category: .emergencySignals)))
        #expect(driver.alerts.count == 1)
        #expect(driver.alerts.first?.title == "Alarm")
        // Further updates of the same episode at the same priority stay silent.
        driver.send(.intent(intent(1, "Alarm", priority: .high, action: .update, at: 15, category: .emergencySignals,
                                   subtitle: "Still going")))
        #expect(driver.alerts.count == 1)
        driver.send(.intent(intent(1, "Alarm", priority: .urgent, action: .update, at: 40, category: .emergencySignals,
                                   subtitle: "Still going")))
        #expect(driver.alerts.count == 2)
        #expect(driver.alerts.last?.priority == .urgent)
    }

    @Test func normalAndLowPrioritiesDoNotRequestAnExpansion() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Dog", priority: .normal, at: 5, category: .animals)))
        driver.send(.intent(intent(2, "Rain", priority: .low, at: 20, category: .weather)))
        #expect(driver.alerts.isEmpty)
        #expect(driver.shown?.mode == .attention)
    }

    @Test func theFirstSpeechSummaryRequestsAnExpansionWithoutCarryingTheWords() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, category: .speech)))
        #expect(driver.alerts.isEmpty)
        // The engine delivers a late summary with "no interruption".
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, action: .update,
                                   interruption: PresentationInterruption.none, at: 9, category: .speech,
                                   summary: "Biology Test Tomorrow", reasons: [.relevantSpeech])))
        #expect(driver.alerts.count == 1)
        #expect(driver.alerts[0].title == "Nearby Speech")
        #expect(!driver.alerts[0].body.contains("Biology"))
        // A reworded summary of the same episode does not expand again.
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, action: .update, at: 20, category: .speech,
                                   summary: "Biology Test Is Tomorrow")))
        #expect(driver.alerts.count == 1)

        var settings = IslandSettings.default
        settings.showsSpeechSummaries = false
        var quiet = IslandDriver(settings: settings)
        quiet.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, category: .speech, summary: "Biology Test Tomorrow",
                                  reasons: [.relevantSpeech])))
        #expect(quiet.alerts.isEmpty)

        var policy = IslandPolicy.standard
        policy.alertsOnFirstSummary = false
        var followsEngine = IslandDriver(policy: policy)
        followsEngine.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, category: .speech,
                                          summary: "Biology Test Tomorrow", reasons: [.relevantSpeech])))
        #expect(followsEngine.alerts.isEmpty)
    }

    /// "Do not turn every conversation into an alert": the summary of ordinary conversation is
    /// shown (touch and hold reads it) but does not ask iOS to expand the island.
    @Test func theSummaryOfOrdinaryConversationIsShownWithoutAnExpansionRequest() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, category: .speech,
                                   summary: "Talking About Lunch", reasons: [.ordinarySpeech, .conditionMet])))
        #expect(driver.shown?.mode == .attention)
        #expect(driver.shown?.headline == "Talking About Lunch")
        #expect(driver.alerts.isEmpty)
        #expect(driver.pipeline.statistics.summariesWithoutExpansion == 1)
        // A possible spoken warning with a summary still asks.
        driver.send(.intent(intent(2, "Possible Spoken Warning", priority: .high, at: 20, category: .speech,
                                   summary: "Watch Out", reasons: [.importantSpeech])))
        #expect(driver.alerts.count == 1)
    }

    // MARK: - Reading a summary after its episode (touch and hold)

    /// The student's report: the island never showed a conversation summary. One cause was that
    /// the text existed only while its episode was in front (20–30 s); a touch and hold after
    /// that found "Listening". The latest summary now stays readable for `summaryRecall`.
    @Test func theLatestSummaryStaysReadableAfterItsEpisodeIsOver() throws {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, expires: 35, category: .speech,
                                   summary: "Biology Test Tomorrow", reasons: [.relevantSpeech])))
        #expect(driver.shown?.headline == "Biology Test Tomorrow")
        #expect(driver.shown?.recentSummary == nil)  // not twice
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, action: .dismiss, at: 35, category: .speech)))
        let after = try #require(driver.shown)
        #expect(after.mode == .listening)
        #expect(after.headline == nil)
        #expect(after.recentSummary == "Biology Test Tomorrow")
        #expect(after.recentSummaryDate == T.date(5))
        #expect(after.redactedSummary.contains("Biology") == false)
        // It does not cost updates while it is readable …
        let sent = driver.commands.count
        driver.advance(to: 150)
        #expect(driver.commands.count == sent)
        #expect(driver.shown?.recentSummary == "Biology Test Tomorrow")
        // … and one quiet update removes it when it is stale (120 s after the episode).
        driver.advance(to: 160)
        #expect(driver.commands.count == sent + 1)
        #expect(driver.shown?.recentSummary == nil)
        #expect(driver.shown?.recentSummaryDate == nil)
        #expect(driver.alerts.count == 1)  // the first summary only
    }

    @Test func anOrdinarySoundTakesTheIconAndTheSummaryStaysReadable() throws {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, expires: 60, category: .speech,
                                   summary: "Biology Test Tomorrow", reasons: [.relevantSpeech])))
        // Protected for 20 s, then a newer ordinary sound gets the icon.
        driver.send(.sound(sound("dog", 1, at: 30).started()))
        let shown = try #require(driver.shown)
        #expect(shown.mode == .ambient)
        #expect(shown.symbolName == "dog.fill" || !shown.symbolName.isEmpty)
        #expect(shown.headline == nil)
        #expect(shown.recentSummary == "Biology Test Tomorrow")
    }

    @Test func aNewerSummaryReplacesTheRecalledOne() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, expires: 20, category: .speech,
                                   summary: "Biology Test Tomorrow", reasons: [.relevantSpeech])))
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, action: .dismiss, at: 20, category: .speech)))
        driver.send(.intent(intent(2, "Nearby Speech", priority: .normal, at: 40, expires: 60, category: .speech,
                                   summary: "Bus Leaves At Four", reasons: [.relevantSpeech])))
        #expect(driver.shown?.headline == "Bus Leaves At Four")
        driver.send(.intent(intent(2, "Nearby Speech", priority: .normal, action: .dismiss, at: 60, category: .speech)))
        #expect(driver.shown?.recentSummary == "Bus Leaves At Four")
        #expect(driver.shown?.recentSummaryDate == T.date(40))
        #expect(driver.pipeline.statistics.summariesPresented == 2)
    }

    // MARK: - Privacy of speech-derived text

    @Test func whileTheIPhoneIsLockedNoSpokenWordIsInTheContent() throws {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, expires: 35, category: .speech,
                                   summary: "Biology Test Tomorrow", reasons: [.relevantSpeech])))
        driver.send(.deviceLock(isLocked: true, at: T.date(10)))
        var shown = try #require(driver.shown)
        #expect(shown.mode == .attention)
        #expect(shown.headline == "Nearby Speech")
        #expect(shown.headlineIsSpeech == false)
        #expect(!String(decoding: try JSONEncoder().encode(shown), as: UTF8.self).contains("Biology"))
        // Still locked when the episode ends: nothing is recalled on the Lock Screen either.
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, action: .dismiss, at: 35, category: .speech)))
        shown = try #require(driver.shown)
        #expect(shown.recentSummary == nil)
        #expect(!String(decoding: try JSONEncoder().encode(shown), as: UTF8.self).contains("Biology"))
        #expect(driver.commands.allSatisfy { T.seconds($0.date) < 10 || $0.content.recentSummary == nil })
        // Unlocked inside the recall time: readable again.
        driver.send(.deviceLock(isLocked: false, at: T.date(60)))
        #expect(driver.shown?.recentSummary == "Biology Test Tomorrow")
        // No expansion is requested by any of this.
        #expect(driver.alerts.count == 1)
    }

    @Test func switchingTranscriptionOffRemovesEverySpokenWordAtOnce() throws {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, expires: 20, category: .speech,
                                   summary: "Biology Test Tomorrow", reasons: [.relevantSpeech])))
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, action: .dismiss, at: 20, category: .speech)))
        #expect(driver.shown?.recentSummary != nil)
        driver.send(.speechTextCleared(at: T.date(25)))
        #expect(driver.shown?.recentSummary == nil)
        // Also while the episode is still in front.
        driver.send(.intent(intent(2, "Nearby Speech", priority: .normal, at: 40, expires: 70, category: .speech,
                                   summary: "Bus Leaves At Four", reasons: [.relevantSpeech])))
        driver.send(.speechTextCleared(at: T.date(45)))
        let shown = try #require(driver.shown)
        #expect(!String(decoding: try JSONEncoder().encode(shown), as: UTF8.self).contains("Bus"))
        driver.advance(to: 100)
        #expect(driver.commands.allSatisfy { T.seconds($0.date) < 45 || $0.content.recentSummary == nil })
    }

    @Test func turningSummariesOffOrEndingTheSessionForgetsTheRecalledSummary() {
        var settings = IslandSettings.default
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, expires: 20, category: .speech,
                                   summary: "Biology Test Tomorrow", reasons: [.relevantSpeech])))
        driver.send(.intent(intent(1, "Nearby Speech", priority: .normal, action: .dismiss, at: 20, category: .speech)))
        settings.showsSpeechSummaries = false
        driver.send(.settings(settings, at: T.date(25)))
        #expect(driver.shown?.recentSummary == nil)
        settings.showsSpeechSummaries = true
        driver.send(.settings(settings, at: T.date(30)))
        #expect(driver.shown?.recentSummary == nil)  // forgotten, not hidden

        var second = IslandDriver()
        second.send(.intent(intent(1, "Nearby Speech", priority: .normal, at: 5, expires: 20, category: .speech,
                                   summary: "Biology Test Tomorrow", reasons: [.relevantSpeech])))
        second.send(.sessionEnded(at: T.date(10)))
        second.send(.sessionStarted(at: T.date(15)))
        #expect(second.shown?.recentSummary == nil)
        #expect(second.shown?.mode == .listening)
    }

    /// The real engine and the pipeline together, as the app wires them (synthetic speech
    /// results): the summary becomes the headline with one expansion request, stays readable
    /// after the episode, and is gone at the end.
    @Test func aConversationSummaryTravelsFromTheEngineToTheExpandedIsland() throws {
        let run = IslandReplayer.run(ScenarioLibrary.lateSummary, tail: 200)
        #expect(run.violations.isEmpty)
        let headline = try #require(run.commands.first { $0.content.headline == "Biology Test Tomorrow" })
        #expect(headline.content.mode == .attention)
        #expect(headline.content.headlineIsSpeech)
        #expect(headline.alert != nil)
        #expect(headline.alert?.title.contains("Biology") == false)
        #expect(run.alertRequests == 1)
        #expect(run.commands.contains { $0.content.mode == .listening && $0.content.recentSummary == "Biology Test Tomorrow" })
        #expect(run.commands.last?.content.recentSummary == nil)
        // Nothing was presented for the speech before there was something to read.
        #expect(run.commands.allSatisfy { $0.content.mode != .attention || $0.content.headlineIsSpeech })
    }

    @Test func expansionRequestsAreSpacedOutExceptForUrgentEpisodes() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Door or knock", priority: .high, at: 5)))
        driver.advance(to: 9)
        driver.send(.intent(intent(2, "Breaking glass", priority: .high, at: 9, category: .impacts)))
        #expect(driver.alerts.count == 1)
        #expect(driver.pipeline.statistics.alertRequestsRateLimited == 1)
        driver.send(.intent(intent(3, "Siren", priority: .urgent, at: 10, category: .emergencySignals)))
        #expect(driver.alerts.count == 2)
    }

    @Test func anEpisodeBehindAnotherOneDoesNotRequestAnExpansion() {
        var driver = IslandDriver()
        driver.send(.intent(intent(1, "Siren", priority: .urgent, at: 5, category: .emergencySignals)))
        driver.send(.intent(intent(2, "Door or knock", priority: .high, at: 30)))
        #expect(driver.alerts.count == 1)
        #expect(driver.shown?.headline == "Siren")
    }

    // MARK: - With the real attention engine

    @Test func soundsTheAttentionEngineSuppressesAreStillIcons() {
        var engine = AttentionEngine(preferences: AttentionPreferences(mode: .balanced))
        var driver = IslandDriver()
        _ = engine.process(.sessionStarted(at: T.origin))
        var intents = 0
        for (index, kindID) in ["rain", "wind", "music", "bird"].enumerated() {
            var event = sound(kindID, index + 1, at: Double(index) * 20 + 2)
            let started = event.started()
            intents += engine.process(.sound(started)).compactMap(\.intent).count
            driver.send(.sound(started))
            #expect(driver.shown?.mode == .ambient, "\(kindID) should be an icon")
            #expect(driver.shown?.kindSymbolMatches(kindID) == true)
            let ended = event.ended(at: T.date(Double(index) * 20 + 10))
            intents += engine.process(.sound(ended)).compactMap(\.intent).count
            driver.send(.sound(ended))
            driver.advance(to: Double(index) * 20 + 16)
        }
        #expect(intents == 0)  // Window 4 presented none of them
        #expect(driver.alerts.isEmpty)
        #expect(driver.commands.allSatisfy { $0.content.headline == nil })
    }

    @Test func everyScriptedSceneKeepsThePresentationRulesInEveryMode() {
        for scenario in ScenarioLibrary.all {
            for mode in AttentionMode.allCases {
                let run = IslandReplayer.run(scenario, preferences: AttentionPreferences(mode: mode))
                #expect(run.violations.isEmpty, "\(scenario.id) \(mode): \(run.violations)")
                #expect(run.statistics.starts == 1)
                #expect(run.statistics.ends == 1)
                // An expansion is only ever requested for something Window 4 presented.
                #expect(run.alertRequests <= run.intents)
            }
        }
    }

    @Test func aLongSceneStaysWithinAModestUpdateRate() {
        let scenario = ScenarioLibrary.soak(hours: 1)
        let run = IslandReplayer.run(scenario, preferences: AttentionPreferences(mode: .balanced))
        #expect(run.violations.isEmpty)
        // Bounded by the ambient limit (10 icon changes a minute) plus the engine's own budget;
        // the scripted hour stays far below that bound.
        #expect(run.updatesPerHour < 600)
        #expect(run.statistics.updates > 0)
    }

    @Test func theSameSceneGivesTheSameCommands() {
        let scenario = ScenarioLibrary.knockFollowedBySpeech
        let first = IslandReplayer.run(scenario)
        let second = IslandReplayer.run(scenario)
        #expect(first.commands == second.commands)
    }
}

private extension IslandContent {
    func kindSymbolMatches(_ kindID: String) -> Bool {
        symbolName == SoundSymbolCatalog.kindSymbols[kindID]
    }
}
