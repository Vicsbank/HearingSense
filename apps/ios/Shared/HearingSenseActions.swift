import AppIntents
import IslandPresentation
import IslandViews
import SwiftUI

// The conversation controls of the Live Activity (Window 7). This folder is compiled into the
// app and into its widget extension: a button in a Live Activity names an App Intent type, and
// the type has to exist where the button is drawn (the extension) and where it runs (the app).
//
// `LiveActivityIntent`: iOS runs `perform()` in the app's process, not in the extension. The
// app is alive there, because a listening session keeps it running. In the extension the
// handler below is never set and `perform()` is never called.
//
// None of these intents is offered to Shortcuts, Siri or the Action Button
// (`isDiscoverable == false`): the Action Button switches listening on and off and nothing
// else. They can only be reached from the expanded Dynamic Island and from the app's own buttons.

enum HearingSenseAction: String, Sendable {
    /// Summarize what was transcribed in the last two minutes.
    case summarize
    /// Keep following the conversation after a summary.
    case continueUnderstanding
    /// Stop following the conversation. Listening for sounds goes on.
    case stopUnderstanding
}

/// Where the intents hand their action to the app. Set once by the app at launch.
@MainActor
enum HearingSenseActionCenter {
    static var handler: (@MainActor (HearingSenseAction) -> Void)?

    static func perform(_ action: HearingSenseAction) {
        handler?(action)
    }
}

/// Where a tap on the Live Activity (or its "Open" control) leads in the app.
enum HearingSenseLink {
    static let conversation = URL(string: "hearingsense://conversation")!
    static let home = URL(string: "hearingsense://home")!
}

struct SummarizeConversationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Summarize the Last Two Minutes"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        HearingSenseActionCenter.perform(.summarize)
        return .result()
    }
}

struct ContinueConversationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Continue Understanding"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        HearingSenseActionCenter.perform(.continueUnderstanding)
        return .result()
    }
}

struct StopConversationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Understanding"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        HearingSenseActionCenter.perform(.stopUnderstanding)
        return .result()
    }
}

/// The controls of the expanded Dynamic Island, chosen by what the content says:
///
/// | state | controls |
/// |---|---|
/// | listening, nothing asked | Summarize |
/// | summary being written | (a line of text, no control) |
/// | summary ready | Continue · Open |
/// | following a conversation | Stop · Open |
/// | paused, not updating | none |
///
/// Touching and holding the island only reveals these; nothing is summarized until the user
/// presses Summarize.
struct IslandControls: View {
    let content: IslandContent
    var isStale = false

    var body: some View {
        if isStale || content.mode == .paused {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                switch content.conversation?.phase {
                case nil, .notice:
                    Button(intent: SummarizeConversationIntent()) {
                        control("Summarize last 2 min", systemImage: "text.bubble")
                    }
                    .tint(IslandStyle.conversationTint)
                    .accessibilityHint("Writes a summary of what was transcribed in the last two minutes.")
                case .summarizing:
                    Label("Writing the summary…", systemImage: "ellipsis.bubble")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                case .summaryReady:
                    Button(intent: ContinueConversationIntent()) {
                        control("Continue", systemImage: "captions.bubble")
                    }
                    .tint(IslandStyle.conversationTint)
                    .accessibilityHint("Keeps following the conversation: captions and a growing summary.")
                    openLink
                case .following:
                    Button(intent: StopConversationIntent()) {
                        control("Stop", systemImage: "stop.circle")
                    }
                    .tint(.orange)
                    .accessibilityHint("Stops following the conversation. Hearing Sense keeps listening for sounds.")
                    openLink
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var openLink: some View {
        Link(destination: HearingSenseLink.conversation) {
            control("Open", systemImage: "arrow.up.forward.app")
        }
        .padding(.vertical, 5)
        .background(.white.opacity(0.12), in: Capsule())
        .foregroundStyle(.white)
        .accessibilityHint("Opens the summary in Hearing Sense.")
    }

    private func control(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }
}
