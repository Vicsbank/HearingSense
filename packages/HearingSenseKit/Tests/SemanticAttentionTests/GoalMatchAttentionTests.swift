import Attention
import Foundation
import HearingSenseDomain
import SemanticEvaluation
import Testing

/// Window 6 → Window 4: accepted goal matches enter the attention engine, which keeps the last
/// word on presentation.
@Suite struct GoalMatchAttentionTests {
    let origin = Date(timeIntervalSince1970: 1_780_000_000)
    let goal = UUID()

    private func signal(_ statement: String, headline: String, at seconds: TimeInterval,
                        urgency: SemanticAttentionSignal.Urgency = .normal, uncertain: Bool = false) -> SemanticAttentionSignal
    {
        SemanticAttentionSignal(goalID: goal, headline: headline, statement: statement, urgency: urgency,
                                isUncertain: uncertain, date: origin.addingTimeInterval(seconds))
    }

    private func engine(_ preferences: AttentionPreferences = .default) -> AttentionEngine {
        var engine = AttentionEngine(preferences: preferences)
        engine.process(.sessionStarted(at: origin))
        return engine
    }

    @Test func aGoalMatchIsShownWithAGenericTitleAndAPrivateHeadline() throws {
        var engine = engine()
        let decisions = engine.process(.semantic(signal("The exam has been postponed until Friday.",
                                                        headline: "exam postponed until Friday", at: 5)))
        let shown = try #require(decisions.first { $0.action == .show })
        #expect(shown.event.title == AttentionEngine.goalMatchTitle)
        #expect(shown.event.kindID == AttentionEngine.goalMatchKindID)
        #expect(shown.event.symbolName == AttentionEngine.goalMatchSymbol)
        #expect(shown.event.priority == .normal)
        #expect(shown.reasons.contains(.goalMatch))
        #expect(shown.intent?.action == .present)
        // The headline is speech-derived: private content only, never in the title or the log line.
        #expect(shown.event.privateContent?.text == "exam postponed until Friday")
        #expect(!shown.summary.localizedCaseInsensitiveContains("exam"))
        #expect(shown.intent?.hasPrivateDetail == true)
    }

    @Test func itExpiresByItselfAndIsForgotten() throws {
        var engine = engine()
        engine.process(.semantic(signal("The exam has been postponed until Friday.", headline: "exam postponed", at: 5)))
        let deadline = try #require(engine.nextDeadline)
        #expect(deadline.timeIntervalSince(origin) > 5)
        let decisions = engine.process(.tick(at: deadline))
        #expect(decisions.contains { $0.action == .expire && $0.intent?.action == .dismiss })
        #expect(engine.snapshot.presented.isEmpty)
        #expect(engine.snapshot.tracked.isEmpty)
        #expect(engine.nextDeadline == nil)
    }

    @Test func aRepeatedAnnouncementIsNotPresentedTwiceButANewOneIs() {
        var engine = engine()
        engine.process(.semantic(signal("The exam has been postponed until Friday.", headline: "exam postponed", at: 5)))
        let repeated = engine.process(.semantic(signal("Reminder, the exam has been postponed until Friday.",
                                                       headline: "exam postponed", at: 65)))
        #expect(!repeated.contains { $0.action == .show })
        #expect(repeated.contains { $0.action == .suppress && $0.reasons.contains(.repeatedStatement) })
        #expect(engine.statistics.semanticRepeats == 1)
        // Another day is another statement.
        let changed = engine.process(.semantic(signal("The exam has been postponed until Monday.",
                                                      headline: "exam postponed until Monday", at: 80)))
        #expect(changed.contains { $0.action == .show })
        // After the repeat window the reminder is presented again.
        let later = engine.process(.semantic(signal("Reminder, the exam has been postponed until Friday.",
                                                    headline: "exam postponed", at: 5 + 400)))
        #expect(later.contains { $0.action == .show })
    }

    @Test func onlyAnUrgentCertainMatchInterrupts() throws {
        var engine = engine()
        let urgent = engine.process(.semantic(signal("Everyone leave through the north exit now.",
                                                     headline: "leave through north exit", at: 5, urgency: .high)))
        let shown = try #require(urgent.first { $0.action == .show })
        #expect(shown.event.priority == .high)
        #expect(shown.intent?.interruption == .active)
        let unsure = engine.process(.semantic(signal("They want the hallway cleared.", headline: "hallway cleared", at: 20,
                                                     urgency: .high, uncertain: true)))
        let second = try #require(unsure.first { $0.action == .show })
        #expect(second.event.priority == .normal)
        #expect(second.event.isUncertain)
    }

    @Test func itIsPresentedInQuietModeBecauseTheUserAskedForIt() {
        var engine = engine(AttentionPreferences(mode: .quiet))
        let decisions = engine.process(.semantic(signal("The exam has been postponed until Friday.",
                                                        headline: "exam postponed", at: 5)))
        #expect(decisions.contains { $0.action == .show })
    }

    @Test func speechAttentionOffSuppressesGoalMatches() {
        var preferences = AttentionPreferences.default
        preferences.speech = .off
        var engine = engine(preferences)
        let decisions = engine.process(.semantic(signal("The exam has been postponed until Friday.",
                                                        headline: "exam postponed", at: 5)))
        #expect(!decisions.contains { $0.action == .show })
        #expect(decisions.contains { $0.reasons.contains(.speechAttentionOff) })
        #expect(engine.snapshot.tracked.isEmpty)
    }

    @Test func clearingSpeechDataRemovesAGoalMatchAndItsText() {
        var engine = engine()
        engine.process(.semantic(signal("The exam has been postponed until Friday.", headline: "exam postponed", at: 5)))
        let decisions = engine.process(.speechDataCleared(at: origin.addingTimeInterval(8)))
        #expect(decisions.contains { $0.intent?.action == .dismiss })
        #expect(engine.snapshot.presented.isEmpty)
        // The memory of what was said is gone as well: the same statement would be new.
        let again = engine.process(.semantic(signal("The exam has been postponed until Friday.",
                                                    headline: "exam postponed", at: 12)))
        #expect(again.contains { $0.action == .show })
    }

    @Test func goalMatchesAreReplayedIdentically() {
        func run() -> [String] {
            var engine = engine()
            var lines: [String] = []
            for (index, text) in ["The exam has been postponed until Friday.", "Attendance now counts toward the final mark.",
                                  "The exam has been postponed until Friday."].enumerated()
            {
                lines += engine.process(.semantic(SemanticAttentionSignal(
                    id: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(index)")!, goalID: goal, headline: "",
                    statement: text, date: origin.addingTimeInterval(Double(index) * 30)))).map(\.summary)
            }
            return lines
        }
        #expect(run() == run())
    }
}

/// The labelled sets themselves.
@Suite struct SemanticDatasetTests {
    @Test func bothSetsLoadAndAreWellFormed() throws {
        for split in SemanticDataset.Split.allCases {
            let dataset = try SemanticDataset.load(split)
            #expect(dataset.items.count >= 80)
            #expect(Set(dataset.items.map(\.id)).count == dataset.items.count)
            let ids = Set(dataset.items.map(\.id))
            for item in dataset.items {
                let goals = Set(SemanticDataset.goals(for: item.profile).map(\.key))
                #expect(!goals.isEmpty, "unknown profile \(item.profile)")
                #expect(Set(item.acceptableGoals).isSubset(of: goals), "\(item.id): unknown goal key")
                #expect(!item.text.isEmpty)
                if item.expected == .relevant { #expect(!item.acceptableGoals.isEmpty, "\(item.id): no goal") }
                if item.expected == .irrelevant { #expect(item.acceptableGoals.isEmpty, "\(item.id): goal on an irrelevant item") }
                if item.expected == .repeat { #expect(item.repeatOf.map(ids.contains) == true, "\(item.id): repeat_of") }
            }
        }
    }

    @Test func theHeldOutSetSharesNoUtteranceWithTheDevelopmentSet() throws {
        let development = Set(try SemanticDataset.load(.dev).items.map { $0.text.lowercased() })
        let heldOut = try SemanticDataset.load(.heldout).items
        #expect(heldOut.allSatisfy { !development.contains($0.text.lowercased()) })
        // And it tests goals the development set never used.
        let profiles = Set(heldOut.map(\.profile))
        #expect(profiles.isSuperset(of: ["traveler", "worker"]))
        #expect(Set(try SemanticDataset.load(.dev).items.map(\.profile)) == ["student"])
    }

    @Test func goalIdentifiersAreStable() {
        let first = SemanticDataset.goals(for: "student").map(\.goal.id)
        #expect(first == SemanticDataset.goals(for: "student").map(\.goal.id))
        #expect(Set(first).count == first.count)
        #expect(Set(first).isDisjoint(with: SemanticDataset.goals(for: "worker").map(\.goal.id)))
    }

    @Test func metricsCountWhatTheySay() throws {
        let dataset = try SemanticDataset.load(.dev)
        // A method that alerts on everything: full recall, every irrelevant item a false alert.
        let all = dataset.items.map {
            SemanticItemOutcome(id: $0.id, alerted: true, verdict: nil, matchedGoal: nil, stage: nil, corrections: [],
                                isNovel: true, score: nil, seconds: 0, modelSeconds: 0)
        }
        let metrics = SemanticEvaluator.metrics(all, dataset: dataset, method: "all")
        #expect(metrics.recall.value == 1)
        #expect(metrics.falseAlertRate.value == 1)
        #expect(metrics.importantMisses.hits == 0)
        #expect(metrics.falseAlertsPerHour == SemanticEvaluator.assumedUtterancesPerHour)
        #expect(metrics.repeatAlerts.hits == metrics.repeatAlerts.total)
        let keyword = SemanticEvaluator.metrics(SemanticEvaluator.runKeyword(dataset), dataset: dataset, method: "keyword")
        #expect((keyword.recall.value ?? 1) < 0.5)
    }
}
