#if DEBUG
import ActivityKit
import AppIntents
import AttentionReplay
import ConversationUnderstanding
import Foundation
import HearingSenseAudio
import HearingSenseDomain
import IslandPresentation
import IslandViews
import SoundEventDetection
import UIKit

/// `--hs-w7-selftest` (Debug builds): walks through the Window 7 acceptance tests inside the
/// running app and writes `Documents/hearing-sense-w7-selftest.txt`.
///
/// What is real: the app's object graph, the listening switch, the App Intents' `perform()`
/// (called directly, not through Shortcuts or the Action Button), ActivityKit, the conversation
/// state machine, the on-device language model where the environment has one, SwiftData.
///
/// What is synthetic: the microphone is off for the whole run (`--hs-synthetic-capture`), sound
/// events come from scripted scenes, and "speech" is text written for this project that enters
/// where transcribed utterances would. It therefore says nothing about recognition, about the
/// microphone in the background, or about how the Dynamic Island looks and responds to touch.
///
/// The report holds states, counts and timings. It never holds a sentence or a summary.
@MainActor
final class Window7SelfTest {
    static let argument = "--hs-w7-selftest"
    static let fileName = "hearing-sense-w7-selftest.txt"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    private let controller: ListeningController
    private var lines: [String] = []
    private var failed = 0
    private var passed = 0

    init(controller: ListeningController) {
        self.controller = controller
    }

    private static let firstPart = [
        "So for the chemistry project, are we still meeting on Thursday?",
        "No, Thursday doesn't work, the library closes at five that day.",
        "What about Saturday morning then, around ten?",
        "Saturday at ten works, but not at the library, it's closed on weekends.",
        "We could use the study room in the science building, room 204.",
        "I have the data on my laptop, but the graphs are not finished.",
        "Then please finish the graphs by Friday night so we can write the report on Saturday.",
    ]
    private static let laterPart = [
        "One more thing, the report is due next Wednesday, not Monday.",
        "And the teacher said it has to be at least six pages.",
        "Fine, then let's split it, three pages each.",
    ]
    /// Said more than two minutes before the request: must never reach a summary.
    private static let oldSentence = "The zebra exhibit at the museum opens in March."

    private var speechID = SpeechEventID()
    private var speechIndex = 0

    func run() async {
        guard !DeviceTestMode.configuration.prohibitsModelInference else {
            // The walk-through asks the language model for summaries of its scripted sentences.
            note("Hearing Sense Window 7 self-test · \(Date.now.formatted(.iso8601)) · \(DeviceInfo.summary)")
            note("NOT RUN: model inference is prohibited by the device test mode (\(DeviceTestMode.summary)).")
            note("In the Simulator: launch with --hs-test-mode off --hs-w7-selftest, then --hs-test-mode locked.")
            write()
            return
        }
        let conversation = controller.conversation
        let live = controller.liveActivity
        let begin = ProcessResourceUsage.sample()
        note("Hearing Sense Window 7 self-test · \(Date.now.formatted(.iso8601)) · \(DeviceInfo.summary)")
        note("Microphone: off for the whole run (synthetic capture). Sound events and speech text are synthetic.")
        await wait(5) { conversation.isLanguageModelAvailable }
        note("Language model available: \(conversation.isLanguageModelAvailable)")
        note("")

        // 1 — OFF → ON through the intent.
        check("1", "OFF → ON with the Toggle intent", !controller.session.isOn && controller.state == .idle, "starts off")
        _ = try? await ToggleHearingSenseIntent().perform()
        await wait(3) { live.status == .running }
        check("1", "OFF → ON with the Toggle intent", controller.session.phase == .on && controller.state == .listening,
              "session \(controller.session.phase.rawValue), state \(controller.state.title), Live Activity \(live.status.title)")
        check("1", "one Live Activity exists", activityCount == 1, "\(activityCount) activity(ies)")

        // 3 — repeated toggles.
        for _ in 0 ..< 6 { _ = try? await ToggleHearingSenseIntent().perform() }
        async let first = controller.toggle(source: .intent)
        async let second = controller.toggle(source: .intent)
        _ = await (first, second)
        await wait(4) { self.activityCount == 1 && live.status == .running }
        let stats = controller.session.statistics
        check("3", "repeated toggles never give two sessions",
              controller.session.isOn && stats.sessionsStarted - stats.sessionsEnded == 1 && activityCount == 1,
              "started \(stats.sessionsStarted), ended \(stats.sessionsEnded), toggles \(stats.toggles), "
                  + "refused \(stats.requestsRefused), activities alive \(activityCount)")

        // 4 and 13 — ordinary sounds: icons, no requests.
        let alertsBefore = live.statistics.alertRequests
        controller.attention.inject(LiveActivityController.DemoScene.ambient.scenario(keyAt: 3))
        await wait(8) { live.ambientStatistics.changes >= 1 && live.content?.mode == .ambient }
        check("4", "ordinary sounds change the icon", live.ambientStatistics.changes >= 1 && live.content?.mode == .ambient,
              "icon changes \(live.ambientStatistics.changes), showing \(live.content?.redactedSummary ?? "nothing")")
        await pause(6)
        check("13", "ordinary sounds ask for nothing", live.statistics.alertRequests == alertsBefore && live.alertsSent == 0,
              "expansion requests \(live.statistics.alertRequests - alertsBefore), sent to iOS \(live.alertsSent)")

        // Summarize without transcription: explained, nothing invented.
        conversation.transcriptionProvider = { false }
        _ = try? await SummarizeConversationIntent().perform()
        check("5b", "without transcription Summarize explains that past speech is gone",
              conversation.phase == .idle && (conversation.unavailableMessage ?? "").contains("cannot be recovered")
                  && conversation.recapsMade == 0 && live.content?.conversation?.phase == .notice,
              "phase \(conversation.phase.rawValue), island \(live.content?.conversation?.phase.rawValue ?? "none")")

        // 5 and 18 — speech alone never summarizes.
        conversation.transcriptionProvider = { true }
        let historyBefore = conversation.history.count
        say(Self.oldSentence, secondsAgo: 200)
        for line in Self.firstPart {
            say(line)
            await pause(0.6)
        }
        await pause(4)
        check("5", "speech does not start a summary", conversation.phase == .idle && conversation.recapsMade == 0
            && conversation.history.count == historyBefore,
            "phase \(conversation.phase.rawValue), summaries \(conversation.recapsMade), buffered \(conversation.captions.count) utterances")
        check("7", "speech older than two minutes is not kept",
              !conversation.captions.contains { $0.text.contains("zebra") }
                  && conversation.captions.allSatisfy { $0.end > Date.now.addingTimeInterval(-135) },
              "buffered \(conversation.captions.count) utterances, all from the last two minutes")

        // 6, 7, 10 — Summarize through the Live Activity's intent.
        check("6", "the island offers Summarize while nothing was asked",
              live.content.map { $0.conversation == nil || $0.conversation?.phase == .notice } ?? false,
              "controls for state: \(live.content?.conversation?.phase.rawValue ?? "listening")")
        let started = ContinuousClock.now
        _ = try? await SummarizeConversationIntent().perform()
        check("6", "Summarize starts a summary and the island says so",
              conversation.phase == .summarizing || conversation.phase == .preparing || conversation.phase == .summaryAvailable,
              "phase \(conversation.phase.rawValue), island \(live.content?.conversation?.phase.rawValue ?? "none")")
        await wait(90) { conversation.phase == .summaryAvailable || conversation.phase == .idle }
        let summarySeconds = Self.seconds(since: started)
        let hasSummary = conversation.phase == .summaryAvailable && conversation.recap?.isSummary == true
        check("7", "a summary of the last two minutes was written", hasSummary,
              hasSummary ? "in \(summarySeconds) s, \(conversation.recap?.utteranceCount ?? 0) utterances, model "
                  + ConversationIntelligenceController.seconds(conversation.lastRecapSeconds ?? 0)
                  : "no summary (\(conversation.isLanguageModelAvailable ? "model available" : "no language model in this environment"))")
        check("7", "the old sentence is not in it", !(conversation.recap?.fullText ?? "").localizedCaseInsensitiveContains("zebra"), "checked")
        check("10", "the summary is saved to History", conversation.history.count == historyBefore + (hasSummary ? 1 : 0) && hasSummary,
              "saved summaries \(conversation.history.count)")
        check("6", "the island offers Continue", live.content?.conversation?.phase == .summaryReady,
              "island \(live.content?.conversation?.phase.rawValue ?? "none"); expansion requests for the summary "
                  + "\(live.statistics.summaryReadyRequests)")

        // 8 — Continue.
        _ = try? await ContinueConversationIntent().perform()
        check("8", "Continue starts continued understanding", conversation.phase == .continuing
            && live.content?.conversation?.phase == .following,
            "phase \(conversation.phase.rawValue), island \(live.content?.conversation?.phase.rawValue ?? "none")")
        for line in Self.laterPart {
            say(line)
            await pause(1.2)
        }
        check("8", "live captions hold the new sentences", conversation.captions.count >= Self.laterPart.count,
              "\(conversation.captions.count) captions")
        await wait(60) { conversation.updatesMade >= 1 }
        check("8", "the summary was extended", conversation.updatesMade >= 1, "updates \(conversation.updatesMade)")
        let extended = conversation.recap?.fullText ?? ""
        check("8", "the extension holds what was said since (the day, the page count)",
              extended.localizedCaseInsensitiveContains("Wednesday") && extended.localizedCaseInsensitiveContains("six"),
              "checked for two facts of the later sentences")
        let copied = (Self.firstPart + Self.laterPart).filter { extended.contains($0) }.count
        check("17", "at most three short sentences are in the summary as they were said, none longer than 12 words",
              copied <= 3 && (Self.firstPart + Self.laterPart).filter { extended.contains($0) }.allSatisfy { $0.split(separator: " ").count <= 12 },
              "\(copied) of \(Self.firstPart.count + Self.laterPart.count) sentences copied")

        // 9 — Stop ends the conversation only.
        _ = try? await StopConversationIntent().perform()
        let completed = conversation.history.first?.status == .completed
        check("9", "Stop ends understanding and listening goes on",
              conversation.phase == .idle && controller.state == .listening && controller.session.isOn && activityCount == 1,
              "phase \(conversation.phase.rawValue), state \(controller.state.title), activities \(activityCount)")
        check("10", "the final summary is in History, completed", completed && conversation.history.count == historyBefore + 1,
              "saved \(conversation.history.count), newest \(conversation.history.first?.status.rawValue ?? "none")")
        check("17", "the temporary captions are deleted after Stop", conversation.captions.isEmpty && conversation.tentativeCaption == nil,
              "\(conversation.captions.count) captions left")

        // 12 — a highest-priority acoustic event.
        let requestsBefore = live.statistics.alertRequests
        controller.attention.inject(LiveActivityController.DemoScene.siren.scenario(keyAt: 2))
        await wait(10) { live.statistics.alertRequests > requestsBefore }
        let blocked = live.alertsBlocked.map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: ", ")
        check("12", "a siren makes the presentation request", live.statistics.alertRequests > requestsBefore
            && live.content?.mode == .attention,
            "requests \(live.statistics.alertRequests - requestsBefore); sent to iOS \(live.alertsSent); held back by the gate: "
                + (blocked.isEmpty ? "none" : blocked) + "; showing \(live.content?.redactedSummary ?? "nothing")")
        await pause(4)

        // Resource use while a session is on and events arrive (Simulator: Mac hardware).
        let idleStart = ProcessResourceUsage.sample()
        await pause(20)
        let idleEnd = ProcessResourceUsage.sample()

        // 11 — OFF while a conversation is followed.
        for line in Self.firstPart {
            say(line)
            await pause(0.3)
        }
        // Window 8, A — Continue before any summary exists: one is written first, then following begins.
        let recapsBeforeContinue = conversation.recapsMade
        _ = try? await ContinueConversationIntent().perform()
        check("W8-A", "Continue without a summary starts writing one",
              conversation.phase == .preparing || conversation.phase == .summarizing || conversation.phase == .continuing,
              "phase \(conversation.phase.rawValue); island \(live.content?.conversation?.phase.rawValue ?? "none")")
        await wait(90) { conversation.phase == .continuing || (conversation.phase == .idle && conversation.recapsMade > recapsBeforeContinue) }
        await pause(1)
        let followed = conversation.phase == .continuing
        check("W8-A", "following begins by itself when the summary is ready",
              followed && conversation.recapsMade == recapsBeforeContinue + 1 && live.content?.conversation?.phase == .following,
              "phase \(conversation.phase.rawValue); recaps +\(conversation.recapsMade - recapsBeforeContinue); island "
                  + "\(live.content?.conversation?.phase.rawValue ?? "none")")
        // Window 8, E — a touch on the island leads to this summary's own page.
        let destination = live.content.map { HearingSenseLink.destination(for: $0) }
        check("W8-E", "the island's link is the saved summary's page",
              conversation.currentRecordID != nil && destination == conversation.currentRecordID.map(HearingSenseLink.summary),
              destination?.host() ?? "no link")
        // Window 8, B — Summary while following: the summary is brought up to date at once.
        let updatesBeforeSummary = conversation.updatesMade
        for line in Self.laterPart {
            say(line)
            await pause(0.3)
        }
        let pressed = ContinuousClock.now
        _ = try? await SummarizeConversationIntent().perform()
        await wait(60) { conversation.updatesMade > updatesBeforeSummary }
        check("W8-B", "Summary while following brings the summary up to date",
              conversation.updatesMade > updatesBeforeSummary && conversation.phase == .continuing,
              "updates +\(conversation.updatesMade - updatesBeforeSummary) after \(Self.seconds(since: pressed)); phase \(conversation.phase.rawValue)")
        // Window 8 — the island's text is a preview; the saved summary is the whole one.
        let preview = live.content?.conversation?.detail ?? ""
        let saved = conversation.currentRecordID.flatMap(conversation.record)
        check("W8", "the saved summary is complete, the island shows a part of it",
              !(saved?.summary ?? "").isEmpty && (saved?.summary.count ?? 0) >= preview.count
                  && live.content?.conversation?.heading == nil,
              "saved \(saved?.summary.count ?? 0) characters, \(saved?.keyPoints.count ?? 0) key points; preview \(preview.count) characters")
        let savedBeforeOff = conversation.history.count
        _ = try? await ToggleHearingSenseIntent().perform()
        await wait(4) { self.activityCount == 0 }
        check("2", "ON → OFF with the Toggle intent", !controller.session.isOn && controller.state == .idle,
              "session \(controller.session.phase.rawValue), state \(controller.state.title)")
        check("11", "OFF ends everything cleanly",
              followed && conversation.phase == .idle && !conversation.isSessionActive && conversation.captions.isEmpty
                  && activityCount == 0 && live.content == nil && controller.scene.estimate == nil,
              "was following: \(followed); phase \(conversation.phase.rawValue); captions \(conversation.captions.count); "
                  + "activities alive \(activityCount)")
        check("11", "saved summaries survive OFF", conversation.history.count == savedBeforeOff && savedBeforeOff >= 2
            && conversation.history.allSatisfy { $0.status == .completed },
            "saved \(conversation.history.count), all completed: \(conversation.history.allSatisfy { $0.status == .completed })")
        _ = try? await SummarizeConversationIntent().perform()
        check("18", "nothing is summarized while off", conversation.phase == .idle && conversation.history.count == savedBeforeOff,
              "phase \(conversation.phase.rawValue)")

        let end = ProcessResourceUsage.sample()
        note("")
        note("Resources (iOS Simulator = Mac hardware; not an iPhone measurement, microphone and classifier not running):")
        note("  whole run: \(Self.format(end.date.timeIntervalSince(begin.date))) s, CPU "
            + Self.percent(end.cpuUtilization(since: begin)) + " of one core on average")
        note("  20 s with a session on and no speech: CPU " + Self.percent(idleEnd.cpuUtilization(since: idleStart))
            + " of one core; memory footprint \(Self.megabytes(idleEnd)) MB (start of run \(Self.megabytes(begin)) MB, end \(Self.megabytes(end)) MB)")
        note("  Live Activity updates in the run: \(live.statistics.updates), keep-alives \(live.statistics.keepAlives); "
            + "activities started \(live.activitiesStarted); scene changes \(controller.scene.statistics.changes)")
        note("  language model calls: \(conversation.recapsMade) summary request(s) + \(conversation.updatesMade) update(s); none without a request")
        note("")
        note("Summary log (metadata only):")
        for entry in controller.log.entries where entry.message.hasPrefix("Recap") || entry.message.hasPrefix("Summary request") {
            note("  " + entry.message)
        }
        note("")
        note("RESULT: \(passed) checks passed, \(failed) failed")
        write()
    }

    // MARK: - Helpers

    private var activityCount: Int { Activity<HearingSenseActivityAttributes>.activities.count }

    /// A sentence enters where a transcribed utterance would.
    private func say(_ text: String, secondsAgo: TimeInterval = 0) {
        let end = Date.now.addingTimeInterval(-secondsAgo)
        var result = SpeechSemanticResult(
            id: speechID, state: .transcribing, audioTime: AudioTimeRange(start: 0, end: Double(speechIndex + 1) * 4),
            startDate: end.addingTimeInterval(-3), updatedDate: end,
            transcript: SpeechTranscript(text: text, language: "en-US", isFinal: true, quality: .unknown,
                                         audioTime: AudioTimeRange(start: Double(speechIndex) * 4, end: Double(speechIndex + 1) * 4)),
            utteranceCount: speechIndex + 1, transcriptionAvailability: .available, modelAvailability: .available)
        result.recentUtterances = [SpeechUtterance(index: speechIndex, text: text, startDate: end.addingTimeInterval(-3),
                                                   endDate: end, quality: .good)]
        speechIndex += 1
        controller.conversation.receive(result)
    }

    private func check(_ number: String, _ title: String, _ isPassed: Bool, _ detail: String) {
        if isPassed { passed += 1 } else { failed += 1 }
        note("[\(isPassed ? "PASS" : "FAIL")] \(number.padding(toLength: 3, withPad: " ", startingAt: 0)) \(title) — \(detail)")
        write()
    }

    private func note(_ line: String) {
        lines.append(line)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @discardableResult
    private func wait(_ seconds: Double, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private func write() {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = (ContinuousClock.now - start).components
        return format(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    private static func format(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
    private static func percent(_ value: Double?) -> String { value.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) + " %" } ?? "–" }
    private static func megabytes(_ usage: ProcessResourceUsage) -> String { usage.memoryFootprintMB.map(format) ?? "–" }
}
#endif
