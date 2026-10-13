import HearingSenseAudio
import SwiftUI

@main
struct HearingSenseApp: App {
    @State private var controller = ListeningController.shared
    #if DEBUG
    @State private var probe: BackgroundInferenceProbe?
    #endif

    #if DEBUG
    private static var launchAidsHandled = false
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
                #if DEBUG
                .task {
                    // Device-test aids; see DebugDiagnosticsExporter. The export itself belongs to
                    // the controller (it also runs in a process started for an intent, which has
                    // no window); what needs launch arguments is here. A window that is created a
                    // second time must not repeat them.
                    guard !Self.launchAidsHandled else { return }
                    Self.launchAidsHandled = true
                    if DebugDiagnosticsExporter.isExportRequested {
                        let exporter = controller.startDiagnosticsExport()
                        if BackgroundInferenceProbe.isRequested, !DeviceTestMode.configuration.prohibitsModelInference {
                            let probe = BackgroundInferenceProbe()
                            controller.attachExperimentConsumer(probe)
                            exporter.extraHeartbeat = { probe.heartbeat() }
                            exporter.extraReport = { probe.reportText() }
                            self.probe = probe
                        }
                    }
                    if DeviceTestSafetyCheck.isRequested {
                        await DeviceTestSafetyCheck(controller: controller).run()
                    }
                    // Armed before listening starts, and whether or not it starts: the limit
                    // belongs to the launch (see ListeningController.limitListening).
                    if let seconds = DebugDiagnosticsExporter.autostopAfter {
                        controller.limitListening(to: seconds)
                    }
                    if DebugDiagnosticsExporter.isAutostartRequested {
                        await controller.start(source: .automation)
                    }
                    // The Window 7 acceptance walk-through, microphone off; see Window7SelfTest.
                    if Window7SelfTest.isRequested {
                        await Window7SelfTest(controller: controller).run()
                    }
                    // The Window 9 engine and postprocessing walk-through, microphone off; see Window9SelfTest.
                    if Window9SelfTest.isRequested {
                        await Window9SelfTest(controller: controller).run()
                    }
                    // Presentation check without a microphone; see LiveActivityController.
                    if let scene = LiveActivityController.requestedDemo, controller.session.isOn {
                        // Into the open (synthetic) session, like real events.
                        controller.playTestScene(scene, keyAt: LiveActivityController.requestedDemoKeyTime,
                                                 afterBackground: LiveActivityController.demoStartsAfterBackground)
                    } else if let scene = LiveActivityController.requestedDemo {
                        controller.liveActivity.runDemo(scene, attention: controller.attention,
                                                        keyAt: LiveActivityController.requestedDemoKeyTime,
                                                        afterBackground: LiveActivityController.demoStartsAfterBackground)
                    }
                    // Layout check of the island's conversation states, with a sample text:
                    // `--hs-island-conversation summarizing|ready|following|notice`.
                    if let sample = LiveActivityController.requestedConversationSample, controller.session.isOn {
                        controller.liveActivity.receive(conversation: sample)
                    }
                }
                #endif
        }
    }
}
