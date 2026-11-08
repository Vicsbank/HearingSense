#if DEBUG
import AVFAudio
import ConversationUnderstanding
import Foundation
import HearingSenseDomain
import HearingSenseAudio
import IslandPresentation
import QwenRuntime
import SpeechPipeline
import UIKit

/// Explicit Debug fixtures only. These modes never open the microphone or ordinary History.
actor StabilityFixtureEngine: SummarizationEngine {
    nonisolated let identity = SummarizationEngineIdentity(kind: .qwen, modelID: "SYNTHETIC-UI-FIXTURE", revision: "test", quantization: "none", runtime: "scripted")
    var fail = false
    var calls = 0
    let delay: Double
    init(delay: Double = 0.3) { self.delay = delay }
    func setFailure(_ value: Bool) { fail = value }
    func isAvailable() -> Bool { true }
    func prewarm() {}
    func recap(transcript: String, notes: [String]) async throws -> RecapDraft {
        calls += 1
        let fails = fail
        await Task.detached { [delay] in try? await Task.sleep(for: .seconds(delay)) }.value
        if fails { throw RecapError.modelFailure("synthetic_failure") }
        return RecapDraft(title: "Bus plans", summary: "The bus departs Friday morning. Maya brings signed forms.")
    }
    func update(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft { try await recap(transcript: newTranscript, notes: []) }
}

@MainActor
enum Window9StabilitySelfTest {
    static let fixture = "The bus is leaving on Friday morning. Maya will bring the signed forms for everyone. The tickets are available at the front entrance."
    static let benchmarkText = "The team meeting is Friday at 7:45. Bring twenty dollars for the tickets."
    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var requested: Bool {
        ["--hs-w9-stability-selftest", "--hs-w9-ui-fixture", "--hs-w9-fixed-audio", "--hs-w9-benchmark", "--hs-w9-device-acceptance"].contains(where: arguments.contains)
    }
    static func feed(_ text: String, to conversation: ConversationIntelligenceController, index: Int = 0, id: SpeechEventID = SpeechEventID()) {
        let now = Date.now
        var result = SpeechSemanticResult(id: id, state: .transcribing, audioTime: AudioTimeRange(start: 0, end: 4),
                                         startDate: now - 3, updatedDate: now,
                                         transcript: SpeechTranscript(text: text, language: "en-US", isFinal: true, quality: .unknown,
                                                                      audioTime: AudioTimeRange(start: 0, end: 4)),
                                         utteranceCount: index + 1, transcriptionAvailability: .available, modelAvailability: .available)
        result.recentUtterances = [SpeechUtterance(index: index, text: text, startDate: now - 3, endDate: now, quality: .good)]
        conversation.receive(result)
    }
    static func wait(_ seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        return condition()
    }
    static func run(controller: ListeningController) async {
        guard requested else { return }
        let wasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasDisabled }
        if arguments.contains("--hs-w9-device-acceptance") {
            // One foreground run avoids auto-lock between separate acceptance launches.
            await audio(controller: controller)
            await Window9SelfTest(controller: controller).run()
            await stability()
            // Stay awake while the operator collects the reports and installs Release.
            // This flag exists only in Debug; terminating this app ends the override.
            UIApplication.shared.isIdleTimerDisabled = true
            await holdForCollection()
            return
        }
        if arguments.contains("--hs-w9-benchmark") { await benchmark(); return }
        if arguments.contains("--hs-w9-fixed-audio") { await audio(controller: controller); return }
        if arguments.contains("--hs-w9-ui-fixture") {
            save(["synthetic_only": true, "ready": false, "stage": "starting",
                  "transcription_allowed": !DeviceTestMode.configuration.prohibitsTranscription], "window9-ui-state.json")
            await controller.start(source: .automation)
            controller.conversation.transcriptionProvider = { true }
            controller.conversation.transcriptionChanged(isOn: true)
            feed(fixture, to: controller.conversation)
            save(["synthetic_only": true, "ready": true, "transcription_enabled": controller.speech.isTranscriptionEnabled,
                  "transcription_locked_off": controller.speech.isTranscriptionLockedOff,
                  "transcription_allowed": !DeviceTestMode.configuration.prohibitsTranscription], "window9-ui-state.json")
            return // Human/automation taps Summary; this is a clearly labeled scripted engine.
        }
        await stability()
    }
    static func holdForCollection() async {
        try? await Task.sleep(for: .seconds(600))
    }
    static func stability() async {
        var checks: [String: Bool] = [:]
        let engine = StabilityFixtureEngine()
        let routed = SummarizationCoordinator(primary: engine, fallback: engine)
        let conversation = ConversationIntelligenceController(inMemory: true, summarizer: routed)
        conversation.transcriptionProvider = { true }
        conversation.sessionWillStart(isTranscriptionOn: true)
        feed(fixture, to: conversation)
        conversation.summarize()
        let first = conversation.summaryRequestID
        checks["immediate_summary_destination"] = first != nil && ConversationNavigation.shared.destination == .request(first!)
        for _ in 0..<8 { conversation.summarize() }
        checks["repeated_taps_coalesce"] = first == conversation.summaryRequestID
        for n in 1...4 { feed("The signs at the entrance are green.", to: conversation, index: n) }
        _ = await wait { !conversation.isSummaryWorking }
        checks["accepted_and_saved"] = conversation.recap?.isSummary == true && conversation.currentRecordID != nil
        checks["request_bound_to_record"] = first.flatMap { conversation.requestRecords[$0] } == conversation.currentRecordID
        checks["one_engine_call"] = await engine.calls == 1
        let saved = conversation.recap
        let record = conversation.currentRecordID
        checks["history_matches_visible_summary"] = record.flatMap { conversation.record($0)?.summary } == saved?.summary
        let count = conversation.history.count
        await engine.setFailure(true)
        conversation.summarize()
        _ = await wait { !conversation.isSummaryWorking }
        checks["failed_attempt_keeps_summary"] = conversation.recap == saved && conversation.currentRecordID == record
        checks["failed_attempt_has_notice"] = conversation.summaryRequestID.flatMap { conversation.requestNotices[$0] } != nil
        checks["failure_inserts_no_history_row"] = conversation.history.count == count
        conversation.continueUnderstanding()
        checks["continue_after_failure_keeps_record"] = conversation.currentRecordID == record && conversation.history.count == count
        conversation.stopUnderstanding()
        feed(fixture, to: conversation, index: 5)
        await engine.setFailure(false)
        conversation.summarize()
        let cancelledID = conversation.summaryRequestID
        conversation.foregroundChanged(false)
        checks["background_ends_visible_work"] = !conversation.isSummaryWorking
        try? await Task.sleep(for: .milliseconds(400))
        checks["cancelled_request_never_saves"] = cancelledID.flatMap { conversation.requestRecords[$0] } == nil && conversation.history.count == count
        conversation.foregroundChanged(true)
        _ = await wait { conversation.summaryRequestID != cancelledID && !conversation.isSummaryWorking }
        checks["resume_has_fresh_request"] = conversation.summaryRequestID != cancelledID
        checks["resume_saves_once"] = conversation.history.count == count + 1
        checks["late_result_does_not_replace_resumed_record"] = conversation.summaryRequestID.flatMap { conversation.requestRecords[$0] } == conversation.currentRecordID
        conversation.sessionDidEnd()
        let unsaved = ConversationIntelligenceController(inMemory: true, summarizer: routed)
        unsaved.transcriptionProvider = { true }
        unsaved.rejectsHistoryWritesForTesting = true
        unsaved.sessionWillStart(isTranscriptionOn: true)
        feed(fixture, to: unsaved)
        var islandPhase: IslandConversation.Phase?
        unsaved.onIslandState = { islandPhase = $0?.phase }
        unsaved.summarize()
        _ = await wait { !unsaved.isSummaryWorking }
        checks["write_failure_is_explicit"] = unsaved.storageError != nil
        checks["write_failure_never_claims_saved"] = unsaved.currentRecordID == nil && unsaved.history.isEmpty && islandPhase == .notice
        checks["write_failure_never_binds_request_to_record"] = unsaved.summaryRequestID.flatMap { unsaved.requestRecords[$0] } == nil
        unsaved.continueUnderstanding()
        unsaved.stopUnderstanding()
        checks["failed_final_write_never_claims_saved"] = unsaved.storageError != nil && islandPhase == .notice
        unsaved.sessionDidEnd()
        save(["synthetic_only": true, "scripted_engine": true, "checks": checks,
              "passed": checks.values.filter { $0 }.count, "failed": checks.values.filter { !$0 }.count], "window9-stability.json")
    }

    static func benchmark() async {
        guard let directory = QwenModelLocator.locate() else { save(["status": "model_missing"], "window9-benchmark.json"); return }
        let engine = QwenSummarizationEngine(modelDirectory: directory, maxRecapTokens: 256)
        var runs: [[String: Any]] = []
        for n in 0..<4 {
            let request = SummaryRequest(operation: .summary, sourceRevision: n, budget: 600, checkReserve: 0)
            let started = ContinuousClock.now
            do {
                let draft = try await SummaryRequest.$current.withValue(request) { try await engine.recap(transcript: benchmarkText, notes: []) }
                let metrics = await engine.lastMetrics
                request.finish(.completed)
                runs.append(["index": n, "cold": n == 0, "seconds": SummaryRequest.seconds(started.duration(to: .now)),
                             "prompt_tokens": metrics.promptTokens, "generated_tokens": metrics.generatedTokens,
                             "tokens_per_second": metrics.tokensPerSecond, "parsed": !draft.summary.isEmpty,
                             "trace": trace(request)])
            } catch { runs.append(["index": n, "status": "failed", "seconds": SummaryRequest.seconds(started.duration(to: .now))]) }
            save(["synthetic_only": true, "backend": QwenSummarizationEngine.executionBackend, "runs": runs], "window9-benchmark.json")
        }
        await engine.releaseResources()
    }

    private actor AudioResults {
        var assembler = TranscriptAssembler()
        var text: String { assembler.text }
        var didFail = false
        var didFinish = false
        func receive(_ event: TranscriptionEvent) {
            switch event {
            case .update(let update): assembler.apply(update)
            case .failed: didFail = true
            case .finished: didFinish = true
            }
        }
    }
    static func audio(controller: ListeningController) async {
        let recognizer = AppleSpeechTranscriber()
        let availability = await recognizer.availability()
        guard availability.isUsable else {
            save(["synthetic_only": true, "status": "transcription_unavailable", "supported": AppleSpeechTranscriber.isSupportedOnThisDevice], "window9-audio.json")
            return
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = folder.appendingPathComponent("window9-fixed-input.aiff")
        let results = AudioResults()
        do {
            let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard input.processingFormat.channelCount == 1 else { throw CancellationError() }
            let utterance = try await recognizer.beginUtterance(at: 0) { await results.receive($0) }
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard let samples = buffer.floatChannelData?[0] else { break }
                await utterance.append(Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))), sampleRate: input.processingFormat.sampleRate)
            }
            await utterance.finish()
            // SpeechAnalyzer finishing and delivery of the final results are separate tasks.
            let deliveryDeadline = ContinuousClock.now + .seconds(10)
            while !(await results.didFinish), !(await results.didFail), ContinuousClock.now < deliveryDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            let text = await results.text
            let failed = await results.didFail
            await controller.start(source: .automation)
            let conversation = controller.conversation
            conversation.transcriptionProvider = { true }
            conversation.transcriptionChanged(isOn: true)
            feed(text, to: conversation)
            conversation.summarize()
            _ = await wait(90) { !conversation.isSummaryWorking }
            save(["synthetic_only": true, "microphone": false, "status": failed ? "transcription_failed" : "finished",
                  "recognized_words": text.split(whereSeparator: \.isWhitespace).count,
                  "recognizes_friday": text.lowercased().contains("friday"),
                  "recognizes_tickets": text.lowercased().contains("tickets"),
                  "recognizes_forms": text.lowercased().contains("forms"),
                  "final_delivery_finished": await results.didFinish,
                  "summary_accepted": conversation.recap?.isSummary == true,
                  "summary_saved": conversation.currentRecordID != nil], "window9-audio.json")
            await controller.stop(source: .automation)
        } catch { save(["synthetic_only": true, "status": "audio_probe_failed"], "window9-audio.json") }
        await recognizer.releaseResources()
    }
    static func trace(_ request: SummaryRequest) -> [[String: Any]] {
        request.snapshot.events.map { ["stage": $0.stage, "outcome": $0.outcome, "elapsed": $0.elapsed, "duration": $0.duration] }
    }
    static func save(_ report: [String: Any], _ name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}
#endif
