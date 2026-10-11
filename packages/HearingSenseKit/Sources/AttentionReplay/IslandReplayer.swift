import Attention
import Foundation
import HearingSenseDomain
import IslandPresentation

/// One Live Activity command with the time the pipeline produced it.
public struct TimedIslandCommand: Hashable, Sendable {
    public var date: Date
    public var command: IslandCommand

    public init(date: Date, command: IslandCommand) {
        self.date = date
        self.command = command
    }

    public var content: IslandContent {
        switch command {
        case .start(let content), .end(let content), .update(let content, _): content
        }
    }

    public var alert: IslandAlertRequest? {
        if case .update(_, let alert) = command { return alert }
        return nil
    }
}

/// What the Live Activity would have been asked to do during one scripted scene.
public struct IslandReplayRun: Sendable {
    public var scenario: AttentionScenario
    public var mode: AttentionMode
    public var commands: [TimedIslandCommand]
    public var statistics: IslandStatistics
    public var ambient: AmbientIconStatistics
    /// Attention decisions that carried an intent (what Window 4 asked to be presented or changed).
    public var intents: Int
    /// Seconds an attention episode was in front, an ordinary icon was shown, and neither.
    public var secondsAttention: TimeInterval
    public var secondsAmbient: TimeInterval
    public var secondsListening: TimeInterval
    /// Broken presentation rules (empty when the pipeline behaved as specified).
    public var violations: [String]

    public var duration: TimeInterval { secondsAttention + secondsAmbient + secondsListening }

    /// Activity updates (not counting start and end) per hour of the scene.
    public var updatesPerHour: Double {
        duration > 0 ? Double(statistics.updates + statistics.keepAlives) / duration * 3600 : 0
    }

    public var alertRequests: Int { commands.filter { $0.alert != nil }.count }
}

/// Runs the attention engine and the Live Activity pipeline together over a scripted scene, the
/// way the app wires them: sound events go to both, the engine's intents go to the pipeline.
/// Synthetic input only; the numbers describe the rules, not recognition accuracy or what iOS
/// does with the updates.
public enum IslandReplayer {
    public static func run(_ scenario: AttentionScenario, preferences: AttentionPreferences = .default,
                           settings: IslandSettings = .default, policy: IslandPolicy = .standard,
                           tail: TimeInterval = 60) -> IslandReplayRun
    {
        var engine = AttentionEngine(preferences: preferences)
        var pipeline = IslandPipeline(policy: policy, settings: settings)
        var commands: [TimedIslandCommand] = []
        var violations: [String] = []
        var intents = 0
        var seconds: [IslandContent.Mode: TimeInterval] = [:]
        var lastDate = scenario.start

        func record(_ produced: [IslandCommand], at date: Date) {
            for command in produced {
                let timed = TimedIslandCommand(date: date, command: command)
                commands.append(timed)
                let content = timed.content
                if content.mode != .attention, content.headline != nil || content.caption != nil {
                    violations.append("\(scenario.id): text outside an attention episode")
                }
                if timed.alert != nil, content.mode != .attention {
                    violations.append("\(scenario.id): alert request without an attention episode")
                }
                if let alert = timed.alert, content.headlineIsSpeech, let headline = content.headline,
                   alert.title.contains(headline) || alert.body.contains(headline)
                {
                    violations.append("\(scenario.id): alert request contains speech-derived text")
                }
            }
        }

        func advance(to date: Date) {
            let mode = pipeline.shown?.mode ?? .listening
            seconds[mode, default: 0] += max(date.timeIntervalSince(lastDate), 0)
            lastDate = max(lastDate, date)
        }

        func feedPipeline(_ input: IslandInput) {
            advance(to: input.date)
            record(pipeline.process(input), at: input.date)
        }

        func feedEngine(_ input: AttentionInput) {
            for decision in engine.process(input) {
                guard let intent = decision.intent else { continue }
                intents += 1
                feedPipeline(.intent(intent))
            }
            // The rule this window exists for: an episode the engine presents is what is in front.
            // (An episode that has ended and only lingers may have lost the island to a later one
            // and does not get it back.)
            // Protected episodes only (high priority or a speech summary): a lower one gives way to
            // a newer ordinary sound.
            // Checked for urgent episodes, which are protected throughout; high-priority ones and
            // summaries are protected for a limited time after their last change (unit-tested).
            let protected = engine.snapshot.presented.contains { $0.lifecycle != .resolved && $0.priority >= .urgent }
            if protected, pipeline.isLive, pipeline.shown?.mode != .attention {
                violations.append("\(scenario.id): engine presents an episode but the activity shows "
                    + "\(pipeline.shown?.mode.rawValue ?? "nothing")")
            }
        }

        /// Delivers both components' deadlines in time order up to `limit`.
        func drain(until limit: Date) {
            var steps = 0
            while steps < 200_000 {
                let next = [engine.nextDeadline, pipeline.nextDeadline].compactMap { $0 }.filter { $0 <= limit }.min()
                guard let next else { return }
                if let deadline = engine.nextDeadline, deadline <= next { feedEngine(.tick(at: next)) }
                if let deadline = pipeline.nextDeadline, deadline <= next { feedPipeline(.tick(at: next)) }
                steps += 1
            }
            violations.append("\(scenario.id): deadlines did not settle")
        }

        feedEngine(.sessionStarted(at: scenario.start))
        feedPipeline(.sessionStarted(at: scenario.start))
        for step in scenario.steps {
            drain(until: step.input.date)
            switch step.input {
            case .sessionStarted(let date):
                feedEngine(step.input)
                feedPipeline(.sessionStarted(at: date))
            case .sessionEnded(let date):
                feedEngine(step.input)
                // The scenes use a session end as an interruption: the activity stays.
                feedPipeline(.sessionPaused(at: date))
            case .sound(let update):
                feedEngine(step.input)
                feedPipeline(.sound(update))
            case .speech, .preferences, .speechDataCleared, .tick:
                feedEngine(step.input)
            }
        }
        let end = scenario.end.addingTimeInterval(tail)
        drain(until: end)
        feedEngine(.sessionEnded(at: end))
        feedPipeline(.sessionEnded(at: end))

        if commands.filter({ if case .start = $0.command { true } else { false } }).count != 1 {
            violations.append("\(scenario.id): expected exactly one activity start")
        }
        if let last = commands.last, case .end = last.command {} else {
            violations.append("\(scenario.id): the activity was not ended with the session")
        }

        return IslandReplayRun(
            scenario: scenario, mode: preferences.mode, commands: commands, statistics: pipeline.statistics,
            ambient: pipeline.ambientStatistics, intents: intents, secondsAttention: seconds[.attention, default: 0],
            secondsAmbient: seconds[.ambient, default: 0],
            secondsListening: seconds[.listening, default: 0] + seconds[.paused, default: 0], violations: violations)
    }
}
