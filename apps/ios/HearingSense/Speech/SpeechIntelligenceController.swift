import HearingSenseAudio
import HearingSenseDomain
import Observation
import SemanticSummary
import SoundEventDetection
import SpeechIntelligence
import SpeechPipeline
import SwiftUI

/// Presentation state for speech intelligence (Window 3). Every value shown comes from the real
/// pipeline: Apple's on-device transcriber and language model through `SpeechIntelligenceEngine`.
///
/// Main-actor isolated (app default).
///
/// Privacy: speech transcription is **off until the user turns it on** (the choice is
/// remembered). Speech events live in memory only, in a bounded list. Transcript text is
/// dropped when listening stops unless the debug option "Keep transcripts after stopping" is on,
/// and immediately when transcription is switched off. Log lines and shared reports carry
/// counts, states and timings only — never transcript or summary text.
@Observable
final class SpeechIntelligenceController {
    static let historyCapacity = 20
    private static let enabledKey = "speech.transcriptionEnabled"
    private static let keepTranscriptsKey = "speech.keepTranscriptsAfterStop"

    enum ModelInstallState: Equatable {
        case idle, installing, failed(String)
    }

    private(set) var isTranscriptionEnabled: Bool
    private(set) var keepsTranscriptsAfterStop: Bool
    private(set) var capabilities: SpeechCapabilities
    private(set) var activity: SpeechActivityReport?
    /// Speech events, newest first; each entry is the latest revision of its id.
    private(set) var events: [SpeechSemanticResult] = []
    private(set) var diagnostics = SpeechIntelligenceDiagnostics()
    private(set) var isSessionActive = false
    private(set) var modelInstall = ModelInstallState.idle

    @ObservationIgnored let engine: SpeechIntelligenceEngine
    @ObservationIgnored private let transcriber: AppleSpeechTranscriber
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var log: (DiagnosticEventLog.Kind, String) -> Void = { _, _ in }
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    /// Window 4: the engine's output stream has a single consumer (this controller), so results
    /// are forwarded from here to the attention engine.
    @ObservationIgnored private var forwardResult: (SpeechSemanticResult) -> Void = { _ in }
    @ObservationIgnored private var forwardCleared: () -> Void = {}

    /// - Parameters:
    ///   - taxonomy: the label table of the sound classifier that feeds this pipeline.
    ///   - vocalMusicLabels: that classifier's labels for a voice making music; nil keeps the
    ///     defaults (Apple's labels).
    init(defaults: UserDefaults = .standard, taxonomy: SoundTaxonomy = .appleV1, vocalMusicLabels: Set<SoundLabel>? = nil) {
        self.defaults = defaults
        let isEnabled = defaults.bool(forKey: Self.enabledKey)
        let transcriber = AppleSpeechTranscriber(locale: Locale(identifier: "en-US"))
        var configuration = SpeechIntelligenceConfiguration.standard
        // Window 6: ordinary speech is an icon; no 2–3 word headline is written for it and the
        // language model is left to the recap and the attention goals. The earlier behaviour
        // remains available for comparison: launch with `-speech.automaticHeadlines YES`.
        configuration.summary.writesHeadlines = defaults.bool(forKey: "speech.automaticHeadlines")
        if let vocalMusicLabels { configuration.activation.vocalMusicLabels = vocalMusicLabels }
        let engine = SpeechIntelligenceEngine(transcriber: transcriber, interpreter: FoundationModelInterpreter(),
                                              configuration: configuration, taxonomy: taxonomy,
                                              isTranscriptionEnabled: isEnabled)
        self.transcriber = transcriber
        self.engine = engine
        isTranscriptionEnabled = isEnabled
        keepsTranscriptsAfterStop = defaults.bool(forKey: Self.keepTranscriptsKey)
        capabilities = SpeechCapabilities(isTranscriptionEnabled: isEnabled,
                                          transcription: isEnabled ? .unknown : .disabledByUser,
                                          language: transcriber.languageIdentifier)
        listenTask = Task { [weak self, outputs = engine.outputs] in
            for await output in outputs {
                guard let self else { return }
                self.handle(output)
            }
        }
        engine.refreshAvailability()
    }

    deinit {
        listenTask?.cancel()
    }

    /// Where pipeline lifecycle messages go (the app's diagnostic log).
    func setLogger(_ logger: @escaping (DiagnosticEventLog.Kind, String) -> Void) {
        log = logger
    }

    /// Receives every speech result in order, and a call when all speech events are discarded.
    func setForwarding(result: @escaping (SpeechSemanticResult) -> Void, cleared: @escaping () -> Void) {
        forwardResult = result
        forwardCleared = cleared
    }

    /// The speech event to feature: the one in progress, otherwise the most recent.
    var current: SpeechSemanticResult? {
        events.first { !$0.state.isTerminal } ?? events.first
    }

    // MARK: - Lifecycle (called by ListeningController)

    func sessionWillStart() {
        isSessionActive = true
        activity = nil
        engine.startSession()
    }

    /// Capture stopped (user, interruption or failure): discard temporary speech data.
    func sessionDidEnd() {
        guard isSessionActive else { return }
        isSessionActive = false
        engine.endSession()
    }

    // MARK: - User actions

    func setTranscriptionEnabled(_ isEnabled: Bool) {
        guard isEnabled != isTranscriptionEnabled else { return }
        isTranscriptionEnabled = isEnabled
        defaults.set(isEnabled, forKey: Self.enabledKey)
        engine.setTranscriptionEnabled(isEnabled)
        log(.recognition, "Speech transcription switched \(isEnabled ? "on" : "off") by the user")
    }

    func setKeepsTranscriptsAfterStop(_ keeps: Bool) {
        keepsTranscriptsAfterStop = keeps
        defaults.set(keeps, forKey: Self.keepTranscriptsKey)
        if !keeps, !isSessionActive { removeTranscripts() }
    }

    /// Deletes every speech event held by the app (transcripts and summaries).
    func clearSpeechData() {
        events.removeAll { $0.state.isTerminal || !isSessionActive }
        for index in events.indices { events[index].transcript = nil }
        log(.recognition, "Speech data cleared by the user")
    }

    /// Downloads the on-device speech model from Apple. Only on the user's request.
    func installSpeechModel() {
        guard modelInstall != .installing else { return }
        modelInstall = .installing
        log(.recognition, "Speech model download requested by the user")
        Task {
            do {
                try await transcriber.installModel()
                modelInstall = .idle
                log(.recognition, "Speech model installed")
            } catch {
                modelInstall = .failed(error.localizedDescription)
                log(.error, "Speech model download failed: \(error.localizedDescription)")
            }
            engine.refreshAvailability()
        }
    }

    func refreshAvailability() {
        engine.refreshAvailability()
    }

    // MARK: - Engine outputs

    private func handle(_ output: SpeechIntelligenceOutput) {
        switch output {
        case .capabilities(let updated):
            if updated != capabilities {
                log(.recognition, "Speech capabilities: transcription \(updated.transcription.displayName); "
                    + "language model \(updated.model.displayName); level \(updated.level.rawValue)")
            }
            capabilities = updated
        case .result(let result):
            apply(result)
            forwardResult(result)
        case .activity(let report):
            guard isSessionActive else { return }
            activity = report
            diagnostics = report.diagnostics
        case .speechDataCleared:
            events.removeAll()
            forwardCleared()
            log(.recognition, "Speech transcripts discarded (transcription off)")
        case .sessionEnded(let final):
            diagnostics = final
            activity = nil
            // The session is over, so every speech event is: nothing will update them any more.
            for index in events.indices where !events[index].state.isTerminal {
                events[index].state = .completed
            }
            if !keepsTranscriptsAfterStop { removeTranscripts() }
            log(.recognition, "Speech session ended: \(final.activations) activations, \(final.finalSegments) "
                + "utterances, \(final.summariesProduced) summaries, \(final.transcriptionFailures) transcription failures")
        }
    }

    private func apply(_ result: SpeechSemanticResult) {
        let previous = events.first { $0.id == result.id }
        if let index = events.firstIndex(where: { $0.id == result.id }) {
            events[index] = result
        } else {
            events.insert(result, at: 0)
            if events.count > Self.historyCapacity { events.removeLast(events.count - Self.historyCapacity) }
            log(.recognition, "Speech event started (level \(result.level.rawValue) possible: \(capabilities.level.rawValue))")
        }
        // Metadata only: never the transcript or the summary text.
        if result.summaryRevision > (previous?.summaryRevision ?? 0) || (result.state.isTerminal && previous?.state != result.state) {
            log(.recognition, "Speech event \(result.state.rawValue): level \(result.level.rawValue), "
                + "\(result.utteranceCount) utterance(s), \(result.transcript?.quality.wordCount ?? 0) words in the last, "
                + "quality \(result.transcript?.quality.rating.rawValue ?? "–"), category \(result.category.rawValue), "
                + "context \(result.acousticContext?.relevance.rawValue ?? "–"), "
                + "summary \(result.summary.map { "\($0.wordCount) words (\($0.reliability.rawValue))" } ?? "none")"
                + (result.latency.speechEndToSummary.map { ", end of speech → summary \(Self.seconds($0))" } ?? "")
                + (result.failure.map { ", note: \($0)" } ?? ""))
        }
    }

    private func removeTranscripts() {
        for index in events.indices { events[index].transcript = nil }
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func seconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " s"
    }

    /// Text for sharing test results: availability, counters, timings and per-event metadata.
    /// Contains no audio, no transcript and no summary text.
    func reportText() -> String {
        var lines = [
            "Speech intelligence",
            "Transcription switch: \(isTranscriptionEnabled ? "on" : "off") · language \(capabilities.language)",
            "Transcription: \(capabilities.transcription.displayName)",
            "Language model: \(capabilities.model.displayName)",
            "Best available level: \(capabilities.level.rawValue) (1 detection, 2 transcript, 3 summary)",
            "",
        ]
        lines += diagnostics.reportLines()
        if let preRoll = activity?.preRoll {
            lines.append("Pre-roll buffer: \(preRoll.bufferedSeconds.formatted(.number.precision(.fractionLength(1)))) of "
                + "\(preRoll.capacitySeconds.formatted()) s, \(preRoll.memoryBytes / 1024) KB, resets \(preRoll.resets)")
        }
        lines.append("")
        lines.append("Speech events (newest first; text omitted):")
        for event in events {
            let latency = event.latency
            lines.append("\(event.startDate.formatted(.iso8601.time(includingFractionalSeconds: true))) "
                + "\(event.state.rawValue) level \(event.level.rawValue) category \(event.category.rawValue) "
                + "utterances \(event.utteranceCount) quality \(event.transcript?.quality.rating.rawValue ?? "–") "
                + "summary \(event.summary.map { "\($0.wordCount)w/\($0.reliability.rawValue)" } ?? "none") "
                + "context \(event.acousticContext.map { "\($0.relevance.rawValue) (music \(Self.percent($0.musicShare)), strong speech \(Self.percent($0.strongSpeechShare)))" } ?? "–") "
                + "sound-events \(event.sourceEventIDs.count) "
                + "start-delay \(latency.activationToTranscription.map(Self.seconds) ?? "–") "
                + "pre-roll \(latency.preRollUsed.map(Self.seconds) ?? "–") "
                + "final \(latency.speechEndToFinalTranscript.map(Self.seconds) ?? "–") "
                + "model \(latency.semanticProcessing.map(Self.seconds) ?? "–") "
                + "summary-after-speech \(latency.speechEndToSummary.map(Self.seconds) ?? "–")"
                + (event.failure.map { " note: \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}
