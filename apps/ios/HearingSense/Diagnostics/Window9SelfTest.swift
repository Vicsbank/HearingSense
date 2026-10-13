#if DEBUG
import ConversationUnderstanding
import Foundation
import HearingSenseAudio
import HearingSenseDomain
import IslandPresentation
import IslandViews
import UIKit

/// `--hs-w9-selftest` (Debug builds): the Window 9 acceptance walk-through in the running app,
/// microphone off, writing `Documents/hearing-sense-w9-selftest.txt`.
///
/// Real: the app's object graph, the App Intents' `perform()`, the conversation state machine,
/// the engine coordinator (Qwen through MLX when its checkpoint is found, Apple's model as the
/// fallback), the postprocessing, SwiftData. Synthetic: the microphone (off) and the speech,
/// which is text written for this project entering where transcribed utterances would.
///
/// Launch arguments: `--hs-w9-expect qwen|apple|fallback` says which engine must write the
/// summaries (`fallback` = Qwen is made unavailable and Apple's model must take over, with the reason).
/// The report holds states, counts, timings and engine names. It never holds a sentence of the
/// conversation; it holds a few words of the (synthetic) summary only as a pass/fail check, not text.
@MainActor
final class Window9SelfTest {
    static let argument = "--hs-w9-selftest"
    static let fileName = "hearing-sense-w9-selftest.txt"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    private let controller: ListeningController
    private var lines: [String] = []
    private var failed = 0
    private var passed = 0
    private var speechID = SpeechEventID()
    private var speechIndex = 0
    /// Longest time the main actor did not run while a model was working (milliseconds).
    private var longestMainStallMs = 0.0
    private var heartbeat: Task<Void, Never>?

    init(controller: ListeningController) { self.controller = controller }

    private static let firstPart = [
        "The team meeting is Thursday at seven forty five.",
        "Actually, move it to Friday, the same time works better.",
        "Please bring twenty dollars for the tickets.",
        "The bus leaves at three thirty p m from the front entrance.",
        "Maria's flight was cancelled so she rebooks for Tuesday morning.",
        "The cupcake order for the party is twenty four, delivered by noon on Saturday.",
        "I'm not sure whether the blue sofa or the grey one arrives first.",
        "The north lot is closed tomorrow for repaving.",
        "The lot reopens on Friday.",
    ]
    private static let laterPart = [
        "Sorry, make that Saturday instead of Friday for the team meeting.",
        "Parking is behind the library and Dana will bring the programs.",
        "The tickets are free now, so no need for the twenty dollars.",
    ]
    private static let oldSentence = "The zebra exhibit at the museum opens in March."

    func run() async {
        guard !DeviceTestMode.configuration.prohibitsModelInference else {
            note("Window 9 self-test NOT RUN: model inference is prohibited by the device test mode. Launch with --hs-test-mode off.")
            write()
            return
        }
        let conversation = controller.conversation
        let live = controller.liveActivity
        let expectation = Self.argumentValue("--hs-w9-expect") ?? "qwen"
        note("Hearing Sense Window 9 self-test · \(Date.now.formatted(.iso8601)) · \(DeviceInfo.summary)")
        note("Microphone: off (synthetic capture). Speech is synthetic text. Expected engine: \(expectation).")
        note("History store: \(ConversationIntelligenceController.usesMemoryOnly ? "memory only" : "isolated synthetic disk store").")
        await wait(8) { conversation.isLanguageModelAvailable }
        note("Some engine available: \(conversation.isLanguageModelAvailable)")
        note("")

        _ = try? await ToggleHearingSenseIntent().perform()
        await wait(4) { live.status == .running }
        check("A", "Hearing Sense ON", controller.session.isOn && controller.state == .listening, "state \(controller.state.title)")

        // Speech alone never summarizes; old speech is not kept.
        conversation.transcriptionProvider = { true }
        let historyBefore = conversation.history.count
        say(Self.oldSentence, secondsAgo: 200)
        for line in Self.firstPart {
            say(line)
            await pause(0.4)
        }
        await pause(3)
        check("6", "normal speech does not start a summary", conversation.phase == .idle && conversation.recapsMade == 0
            && conversation.history.count == historyBefore, "phase \(conversation.phase.rawValue), summaries \(conversation.recapsMade)")
        check("5", "only the last two minutes are buffered",
              !conversation.captions.contains { $0.text.contains("zebra") } && conversation.captions.count == Self.firstPart.count,
              "\(conversation.captions.count) utterances buffered")

        // Summary, with a heartbeat on the main actor to see whether the UI could have stalled.
        startHeartbeat()
        let started = ContinuousClock.now
        _ = try? await SummarizeConversationIntent().perform()
        let sawProgress = await waitFor(seconds: 5) { conversation.phase == .preparing || conversation.phase == .summarizing }
        let islandWhileWorking = live.content?.conversation?.phase
        await wait(180) { conversation.phase == .summaryAvailable || conversation.phase == .idle }
        let toReady = Self.seconds(since: started)
        stopHeartbeat()
        let hasSummary = conversation.phase == .summaryAvailable && conversation.recap?.isSummary == true
        for attempt in await conversation.summarizationAttempts() {
            note("Engine attempt: \(attempt.engine.label), \(attempt.seconds.formatted()) s, \(attempt.failure ?? "success")")
        }
        check("7", "a complete summary was written", hasSummary,
              hasSummary ? "tap to ready \(toReady) s, model \(ConversationIntelligenceController.seconds(conversation.lastRecapSeconds ?? 0))"
                  : "no summary: \(conversation.unavailableMessage ?? "unknown")")
        check("18", "progress is shown while the model works", sawProgress && (islandWhileWorking == .summarizing || islandWhileWorking == nil),
              "phase seen: \(sawProgress), island \(islandWhileWorking?.rawValue ?? "none")")
        check("18", "the main actor was never blocked for long during inference", longestMainStallMs < 750,
              "longest gap \(Int(longestMainStallMs)) ms")
        guard hasSummary else {
            await controller.stop(source: .automation)
            note("RESULT: \(passed) checks passed, \(failed) failed; dependent summary checks not run")
            write()
            return
        }
        let label = conversation.lastEngineLabel ?? "none"
        let reason = conversation.lastFallbackReason
        switch expectation {
        case "qwen":
            check("1-3", "Qwen wrote the summary (default engine)", label.contains("Qwen") && reason == nil, "engine \(label), fallback \(reason ?? "none")")
        case "apple":
            check("4", "Apple's model wrote the summary", label.contains("Apple") && !label.contains("Qwen"), "engine \(label)")
        default:
            check("4", "Qwen unavailable → Apple's model wrote it, and the reason is recorded",
                  label.contains("Apple") && !label.contains("Qwen") && reason != nil, "engine \(label), fallback \(reason ?? "none")")
        }
        check("8", "the summary is saved with the engine's name", conversation.history.first?.engineLabel == conversation.recap?.engineLabel
            && conversation.history.first?.engineLabel != nil, "stored \(conversation.history.first?.engineLabel ?? "none")")
        let text = (conversation.recap?.fullText ?? "").lowercased()
        check("8", "supported facts survived postprocessing (day, times, money, names)",
              text.contains("friday") && (text.contains("7:45") || text.contains("seven forty")) && (text.contains("$20") || text.contains("twenty dollars") || text.contains("20 dollars"))
                  && text.contains("maria"), "checked four facts")
        check("9", "written and spoken numbers agree: nothing deleted for its spelling",
              (text.contains("3:30") || text.contains("three thirty")) && (text.contains("24") || text.contains("twenty four")),
              "bus time and cupcake count present")
        check("10", "unsupported additions are absent (invented sofa decision, old sentence)",
              !text.contains("zebra") && !(text.contains("blue sofa") && text.contains("arrives first") && !text.contains("not sure") && !text.contains("unsure")
                  && !text.contains("unclear")), "checked")
        check("12", "the correction replaced the old day: Friday stated, Thursday not stated as current",
              text.contains("friday") && !Self.statesAsCurrent("thursday", in: conversation.recap?.summary ?? ""),
              "summary mentions Thursday only as the former day: \(!Self.statesAsCurrent("thursday", in: conversation.recap?.summary ?? ""))")
        let fullSummary = conversation.recap?.summary ?? ""
        let preview = live.content?.conversation?.detail ?? ""
        check("16", "the island preview is a part; the stored summary is whole",
              !fullSummary.isEmpty && fullSummary.count >= preview.count && conversation.history.first?.summary == fullSummary,
              "stored \(fullSummary.count) characters, preview \(preview.count) characters")

        // Continue with a correction.
        _ = try? await ContinueConversationIntent().perform()
        check("11", "Continue starts following", conversation.phase == .continuing, "phase \(conversation.phase.rawValue)")
        let updateStarted = ContinuousClock.now
        for line in Self.laterPart {
            say(line)
            await pause(1.2)
        }
        startHeartbeat()
        await wait(150) { conversation.updatesMade >= 1 }
        stopHeartbeat()
        let after = (conversation.recap?.fullText ?? "").lowercased()
        let afterSummary = conversation.recap?.summary ?? ""
        check("11", "the update added the new facts (Saturday, parking, Dana)",
              conversation.updatesMade >= 1 && after.contains("saturday") && (after.contains("parking") || after.contains("library")) && after.contains("dana"),
              "updates \(conversation.updatesMade), Saturday \(after.contains("saturday")), parking/library \(after.contains("parking") || after.contains("library")), Dana \(after.contains("dana")), speech to update \(Self.seconds(since: updateStarted)) s")
        check("12", "the new correction replaced the outdated day (Friday no longer current for the meeting)",
              !Self.statesAsCurrent("friday", about: "meeting", in: conversation.recap?.fullText ?? ""),
              "meeting Friday current: \(Self.statesAsCurrent("friday", about: "meeting", in: conversation.recap?.fullText ?? ""))")
        check("11", "Continue kept unrelated facts across summary and key points",
              after.contains("maria") && after.contains("tuesday") && after.contains("3:30") && after.contains("24"),
              "flight, bus time and cupcake count present")
        check("12", "free tickets supersede the payment instruction in summary and key points",
              after.contains("free") && !Self.statesAsCurrent("$20", about: "ticket", in: conversation.recap?.fullText ?? ""),
              "old payment current: \(Self.statesAsCurrent("$20", about: "ticket", in: conversation.recap?.fullText ?? ""))")
        check("11", "the update did not duplicate earlier statements", Self.duplicateSentences(in: afterSummary) == 0,
              "duplicate sentences \(Self.duplicateSentences(in: afterSummary))")
        check("11", "the engine of the update is named", (conversation.recap?.engineLabel ?? "") != "", "engine \(conversation.recap?.engineLabel ?? "none")")

        // Stop.
        _ = try? await StopConversationIntent().perform()
        check("13", "Stop saves the final summary as completed", conversation.history.first?.status == .completed
            && conversation.history.count == historyBefore + 1, "saved \(conversation.history.count), newest \(conversation.history.first?.status.rawValue ?? "none")")
        check("14", "Stop does not stop listening", controller.session.isOn && controller.state == .listening && conversation.phase == .idle,
              "state \(controller.state.title)")
        check("15", "the full summary is in History, unabridged", conversation.history.first?.summary.count == afterSummary.count,
              "stored \(conversation.history.first?.summary.count ?? 0) characters")
        if !ConversationIntelligenceController.usesMemoryOnly, let saved = conversation.history.first {
            let reopened = try? SwiftDataConversationHistory(inMemory: false).record(saved.id)
            check("15", "a fresh disk store reads the completed full summary and engine",
                  reopened?.summary == saved.summary && reopened?.keyPoints == saved.keyPoints
                    && reopened?.engineLabel == saved.engineLabel && reopened?.status == .completed,
                  "reopened synthetic store")
        }
        check("17", "the temporary transcript is gone", conversation.captions.isEmpty, "\(conversation.captions.count) captions")
        let longest = Self.longestSharedRun(between: conversation.history.map(\.fullText).joined(separator: "\n"),
                                            and: (Self.firstPart + Self.laterPart))
        check("17", "no stored text repeats more than 12 words of the speech in a row", longest <= 12, "longest shared run \(longest) words")

        // Cancellation: switching OFF while a summary is being written.
        for line in Self.firstPart.prefix(6) {
            say(line)
            await pause(0.2)
        }
        _ = try? await SummarizeConversationIntent().perform()
        await pause(0.6)
        _ = try? await ToggleHearingSenseIntent().perform()
        await wait(10) { !self.controller.session.isOn }
        await pause(2)
        check("19", "OFF during a summary cancels cleanly",
              !controller.session.isOn && conversation.phase == .idle && conversation.captions.isEmpty,
              "phase \(conversation.phase.rawValue), session \(controller.session.phase.rawValue)")
        note("")
        note("Engines: " + (conversation.reportText().split(separator: "\n").first { $0.contains("Summary engines") }.map(String.init) ?? "–"))
        note("Memory footprint at end: \(ProcessResourceUsage.sample().memoryFootprintMB.map { String(Int($0)) } ?? "–") MB (Simulator, Mac hardware; not an iPhone figure)")
        note("RESULT: \(passed) checks passed, \(failed) failed")
        write()
    }

    // MARK: - Helpers

    private func startHeartbeat() {
        longestMainStallMs = 0
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                let now = ContinuousClock.now
                let gap = now - last
                let ms = Double(gap.components.seconds) * 1000 + Double(gap.components.attoseconds) / 1e15
                self?.longestMainStallMs = max(self?.longestMainStallMs ?? 0, ms - 50)
                last = now
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// The word is stated as the current value: it appears in a sentence that does not frame it as
    /// changed, former or cancelled.
    static func statesAsCurrent(_ word: String, in text: String) -> Bool {
        let framing = ["moved", "instead", "changed", "from", "originally", "rather", "not", "no longer", "was", "former", "previously", "rescheduled", "superseded"]
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in if let s { sentences.append(s.lowercased()) } }
        return sentences.contains { sentence in sentence.contains(word) && !framing.contains { sentence.contains($0) } }
    }

    static func statesAsCurrent(_ word: String, about topic: String, in text: String) -> Bool {
        // Key points may have no punctuation: inspect each line as well as its sentences.
        text.split(separator: "\n").contains { line in
            var candidates: [String] = []
            let value = String(line)
            value.enumerateSubstrings(in: value.startIndex..., options: .bySentences) { s, _, _, _ in
                if let s { candidates.append(s) }
            }
            return candidates.contains { $0.lowercased().contains(topic) && statesAsCurrent(word, in: $0) }
        }
    }

    static func duplicateSentences(in text: String) -> Int {
        var seen: Set<String> = []
        var duplicates = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            guard let s else { return }
            let key = s.lowercased().filter { $0.isLetter || $0.isNumber }
            if !seen.insert(key).inserted { duplicates += 1 }
        }
        return duplicates
    }

    /// Longest run of words of `text` that also occurs, in the same order, in one of `speech`.
    static func longestSharedRun(between text: String, and speech: [String]) -> Int {
        func words(_ s: String) -> [String] { s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init) }
        let spoken = speech.map(words)
        let source = words(text)
        var best = 0
        for line in spoken where !line.isEmpty {
            var previous = [Int](repeating: 0, count: line.count + 1)
            for word in source {
                var current = [Int](repeating: 0, count: line.count + 1)
                for (index, other) in line.enumerated() where other == word { current[index + 1] = previous[index] + 1; best = max(best, current[index + 1]) }
                previous = current
            }
        }
        return best
    }

    private func say(_ text: String, secondsAgo: TimeInterval = 0) {
        let end = Date.now.addingTimeInterval(-secondsAgo)
        var result = SpeechSemanticResult(
            id: speechID, state: .transcribing, audioTime: AudioTimeRange(start: 0, end: Double(speechIndex + 1) * 4),
            startDate: end.addingTimeInterval(-3), updatedDate: end,
            transcript: SpeechTranscript(text: text, language: "en-US", isFinal: true, quality: .unknown,
                                         audioTime: AudioTimeRange(start: Double(speechIndex) * 4, end: Double(speechIndex + 1) * 4)),
            utteranceCount: speechIndex + 1, transcriptionAvailability: .available, modelAvailability: .available)
        result.recentUtterances = [SpeechUtterance(index: speechIndex, text: text, startDate: end.addingTimeInterval(-3), endDate: end, quality: .good)]
        speechIndex += 1
        controller.conversation.receive(result)
    }

    private func check(_ number: String, _ title: String, _ isPassed: Bool, _ detail: String) {
        if isPassed { passed += 1 } else { failed += 1 }
        note("[\(isPassed ? "PASS" : "FAIL")] \(number.padding(toLength: 4, withPad: " ", startingAt: 0)) \(title) — \(detail)")
        write()
    }

    private func note(_ line: String) { lines.append(line) }
    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    @discardableResult
    private func wait(_ seconds: Double, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func waitFor(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool { await wait(seconds, until: condition) }

    private func write() {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    private static func argumentValue(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = (ContinuousClock.now - start).components
        return (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18).formatted(.number.precision(.fractionLength(1)))
    }
}
#endif
