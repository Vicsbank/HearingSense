import SwiftUI

@main
struct HearingSenseApp: App {
    @State private var controller = ListeningController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
        }
    }
}
