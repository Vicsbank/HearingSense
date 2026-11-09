import ActivityKit
import IslandPresentation
import IslandViews
import SwiftUI
import WidgetKit

/// Places the shared presentation pieces (`IslandViews`) into the Lock Screen banner and the
/// Dynamic Island regions. It draws `IslandContent` as the app sent it and decides nothing: what
/// is shown, and whether an update may expand the island, is decided in the app
/// (`IslandPipeline`, `AlertGate`).
///
/// - Compact and minimal: icons only.
/// - Expanded (the user touches and holds the island): the current sound, the listening status
///   and one control (`IslandControls`, `IslandTrailingControl`: Summary, then Open or Stop).
///   Holding the island only shows it; nothing is summarized until Summary is pressed.
/// - Lock Screen: icon-focused, whatever the priority; never event text or speech text. A warning
///   that waits for acknowledgement adds "Got It".
///
/// A tap on the activity opens the app, on the conversation screen while a summary exists.
struct HearingSenseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HearingSenseActivityAttributes.self) { context in
            VStack(spacing: 8) {
                IslandLockScreenView(context.state, sessionStart: context.attributes.sessionStart, isStale: context.isStale)
                // A warning that waits for the user can be cleared here too.
                if context.state.needsAcknowledgement, !context.isStale {
                    IslandAcknowledgeButton(content: context.state)
                        .frame(maxWidth: 200)
                        .padding(.bottom, 8)
                }
            }
                .foregroundStyle(.white)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.link(for: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if Self.hasHeader(context) {
                        IslandSummaryHeaderControl(content: context.state, isLeading: true)
                    } else {
                        IslandExpandedLeading(context.state, isStale: context.isStale)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                // Priority: the control beside the camera (Open, Stop) keeps its full width; a long
                // title in the centre is shortened instead.
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    if Self.hasHeader(context) {
                        IslandSummaryHeaderControl(content: context.state, isLeading: false)
                    } else {
                        IslandTrailingControl(content: context.state, sessionStart: context.attributes.sessionStart,
                                              isStale: context.isStale)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandExpandedCenter(context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBottom(context.state) {
                        if !Self.hasHeader(context) { IslandControls(content: context.state, isStale: context.isStale) }
                    }
                }
            } compactLeading: {
                IslandCompactLeading(context.state, isStale: context.isStale)
            } compactTrailing: {
                IslandCompactTrailing(context.state, isStale: context.isStale)
            } minimal: {
                IslandMinimal(context.state, isStale: context.isStale)
            }
            // Ready/following controls occupy the camera row; the bottom is text only.
            .contentMargins(.horizontal, 12, for: .expanded)
            .contentMargins(.top, 8, for: .expanded)
            .contentMargins(.bottom, 8, for: .expanded)
            .keylineTint(context.state.mode == .attention ? IslandStyle.tint(for: context.state) : nil)
            .widgetURL(Self.link(for: context.state))
        }
    }

    private static func link(for content: IslandContent) -> URL {
        HearingSenseLink.destination(for: content)
    }

    /// The summary layout: a small header beside the camera and one column of text below it.
    private static func hasHeader(_ context: ActivityViewContext<HearingSenseActivityAttributes>) -> Bool {
        !context.isStale && context.state.summaryConversation != nil
    }
}
