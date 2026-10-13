#if DEBUG
import ActivityKit
import AppIntents
import ConversationUnderstanding
import Foundation
import HearingSenseAudio
import IslandPresentation
import IslandViews
import UIKit

/// `--hs-test-safety-check` (Debug builds, Window 8): checks inside the running app that the
/// device test mode holds, and writes `Documents/hearing-sense-safety-check.txt`.
///
/// It asks for a session in every way the app can be asked — the app's own start, the Toggle
/// intent's `perform()` (called directly, not through the Action Button), a script's start — and
/// after each one reads the objects that would run the microphone: this app's audio session and
/// its audio engine. It then tries to switch transcription on, asks for a summary, waits for the
/// session's own time limit when that is short enough, and uses the emergency stop.
///
/// It proves what the app did in this run, on this device or Simulator. It is not a statement
/// about the microphone's behaviour when it is allowed: nothing here records anything.
///
/// The report holds states and counts only.
@MainActor
final class DeviceTestSafetyCheck {
    static let argument = "--hs-test-safety-check"
    static let fileName = "hearing-sense-safety-check.txt"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    private let controller: ListeningController
    private var lines: [String] = []
    private var passed = 0
    private var failed = 0

    init(controller: ListeningController) {
        self.controller = controller
    }

    func run() async {
        let configuration = DeviceTestMode.configuration
        let live = controller.liveActivity
        let conversation = controller.conversation
        let speech = controller.speech
        note("Hearing Sense device test mode safety check · \(Date.now.formatted(.iso8601)) · \(DeviceInfo.summary)")
        note(DeviceTestMode.reportLines().joined(separator: "\n"))
        note("At the start: \(controller.microphoneFacts)")
        note("")

        check("1", "the test mode is on and prohibits the microphone, transcription and model inference",
              configuration.isEnabled && configuration.prohibitsMicrophone && configuration.prohibitsTranscription
                  && configuration.prohibitsModelInference && !configuration.isHalted,
              DeviceTestMode.summary)
        guard failed == 0 else {
            note("")
            note("STOPPED: the remaining checks only make sense under the locked configuration.")
            finish()
            return
        }
        let permissionBefore = MicrophonePermission.current
        let storedSwitchBefore = speech.storedTranscriptionSetting
        let prominentBefore = live.settings.expandsForImportantEvents
        let whileLockedBefore = live.settings.alertsWhileLocked
        let savedBefore = conversation.history.count

        // 2 — every way to ask for a session gives one without the microphone.
        check("2", "starts off", !controller.session.isOn && controller.state == .idle && microphoneIsOff, controller.microphoneFacts)
        await controller.start(source: .app)
        await wait(3) { live.status == .running }
        check("2a", "the app's own start: a session, no microphone",
              controller.session.phase == .on && controller.sessionIsSynthetic && microphoneIsOff && activityCount == 1,
              "session \(controller.session.phase.rawValue); \(controller.microphoneFacts); activities \(activityCount)")
        await controller.stop(source: .app)
        await wait(3) { self.activityCount == 0 }
        check("2a", "the app's own stop: off, no activity left", !controller.session.isOn && controller.state == .idle && activityCount == 0,
              "session \(controller.session.phase.rawValue); activities \(activityCount)")

        check("2b", "the Toggle intent would not bring the app to the front for the microphone", !controller.needsForegroundToStart,
              "needs foreground: \(controller.needsForegroundToStart)")
        _ = try? await ToggleHearingSenseIntent().perform()
        await wait(3) { live.status == .running }
        check("2b", "the Toggle intent: a session, no microphone",
              controller.session.phase == .on && controller.sessionIsSynthetic && microphoneIsOff && activityCount == 1,
              "session \(controller.session.phase.rawValue); \(controller.microphoneFacts); activities \(activityCount)")

        // 3 — transcription cannot be switched on, and the stored switch is left alone.
        speech.setTranscriptionEnabled(true)
        check("3", "transcription stays off when it is switched on",
              !speech.isTranscriptionEnabled && speech.isTranscriptionLockedOff && speech.storedTranscriptionSetting == storedSwitchBefore,
              "transcription \(speech.isTranscriptionEnabled ? "on" : "off"), locked \(speech.isTranscriptionLockedOff), "
                  + "stored switch unchanged (\(storedSwitchBefore ? "on" : "off"))")

        // 4 — a summary request reaches no model.
        _ = try? await SummarizeConversationIntent().perform()
        try? await Task.sleep(for: .seconds(1))
        check("4", "Summarize writes nothing and calls no model",
              conversation.recapsMade == 0 && !conversation.isLanguageModelAvailable && conversation.history.count == savedBefore,
              "summary requests that reached the model \(conversation.recapsMade); language model reachable: "
                  + "\(conversation.isLanguageModelAvailable); phase \(conversation.phase.rawValue)")
        check("4", "listening goes on after Summarize, still without the microphone",
              controller.session.isOn && microphoneIsOff, controller.microphoneFacts)

        _ = try? await ToggleHearingSenseIntent().perform()
        await wait(3) { self.activityCount == 0 }
        check("2b", "the Toggle intent again: off", !controller.session.isOn && activityCount == 0,
              "session \(controller.session.phase.rawValue); activities \(activityCount)")

        // 2c — a script's start.
        await controller.start(source: .automation)
        await wait(3) { live.status == .running }
        check("2c", "a script's start: a session, no microphone",
              controller.session.phase == .on && controller.sessionIsSynthetic && microphoneIsOff,
              "session \(controller.session.phase.rawValue); \(controller.microphoneFacts)")

        // 5 — the session ends by itself.
        if let deadline = controller.testSessionDeadline, deadline.timeIntervalSinceNow <= 30 {
            let limit = Int(configuration.normalized.sessionLimit)
            await wait(deadline.timeIntervalSinceNow + 5) { !self.controller.session.isOn }
            await wait(3) { self.activityCount == 0 }
            check("5", "the session ends by itself after \(limit) s",
                  !controller.session.isOn && controller.state == .idle && controller.session.lastEndReason == .timeLimit && activityCount == 0,
                  "session \(controller.session.phase.rawValue), last end \(controller.session.lastEndReason?.rawValue ?? "none"), "
                      + "activities \(activityCount)")
            await controller.start(source: .app)
            await wait(3) { live.status == .running }
            check("5", "a new session can be started afterwards, with a new limit",
                  controller.session.isOn && controller.testSessionDeadline != nil && microphoneIsOff,
                  "session \(controller.session.phase.rawValue); \(controller.microphoneFacts)")
        } else {
            check("5", "a time limit is armed for the session", controller.testSessionDeadline != nil,
                  "ends in \(controller.testSessionDeadline.map { Int($0.timeIntervalSinceNow) } ?? -1) s "
                      + "(not waited for: launch with --hs-test-session-limit 10 to see it fire)")
        }

        // 6 — the emergency stop.
        controller.emergencyStop(reason: "safety check")
        await wait(3) { self.activityCount == 0 }
        check("6", "the emergency stop ends the session and the Live Activity",
              !controller.session.isOn && controller.state == .idle && activityCount == 0 && microphoneIsOff
                  && DeviceTestMode.configuration.isHalted,
              "session \(controller.session.phase.rawValue); activities \(activityCount); \(controller.microphoneFacts)")
        _ = try? await ToggleHearingSenseIntent().perform()
        await controller.start(source: .app)
        await controller.start(source: .automation)
        try? await Task.sleep(for: .seconds(1))
        check("6", "nothing starts while it is set: the intent, the app, a script",
              !controller.session.isOn && controller.state == .idle && activityCount == 0 && microphoneIsOff,
              "session \(controller.session.phase.rawValue); activities \(activityCount); \(controller.microphoneFacts)")
        controller.clearEmergencyStop()
        check("6", "it can be cleared, and the mode is still locked",
              !DeviceTestMode.configuration.isHalted && DeviceTestMode.configuration.prohibitsMicrophone, DeviceTestMode.summary)

        // 7 — nothing of the user's was changed, and nothing was asked of iOS.
        check("7", "the microphone permission was not requested", MicrophonePermission.current == permissionBefore,
              "before \(permissionBefore.rawValue), after \(MicrophonePermission.current.rawValue)")
        check("7", "the user's switches are as they were",
              speech.storedTranscriptionSetting == storedSwitchBefore && live.settings.expandsForImportantEvents == prominentBefore
                  && live.settings.alertsWhileLocked == whileLockedBefore,
              "transcribe nearby speech (stored) \(storedSwitchBefore ? "on" : "off"), prominent alerts \(prominentBefore ? "on" : "off"), "
                  + "while locked \(whileLockedBefore ? "on" : "off")")
        check("7", "the microphone never ran in this check", microphoneNeverRan && microphoneIsOff,
              "sampled after every step; at the end: \(controller.microphoneFacts)")
        finish()
    }

    // MARK: - Helpers

    private var microphoneNeverRan = true

    /// This app's audio session is not active and its engine is not running.
    private var microphoneIsOff: Bool {
        let facts = controller.microphoneFacts
        let isOff = facts.contains("audioSession=inactive") && facts.contains("engine=stopped") && !facts.contains("capture=microphone")
        if !isOff { microphoneNeverRan = false }
        return isOff
    }

    private var activityCount: Int { Activity<HearingSenseActivityAttributes>.activities.count }

    private func check(_ number: String, _ title: String, _ isPassed: Bool, _ detail: String) {
        if isPassed { passed += 1 } else { failed += 1 }
        note("[\(isPassed ? "PASS" : "FAIL")] \(number.padding(toLength: 3, withPad: " ", startingAt: 0)) \(title) — \(detail)")
        write()
    }

    private func note(_ line: String) {
        lines.append(line)
    }

    private func finish() {
        note("")
        note("RESULT: \(passed) checks passed, \(failed) failed")
        write()
        controller.diagnosticsExporter?.writeNow()
    }

    @discardableResult
    private func wait(_ seconds: Double, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(max(seconds, 0))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private func write() {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent(Self.fileName),
                                                             options: [.atomic, .noFileProtection])
    }
}
#endif
