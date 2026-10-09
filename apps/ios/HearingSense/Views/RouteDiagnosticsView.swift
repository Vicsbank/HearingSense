import HearingSenseAudio
import SwiftUI

/// Everything AVAudioSession reports about the current configuration and route.
/// Used for the physical-device routing tests in docs/AUDIO_ROUTING_FEASIBILITY.md.
struct RouteDiagnosticsView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let route = controller.route
        let assessment = controller.assessment
        List {
            Section("Assessment") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(assessment.headline).font(.headline)
                    Text(assessment.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Text("Reflects what iOS reports. Judge media quality by listening.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Session") {
                Row("Microphone permission", route.permission.rawValue)
                Row("Category", route.category)
                Row("Mode", route.mode)
                Row("Options", route.categoryOptions.isEmpty ? "none" : route.categoryOptions.joined(separator: ", "))
                Row("Sample rate", "\(Int(route.sampleRate)) Hz")
                Row("IO buffer", milliseconds(route.ioBufferDuration))
                Row("Input latency", milliseconds(route.inputLatency))
                Row("Output latency", milliseconds(route.outputLatency))
                Row("Channels in / out", "\(route.inputChannelCount) / \(route.outputChannelCount)")
                Row("Input available", yesNo(route.isInputAvailable))
                Row("Input gain", route.isInputGainSettable ? "\(route.inputGain) (settable)" : "\(route.inputGain)")
                Row("Other audio playing", yesNo(route.isOtherAudioPlaying))
                Row("Secondary audio should be silenced", yesNo(route.secondaryAudioShouldBeSilencedHint))
            }

            Section("Current inputs") { ports(route.inputs) }
            Section("Current outputs") { ports(route.outputs) }

            Section {
                ForEach(route.availableInputs) { port in
                    Button {
                        controller.selectInput(uid: port.uid)
                    } label: {
                        HStack {
                            PortRow(port: port)
                            if route.preferredInputUID == port.uid {
                                Image(systemName: "checkmark").accessibilityLabel("Preferred")
                            }
                        }
                    }
                    .accessibilityHint("Makes this the preferred microphone.")
                }
                Button("Use system default input") { controller.selectInput(uid: nil) }
            } header: {
                Text("Available inputs")
            } footer: {
                Text("Selecting an input changes the preferred input of the active session. "
                    + "Start listening first; the list is filled once the session is configured.")
            }

            Section {
                Text("Snapshot taken \(route.capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Route Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { controller.refreshRoute() }
        .onAppear { controller.refreshRoute() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: controller.diagnosticsReport()) {
                    Label("Share report", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    controller.refreshRoute()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder
    private func ports(_ ports: [AudioPortInfo]) -> some View {
        if ports.isEmpty {
            Text("None").foregroundStyle(.secondary)
        } else {
            ForEach(ports) { PortRow(port: $0) }
        }
    }

    private func milliseconds(_ seconds: TimeInterval) -> String {
        (seconds * 1000).formatted(.number.precision(.fractionLength(1))) + " ms"
    }

    private func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }
}

private struct Row: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

private struct PortRow: View {
    let port: AudioPortInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(port.name).font(.body)
            Text("\(port.kind.displayName) · \(port.rawType) · \(port.channelCount) ch")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let source = port.selectedDataSource {
                Text("Data source: \(source) (of \(port.dataSources.count))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let hq = port.highQualityRecording {
                Text("High-quality Bluetooth recording: \(hq.isSupported ? "supported" : "not supported")"
                    + (hq.isEnabled ? ", enabled" : ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let farField = port.farFieldCapture, farField.isSupported {
                Text("Far-field capture: supported" + (farField.isEnabled ? ", enabled" : ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
