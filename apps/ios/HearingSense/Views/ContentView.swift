import HearingSenseAudio
import HearingSenseDomain
import SwiftUI

struct ContentView: View {
    @Environment(ListeningController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    /// `--hs-screen conversation|history|summary|privacy|icons`
    enum DebugScreen: String, Hashable, Identifiable {
        case conversation, history, summary, privacy, icons
        var id: String { rawValue }
    }

    @State private var debugScreen: DebugScreen? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--hs-screen"), index + 1 < arguments.count else { return nil }
        return DebugScreen(rawValue: arguments[index + 1])
    }()
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BrandHeader()
                    StatusCard(state: controller.state, format: controller.captureFormat)
                    ListeningButtons()
                    SceneRow()
                    LiveActivityCard()
                    AttentionCard()
                    ConversationCard()
                    RecognitionCard()
                    SpeechIntelligenceCard()
                    RecentEventsCard()
                    LevelMeterView(level: controller.level, history: controller.levelHistory,
                                   capacity: ListeningController.historyLength,
                                   isActive: controller.state.isCapturing)
                    RouteSummaryCard(assessment: controller.assessment, route: controller.route)
                    PolicyCard()
                    DiagnosticsLinks()
                    PrivacyNote()
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Hearing Sense")
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .navigationDestination(item: $debugScreen) { screen in
                switch screen {
                case .conversation: ConversationLiveView()
                case .history: ConversationHistoryView()
                case .summary: NewestConversationRecordView()
                case .privacy: ConversationPrivacyView()
                case .icons: SoundIconGalleryView()
                }
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            controller.scenePhaseChanged(phase)
        }
        // A tap on the Live Activity, or its "Open" control.
        .onOpenURL { url in
            if url == HearingSenseLink.conversation { ConversationNavigation.shared.showsConversation = true }
        }
        #if DEBUG
        .task {
            // Checks without a microphone: `--hs-conversation-demo` plays a scripted conversation,
            // `--hs-screen <name>` opens one of the Window 6 screens directly.
            if ConversationIntelligenceController.isDemoRequested {
                controller.conversation.runDemo()
            }
        }
        #endif
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "ear.badge.waveform")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hearing Sense")
                    .font(.title.bold())
                Text("Ambient awareness for headphone wearers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ListeningButtons: View {
    @Environment(ListeningController.self) private var controller
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        VStack(alignment: .leading, spacing: 12) {
            layout {
                Button {
                    Task { await controller.start() }
                } label: {
                    Label("Start Listening", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.state.canStart)
                .accessibilityHint("Turns on the microphone and starts measuring sound around you.")

                Button {
                    Task { await controller.stop() }
                } label: {
                    Label("Stop Listening", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!controller.state.canStop)
                .accessibilityHint("Turns off the microphone.")
            }
            .controlSize(.large)

            if controller.state == .permissionDenied,
               let settings = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: settings) {
                    Label("Open Settings to allow microphone access", systemImage: "gear")
                }
            }
        }
    }
}

/// The acoustic scene, as a line under the listening buttons. Secondary: the individual sounds
/// are in the recognition card and in the Dynamic Island.
private struct SceneRow: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        if controller.state.isCapturing {
            let scene = controller.scene.estimate?.scene
            Label(scene?.title ?? "Listening for the surroundings…", systemImage: scene?.symbolName ?? "waveform")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Surroundings: \(scene?.title ?? "not known yet")")
                .accessibilityIdentifier("scene.row")
        }
    }
}

private struct RouteSummaryCard: View {
    let assessment: RouteAssessment
    let route: AudioRouteSnapshot

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Audio route", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text(assessment.headline)
                    .font(.body.weight(.semibold))
                Text(assessment.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                RouteLine(title: "In", ports: route.inputs)
                RouteLine(title: "Out", ports: route.outputs)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RouteLine: View {
    let title: String
    let ports: [AudioPortInfo]

    var body: some View {
        LabeledContent(title) {
            Text(ports.isEmpty ? "None" : ports.map { "\($0.name) (\($0.kind.displayName))" }.joined(separator: ", "))
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct PolicyCard: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Picker(selection: Binding(get: { controller.policy }, set: { controller.select($0) })) {
                    ForEach(AudioSessionPolicy.all) { policy in
                        Text(policy.isExperimental ? "\(policy.title) (test)" : policy.title).tag(policy)
                    }
                } label: {
                    Label("Audio session policy", systemImage: "slider.horizontal.3")
                        .font(.headline)
                }
                .pickerStyle(.navigationLink)
                .disabled(controller.state.isCapturing)

                Text(controller.policy.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if controller.state.isCapturing {
                    Text("Stop listening to change the policy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DiagnosticsLinks: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    RecognitionDiagnosticsView()
                } label: {
                    Label("Recognition diagnostics", systemImage: "gauge.with.dots.needle.33percent")
                }
                Divider()
                NavigationLink {
                    RouteDiagnosticsView()
                } label: {
                    Label("Audio route diagnostics", systemImage: "stethoscope")
                }
                Divider()
                NavigationLink {
                    DiagnosticLogView()
                } label: {
                    LabeledContent {
                        Text("\(controller.log.entries.count)")
                    } label: {
                        Label("Event log", systemImage: "list.bullet.rectangle")
                    }
                }
                #if DEBUG
                Divider()
                NavigationLink {
                    SoundIconGalleryView()
                } label: {
                    Label("Sound icon gallery (debug)", systemImage: "square.grid.3x3")
                }
                #endif
            }
        }
    }
}

private struct PrivacyNote: View {
    var body: some View {
        Label {
            Text("Audio is processed on this iPhone, in memory only. Hearing Sense does not record, "
                + "store or upload audio. Speech is transcribed only while “Transcribe nearby speech” is on; "
                + "the last two minutes stay in memory for a summary you ask for, and only that summary is saved. "
                + "While listening, a Live Activity shows icons outside the app. "
                + "It is not a safety or emergency alert system.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// Rounded container used by the main screen sections.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
