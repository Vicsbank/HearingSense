import Attention
import Foundation
import HearingSenseDomain

extension AttentionScenario {
    /// One input of a scenario prepared for playback.
    public struct TimedInput: Sendable {
        /// Seconds after the start of the playback.
        public var offset: TimeInterval
        public var input: AttentionInput
    }

    /// The scenario's sound and speech inputs moved in time so that the scenario starts at
    /// `date`, with new source ids (so the same scene can be played more than once into a running
    /// engine). Preference and session steps are left out: playback must not change the user's
    /// settings or end their listening session.
    public func playback(startingAt date: Date) -> [TimedInput] {
        let shift = date.timeIntervalSince(start)
        var soundIDs: [AcousticEventID: AcousticEventID] = [:]
        var speechIDs: [SpeechEventID: SpeechEventID] = [:]
        var result: [TimedInput] = []
        for step in steps {
            let offset = step.input.date.timeIntervalSince(start)
            switch step.input {
            case .sound(let update):
                let old = update.event
                let id = soundIDs[old.id, default: AcousticEventID()]
                soundIDs[old.id] = id
                let event = ConfirmedAcousticEvent(
                    id: id, kind: old.kind, source: old.source, primaryLabel: old.primaryLabel, phase: old.phase,
                    audioStart: old.audioStart, audioConfirmed: old.audioConfirmed, audioLastObserved: old.audioLastObserved,
                    startDate: old.startDate.addingTimeInterval(shift), confirmedDate: old.confirmedDate.addingTimeInterval(shift),
                    lastObservedDate: old.lastObservedDate.addingTimeInterval(shift),
                    endedDate: old.endedDate?.addingTimeInterval(shift), evidence: old.evidence, quality: old.quality)
                let moved: AcousticEventUpdate = switch update {
                case .started: .started(event)
                case .updated: .updated(event)
                case .ended: .ended(event)
                }
                result.append(TimedInput(offset: offset, input: .sound(moved)))
            case .speech(let old):
                let id = speechIDs[old.id, default: SpeechEventID()]
                speechIDs[old.id] = id
                let moved = SpeechSemanticResult(
                    id: id, revision: old.revision, summaryRevision: old.summaryRevision, sourceEventIDs: [],
                    state: old.state, audioTime: old.audioTime, startDate: old.startDate.addingTimeInterval(shift),
                    updatedDate: old.updatedDate.addingTimeInterval(shift), transcript: old.transcript,
                    utteranceCount: old.utteranceCount, summary: old.summary, category: old.category, details: old.details,
                    isUnclear: old.isUnclear, acousticContext: old.acousticContext,
                    transcriptionAvailability: old.transcriptionAvailability, modelAvailability: old.modelAvailability,
                    latency: old.latency, failure: old.failure)
                result.append(TimedInput(offset: offset, input: .speech(moved)))
            case .preferences, .sessionStarted, .sessionEnded, .speechDataCleared, .tick:
                continue
            }
        }
        return result
    }
}

extension ScenarioLibrary {
    /// A single sound, for quick injection from the debug screen.
    public static func singleSound(_ kindID: String, duration: TimeInterval, quality: EventQuality = .strong) -> AttentionScenario {
        var scene = ScenarioBuilder(id: "inject-\(kindID)", title: SyntheticSound.kind(kindID).displayName,
                                    summary: "One synthetic \(kindID) event.")
        scene.sound(kindID, at: 0, duration: duration, quality: quality, label: .optional, confirmDelay: 0,
                    endAfter: duration > 5 ? 3 : 2)
        return scene.build()
    }

    /// Speech for quick injection: without text, as a warning, as a reminder with a late
    /// summary, or as lyrics.
    public enum InjectedSpeech: String, CaseIterable, Sendable {
        case noText, warning, reminder, lyrics

        public var title: String {
            switch self {
            case .noText: "Speech (no text)"
            case .warning: "“Watch out!”"
            case .reminder: "Reminder + summary"
            case .lyrics: "Lyrics"
            }
        }
    }

    public static func singleSpeech(_ kind: InjectedSpeech) -> AttentionScenario {
        var scene = ScenarioBuilder(id: "inject-speech-\(kind.rawValue)", title: kind.title, summary: "One synthetic speech event.")
        switch kind {
        case .noText:
            scene.speech(at: 0, label: .optional, name: kind.title, transcription: .disabledByUser) { speech in
                speech.detected(at: 3)
                speech.completed(at: 8)
            }
        case .warning:
            scene.speech(at: 0, label: .important, name: kind.title) { speech in
                speech.final("watch out", at: 1.5, category: .warning)
                speech.summary("Watch Out", at: 2.3, category: .warning)
                speech.completed(at: 9)
            }
        case .reminder:
            scene.speech(at: 0, label: .optional, name: kind.title) { speech in
                speech.final("we have a biology test tomorrow", at: 3)
                speech.summary("Biology Test Tomorrow", at: 7.5, category: .reminder, timeOrNumber: "tomorrow")
                speech.completed(at: 14)
            }
        case .lyrics:
            scene.speech(at: 0, label: .irrelevant, name: kind.title) { speech in
                speech.final("oh baby watch out for my love", at: 3, quality: .fair, relevance: .possiblyMusic)
                speech.completed(at: 10)
            }
        }
        return scene.build()
    }
}
