import HearingSenseDomain
import IslandPresentation
import IslandViews
import SwiftUI

/// The Live Activity as seen from inside the app. iOS does not show an app's own activity in
/// the Dynamic Island while that app is on screen, so this card mirrors it: the same views the
/// widget extension draws, fed with the same content.
struct LiveActivityCard: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let live = controller.liveActivity
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Dynamic Island", systemImage: "capsule.portrait.righthalf.filled")
                    .font(.headline)
                if let content = live.content {
                    IslandCompactPreview(content: content)
                        .frame(maxWidth: .infinity)
                    Text(Self.explanation(content))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(live.settings.isEnabled
                        ? "While you listen, Hearing Sense stays in the Dynamic Island: an icon for ordinary sounds, "
                            + "text only for what matters."
                        : "The Live Activity is turned off.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if live.status != .idle, live.status != .running {
                    Label(live.status.title, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Divider()
                NavigationLink {
                    LiveActivitySettingsView()
                } label: {
                    Label("Dynamic Island settings", systemImage: "slider.horizontal.3").font(.subheadline)
                }
                NavigationLink {
                    LiveActivityDebugView()
                } label: {
                    Label("Dynamic Island preview (debug)", systemImage: "rectangle.on.rectangle").font(.subheadline)
                }
            }
        }
    }

    private static func explanation(_ content: IslandContent) -> String {
        switch content.mode {
        case .listening: "Listening. Nothing recognized right now."
        case .ambient: "An ordinary sound: shown as an icon only."
        case .attention: "Needs attention: the island shows the text when it is expanded."
        case .paused: "Paused by the system."
        }
    }
}

/// The compact Dynamic Island, drawn with the widget extension's own views.
struct IslandCompactPreview: View {
    let content: IslandContent
    var isStale = false

    var body: some View {
        HStack(spacing: 0) {
            IslandCompactLeading(content, isStale: isStale)
                .frame(width: 44, alignment: .leading)
            Spacer(minLength: 96)
            IslandCompactTrailing(content, isStale: isStale)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(width: 216, height: 37)
        .background(.black, in: Capsule())
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dynamic Island preview: \(content.spokenLabel)")
    }
}

/// The expanded Dynamic Island, drawn with the widget extension's own views (an approximation
/// of the system's layout).
struct IslandExpandedPreview: View {
    let content: IslandContent
    let sessionStart: Date

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                IslandExpandedLeading(content)
                IslandExpandedCenter(content)
                IslandExpandedTrailing(content, sessionStart: sessionStart)
            }
            IslandExpandedBottom(content) { IslandControls(content: content) }
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(.black, in: RoundedRectangle(cornerRadius: 40))
        .environment(\.colorScheme, .dark)
    }
}

struct IslandLockScreenPreview: View {
    let content: IslandContent
    let sessionStart: Date

    var body: some View {
        IslandLockScreenView(content, sessionStart: sessionStart)
            .foregroundStyle(.white)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 22))
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Settings

struct LiveActivitySettingsView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let live = controller.liveActivity
        Form {
            Section {
                Toggle("Show in the Dynamic Island", isOn: binding(\.isEnabled))
                    .accessibilityIdentifier("island.enabled.switch")
            } footer: {
                Text("While you listen, Hearing Sense stays in the Dynamic Island and on the Lock Screen. iOS ends a "
                    + "Live Activity after about eight hours; open the app to show it again.")
            }

            Section {
                Toggle("Icons for ordinary sounds", isOn: binding(\.showsAmbientIcons))
                    .accessibilityIdentifier("island.ambientIcons.switch")
            } footer: {
                Text("Rain, music, a dog, footsteps and other everyday sounds appear as a small icon, without text "
                    + "and without any alert.")
            }
            .disabled(!live.settings.isEnabled)

            Section {
                Toggle("Expand for important events", isOn: binding(\.expandsForImportantEvents))
                    .accessibilityIdentifier("island.expansion.switch")
                Toggle("Play the alert sound", isOn: binding(\.playsAlertSound))
                    .accessibilityIdentifier("island.alertSound.switch")
                    .disabled(!live.settings.expandsForImportantEvents)
            } footer: {
                Text("Prominent alerts for the highest-priority sounds (a siren, an alarm, a knock). Off: such a "
                    + "sound changes the icon to a warning mark, silently; touch and hold the island to read what it "
                    + "is. On: Hearing Sense also asks iOS to expand the island while the iPhone seems unlocked. "
                    + "iOS decides whether it does. On a locked iPhone the activity is always updated silently. iOS "
                    + "does not tell apps reliably whether the iPhone is locked: with this on, an event in the first "
                    + "seconds after you lock it can light up the screen, and with the alert sound on it can play "
                    + "a sound. Speech never causes an alert. This is not an emergency alert system.")
            }
            .disabled(!live.settings.isEnabled)

            Section {
                Toggle("Show the summary when it is ready", isOn: binding(\.expandsForSummaries))
                    .accessibilityIdentifier("island.summaryExpansion.switch")
            } footer: {
                Text("After you press Summarize, Hearing Sense asks iOS to expand the island once, when the summary "
                    + "is written, while the iPhone seems unlocked. Off: the island shows a bubble; touch and hold it.")
            }
            .disabled(!live.settings.isEnabled)

            Section {
                Toggle("Show speech summaries", isOn: binding(\.showsSpeechSummaries))
                    .accessibilityIdentifier("island.speechSummaries.switch")
            } footer: {
                Text("The first lines of a summary you asked for, in the expanded island. The Lock Screen never "
                    + "shows it, and it is removed while the iPhone is locked. Off: the island says that a summary "
                    + "is ready and the text is read in the app.")
            }
            .disabled(!live.settings.isEnabled)

            Section {
                LabeledContent("Lock state", value: live.lockEstimate.rawValue.capitalized)
            } footer: {
                Text("What this iPhone lets the app know. “Unknown” means expansion is not requested; it stays "
                    + "unknown without a passcode and until the iPhone has been locked once while Hearing Sense was running.")
            }
        }
        .navigationTitle("Dynamic Island")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ keyPath: WritableKeyPath<IslandSettings, Bool>) -> Binding<Bool> {
        let live = controller.liveActivity
        return Binding(get: { live.settings[keyPath: keyPath] }, set: { value in live.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Debug

/// The three presentations with the current content, counters, and synthetic scenes that drive
/// the real activity without a microphone.
struct LiveActivityDebugView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let live = controller.liveActivity
        let content = live.content ?? .listening(since: .now)
        let start = live.activityStartedAt ?? .now
        List {
            Section("Compact") {
                IslandCompactPreview(content: content).frame(maxWidth: .infinity)
            }
            Section("Expanded") {
                IslandExpandedPreview(content: content, sessionStart: start)
            }
            Section("Lock Screen") {
                IslandLockScreenPreview(content: content, sessionStart: start)
            }
            Section("State") {
                LabeledContent("Activity", value: live.status.title)
                LabeledContent("Lock estimate", value: live.lockEstimate.rawValue)
                LabeledContent("Updates", value: "\(live.statistics.updates) · keep-alive \(live.statistics.keepAlives) · "
                    + "coalesced \(live.statistics.coalesced)")
                LabeledContent("Ambient icons", value: "\(live.ambientStatistics.changes) changes · "
                    + "held back \(live.ambientStatistics.heldBack)")
                LabeledContent("Expansion", value: "\(live.alertsSent) sent · "
                    + "\(live.alertsBlocked.values.reduce(0, +)) silent instead")
                LabeledContent("Activities", value: "\(live.activitiesStarted) started · \(live.endedBySystem) ended by iOS")
            }
            .font(.subheadline)
            #if DEBUG
            Section {
                Text("Synthetic events, microphone off. Start a scene, then leave the app: the island shows the "
                    + "activity only while Hearing Sense is not on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(LiveActivityController.DemoScene.allCases, id: \.self) { scene in
                    Button(scene.title) { live.runDemo(scene, attention: controller.attention) }
                }
                if live.isDemoRunning {
                    Button("Stop demo", role: .destructive) { live.stopDemo(attention: controller.attention) }
                }
            } header: {
                Text("Demo scenes")
            }
            #endif
        }
        .navigationTitle("Dynamic Island preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: live.reportText()) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share Live Activity report")
        }
    }
}
