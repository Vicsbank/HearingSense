import AttentionReplay
import Foundation
import HearingSenseDomain
import IslandPresentation

/// Explicit times (seconds from a fixed origin) for the value types under test. Test-only:
/// production code never fabricates events.
enum T {
    static let origin = ScenarioBuilder.origin
    static func date(_ time: TimeInterval) -> Date { origin.addingTimeInterval(time) }
    static func seconds(_ date: Date) -> TimeInterval { date.timeIntervalSince(origin) }
}

/// A synthetic sound confirmed exactly at `time`.
func sound(_ kindID: String, _ number: Int, at time: TimeInterval, quality: EventQuality = .strong) -> SyntheticSoundEvent {
    SyntheticSoundEvent(kindID: kindID, number: number, start: T.date(time), quality: quality, confirmDelay: 0)
}

/// Drives an `AmbientIconStream` and delivers its deadlines.
struct AmbientDriver {
    var stream: AmbientIconStream
    private(set) var changes: [AmbientIconStream.Change] = []

    init(policy: AmbientIconPolicy = .standard) {
        stream = AmbientIconStream(policy: policy)
        stream.process(.sessionStarted(at: T.origin))
    }

    mutating func send(_ update: AcousticEventUpdate) {
        advance(to: T.seconds(AmbientIconInput.sound(update).date))
        if let change = stream.process(.sound(update)) { changes.append(change) }
    }

    mutating func advance(to time: TimeInterval) {
        while let deadline = stream.nextDeadline, deadline <= T.date(time) {
            if let change = stream.process(.tick(at: deadline)) { changes.append(change) }
        }
        if let change = stream.process(.tick(at: T.date(time))) { changes.append(change) }
    }

    /// (seconds, symbol) of every published change.
    var timeline: [String] {
        changes.map { "\(T.seconds($0.date).formatted()):\($0.icon?.symbolName ?? "-")" }
    }
}

func intent(_ id: Int, _ title: String, priority: AttentionPriority, action: PresentationAction = .present,
            interruption: PresentationInterruption? = nil, at time: TimeInterval, expires: TimeInterval? = nil,
            category: AttentionCategory = .doorAndKnock, subtitle: String? = nil, summary: String? = nil,
            uncertain: Bool = false, reasons: [AttentionReason] = []) -> AttentionPresentationIntent
{
    let event = AttentionEvent(
        id: AttentionEventID(rawValue: id), category: category, kindID: nil, title: title, subtitle: subtitle,
        symbolName: category.systemImage, priority: priority, createdAt: T.date(time), updatedAt: T.date(time),
        isPresented: true, isUncertain: uncertain,
        privateContent: summary.map { AttentionPrivateContent(text: $0, summaryRevision: 1, isNegated: false, isQuestion: false) })
    let suggested: PresentationInterruption = switch priority {
    case .urgent: .timeSensitive
    case .high: .active
    case .normal: .passive
    case .low, .ambient: .none
    }
    return AttentionPresentationIntent(event: event, action: action, interruption: interruption ?? suggested,
                                       timestamp: T.date(time), expiresAt: expires.map(T.date), reasons: reasons)
}

/// Drives an `IslandPipeline` and delivers its deadlines.
struct IslandDriver {
    var pipeline: IslandPipeline
    private(set) var commands: [TimedIslandCommand] = []

    init(settings: IslandSettings = .default, policy: IslandPolicy = .standard, start: Bool = true) {
        pipeline = IslandPipeline(policy: policy, settings: settings)
        if start { send(.sessionStarted(at: T.origin)) }
    }

    @discardableResult
    mutating func send(_ input: IslandInput) -> [IslandCommand] {
        drain(until: input.date)
        return deliver(input)
    }

    @discardableResult
    mutating func advance(to time: TimeInterval) -> [IslandCommand] {
        let before = commands.count
        drain(until: T.date(time))
        deliver(.tick(at: T.date(time)))
        return commands[before...].map(\.command)
    }

    private mutating func drain(until limit: Date) {
        while let deadline = pipeline.nextDeadline, deadline <= limit {
            deliver(.tick(at: deadline))
        }
    }

    @discardableResult
    private mutating func deliver(_ input: IslandInput) -> [IslandCommand] {
        let produced = pipeline.process(input)
        commands += produced.map { TimedIslandCommand(date: input.date, command: $0) }
        return produced
    }

    var shown: IslandContent? { pipeline.shown }
    var updates: [TimedIslandCommand] { commands.filter { if case .update = $0.command { true } else { false } } }
    var alerts: [IslandAlertRequest] { commands.compactMap(\.alert) }
}
