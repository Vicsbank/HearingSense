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
/// - Expanded: text, for attention episodes only.
/// - Lock Screen: icon-focused, whatever the priority; never event text or speech text.
struct HearingSenseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HearingSenseActivityAttributes.self) { context in
            IslandLockScreenView(context.state, sessionStart: context.attributes.sessionStart, isStale: context.isStale)
                .foregroundStyle(.white)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedLeading(context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpandedTrailing(context.state, sessionStart: context.attributes.sessionStart)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandExpandedCenter(context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBottom(context.state)
                }
            } compactLeading: {
                IslandCompactLeading(context.state, isStale: context.isStale)
            } compactTrailing: {
                IslandCompactTrailing(context.state, isStale: context.isStale)
            } minimal: {
                IslandMinimal(context.state, isStale: context.isStale)
            }
            .keylineTint(context.state.mode == .attention ? IslandStyle.tint(for: context.state) : nil)
        }
    }
}
