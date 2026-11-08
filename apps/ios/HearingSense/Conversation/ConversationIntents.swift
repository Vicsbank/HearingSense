import Foundation
import Observation

/// Lets an intent or a link from the Live Activity ask the app's interface to show the
/// conversation screen.
@Observable
final class ConversationNavigation {
    static let shared = ConversationNavigation()
    enum Destination: Hashable { case captions, request(UUID), record(UUID) }
    private(set) var destination: Destination?
    private(set) var revision = 0
    func open(_ destination: Destination?) {
        self.destination = destination
        revision += 1 // the same destination can be requested again after the user went back
    }
    var showsConversation: Bool {
        get { destination == .captions }
        set { if newValue { open(.captions) } else if destination == .captions { open(nil) } }
    }
    func showSummary(_ requestID: UUID) { open(.request(requestID)) }
}
