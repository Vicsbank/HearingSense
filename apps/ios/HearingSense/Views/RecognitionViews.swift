import HearingSenseDomain
import SoundEventDetection
import SwiftUI

/// Live recognition: status, current sound, category, score and the raw classifier output.
/// Temporary debug presentation for Window 2; the final experience is designed in Window 5.
struct RecognitionCard: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let recognition = controller.recognition
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Sound recognition", systemImage: "waveform.badge.magnifyingglass")
                        .font(.headline)
                    Spacer()
                    if controller.state.isCapturing {
                        Text(recognition.status.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if !controller.state.isCapturing {
                    Text("Start listening to classify sounds around you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Fixed-size layout: the card must not change height with every classifier
                    // window, or the whole screen jumps while listening.
                    CurrentSoundView(status: recognition.status, taxonomy: recognition.taxonomy)
                        .frame(minHeight: 120, alignment: .top)
                    Divider()
                    RawOutputView(frame: recognition.latestFrame, taxonomy: recognition.taxonomy)
                    Text("Checking: " + (recognition.candidates.isEmpty ? "–" : recognition.candidates.map {
                        "\($0.kind.displayName) (\($0.recentHits)/\($0.requiredHits))"
                    }.joined(separator: ", ")))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let failure = recognition.lastFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

private struct CurrentSoundView: View {
    let status: EnvironmentStatus
    let taxonomy: SoundTaxonomy

    var body: some View {
        switch status {
        case .recognized(let events):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events.prefix(2)) { event in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: event.category.systemImage)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind.displayName).font(.title3.weight(.semibold))
                            Text("\(event.category.displayName) · \(taxonomy.displayName(for: event.primaryLabel))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(event.evidence.peakScore.description)
                                .font(.title3.monospacedDigit())
                            Text("peak score").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(event.kind.displayName), \(event.category.displayName), "
                        + "peak score \(event.evidence.peakScore.description)")
                }
                if events.count > 2 {
                    Text("+ \(events.count - 2) more: " + events.dropFirst(2).map(\.kind.displayName).joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        case .uncertain(let top):
            StatusLine(symbol: "questionmark.circle", title: "No reliable classification",
                       detail: "Maybe \(taxonomy.displayName(for: top.label)) (score \(top.score)), "
                           + "not confirmed")
        case .unclassified:
            StatusLine(symbol: "waveform", title: "Sound present, not recognized",
                       detail: "No label reached the display threshold.")
        case .quiet:
            StatusLine(symbol: "speaker.zzz", title: "Quiet",
                       detail: "Input level is low or the classifier reports silence.")
        case .warmingUp:
            StatusLine(symbol: "hourglass", title: "Analyzing…",
                       detail: "The classifier needs one full analysis window before its first result.")
        }
    }
}

private struct StatusLine: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The top raw labels of the latest window, exactly as reported (identifier + score). Always
/// three rows tall so the layout stays still.
private struct RawOutputView: View {
    let frame: ClassificationFrame?
    let taxonomy: SoundTaxonomy

    var body: some View {
        let predictions = Array(frame?.predictions.prefix(3) ?? [])
        VStack(alignment: .leading, spacing: 4) {
            Text(frame.map { "Latest window \($0.audioTime.description)" } ?? "Waiting for the first window")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(predictions, id: \.label) { prediction in
                HStack {
                    Text(prediction.label.rawValue).font(.footnote.monospaced())
                    Text(taxonomy.category(for: prediction.label).displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView(value: prediction.score.rawValue)
                        .frame(width: 60)
                        .accessibilityHidden(true)
                    Text(prediction.score.description).font(.footnote.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(predictions.count ..< 3, id: \.self) { _ in
                Text("–").font(.footnote.monospaced()).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            Text(frame.map { frame in
                (frame.inputLevel.map { "Input \(Int($0.rmsDBFS.rounded())) dBFS RMS" } ?? "Input level unknown")
                    + (frame.resultDelay.map { " · result \(Int(($0 * 1000).rounded())) ms after window end" } ?? "")
            } ?? " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Recent confirmed events (metadata only), newest first.
struct RecentEventsCard: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let history = controller.recognition.history
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Recent events", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                if history.isEmpty {
                    Text("Confirmed sound events appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history.prefix(8)) { event in
                        EventRow(event: event)
                    }
                    if history.count > 8 {
                        NavigationLink("All \(history.count) events") { EventHistoryView() }
                            .font(.subheadline)
                    }
                }
            }
        }
    }
}

struct EventRow: View {
    let event: ConfirmedAcousticEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: event.category.systemImage)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.kind.displayName).font(.subheadline.weight(.semibold))
                Text("\(event.primaryLabel.rawValue) · peak \(event.evidence.peakScore.description) · \(event.quality.description)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(event.confirmedDate, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                Text(event.isActive ? "ongoing" : "\(event.observedDuration.formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.caption2)
                    .foregroundStyle(event.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct EventHistoryView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        List(controller.recognition.history) { event in
            EventRow(event: event)
        }
        .navigationTitle("Events")
        .toolbar {
            Button("Clear ended") { controller.recognition.clearHistory() }
        }
    }
}

/// Pipeline measurements, detector statistics, configuration and the audio-session experiment.
struct RecognitionDiagnosticsView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let recognition = controller.recognition
        List {
            Section("Classifier") {
                Text(recognition.analyzerDescription ?? "Not started yet")
                    .font(.footnote)
                Picker("Window length", selection: Binding(
                    get: { recognition.configuration.windowDuration },
                    set: { recognition.select(windowDuration: $0) }
                )) {
                    ForEach(ClassifierConfiguration.selectableWindowDurations, id: \.self) { value in
                        Text("\(value.formatted()) s").tag(value)
                    }
                }
                .disabled(controller.state.isCapturing)
                NavigationLink("Classifier labels on this device") { ClassifierLabelsView() }
            }
            Section("Pipeline") {
                ForEach(recognition.diagnostics.reportLines(), id: \.self) { line in
                    Text(line).font(.footnote.monospacedDigit())
                }
            }
            Section("Detector") {
                let stats = recognition.detectorStatistics
                Text("\(stats.windows) windows · \(stats.candidatesStarted) candidates · \(stats.candidatesRejected) rejected · "
                    + "\(stats.eventsConfirmed) confirmed · \(stats.eventsEnded) ended")
                    .font(.footnote.monospacedDigit())
            }
            Section("Process") {
                if let resources = recognition.resources {
                    Text("CPU \(resources.cpuUtilization.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "–") "
                        + "(100 % = one core) · memory \(resources.memoryMB.map { "\(Int($0)) MB" } ?? "–") · "
                        + "thermal \(resources.thermal)")
                        .font(.footnote.monospacedDigit())
                } else {
                    Text("Sampled while listening.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Keep audio session active when stopped", isOn: Binding(
                    get: { controller.keepsSessionActiveWhenStopped },
                    set: { controller.setKeepsSessionActiveWhenStopped($0) }
                ))
            } header: {
                Text("Start/stop stall experiment")
            } footer: {
                Text("Stop always turns the microphone off. With this on, the audio session stays active between "
                    + "Stop and Start to test whether that avoids the short music stall.")
            }
            Section {
                ShareLink(item: controller.diagnosticsReport()) {
                    Label("Share recognition report", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("The report contains timings, labels and scores only — no audio.")
            }
        }
        .navigationTitle("Recognition diagnostics")
    }
}

/// The classifier's own label inventory on this OS, compared with the app's taxonomy.
struct ClassifierLabelsView: View {
    @State private var catalog: Result<SoundClassifierCatalog, any Error>?
    private let taxonomy = SoundTaxonomy.appleV1

    var body: some View {
        List {
            switch catalog {
            case .none:
                ProgressView()
            case .failure(let error):
                Text("Could not load: \(error.localizedDescription)")
            case .success(let catalog):
                let coverage = taxonomy.coverage(of: catalog.labels)
                Section("Summary") {
                    LabeledContent("Labels", value: "\(catalog.labels.count)")
                    LabeledContent("Default window", value: "\(catalog.defaultWindowDuration.formatted()) s")
                    LabeledContent("Default overlap", value: catalog.defaultOverlapFactor.formatted())
                    LabeledContent("Window constraint", value: catalog.windowConstraint)
                    LabeledContent("Matches taxonomy", value: coverage.isExactMatch ? "Yes" : "No")
                    if !coverage.notInTaxonomy.isEmpty {
                        Text("Not in taxonomy: " + coverage.notInTaxonomy.map(\.rawValue).joined(separator: ", "))
                            .font(.footnote)
                    }
                    if !coverage.notReportedByClassifier.isEmpty {
                        Text("Not reported here: " + coverage.notReportedByClassifier.map(\.rawValue).joined(separator: ", "))
                            .font(.footnote)
                    }
                    ShareLink(item: catalog.reportText(platform: "\(DeviceInfo.summary)")) {
                        Label("Share label inventory", systemImage: "square.and.arrow.up")
                    }
                }
                Section("Labels (classifier order)") {
                    ForEach(catalog.labels, id: \.self) { label in
                        HStack {
                            Text(label.rawValue).font(.footnote.monospaced())
                            Spacer()
                            Text(taxonomy.category(for: label).displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Classifier labels")
        .task {
            catalog = Result { try SoundClassifierCatalog.load() }
        }
    }
}
