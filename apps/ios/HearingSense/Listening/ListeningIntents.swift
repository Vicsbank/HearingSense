import AppIntents
import Foundation
import HearingSenseAudio

// The listening switch as App Intents (Window 7).
//
// "Toggle Hearing Sense" is the one intent meant for the Action Button (Settings → Action Button →
// Shortcut → Hearing Sense → Toggle Hearing Sense). It turns the listening session on or off and
// does nothing else: no summary, no menu, no "continue", no conversation stop. Those live in the
// Dynamic Island and in the app.
//
// Public App Intents only. No hardware input is intercepted and the app is never terminated:
// "off" stops the microphone, the recognition, the temporary speech text and the Live Activity.
//
// `AudioRecordingIntent` (iOS 18) is the system's contract for an intent that changes an app's
// recording state: the app may start the microphone while it is not on screen, and must show a
// Live Activity for as long as it records — which is what a listening session does anyway.
// `LiveActivityIntent` runs the intent in the app's process and lets it start that activity.
//
// The contract is enforced by App Intents: when `perform()` of an `AudioRecordingIntent` returns
// with an active audio session and no Live Activity, the framework stops the process with a
// fatal error (crash reports of 2026-10-11 on the iPhone 18 Pro, PerformActionExecutorTask). The
// activity is requested by a queued job, so every intent that leaves the microphone on waits
// for it (`requireLiveActivityForIntent`) and switches listening off again when there is none.

/// ON when off, OFF when on.
struct ToggleHearingSenseIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Hearing Sense"
    static let description = IntentDescription(
        "Turns Hearing Sense listening on or off. Made for the Action Button.",
        categoryName: "Listening")
    /// Runs without opening the app; comes to the front only when it has to (the first
    /// microphone permission prompt).
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ListeningController.shared
        if controller.needsForegroundToStart {
            try await continueInForeground("Hearing Sense needs to ask for the microphone once.", alwaysConfirm: false)
        }
        let outcome = await controller.toggle(source: .intent)
        if let problem = await controller.requireLiveActivityForIntent() {
            return .result(dialog: IntentDialog(stringLiteral: problem))
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

/// Turns listening on; does nothing when it is on already. For automations.
struct StartHearingSenseIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Hearing Sense"
    static let description = IntentDescription("Turns Hearing Sense listening on.", categoryName: "Listening")
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ListeningController.shared
        guard !controller.session.isOn else {
            if let problem = await controller.requireLiveActivityForIntent() {
                return .result(dialog: IntentDialog(stringLiteral: problem))
            }
            return .result(dialog: "Hearing Sense is already on.")
        }
        if controller.needsForegroundToStart {
            try await continueInForeground("Hearing Sense needs to ask for the microphone once.", alwaysConfirm: false)
        }
        await controller.start(source: .intent)
        if let problem = await controller.requireLiveActivityForIntent() {
            return .result(dialog: IntentDialog(stringLiteral: problem))
        }
        let isOn = controller.session.isOn
        return .result(dialog: isOn ? "Hearing Sense is on." : "Hearing Sense could not start. Open the app and try again.")
    }
}

/// Turns listening off; does nothing when it is off already. For automations.
struct StopHearingSenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Hearing Sense"
    static let description = IntentDescription("Turns Hearing Sense listening off.", categoryName: "Listening")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ListeningController.shared.stop(source: .intent)
        return .result(dialog: "Hearing Sense is off.")
    }
}

/// What the Shortcuts app and the Action Button's shortcut picker offer: the listening switch.
/// The conversation controls (Summarize, Continue, Stop) are deliberately not here.
struct HearingSenseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleHearingSenseIntent(),
                    phrases: ["Toggle \(.applicationName)", "Switch \(.applicationName) on or off"],
                    shortTitle: "Toggle Hearing Sense", systemImageName: "ear.badge.waveform")
        AppShortcut(intent: StartHearingSenseIntent(),
                    phrases: ["Start \(.applicationName)", "Start listening with \(.applicationName)"],
                    shortTitle: "Start Listening", systemImageName: "mic.fill")
        AppShortcut(intent: StopHearingSenseIntent(),
                    phrases: ["Stop \(.applicationName)", "Stop listening with \(.applicationName)"],
                    shortTitle: "Stop Listening", systemImageName: "stop.fill")
    }
}
