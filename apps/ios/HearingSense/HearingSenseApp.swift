import SwiftUI

@main
struct HearingSenseApp: App {
    @State private var controller = ListeningController()
    #if DEBUG
    @State private var exporter: DebugDiagnosticsExporter?
    @State private var probe: BackgroundInferenceProbe?
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
                        if BackgroundInferenceProbe.isRequested {
                            let probe = BackgroundInferenceProbe()
                            controller.attachExperimentConsumer(probe)
                            exporter.extraHeartbeat = { probe.heartbeat() }
                            exporter.extraReport = { probe.reportText() }
                            self.probe = probe
                        }
                        exporter.start()
                        self.exporter = exporter
                    }
                    if DebugDiagnosticsExporter.isAutostartRequested { await controller.start() }
                }
                #endif
        }
    }
}
