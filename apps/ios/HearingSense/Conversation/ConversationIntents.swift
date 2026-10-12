import Foundation
import Observation

/// Lets an intent or a link from the Live Activity ask the app's interface to show the
/// conversation screen.
@Observable
final class ConversationNavigation {
    static let shared = ConversationNavigation()
    var showsConversation = false
}
