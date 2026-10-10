import HearingSenseDomain
import SpeechIntelligence
import SpeechPipeline
import SwiftUI

/// Speech intelligence: the transcription switch, what the pipeline currently hears and the
/// latest transcript and summary. Temporary debug presentation for Window 3; the final
/// experience (Dynamic Island) is designed in Window 5.
struct SpeechIntelligenceCard: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let speech = controller.speech
        let isCapturing = controller.state.isCapturing
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Speech intelligence", systemImage: "captions.bubble")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    TranscriptionBadge(isOn: speech.isTranscriptionEnabled, isListening: isCapturing)
                        .layoutPriority(1)
                }
                Toggle(isOn: Binding(get: { speech.isTranscriptionEnabled },
                                     set: { speech.setTranscriptionEnabled($0) }))
                {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcribe nearby speech")
                        Text("On this iPhone only. Nothing is recorded or uploaded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityHint("When on, speech near you is turned into text and a short summary while listening.")

                Divider()
                SpeechResultView(result: isCapturing || speech.current != nil ? speech.current : nil,
                                 isTranscriptionEnabled: speech.isTranscriptionEnabled)
                    .frame(minHeight: 132, alignment: .top)
                Divider()

                SpeechStatusRows(speech: speech, isCapturing: isCapturing)
                NavigationLink {
                    SpeechDiagnosticsView()
                } label: {
                    Label("Speech events and diagnostics", systemImage: "list.bullet.rectangle")
                        .font(.subheadline)
                }
            }
        }
    }
}

/// States clearly whether nearby speech is being transcribed right now. Symbol + text, so the
/// state never depends on color.
private struct TranscriptionBadge: View {
    let isOn: Bool
    let isListening: Bool

    var body: some View {
        let isActive = isOn && isListening
        Label(isActive ? "TRANSCRIBING" : isOn ? "TEXT ON" : "TEXT OFF",
              systemImage: isOn ? "text.bubble.fill" : "text.bubble")
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(isActive ? AnyShapeStyle(.red) : AnyShapeStyle(.quaternary), in: Capsule())
            .accessibilityLabel(isActive ? "Speech transcription is active"
                : isOn ? "Speech transcription is on and starts with listening" : "Speech transcription is off")
    }
}

/// Summary, category, state and transcript of one speech event. Fixed minimum height so the
/// card does not jump while partial transcripts arrive.
private struct SpeechResultView: View {
    let result: SpeechSemanticResult?
    let isTranscriptionEnabled: Bool

    var body: some View {
        if let result {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.summary == nil ? "Speech" : "AI summary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(result.headline)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(result.state.displayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        Text(result.category == .unknown ? "Category –" : result.category.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.transcript.map { $0.isFinal ? "Transcript" : "Transcript (in progress)" } ?? "Transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transcriptText(result))
                        .font(.body)
                        .foregroundStyle(result.transcript == nil ? .secondary : .primary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = result.summary?.notes.first ?? result.failure {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(result))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("No speech yet").font(.title3.weight(.semibold))
                Text(isTranscriptionEnabled
                    ? "When someone speaks nearby while listening, the transcript and a short summary appear here."
                    : "Nearby speech is only reported as “Nearby Speech” while transcription is off.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func transcriptText(_ result: SpeechSemanticResult) -> String {
        if let transcript = result.transcript, !transcript.text.isEmpty { return "“\(transcript.text)”" }
        if result.level == .detection, result.state.isTerminal { return "No transcript for this speech." }
        return result.utteranceCount > 0 ? "Transcript removed." : "–"
    }

    private func accessibilityText(_ result: SpeechSemanticResult) -> String {
        var parts = [result.summary == nil ? result.headline : "Summary: \(result.headline)"]
        if result.category != .unknown { parts.append("Category: \(result.category.displayName)") }
        parts.append("Status: \(result.state.displayName)")
        if let transcript = result.transcript, !transcript.text.isEmpty { parts.append("Transcript: \(transcript.text)") }
        return parts.joined(separator: ". ")
    }
}

/// Detection, transcription and model availability, latency and errors.
private struct SpeechStatusRows: View {
    let speech: SpeechIntelligenceController
    let isCapturing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Speech detection", detection)
            row("Transcription", transcription)
            row("Foundation Models", speech.capabilities.model.displayName)
            row("Latency", latency)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private var detection: String {
        guard isCapturing else { return "Not listening" }
        guard let activity = speech.activity else { return "Waiting for the first window" }
        let score = activity.evidence.speechScore.formatted(.number.precision(.fractionLength(2)))
        if activity.isSpeechActive { return "Nearby speech detected (score \(score))" }
        if activity.evidence.suppressedByMusic { return "Voice in music, ignored (score \(score))" }
        return "No speech (score \(score))"
    }

    private var transcription: String {
        let capabilities = speech.capabilities
        guard capabilities.isTranscriptionEnabled else { return "Off" }
        guard capabilities.transcription.isUsable else { return capabilities.transcription.displayName }
        if speech.activity?.isTranscribing == true { return "Transcribing… (on device, \(capabilities.language))" }
        return "Ready (on device, \(capabilities.language))"
    }

    private var latency: String {
        guard let latency = speech.current?.latency else { return "–" }
        let parts = [
            latency.speechEndToFinalTranscript.map { "transcript \(SpeechIntelligenceController.seconds($0))" },
            latency.semanticProcessing.flatMap { $0 > 0.01 ? "model \(SpeechIntelligenceController.seconds($0))" : nil },
            latency.speechEndToSummary.map { "summary \(SpeechIntelligenceController.seconds($0)) after speech" },
        ].compactMap(\.self)
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }

    private var error: String? {
        if case .failed(let message) = speech.capabilities.transcription { return "Transcription stopped: \(message)" }
        if case .failed(let message) = speech.modelInstall { return "Model download failed: \(message)" }
        return speech.diagnostics.lastTranscriptionFailure.map { "Last recognition error: \($0)" }
    }
}

struct SpeechEventRow: View {
    let event: SpeechSemanticResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.headline).font(.subheadline.weight(.semibold))
                Spacer()
                Text(event.startDate, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
            }
            if let transcript = event.transcript, !transcript.text.isEmpty {
                Text("“\(transcript.text)”").font(.footnote)
            }
            Text("\(event.state.displayName) · level \(event.level.rawValue) · \(event.category.displayName) · "
                + "\(event.utteranceCount) utterance\(event.utteranceCount == 1 ? "" : "s")"
                + (event.transcript.map { " · recognition \($0.quality.rating.rawValue)" } ?? "")
                + (event.summary.map { " · summary \($0.reliability.rawValue)" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let delay = event.latency.speechEndToSummary {
                Text("Summary \(SpeechIntelligenceController.seconds(delay)) after the speech ended"
                    + (event.latency.preRollUsed.map { " · pre-roll \(SpeechIntelligenceController.seconds($0))" } ?? ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let failure = event.failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Availability, privacy controls, speech events and pipeline measurements.
struct SpeechDiagnosticsView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let speech = controller.speech
        List {
            Section {
                LabeledContent("Transcription", value: speech.capabilities.transcription.displayName)
                LabeledContent("Foundation Models", value: speech.capabilities.model.displayName)
                LabeledContent("Language", value: speech.capabilities.language)
                LabeledContent("Output level", value: levelDescription(speech.capabilities.level))
                if case .modelNotInstalled = speech.capabilities.transcription {
                    Button {
                        speech.installSpeechModel()
                    } label: {
                        Label(speech.modelInstall == .installing ? "Downloading speech model…" : "Download speech model",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(speech.modelInstall == .installing)
                }
                Button("Check availability again") { speech.refreshAvailability() }
            } header: {
                Text("On-device models")
            } footer: {
                Text("Speech is transcribed by Apple's on-device recognizer and summarized by Apple's on-device "
                    + "language model. Hearing Sense never sends audio or text to a server. The speech model itself is "
                    + "a system download from Apple; without it, or without Apple Intelligence, the app falls back to "
                    + "“Nearby Speech” or to the plain transcript.")
            }

            Section {
                Toggle("Keep transcripts after stopping", isOn: Binding(
                    get: { speech.keepsTranscriptsAfterStop },
                    set: { speech.setKeepsTranscriptsAfterStop($0) }))
                Button("Delete speech events", role: .destructive) { speech.clearSpeechData() }
                    .disabled(speech.events.isEmpty)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Transcripts and summaries are kept in memory only, for at most \(SpeechIntelligenceController.historyCapacity) "
                    + "speech events. By default the transcript text is removed when listening stops; keeping it is a "
                    + "testing aid. Turning transcription off discards all speech events.")
            }

            Section("Speech events (\(speech.events.count))") {
                if speech.events.isEmpty {
                    Text("Speech events appear here while listening.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(speech.events) { event in
                    SpeechEventRow(event: event)
                }
            }

            Section("Pre-roll buffer") {
                if let preRoll = speech.activity?.preRoll {
                    Text("\(preRoll.bufferedSeconds.formatted(.number.precision(.fractionLength(1)))) of "
                        + "\(preRoll.capacitySeconds.formatted()) s buffered · "
                        + "\((preRoll.sampleRate / 1000).formatted(.number.precision(.fractionLength(0 ... 1)))) kHz mono · "
                        + "\(preRoll.memoryBytes / 1024) KB · resets \(preRoll.resets) · gap frames \(preRoll.gapFramesFilled)")
                        .font(.footnote.monospacedDigit())
                    if !preRoll.isEnabled {
                        Text("Not buffering: transcription is off.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Reported while listening. The buffer holds the most recent audio in memory so a sentence "
                        + "can be transcribed from its beginning; it is erased when listening stops.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Pipeline") {
                ForEach(speech.diagnostics.reportLines(), id: \.self) { line in
                    Text(line).font(.footnote.monospacedDigit())
                }
            }

            Section {
                ShareLink(item: controller.diagnosticsReport()) {
                    Label("Share speech report", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("The report contains states, counts and timings only — no audio, no transcripts, no summaries.")
            }
        }
        .navigationTitle("Speech intelligence")
    }

    private func levelDescription(_ level: SpeechOutputLevel) -> String {
        switch level {
        case .detection: "1 · speech detection only"
        case .transcript: "2 · transcript"
        case .summary: "3 · transcript and AI summary"
        }
    }
}
