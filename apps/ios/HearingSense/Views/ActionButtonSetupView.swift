import SwiftUI

// "Action Button": how to put "Toggle Hearing Sense" on the Action Button.
//
// iOS has no public API that assigns the Action Button and no public link to its page in
// Settings, so the user chooses the shortcut there once, by hand. The app's part is done at
// installation: "Toggle Hearing Sense" is an App Shortcut (`HearingSenseShortcuts`) and is
// listed in the Action Button's shortcut picker without any setup in the Shortcuts app.
//
// This screen therefore only says which three taps are needed. It has no button that opens
// Settings: the only page an app may open is its own, which is not where the Action Button is.
//
// Optional: Start and Stop in the app work without it.

struct ActionButtonSetupView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: HSSpacing.s) {
                    Image(systemName: "button.vertical.left.press")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Turn Hearing Sense on or off with one press, without opening the app.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HSSpacing.xs)
            }

            Section {
                Step(number: 1, text: "Open the **Settings** app and tap **Action Button**.")
                Step(number: 2, text: "Swipe to **Shortcut**, then tap **Choose a Shortcut**.")
                Step(number: 3, text: "Under **Hearing Sense**, tap **Toggle Hearing Sense**.")
            } header: {
                Text("Set Up Once")
            } footer: {
                Text("iOS lets only you choose what the Action Button does. Afterwards, press and hold it to switch listening on or off.")
            }
        }
        .navigationTitle("Action Button")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
    }
}
