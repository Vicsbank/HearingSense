import HearingSenseAudio
import HearingSenseDomain
import SwiftUI

/// The app's three places: the listening screen, the saved summaries and the settings.
struct ContentView: View {
    @Environment(ListeningController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = ConversationNavigation.shared
    /// Saved summaries opened on top of History (a summary opened from the Dynamic Island).
    @State private var historyPath = NavigationPath()

    enum AppTab: Hashable {
        case listen, history, settings
    }

    #if DEBUG
    /// `--hs-screen conversation|history|summary|privacy|icons|island|islandsettings|actionbutton|settings|developer`
    enum DebugScreen: String, Hashable, Identifiable {
        case conversation, history, summary, privacy, icons, island, islandsettings, actionbutton, settings, developer
        var id: String { rawValue }

        var tab: AppTab {
            switch self {
            case .history, .summary: .history
            case .settings, .actionbutton, .privacy, .islandsettings, .developer: .settings
            default: .listen
            }
        }
    }

    private static let requestedScreen: DebugScreen? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--hs-screen"), index + 1 < arguments.count else { return nil }
        return DebugScreen(rawValue: arguments[index + 1])
    }()

    @State private var tab = requestedScreen?.tab ?? .listen
    @State private var debugScreen = requestedScreen.flatMap { $0 == .history || $0 == .settings ? nil : $0 }
    #else
    @State private var tab = AppTab.listen
    #endif

    var body: some View {
        TabView(selection: $tab) {
            Tab("Listen", systemImage: "ear", value: AppTab.listen) {
                NavigationStack {
                    HomeView { }
                        .navigationDestination(isPresented: $navigation.showsConversation) {
                            ConversationLiveView()
                        }
                        #if DEBUG
                        .navigationDestination(item: debugBinding(for: .listen)) { debugDestination($0) }
                        #endif
                }
            }
            Tab("History", systemImage: "clock", value: AppTab.history) {
                NavigationStack(path: $historyPath) {
                    ConversationHistoryView()
                        .navigationDestination(for: UUID.self) { ConversationRecordView(id: $0) }
                        .navigationDestination(for: ConversationNavigation.Destination.self) { destination in
                            switch destination {
                            case .request(let id): SummaryRequestView(requestID: id)
                            case .record(let id): ConversationRecordView(id: id)
                            case .captions: ConversationLiveView()
                            }
                        }
                        #if DEBUG
                        .navigationDestination(item: debugBinding(for: .history)) { debugDestination($0) }
                        #endif
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                        #if DEBUG
                        .navigationDestination(item: debugBinding(for: .settings)) { debugDestination($0) }
                        #endif
                }
            }
        }
        .onChange(of: navigation.revision, initial: true) { _, _ in
            guard let destination = navigation.destination else { return }
            switch destination {
            case .captions: tab = .listen
            case .request, .record:
                tab = .history
                historyPath = NavigationPath([destination])
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            controller.scenePhaseChanged(phase)
        }
        // The summary's two-minute buffer follows the transcription switch.
        .onChange(of: controller.speech.isTranscriptionEnabled, initial: true) { _, isOn in
            controller.conversation.transcriptionChanged(isOn: isOn)
        }
        // A tap on the Live Activity, or its "Open" control.
        .onOpenURL { url in
            if let id = HearingSenseLink.summaryID(in: url) {
                // "Open" on a finished summary: that summary's own page, in History.
                controller.conversation.refreshHistory()
                navigation.open(.record(id))
                return
            }
            tab = .listen
            if url == HearingSenseLink.conversation || HearingSenseLink.summaryID(in: url) != nil {
                if let requestID = controller.conversation.summaryRequestID { navigation.showSummary(requestID) }
                else { navigation.showsConversation = true }
            }
        }
        #if DEBUG
        .task {
            // Checks without a microphone: `--hs-conversation-demo` plays a scripted conversation,
            // `--hs-screen <name>` opens one of the screens directly.
            if ConversationIntelligenceController.isDemoRequested {
                controller.conversation.runDemo()
            }
        }
        #endif
    }

    #if DEBUG
    private func debugBinding(for tab: AppTab) -> Binding<DebugScreen?> {
        Binding(get: { debugScreen?.tab == tab ? debugScreen : nil }, set: { debugScreen = $0 })
    }

    @ViewBuilder
    private func debugDestination(_ screen: DebugScreen) -> some View {
        switch screen {
        case .conversation: ConversationLiveView()
        case .history: ConversationHistoryView()
        case .summary: NewestConversationRecordView()
        case .privacy: ConversationPrivacyView()
        case .icons: SoundIconGalleryView()
        case .island: LiveActivityDebugView()
        case .islandsettings: LiveActivitySettingsView()
        case .actionbutton: ActionButtonSetupView()
        case .settings: SettingsView()
        case .developer: DeveloperView()
        }
    }
    #endif
}

/// Diagnostics and research tools: everything the first screen showed before the redesign.
/// Reached from Settings in Debug builds only.
struct DeveloperView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HSSpacing.m) {
                #if DEBUG
                DeviceTestModeCard()
                StatusCard(state: controller.state, format: controller.captureFormat, isSynthetic: controller.sessionIsSynthetic)
                #else
                StatusCard(state: controller.state, format: controller.captureFormat)
                #endif
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
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
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
                .accessibilityIdentifier("start-listening")

                Button {
                    Task { await controller.stop() }
                } label: {
                    Label("Stop Listening", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!controller.state.canStop)
                .accessibilityHint("Turns off the microphone.")
                .accessibilityIdentifier("stop-listening")
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

/// Rounded container used by the main screen sections.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: HSRadius.card, style: .continuous))
    }
}
