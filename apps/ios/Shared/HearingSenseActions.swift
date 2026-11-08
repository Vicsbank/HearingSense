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
    private static var pending: HearingSenseAction?
    static var handler: (@MainActor (HearingSenseAction) -> Void)? {
        didSet {
            if let pending, let handler { self.pending = nil; handler(pending) }
        }
    }

    static func perform(_ action: HearingSenseAction) {
        if let handler { handler(action) } else { pending = action }
    }
}

/// Where a tap on the Live Activity (or its "Open" control) leads in the app.
enum HearingSenseLink {
    static let conversation = URL(string: "hearingsense://conversation")!
    static let home = URL(string: "hearingsense://home")!

    /// The page of one saved summary. An identifier only: no text of the summary is in the link.
    static func summary(_ id: UUID) -> URL {
        URL(string: "hearingsense://summary/\(id.uuidString)")!
    }

    /// The saved summary a link names, if it is such a link.
    static func summaryID(in url: URL) -> UUID? {
        guard url.scheme == "hearingsense", url.host() == "summary" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// Where a touch on the island (outside its buttons) leads: the page of the summary it
    /// shows, otherwise the first screen.
    static func destination(for content: IslandContent) -> URL {
        content.conversation?.recordID.map(summary) ?? home
    }
}

struct SummarizeConversationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Summarize the Last Two Minutes"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .foreground(.immediate) }

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

/// The two buttons along the bottom of the expanded Dynamic Island, in every state:
///
/// | state | left | right |
/// |---|---|---|
/// | listening, summary ready | Summary | Continue |
/// | summary being written | Summary (a progress bar above) | Continue |
/// | following a conversation | Summary | Stop |
/// | paused, not updating | none | none |
///
/// - Summary writes a summary of the last two minutes, or brings a followed one up to date.
/// - Continue keeps following the conversation (a summary is written first when there is none).
/// - Stop ends the following; the summary is finished and saved, listening for sounds goes on.
///
/// Equal weight, one row, one height. Each runs its own App Intent; a touch anywhere else on
/// the island opens the app (`HearingSenseLink.destination`). Touching and holding the island
/// only reveals them; nothing is summarized until the user presses one.
struct IslandControls: View {
    let content: IslandContent
    var isStale = false

    var body: some View {
        if isStale || content.mode == .paused {
            EmptyView()
        } else {
            VStack(spacing: 4) {
                if let conversation = content.conversation, conversation.phase == .summarizing {
                    HStack {
                        Text(conversation.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(conversation.since, style: .timer).monospacedDigit()
                    }
                    .font(.caption)
                    .accessibilityLabel("Writing the summary")
                }
                HStack(spacing: IslandMetrics.margin) {
                    Button(intent: SummarizeConversationIntent()) {
                        pill("Summary", systemImage: "text.bubble.fill", tint: IslandStyle.conversationTint)
                    }
                    .accessibilityHint("Summarizes what was transcribed in the last two minutes.")
                    if content.conversation?.phase == .following {
                        Button(intent: StopConversationIntent()) {
                            pill("Stop", systemImage: "stop.fill", tint: .orange)
                        }
                        .accessibilityHint("Stops following the conversation. Hearing Sense keeps listening for sounds.")
                    } else {
                        Button(intent: ContinueConversationIntent()) {
                            pill("Continue", systemImage: "captions.bubble.fill", tint: IslandStyle.conversationTint)
                        }
                        .accessibilityHint("Keeps following the conversation: captions and a growing summary.")
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func pill(_ title: String, systemImage: String, tint: Color) -> some View {
        IslandControlPill(title: title, systemImage: systemImage, tint: tint)
    }
}

/// Finished summaries put their controls beside the camera, leaving the bottom region for
/// three readable preview lines within the system's 160 pt expanded-height limit.
struct IslandSummaryHeaderControl: View {
    let content: IslandContent
    let isLeading: Bool

    var body: some View {
        Group {
            if isLeading {
                Button(intent: SummarizeConversationIntent()) {
                    IslandControlPill(title: "Summary", systemImage: "text.bubble.fill", tint: IslandStyle.conversationTint)
                }
            } else if content.conversation?.phase == .following {
                Button(intent: StopConversationIntent()) {
                    IslandControlPill(title: "Stop", systemImage: "stop.fill", tint: .orange)
                }
            } else {
                Button(intent: ContinueConversationIntent()) {
                    IslandControlPill(title: "Continue", systemImage: "captions.bubble.fill", tint: IslandStyle.conversationTint)
                }
            }
        }
        .frame(width: 104)
        .padding(isLeading ? .leading : .trailing, 8)
        .buttonStyle(.plain)
    }
}

private struct IslandControlPill: View {
    let title: String
    let systemImage: String
    let tint: Color
    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(IslandControlLabelStyle())
            .dynamicTypeSize(...IslandMetrics.largestTextSize)
            .frame(maxWidth: .infinity)
            .frame(height: IslandMetrics.controlHeight)
            .foregroundStyle(tint)
            .background(tint.opacity(0.24), in: Capsule())
    }
}

/// The trailing region of the expanded Dynamic Island: the session timer. In the summary layout
/// it is part of the small header beside the camera.
struct IslandTrailingControl: View {
    let content: IslandContent
    let sessionStart: Date
    var isStale = false

    var body: some View {
        if !isStale, content.summaryConversation != nil {
            Text(sessionStart, style: .timer)
                .font(.footnote.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .dynamicTypeSize(...IslandMetrics.largestTextSize)
                .frame(maxWidth: 52, alignment: .trailing)
                .frame(height: IslandMetrics.headerHeight)
                .padding(.trailing, IslandMetrics.margin)
                .accessibilityHidden(true)
        } else {
            IslandExpandedTrailing(content, sessionStart: sessionStart)
        }
    }
}

/// Icon and title of a control, with one spacing and one weight for all of them.
private struct IslandControlLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.footnote.weight(.semibold))
            configuration.title.font(.subheadline.weight(.semibold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}
