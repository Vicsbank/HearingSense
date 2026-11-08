import IslandPresentation
import SwiftUI

/// The app's settings: the choices a user makes, in the system's grouped style. Diagnostics and
/// research tools are not here; Debug builds reach them through "Developer" at the bottom.
struct SettingsView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let live = controller.liveActivity
        let speech = controller.speech
        Form {
            Section("General") {
                NavigationLink("Action Button") { ActionButtonSetupView() }
                    .accessibilityIdentifier("settings.action-button")
                Toggle("Show in Dynamic Island", isOn: binding(\.isEnabled))
                    .accessibilityIdentifier("island.enabled.switch")
            }

            Section {
                Toggle("Sound Icons", isOn: binding(\.showsAmbientIcons))
                    .accessibilityIdentifier("island.ambientIcons.switch")
                Toggle("Urgent Sound Alerts", isOn: binding(\.expandsForImportantEvents))
                    .accessibilityIdentifier("island.expansion.switch")
                Toggle("Alert When Locked", isOn: binding(\.alertsWhileLocked))
                    .accessibilityIdentifier("island.alertsWhileLocked.switch")
                    .disabled(!live.settings.expandsForImportantEvents)
                Toggle("Alert Sound", isOn: binding(\.playsAlertSound))
                    .accessibilityIdentifier("island.alertSound.switch")
                    .disabled(!live.settings.expandsForImportantEvents)
                NavigationLink("Sound Priorities") { AttentionSettingsView() }
            } header: {
                Text("Awareness")
            } footer: {
                Text("For a siren or an alarm, Hearing Sense asks iOS to expand the Dynamic Island. iOS decides whether it does. "
                    + "Hearing Sense is an awareness aid, not an emergency alert system.")
            }
            .disabled(!live.settings.isEnabled)

            Section {
                Toggle("Transcribe Nearby Speech", isOn: Binding(get: { speech.isTranscriptionEnabled },
                                                               set: { speech.setTranscriptionEnabled($0) }))
                    .accessibilityIdentifier("speech.transcription.switch")
                Toggle("Show Summary When Ready", isOn: binding(\.expandsForSummaries))
                    .accessibilityIdentifier("island.summaryExpansion.switch")
                Toggle("Summary Text in Dynamic Island", isOn: binding(\.showsSpeechSummaries))
                    .accessibilityIdentifier("island.speechSummaries.switch")
                NavigationLink("Speech Data & Privacy") { ConversationPrivacyView() }
            } header: {
                Text("Conversation")
            } footer: {
                Text("Needed for Summary. Speech is transcribed on this iPhone and kept in memory for two minutes. "
                    + "Only summaries you ask for are saved.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                NavigationLink("Privacy") { AboutPrivacyView() }
            }

            #if DEBUG
            Section("Developer") {
                NavigationLink("Diagnostics") { DeveloperView() }
                    .accessibilityIdentifier("settings.developer")
            }
            #endif
        }
        .navigationTitle("Settings")
    }

    private func binding(_ keyPath: WritableKeyPath<IslandSettings, Bool>) -> Binding<Bool> {
        let live = controller.liveActivity
        return Binding(get: { live.settings[keyPath: keyPath] }, set: { value in live.update { $0[keyPath: keyPath] = value } })
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }
}

/// What the app does with sound, in a few sentences.
private struct AboutPrivacyView: View {
    var body: some View {
        Form {
            Section {
                Text("Audio is processed on this iPhone, in memory only. Hearing Sense does not record, store or upload audio.")
                Text("Speech is transcribed only while Transcribe Nearby Speech is on. The last two minutes stay in memory "
                    + "for a summary you ask for, and only that summary is saved.")
                Text("While listening, a Live Activity shows icons outside the app.")
            }
            Section {
                Text("Hearing Sense is an awareness aid. It can miss or misunderstand sounds and speech. "
                    + "It is not a safety or emergency alert system.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
