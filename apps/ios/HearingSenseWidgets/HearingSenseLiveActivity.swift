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
/// - Lock Screen: icon-focused, whatever the priority; never event text or speech text.
///
/// A tap on the activity opens the app, on the conversation screen while a summary exists.
struct HearingSenseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HearingSenseActivityAttributes.self) { context in
            IslandLockScreenView(context.state, sessionStart: context.attributes.sessionStart, isStale: context.isStale)
                .foregroundStyle(.white)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.link(for: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // The centre region lies below the camera; the icon and the timer are moved
                    // down to its row, so that the three share one centre line.
                    // (Not in the summary layout: it has no centre region, and its header stays
                    // beside the camera.)
                    IslandExpandedLeading(context.state, isStale: context.isStale)
                        .frame(maxHeight: Self.hasHeader(context) ? nil : .infinity, alignment: .bottom)
                }
                // Priority: the control beside the camera (Open, Stop) keeps its full width; a long
                // title in the centre is shortened instead.
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    IslandTrailingControl(content: context.state, sessionStart: context.attributes.sessionStart,
                                          isStale: context.isStale)
                        .frame(maxHeight: Self.hasHeader(context) ? nil : .infinity, alignment: .bottom)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandExpandedCenter(context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBottom(context.state) {
                        IslandControls(content: context.state, isStale: context.isStale)
                    }
                }
            } compactLeading: {
                IslandCompactLeading(context.state, isStale: context.isStale)
            } compactTrailing: {
                IslandCompactTrailing(context.state, isStale: context.isStale)
            } minimal: {
                IslandMinimal(context.state, isStale: context.isStale)
            }
            // The system's defaults leave more room above the header and under the buttons than
            // beside them. With these the header sits level with the camera, and three lines
            // of text and the buttons fit below it.
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
