import Attention
import Foundation
import HearingSenseDomain

/// Ground-truth label of one scripted source event. The labels belong to the script (what the
/// author of the scenario put into the scene); they are independent of the attention mode.
public enum EvaluationLabel: String, Hashable, Sendable, Codable, CaseIterable {
    /// Should lead to an alert in every mode: a warning signal, a knock, a possible spoken
    /// warning, or a new independent occurrence of one of these.
    case important
    /// Depends on the mode and the context: a dog barking, ordinary or informative speech.
    /// Counted separately; an alert is neither required nor an error.
    case optional
    /// Background sound (rain, wind, traffic). An alert is unwanted in Quiet and Balanced;
    /// Sensitive mentions it once at low priority by design.
    case ambient
    /// Must never alert: music, probable lyrics, handling noise, anything the user muted.
    case irrelevant
    /// A repeat of something already reported: the same sound continuing or coming back within
    /// seconds, a reworded summary.
    case duplicate

    /// An alert on this label counts as unnecessary.
    public var isUnnecessary: Bool { self == .ambient || self == .irrelevant || self == .duplicate }
}

/// One scripted source event with its label.
public struct GroundTruth: Hashable, Sendable, Codable {
    /// `sound-<n>` or `speech-<n>`.
    public var key: String
    public var name: String
    public var label: EvaluationLabel
    /// When the source began.
    public var time: Date
}

public struct ScenarioStep: Sendable {
    public var input: AttentionInput
    /// The scripted source this input belongs to (nil for preferences, session and ticks).
    public var sourceKey: String?
}

/// A scripted sequence of engine inputs with ground truth.
public struct AttentionScenario: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var steps: [ScenarioStep]
    public var truths: [GroundTruth]
    public var start: Date
    public var end: Date

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Builds a scenario from sounds and speech placed on a timeline (seconds from the start).
public struct ScenarioBuilder {
    public static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    public let id: String
    public let title: String
    public let summary: String
    private var timed: [(time: TimeInterval, order: Int, step: ScenarioStep)] = []
    private var truths: [GroundTruth] = []
    private var soundCount = 0
    private var speechCount = 0
    private var end: TimeInterval = 0

    public init(id: String, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = summary
    }

    private func date(_ time: TimeInterval) -> Date { Self.origin.addingTimeInterval(time) }

    private mutating func add(_ input: AttentionInput, at time: TimeInterval, key: String?) {
        timed.append((time, timed.count, ScenarioStep(input: input, sourceKey: key)))
        end = max(end, time)
    }

    /// A sound that starts at `time` and lasts `duration`. The detector's behaviour is imitated:
    /// confirmation after `confirmDelay`, an update every `updateInterval` while it lasts, the end
    /// `endAfter` after the last evidence.
    @discardableResult
    public mutating func sound(_ kindID: String, at time: TimeInterval, duration: TimeInterval = 1,
                               quality: EventQuality = .strong, label: EvaluationLabel, name: String? = nil,
                               confirmDelay: TimeInterval = 1.6, updateInterval: TimeInterval = 5,
                               endAfter: TimeInterval = 2, ends: Bool = true, partOf source: String? = nil) -> String
    {
        soundCount += 1
        // A sound that is another view of a scripted source (the classifier's `speech` event for
        // a speech event) shares that source's key and label.
        let key = source ?? "sound-\(soundCount)"
        if source == nil {
            truths.append(GroundTruth(key: key, name: name ?? kindID, label: label, time: date(time)))
        }
        var event = SyntheticSoundEvent(kindID: kindID, number: soundCount, start: date(time), quality: quality,
                                        confirmDelay: confirmDelay)
        add(.sound(event.started()), at: time + confirmDelay, key: key)
        var next = time + confirmDelay + updateInterval
        while next < time + duration {
            add(.sound(event.updated(at: date(next))), at: next, key: key)
            next += updateInterval
        }
        if ends {
            let last = max(time + duration, time + confirmDelay)
            add(.sound(event.ended(at: date(last + endAfter))), at: last + endAfter, key: key)
        }
        return key
    }

    /// A speech event starting at `time`. `script` publishes its revisions; times inside it are
    /// seconds from the start of the scenario.
    @discardableResult
    public mutating func speech(at time: TimeInterval, label: EvaluationLabel, name: String,
                                transcription: TranscriptionAvailability = .available,
                                model: SemanticModelAvailability = .available,
                                _ script: (inout SpeechScript) -> Void) -> String
    {
        speechCount += 1
        let key = "speech-\(speechCount)"
        truths.append(GroundTruth(key: key, name: name, label: label, time: date(time)))
        var recorder = SpeechScript(speech: SyntheticSpeech(number: speechCount, start: date(time),
                                                            transcription: transcription, model: model))
        recorder.detected(at: time)
        script(&recorder)
        for (stepTime, result) in recorder.results { add(.speech(result), at: stepTime, key: key) }
        return key
    }

    public mutating func preferences(_ preferences: AttentionPreferences, at time: TimeInterval) {
        add(.preferences(preferences, at: date(time)), at: time, key: nil)
    }

    public mutating func sessionEnded(at time: TimeInterval) {
        add(.sessionEnded(at: date(time)), at: time, key: nil)
    }

    public mutating func sessionStarted(at time: TimeInterval) {
        add(.sessionStarted(at: date(time)), at: time, key: nil)
    }

    /// Extends the scenario so that expirations after the last event are part of the run.
    public mutating func quiet(until time: TimeInterval) {
        end = max(end, time)
    }

    public func build() -> AttentionScenario {
        let ordered = timed.sorted { $0.time != $1.time ? $0.time < $1.time : $0.order < $1.order }
        return AttentionScenario(id: id, title: title, summary: summary, steps: ordered.map(\.step), truths: truths,
                                 start: Self.origin, end: date(end))
    }
}

/// Records the revisions of one scripted speech event.
public struct SpeechScript {
    var speech: SyntheticSpeech
    var results: [(TimeInterval, SpeechSemanticResult)] = []

    private func date(_ time: TimeInterval) -> Date { ScenarioBuilder.origin.addingTimeInterval(time) }

    public mutating func detected(at time: TimeInterval) {
        results.append((time, speech.detected(at: date(time))))
    }

    public mutating func partial(_ text: String, at time: TimeInterval) {
        results.append((time, speech.partial(text, at: date(time))))
    }

    public mutating func final(_ text: String, at time: TimeInterval, category: SpeechSemanticCategory = .unknown,
                               quality: TranscriptQuality.Rating = .good, relevance: SpeechRelevance = .nearbySpeech,
                               isUnclear: Bool = false, isNegated: Bool = false, isQuestion: Bool = false)
    {
        results.append((time, speech.final(text, at: date(time), category: category, quality: quality,
                                           relevance: relevance, isUnclear: isUnclear, isNegated: isNegated,
                                           isQuestion: isQuestion)))
    }

    public mutating func summary(_ headline: String, at time: TimeInterval, category: SpeechSemanticCategory,
                                 reliability: SummaryReliability = .validated, isNegated: Bool = false,
                                 isQuestion: Bool = false, timeOrNumber: String? = nil)
    {
        results.append((time, speech.summary(headline, at: date(time), category: category, reliability: reliability,
                                             isNegated: isNegated, isQuestion: isQuestion, timeOrNumber: timeOrNumber)))
    }

    public mutating func completed(at time: TimeInterval) {
        results.append((time, speech.completed(at: date(time))))
    }
}
