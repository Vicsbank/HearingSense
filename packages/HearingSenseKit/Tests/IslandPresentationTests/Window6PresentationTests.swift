import Attention
import Foundation
import HearingSenseDomain
import IslandPresentation
import Testing

/// Window 6 in the Live Activity: goal matches and recap states arrive as attention intents and
/// go through the Window 5 pipeline unchanged.
@Suite struct Window6PresentationTests {
    @Test func aGoalMatchIsShownWithAGenericTitleAndNeverAsksToExpand() throws {
        var engine = AttentionEngine()
        engine.process(.sessionStarted(at: T.origin))
        let decisions = engine.process(.semantic(SemanticAttentionSignal(
            goalID: UUID(), headline: "exam postponed until Friday", statement: "The exam has been postponed until Friday.",
            date: T.date(5))))
        let intent = try #require(decisions.compactMap(\.intent).first)

        var settings = IslandSettings.default
        settings.showsSpeechSummaries = false
        var driver = IslandDriver(settings: settings)
        driver.send(.intent(intent))
        driver.advance(to: 8)
        let shown = try #require(driver.shown)
        #expect(shown.mode == .attention)
        #expect(shown.symbolName == AttentionEngine.goalMatchSymbol)
        // Speech summaries not allowed: the generic title, not what was said.
        #expect(shown.headline == AttentionEngine.goalMatchTitle)
        #expect(!shown.redactedSummary.localizedCaseInsensitiveContains("exam"))
        // Normal priority: a quiet update, no expansion request.
        #expect(driver.alerts.isEmpty)
    }

    @Test func withSpeechSummariesAllowedTheHeadlineIsShownAsSpeech() throws {
        var engine = AttentionEngine()
        engine.process(.sessionStarted(at: T.origin))
        let intent = try #require(engine.process(.semantic(SemanticAttentionSignal(
            goalID: UUID(), headline: "exam postponed until Friday", statement: "The exam has been postponed until Friday.",
            date: T.date(5)))).compactMap(\.intent).first)
        var settings = IslandSettings.default
        settings.showsSpeechSummaries = true
        var driver = IslandDriver(settings: settings, policy: .window5)
        driver.send(.intent(intent))
        driver.advance(to: 8)
        #expect(driver.shown?.headline == "exam postponed until Friday")
        #expect(driver.shown?.headlineIsSpeech == true)
        // Never in what is logged or exported.
        #expect(driver.shown?.redactedSummary.localizedCaseInsensitiveContains("exam") == false)
        // Window 5's own rule: the first summary of an episode asks for one expansion (which the
        // alert gate grants only if the user turned "Expand for important events" on).
        #expect(driver.alerts.count == 1)
        #expect(driver.alerts.first?.title == AttentionEngine.goalMatchTitle)
    }

    @Test func aRecapStateIsAQuietGenericEpisodeThatIsRemovedWhenDismissed() {
        // The app builds these in ConversationIntelligenceController.statusIntent: category
        // `other`, normal priority, no interruption, no private detail.
        var driver = IslandDriver()
        driver.send(.intent(intent(1_000_001, "Summarizing", priority: .normal, interruption: PresentationInterruption.none,
                                   at: 5, category: .other, subtitle: "Hearing Sense")))
        driver.advance(to: 8)
        #expect(driver.shown?.mode == .attention)
        #expect(driver.shown?.headline == "Summarizing")
        #expect(driver.shown?.headlineIsSpeech == false)
        #expect(driver.alerts.isEmpty)
        driver.send(.intent(intent(1_000_001, "Summarizing", priority: .normal, action: .dismiss,
                                   interruption: PresentationInterruption.none, at: 12, category: .other)))
        driver.advance(to: 20)
        #expect(driver.shown?.mode != .attention)
    }
}
