import SwiftUI
import WidgetKit

/// The app's widget extension. It holds one thing: the Live Activity of a listening session.
@main
struct HearingSenseWidgetBundle: WidgetBundle {
    var body: some Widget {
        HearingSenseLiveActivity()
    }
}
