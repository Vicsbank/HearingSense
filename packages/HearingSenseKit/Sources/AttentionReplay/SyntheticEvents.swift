import Attention
import Foundation
import HearingSenseDomain
import SoundEventDetection

// Synthetic inputs for the attention engine: scripted `ConfirmedAcousticEvent` and
// `SpeechSemanticResult` values with explicit times. They drive the production engine in tests,
// in the replay tool and from the app's debug screen, without a microphone, a classifier or a
// language model.
//
// Everything built here is marked with the model id `synthetic.replay`. It is not evidence about
// real sounds: results obtained with it describe the engine's rules, not recognition accuracy.

public enum SyntheticSound {
    public static let model = SoundModelID(rawValue: "synthetic.replay")

    /// The real kind from the app's taxonomy, so titles and categories match the app.
    public static func kind(_ id: String) -> SoundEventKind {
        SoundTaxonomy.appleV1.definitions.first { $0.kind.id == id }?.kind
            ?? SoundEventKind(id: id, displayName: id, category: .other)
    }

    /// Every kind id the taxonomy can produce as an event.
    public static var allKindIDs: [String] {
        SoundTaxonomy.appleV1.definitions.filter(\.producesEvents).map(\.kind.id)
    }

    /// A deterministic identifier (the same script gives the same ids).
    public static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number)) ?? UUID()
    }
}

/// One scripted sound event and the updates the detector would publish for it.
public struct SyntheticSoundEvent: Sendable {
    public private(set) var event: ConfirmedAcousticEvent
    /// Hop between classifier windows (the app's 1.5 s window with 50 % overlap).
    static let hop: TimeInterval = 0.75

    /// - Parameters:
    ///   - start: when the sound began.
    ///   - confirmDelay: time from the start to the detector's confirmation.
    public init(kindID: String, number: Int, start: Date, quality: EventQuality = .strong,
                confirmDelay: TimeInterval = 1.6)
    {
        let kind = SyntheticSound.kind(kindID)
        let confirmed = start.addingTimeInterval(confirmDelay)
        event = ConfirmedAcousticEvent(
            id: AcousticEventID(rawValue: SyntheticSound.uuid(number)), kind: kind,
            source: .soundClassifier(SyntheticSound.model), primaryLabel: SoundLabel(kindID), phase: .confirmed,
            audioStart: 0, audioConfirmed: confirmDelay, audioLastObserved: confirmDelay, startDate: start,
            confirmedDate: confirmed, lastObservedDate: confirmed,
            evidence: Self.evidence(quality: quality, duration: confirmDelay), quality: quality)
    }

    public var id: AcousticEventID { event.id }

    public func started() -> AcousticEventUpdate { .started(event) }

    public mutating func updated(at date: Date, quality: EventQuality? = nil) -> AcousticEventUpdate {
        let duration = date.timeIntervalSince(event.startDate)
        event.phase = .ongoing
        event.lastObservedDate = date
        event.audioLastObserved = duration
        event.quality = max(event.quality, quality ?? event.quality)
        event.evidence = Self.evidence(quality: event.quality, duration: duration)
        return .updated(event)
    }

    public mutating func ended(at date: Date) -> AcousticEventUpdate {
        event.phase = .ended
        event.endedDate = date
        return .ended(event)
    }

    /// Evidence consistent with `EventQuality.assess` for the requested quality.
    static func evidence(quality: EventQuality, duration: TimeInterval) -> EventEvidence {
        let observed = max(Int(duration / hop), 1)
        let (peak, windows): (Double, Int) = switch quality {
        case .weak: (0.45, min(observed, 2))
        case .moderate: (0.6, observed)
        case .strong: (0.9, max(observed, 3))
        }
        return EventEvidence(supportingWindows: windows, observedWindows: max(observed, windows),
                             peakScore: ClassifierScore(peak), scoreSum: peak * Double(windows) * 0.9)
    }
}

/// One scripted speech event (conversation) and the revisions the speech pipeline would publish.
public struct SyntheticSpeech: Sendable {
    public private(set) var result: SpeechSemanticResult

    public init(number: Int, start: Date, transcription: TranscriptionAvailability = .available,
                model: SemanticModelAvailability = .available)
    {
        result = SpeechSemanticResult(id: SpeechEventID(rawValue: SyntheticSound.uuid(1_000_000 + number)),
                                      state: .detected, audioTime: AudioTimeRange(start: 0, duration: 0),
                                      startDate: start, updatedDate: start, transcriptionAvailability: transcription,
                                      modelAvailability: model)
    }

    public var id: SpeechEventID { result.id }

    private mutating func publish(at date: Date) -> SpeechSemanticResult {
        result.revision += 1
        result.updatedDate = date
        result.audioTime = AudioTimeRange(start: 0, duration: max(date.timeIntervalSince(result.startDate), 0))
        return result
    }

    /// Speech-like sound was noticed; nothing transcribed.
    public mutating func detected(at date: Date) -> SpeechSemanticResult {
        result.state = .detected
        return publish(at: date)
    }

    /// A partial transcript while the recognizer is still listening.
    public mutating func partial(_ text: String, at date: Date) -> SpeechSemanticResult {
        result.state = .transcribing
        result.transcript = SpeechTranscript(text: text, language: "en-US", isFinal: false, quality: .unknown,
                                             audioTime: result.audioTime)
        return publish(at: date)
    }

    /// A finalized utterance with the rule-based details Window 3 attaches to it.
    public mutating func final(_ text: String, at date: Date, category: SpeechSemanticCategory = .unknown,
                               quality: TranscriptQuality.Rating = .good,
                               relevance: SpeechRelevance = .nearbySpeech, isUnclear: Bool = false,
                               isNegated: Bool = false, isQuestion: Bool = false) -> SpeechSemanticResult
    {
        let words = text.split(separator: " ").count
        let confidence: Double? = switch quality {
        case .good: 0.92
        case .fair: 0.65
        case .poor: 0.35
        case .unknown: nil
        }
        result.state = result.modelAvailability.isUsable && !isUnclear && relevance != .possiblyMusic ? .processing : .transcribing
        result.utteranceCount += 1
        result.transcript = SpeechTranscript(
            text: text, language: "en-US", isFinal: true,
            quality: TranscriptQuality(rating: quality, meanConfidence: confidence, minimumConfidence: confidence,
                                       wordCount: words),
            audioTime: result.audioTime)
        result.category = category
        result.isUnclear = isUnclear
        result.details = SpeechSemanticDetails(source: .rules, isNegated: isNegated, isQuestion: isQuestion)
        result.acousticContext = SpeechAcousticContext(
            relevance: relevance, windows: 4, musicShare: relevance == .nearbySpeech ? 0 : 0.9,
            strongSpeechShare: relevance == .possiblyMusic ? 0.2 : 0.9,
            vocalMusicShare: relevance == .possiblyMusic ? 0.6 : 0)
        return publish(at: date)
    }

    /// A validated headline from the language model (a new `summaryRevision` when the text changes).
    public mutating func summary(_ headline: String, at date: Date, category: SpeechSemanticCategory,
                                 reliability: SummaryReliability = .validated, isNegated: Bool = false,
                                 isQuestion: Bool = false, timeOrNumber: String? = nil) -> SpeechSemanticResult
    {
        if result.summary?.text != headline { result.summaryRevision += 1 }
        result.state = .summarized
        result.summary = SpeechSummary(text: headline, wordCount: headline.split(separator: " ").count,
                                       source: .onDeviceLanguageModel, reliability: reliability)
        result.category = category
        result.details = SpeechSemanticDetails(source: .onDeviceLanguageModel, timeOrNumber: timeOrNumber,
                                               isNegated: isNegated, isQuestion: isQuestion)
        return publish(at: date)
    }

    public mutating func completed(at date: Date) -> SpeechSemanticResult {
        result.state = .completed
        return publish(at: date)
    }
}
