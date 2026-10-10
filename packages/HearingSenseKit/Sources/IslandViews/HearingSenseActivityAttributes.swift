#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation
import IslandPresentation

/// The one Live Activity of a listening session. Shared by the app (which starts and updates
/// it) and the widget extension (which draws it).
public struct HearingSenseActivityAttributes: ActivityAttributes {
    public typealias ContentState = IslandContent

    /// When the activity was started (the session timer of the Lock Screen presentation).
    public var sessionStart: Date

    public init(sessionStart: Date) {
        self.sessionStart = sessionStart
    }
}
#endif
