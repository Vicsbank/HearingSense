import AppIntents
import ConversationUnderstanding
import Foundation
import Observation

/// "Recap Conversation": the shortcut meant for the Action Button (Settings → Action Button →
/// Shortcut → Hearing Sense). Public App Intents only; no hardware button is intercepted.
///
/// First run: a recap of the recent conversation is written and saved. While a conversation is
/// being followed: it stops following. It runs in the app's process without bringing the app
/// to the front, so it also works while Hearing Sense listens in the background.
///
/// The answer is a generic sentence. It never contains what was said: the shortcut can run on
/// a locked iPhone, and the recap is read in the app.
struct RecapConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Recap Conversation"
    static let description = IntentDescription(
        "Writes a summary of what was just said nearby and saves it in Hearing Sense. Run it again to stop following the conversation.",
        categoryName: "Conversation")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = ConversationIntelligenceController.shared else {
            return .result(dialog: "Hearing Sense is not listening. Open the app and start listening first.")
        }
        return .result(dialog: IntentDialog(stringLiteral: controller.actionInvoked()))
    }
}

/// "Continue Understanding" after a recap, without opening the app.
struct ContinueUnderstandingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Understanding"
    static let description = IntentDescription(
        "Keeps following the conversation after a recap: live captions in Hearing Sense and a summary that grows.",
        categoryName: "Conversation")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = ConversationIntelligenceController.shared, controller.phase == .summaryAvailable else {
            return .result(dialog: "Ask for a recap first, then continue.")
        }
        controller.continueUnderstanding()
        return .result(dialog: controller.phase == .continuing
            ? "Following the conversation. Open Hearing Sense to read the captions."
            : "The conversation cannot be followed right now.")
    }
}

/// Opens the live conversation screen.
struct OpenConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens the recap and the live captions in Hearing Sense.",
                                               categoryName: "Conversation")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ConversationNavigation.shared.showsConversation = true
        return .result()
    }
}

struct HearingSenseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecapConversationIntent(),
                    phrases: ["Recap the conversation with \(.applicationName)", "What did they say, \(.applicationName)",
                              "\(.applicationName) recap"],
                    shortTitle: "Recap Conversation", systemImageName: "text.bubble")
        AppShortcut(intent: ContinueUnderstandingIntent(),
                    phrases: ["Continue understanding with \(.applicationName)", "Keep following with \(.applicationName)"],
                    shortTitle: "Continue Understanding", systemImageName: "captions.bubble")
        AppShortcut(intent: OpenConversationIntent(),
                    phrases: ["Open the conversation in \(.applicationName)"],
                    shortTitle: "Open Conversation", systemImageName: "bubble.left.and.text.bubble.right")
    }
}

/// Lets an intent ask the app's interface to show the conversation screen.
@Observable
final class ConversationNavigation {
    static let shared = ConversationNavigation()
    var showsConversation = false
}
