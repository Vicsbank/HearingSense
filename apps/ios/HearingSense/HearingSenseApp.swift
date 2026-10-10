import SwiftUI

@main
struct HearingSenseApp: App {
    @State private var controller = ListeningController()
    #if DEBUG
    @State private var exporter: DebugDiagnosticsExporter?
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
                #if DEBUG
                .task {
                    // Device-test aids; see DebugDiagnosticsExporter.
                    if DebugDiagnosticsExporter.isExportRequested, exporter == nil {
                        let exporter = DebugDiagnosticsExporter(controller: controller)
                        exporter.start()
                        self.exporter = exporter
                    }
                    if DebugDiagnosticsExporter.isAutostartRequested { await controller.start() }
                }
                #endif
        }
    }
}
