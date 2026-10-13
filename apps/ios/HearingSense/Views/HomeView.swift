import ConversationUnderstanding
import HearingSenseDomain
import IslandPresentation
import IslandViews
import SwiftUI

/// The first screen. It answers three questions and nothing else: is Hearing Sense listening,
/// what does it hear, and how is it switched on and off. Everything else is in History and
/// Settings.
struct HomeView: View {
    @Environment(ListeningController.self) private var controller
    @ScaledMetric(relativeTo: .largeTitle) private var heroSymbol = HSLayout.heroSymbol
    @State private var asksForTranscription = false
    var showConversation: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: HSSpacing.xl)
                    hero
                    Spacer(minLength: HSSpacing.xl)
                    controls
                }
                .padding(.horizontal, HSLayout.margin)
                .padding(.top, HSSpacing.xs)
                .padding(.bottom, HSSpacing.l)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .alert("Turn On Transcription?", isPresented: $asksForTranscription) {
            Button("Turn On") { controller.speech.setTranscriptionEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Summary needs Transcribe Nearby Speech. Speech from before it is on cannot be summarized.")
        }
    }

    // MARK: - Title and status

    private var header: some View {
        VStack(alignment: .leading, spacing: HSSpacing.xs) {
            Text("Hearing Sense")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: HSSpacing.xs) {
                Circle()
                    .fill(statusColor)
                    .frame(width: HSLayout.statusDot, height: HSLayout.statusDot)
                    .accessibilityHidden(true)
                Text(statusTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home.status")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusTitle: String {
        switch controller.state {
        case .idle: return "Off"
        case .listening:
            #if DEBUG
            if controller.sessionIsSynthetic { return "Listening · Test mode, microphone off" }
            #endif
            return "Listening"
        default: return controller.state.title
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .listening: .green
        case .idle: Color(.systemGray3)
        case .starting, .requestingPermission: .yellow
        default: .orange
        }
    }

    // MARK: - The current sound

    private struct Sound {
        var symbol: String
        var title: String
        var detail: String?
        var tint: Color?
    }

    /// What the Dynamic Island shows right now, in words; the recognizer's own newest event when
    /// the Live Activity is switched off.
    private var sound: Sound {
        guard controller.state.isCapturing else {
            return Sound(symbol: IslandSymbol.listening, title: controller.state == .interrupted ? "Paused" : "Not Listening")
        }
        let scene = controller.scene.estimate?.scene.title
        if let content = controller.liveActivity.content {
            switch content.mode {
            case .ambient:
                return Sound(symbol: content.symbolName, title: content.spokenLabel, detail: scene)
            case .attention:
                let title = content.headlineIsSpeech ? "Nearby Speech" : content.headline ?? content.spokenLabel
                let tint: Color? = switch content.priority {
                case .urgent: .red
                case .high: .orange
                default: nil
                }
                return Sound(symbol: content.symbolName, title: title, detail: scene, tint: tint)
            case .paused:
                return Sound(symbol: IslandSymbol.paused, title: "Paused")
            case .listening:
                break
            }
        } else if let event = controller.recognition.activeEvents.first {
            return Sound(symbol: SoundSymbolCatalog.symbol(for: event).name, title: SoundSymbolCatalog.spokenName(for: event),
                         detail: scene)
        }
        return Sound(symbol: IslandSymbol.listening, title: "Listening", detail: scene)
    }

    private var hero: some View {
        let sound = sound
        let isOn = controller.state.isCapturing
        let tint = sound.tint ?? .accentColor
        return VStack(spacing: HSSpacing.l) {
            SoundSymbolImage(sound.symbol)
                .font(.system(size: min(heroSymbol, HSLayout.heroSymbolLimit), weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: HSLayout.heroDiameter, height: HSLayout.heroDiameter)
                .background(isOn ? AnyShapeStyle(tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: HSSpacing.xxs) {
                Text(sound.title)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                if let detail = sound.detail {
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: sound.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("home.sound")
    }

    // MARK: - Controls

    private var controls: some View {
        let state = controller.state
        return VStack(spacing: HSSpacing.s) {
            if state == .permissionDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Allow Microphone Access…", destination: settings)
                    .font(.body)
                    .frame(minHeight: HSLayout.minimumHitTarget)
            }
            if state.isCapturing {
                Button {
                    let conversation = controller.conversation
                    guard controller.speech.isTranscriptionEnabled else {
                        asksForTranscription = true
                        return
                    }
                    if conversation.phase == .idle { conversation.summarize() }
                    showConversation()
                } label: {
                    buttonLabel("Summary", systemImage: "text.bubble")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Summarizes the last two minutes of speech.")
                .accessibilityIdentifier("conversation.summarize")
            }
            if state.canStop {
                Button {
                    Task { await controller.stop() }
                } label: {
                    buttonLabel("Stop Listening", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityHint("Turns off the microphone.")
                .accessibilityIdentifier("stop-listening")
            } else {
                Button {
                    Task { await controller.start() }
                } label: {
                    buttonLabel("Start Listening", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canStart)
                .accessibilityHint("Turns on the microphone and recognizes sounds around you.")
                .accessibilityIdentifier("start-listening")
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    private func buttonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: HSLayout.buttonLabelHeight)
    }
}
