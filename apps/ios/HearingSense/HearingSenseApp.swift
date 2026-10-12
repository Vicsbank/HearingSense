import HearingSenseAudio
import SwiftUI

@main
struct HearingSenseApp: App {
    @State private var controller = ListeningController.shared
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
                        // The stop of a timed test is in the file the moment it happens.
                        controller.onTimeLimitStop = { [exporter] in exporter.writeNow() }
                    }
                    // Armed before listening starts, and whether or not it starts: the limit
                    // belongs to the launch (see ListeningController.limitListening).
                    if let seconds = DebugDiagnosticsExporter.autostopAfter {
                        controller.limitListening(to: seconds)
                    }
                    if DebugDiagnosticsExporter.isAutostartRequested {
                        await controller.start(source: .automation)
                    }
                    // Presentation check without a microphone; see LiveActivityController.
                    if let scene = LiveActivityController.requestedDemo {
                        controller.liveActivity.runDemo(scene, attention: controller.attention,
                                                        keyAt: LiveActivityController.requestedDemoKeyTime,
                                                        afterBackground: LiveActivityController.demoStartsAfterBackground)
                    }
                }
                #endif
        }
    }
}
