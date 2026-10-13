#if DEBUG
import HearingSenseAudio
import SwiftUI

/// What the device test mode (Window 8, `DeviceTestMode`) prohibits right now, and its emergency
/// stop. Shown at the top of the main screen of Debug builds while the mode is on, so that a
/// person and a screen reader (and phone automation, which reads the same labels) see at once
/// that this build does not use the microphone.
struct DeviceTestModeCard: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let configuration = controller.testConfiguration
        if configuration.isEnabled {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Device test mode", systemImage: "lock.shield")
                        .font(.headline)
                    Text(Self.description(configuration))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("test-mode-description")
                    if let deadline = controller.testSessionDeadline {
                        Text("This session ends by itself at \(deadline.formatted(date: .omitted, time: .standard)).")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if configuration.isHalted {
                        Label("Emergency stop is set: nothing starts.", systemImage: "hand.raised.fill")
                            .font(.subheadline.weight(.semibold))
                        Button("Clear emergency stop") { controller.clearEmergencyStop() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("clear-emergency-stop")
                    } else {
                        Button("Emergency stop", role: .destructive) { controller.emergencyStop(reason: "button in the app") }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("emergency-stop")
                            .accessibilityHint("Ends the session and the Live Activity and refuses every start until it is cleared.")
                    }
                }
            }
        }
    }

    static func description(_ configuration: DeviceTestConfiguration) -> String {
        func word(_ isProhibited: Bool) -> String { isProhibited ? "prohibited" : "allowed" }
        return "Microphone \(word(configuration.prohibitsMicrophone)). Speech transcription "
            + "\(word(configuration.prohibitsTranscription)). Model inference \(word(configuration.prohibitsModelInference)). "
            + "Sessions end by themselves after \(Int(configuration.normalized.sessionLimit)) s."
    }
}
#endif
