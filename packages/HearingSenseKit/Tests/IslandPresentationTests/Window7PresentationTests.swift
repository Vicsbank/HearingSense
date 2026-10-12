import Attention
import AttentionReplay
import Foundation
import HearingSenseDomain
import IslandPresentation
import Testing

/// Window 7: the Live Activity as the product's main interface — one activity per listening
/// session, silent icons, the state of a summary the user asked for, the acoustic scene, and
/// expansion requests for acoustic events only.
@Suite struct Window7PresentationTests {
    private func summarizing(at time: TimeInterval) -> IslandConversation {
        IslandConversation(phase: .summarizing, title: "Summarizing", since: T.date(time))
    }

    private func ready(at time: TimeInterval, _ text: String = "They agreed to meet on Saturday at ten.") -> IslandConversation {
        IslandConversation(phase: .summaryReady, title: "Summary ready", detail: text, since: T.date(time))
    }

    // MARK: - One activity, silent icons

    /// Acceptance tests 4 and 13, and the lifecycle rule: one activity for the whole session.
    @Test func ordinarySoundsChangeTheIconSilentlyInTheOneActivity() {
        var driver = IslandDriver()
        for (index, kind) in ["rain", "dog", "bird", "music", "footsteps", "typing_writing"].enumerated() {
            var event = sound(kind, index + 1, at: Double(index) * 20 + 2)
            driver.send(.sound(event.started()))
            driver.advance(to: Double(index) * 20 + 8)
            driver.send(.sound(event.ended(at: T.date(Double(index) * 20 + 9))))
        }
        driver.send(.conversation(summarizing(at: 130), at: T.date(130)))
        driver.send(.conversation(ready(at: 136), at: T.date(136)))
        driver.send(.conversation(nil, at: T.date(150)))
        driver.advance(to: 200)
        #expect(driver.pipeline.statistics.starts == 1)
        let starts = driver.commands.filter { if case .start = $0.command { true } else { false } }
        #expect(starts.count == 1)
        let ambient = driver.updates.map(\.content).filter { $0.mode == .ambient }
        #expect(Set(ambient.map(\.symbolName)).count >= 4)
        // No ordinary sound asked for anything: the only request is the summary the user asked for.
        let fromEvents = driver.alerts.filter { !$0.isUserRequested }
        #expect(fromEvents.isEmpty)
        #expect(driver.alerts.count == 1)
    }

    @Test func theExpandedPresentationCanNameTheCurrentSound() {
        var driver = IslandDriver()
        driver.send(.sound(sound("rain", 1, at: 2).started()))
        #expect(driver.shown?.mode == .ambient)
        #expect(driver.shown?.spokenLabel.isEmpty == false)
        #expect(driver.shown?.headline == nil)
        #expect(driver.shown?.conversation == nil)
    }

    // MARK: - Scene (secondary)

    @Test func theSceneTravelsWithTheContentAndNeverCausesAnUpdateOfItsOwn() {
        var driver = IslandDriver()
        driver.send(.sound(sound("road_vehicle", 1, at: 2).started()))
        let before = driver.updates.count
        #expect(driver.send(.scene("Traffic nearby", at: T.date(20))).isEmpty)
        driver.advance(to: 24)
        #expect(driver.updates.count == before)
        #expect(driver.pipeline.statistics.secondaryChangesNotSent >= 1)
        // It is in the next update that is sent anyway.
        driver.send(.sound(sound("dog", 2, at: 30).started()))
        #expect(driver.shown?.sceneTitle == "Traffic nearby")
        #expect(driver.shown?.redactedSummary.contains("Traffic nearby") == true)
    }

    // MARK: - A summary the user asked for

    @Test func aRequestedSummaryIsShownAtOnceAndAsksForOneExpansionWhenReady() throws {
        var driver = IslandDriver()
        driver.send(.sound(sound("speech", 1, at: 2).started()))
        // Within the icon channel's quiet interval: an answer to the user is not held back.
        let first = driver.send(.conversation(summarizing(at: 2.3), at: T.date(2.3)))
        #expect(first.count == 1)
        #expect(first.first?.content?.conversation?.phase == .summarizing)
        #expect(first.first?.alert == nil)
        // The sound's icon stays the primary thing.
        #expect(first.first?.content?.mode == .ambient)

        let done = driver.send(.conversation(ready(at: 9), at: T.date(9)))
        let alert = try #require(done.first?.alert)
        #expect(alert.isUserRequested)
        #expect(alert.title == "Summary ready")
        // The request never carries the words.
        #expect(!alert.title.contains("Saturday"))
        #expect(!alert.body.contains("Saturday"))
        #expect(done.first?.content?.conversation?.detail == "They agreed to meet on Saturday at ten.")
        #expect(driver.pipeline.statistics.summaryReadyRequests == 1)
        // The same state again (the summary grew): no second request.
        let again = driver.send(.conversation(ready(at: 9, "They agreed to meet on Saturday at ten, in room 204."), at: T.date(40)))
        #expect(again.first?.alert == nil)
        #expect(driver.alerts.count == 1)
    }

    @Test func theSummaryTextLeavesTheContentWhenLockedWhenNotWantedAndWhenCleared() {
        var driver = IslandDriver()
        driver.send(.conversation(summarizing(at: 1), at: T.date(1)))
        driver.send(.conversation(ready(at: 5), at: T.date(5)))
        #expect(driver.shown?.conversation?.detail != nil)
        #expect(driver.shown?.redactedSummary.contains("Saturday") == false)

        driver.send(.deviceLock(isLocked: true, at: T.date(10)))
        #expect(driver.shown?.conversation?.phase == .summaryReady)
        #expect(driver.shown?.conversation?.detail == nil)
        driver.send(.deviceLock(isLocked: false, at: T.date(20)))
        #expect(driver.shown?.conversation?.detail != nil)

        var settings = IslandSettings.default
        settings.showsSpeechSummaries = false
        driver.send(.settings(settings, at: T.date(30)))
        #expect(driver.shown?.conversation?.detail == nil)
        settings.showsSpeechSummaries = true
        driver.send(.settings(settings, at: T.date(40)))
        #expect(driver.shown?.conversation?.detail != nil)

        // Transcription switched off or "Clear speech data": gone for good.
        driver.send(.speechTextCleared(at: T.date(50)))
        #expect(driver.shown?.conversation?.detail == nil)
        driver.send(.deviceLock(isLocked: false, at: T.date(60)))
        #expect(driver.shown?.conversation?.detail == nil)
    }

    @Test func aLongSummaryIsClippedForTheIsland() {
        var driver = IslandDriver()
        driver.send(.conversation(summarizing(at: 1), at: T.date(1)))
        driver.send(.conversation(ready(at: 5, String(repeating: "word ", count: 200)), at: T.date(5)))
        #expect((driver.shown?.conversation?.detail?.count ?? 0) <= IslandPolicy.standard.maximumSummaryLength)
    }

    @Test func theEndOfTheSessionRemovesTheConversationState() {
        var driver = IslandDriver()
        driver.send(.conversation(IslandConversation(phase: .following, title: "Following the conversation", since: T.date(3)),
                                  at: T.date(3)))
        #expect(driver.shown?.conversation?.phase == .following)
        driver.send(.sessionEnded(at: T.date(10)))
        #expect(!driver.pipeline.isLive)
        driver.send(.sessionStarted(at: T.date(20)))
        #expect(driver.shown?.conversation == nil)
        #expect(driver.shown?.sceneTitle == nil)
    }

    // MARK: - Expansion requests: acoustic events only

    /// Acceptance test 12.
    @Test func aHighestPriorityAcousticEventAsksForAnExpansion() throws {
        var driver = IslandDriver()
        driver.send(.sound(sound("music", 1, at: 1).started()))
        let commands = driver.send(.intent(intent(1, "Siren", priority: .urgent, at: 10, category: .emergencySignals)))
        let alert = try #require(commands.first?.alert)
        #expect(!alert.isUserRequested)
        #expect(alert.priority == .urgent)
        #expect(commands.first?.content?.mode == .attention)
        // The same episode updated: no second request (deduplication).
        driver.send(.intent(intent(1, "Siren", priority: .urgent, action: .update, at: 14, category: .emergencySignals)))
        #expect(driver.alerts.count == 1)
    }

    @Test func aSpeechEpisodeNeverAsksForAnExpansion() {
        var driver = IslandDriver()
        let commands = driver.send(.intent(intent(1, "Possible Spoken Warning", priority: .high, at: 5, category: .speech,
                                                  summary: "watch out behind you", reasons: [.importantSpeech])))
        // It is presented (the engine decided so), silently.
        #expect(commands.first?.content?.mode == .attention)
        #expect(driver.alerts.isEmpty)
        #expect(driver.pipeline.statistics.speechAlertsWithheld == 1)
        driver.send(.intent(intent(1, "Possible Spoken Warning", priority: .high, action: .update, at: 7, category: .speech,
                                   summary: "watch out behind you", reasons: [.importantSpeech])))
        #expect(driver.alerts.isEmpty)
        #expect(driver.pipeline.statistics.speechAlertsWithheld == 1)
    }

    @Test func anEventsRequestHasPrecedenceOverTheSummarys() {
        var driver = IslandDriver()
        driver.send(.conversation(summarizing(at: 1), at: T.date(1)))
        driver.send(.intent(intent(1, "Siren", priority: .urgent, at: 4, category: .emergencySignals)))
        let done = driver.send(.conversation(ready(at: 6), at: T.date(6)))
        // The alarm keeps the island; the summary does not ask on top of it.
        #expect(done.first?.alert == nil)
        #expect(driver.alerts.count == 1)
        #expect(driver.alerts.first?.isUserRequested == false)
    }

    // MARK: - Gate and settings

    @Test func theGateFollowsTheRightSettingForEachKindOfRequest() {
        var settings = IslandSettings.default
        #expect(!settings.expandsForImportantEvents)
        #expect(settings.expandsForSummaries)
        // Defaults: an event never expands by itself; a requested summary may.
        #expect(AlertGate.evaluate(settings: settings, lock: .unlocked, appIsActive: false) == .blocked(.disabledInSettings))
        #expect(AlertGate.evaluate(settings: settings, lock: .unlocked, appIsActive: false, isUserRequested: true) == .send)
        // The lock rule is the same for both.
        settings.expandsForImportantEvents = true
        for requested in [false, true] {
            #expect(AlertGate.evaluate(settings: settings, lock: .locked, appIsActive: false, isUserRequested: requested)
                == .blocked(.deviceLocked))
            #expect(AlertGate.evaluate(settings: settings, lock: .unknown, appIsActive: false, isUserRequested: requested)
                == .blocked(.lockStateUnknown))
        }
        settings.expandsForSummaries = false
        #expect(AlertGate.evaluate(settings: settings, lock: .unlocked, appIsActive: false, isUserRequested: true)
            == .blocked(.disabledInSettings))
        #expect(AlertGate.evaluate(settings: settings, lock: .unlocked, appIsActive: false) == .send)
    }

    @Test func contentAndSettingsOfAnOlderBuildStillDecode() throws {
        let oldSettings = Data(#"{"isEnabled":true,"showsAmbientIcons":true,"expandsForImportantEvents":true,"showsSpeechSummaries":false,"playsAlertSound":false}"#.utf8)
        let settings = try JSONDecoder().decode(IslandSettings.self, from: oldSettings)
        #expect(settings.expandsForImportantEvents)
        #expect(settings.expandsForSummaries)

        var content = IslandContent.listening(since: T.origin)
        let plain = try JSONEncoder().encode(content)
        let decodedPlain = try JSONDecoder().decode(IslandContent.self, from: plain)
        #expect(decodedPlain == content)
        content.conversation = IslandConversation(phase: .following, title: "Following the conversation", detail: "text",
                                                  message: "note", since: T.date(3))
        content.sceneTitle = "Music playing"
        let encoded = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(IslandContent.self, from: encoded)
        #expect(decoded == content)
        // Small enough for an activity's content state (ActivityKit allows 4 KB).
        content.conversation?.detail = String(repeating: "w", count: IslandPolicy.standard.maximumSummaryLength)
        let size = try JSONEncoder().encode(content).count
        #expect(size < 1_500)
    }
}

private extension IslandCommand {
    var content: IslandContent? {
        switch self {
        case .start(let content), .end(let content): content
        case .update(let content, _): content
        }
    }

    var alert: IslandAlertRequest? {
        if case .update(_, let alert) = self { alert } else { nil }
    }
}
