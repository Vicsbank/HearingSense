import Attention
import AttentionReplay
import Foundation
import HearingSenseDomain

/// Drives the production engine directly with synthetic events at explicit times (seconds from
/// a fixed origin). Test-only: production code never fabricates events.
struct EngineDriver {
    static let origin = ScenarioBuilder.origin

    var engine: AttentionEngine
    private(set) var decisions: [AttentionDecision] = []
    private var number = 0

    init(mode: AttentionMode = .balanced, preferences: AttentionPreferences? = nil,
         configuration: AttentionConfiguration = .standard)
    {
        engine = AttentionEngine(configuration: configuration, preferences: preferences ?? AttentionPreferences(mode: mode))
        engine.process(.sessionStarted(at: Self.origin))
    }

    static func date(_ time: TimeInterval) -> Date { origin.addingTimeInterval(time) }

    @discardableResult
    mutating func send(_ input: AttentionInput) -> [AttentionDecision] {
        let produced = engine.process(input)
        decisions += produced
        return produced
    }

    /// Delivers every deadline up to `time`, then a tick at `time`.
    @discardableResult
    mutating func advance(to time: TimeInterval) -> [AttentionDecision] {
        var produced: [AttentionDecision] = []
        while let deadline = engine.nextDeadline, deadline <= Self.date(time) {
            produced += send(.tick(at: deadline))
        }
        produced += send(.tick(at: Self.date(time)))
        return produced
    }

    mutating func sound(_ kindID: String, at time: TimeInterval, quality: EventQuality = .strong,
                        confirmDelay: TimeInterval = 1.6) -> SyntheticSoundEvent
    {
        number += 1
        return SyntheticSoundEvent(kindID: kindID, number: number, start: Self.date(time), quality: quality,
                                   confirmDelay: confirmDelay)
    }

    /// Starts a sound and returns it with the decisions of its confirmation.
    @discardableResult
    mutating func start(_ kindID: String, at time: TimeInterval, quality: EventQuality = .strong)
        -> (event: SyntheticSoundEvent, decisions: [AttentionDecision])
    {
        let event = sound(kindID, at: time, quality: quality)
        return (event, send(.sound(event.started())))
    }

    /// A complete brief sound: confirmed 1.6 s after `time`, ended 2 s after that.
    @discardableResult
    mutating func brief(_ kindID: String, at time: TimeInterval, quality: EventQuality = .strong) -> [AttentionDecision] {
        var (event, produced) = start(kindID, at: time, quality: quality)
        produced += send(.sound(event.ended(at: Self.date(time + 3.6))))
        return produced
    }

    mutating func speech(at time: TimeInterval, transcription: TranscriptionAvailability = .available,
                         model: SemanticModelAvailability = .available) -> SyntheticSpeech
    {
        number += 1
        return SyntheticSpeech(number: number, start: Self.date(time), transcription: transcription, model: model)
    }

    func actions(_ list: [AttentionDecision]? = nil) -> [AttentionAction] { (list ?? decisions).map(\.action) }

    var shows: [AttentionDecision] { decisions.filter { $0.action == .show } }
}

extension ScenarioRun {
    /// Actions of the decisions attributed to one scripted source, in order.
    func actions(for key: String) -> [AttentionAction] { decisions(for: key).map(\.decision.action) }

    func seconds(_ decision: AttributedDecision) -> TimeInterval {
        decision.decision.decidedAt.timeIntervalSince(scenario.start)
    }

    func key(named name: String) -> String {
        scenario.truths.first { $0.name == name }?.key ?? "missing-\(name)"
    }
}

func run(_ scenario: AttentionScenario, _ mode: AttentionMode) -> ScenarioRun {
    AttentionReplayer.run(scenario, preferences: AttentionPreferences(mode: mode))
}
