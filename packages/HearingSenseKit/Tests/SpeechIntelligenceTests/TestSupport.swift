import AVFAudio
import Foundation
import HearingSenseDomain
import SemanticSummary
import SpeechPipeline
import os
@testable import SpeechIntelligence

// Everything in this file is SYNTHETIC test scaffolding: scripted "speech", a scripted
// recognizer and a scripted language model. It exercises the pipeline's logic deterministically
// and says nothing about recognition or summary accuracy.

/// Words "spoken" at known times on the audio clock.
struct SpokenUtterance: Sendable {
    var start: TimeInterval
    var words: [String]
    var wordDuration: TimeInterval = 0.3

    init(_ text: String, at start: TimeInterval, wordDuration: TimeInterval = 0.3) {
        self.start = start
        words = text.split(separator: " ").map(String.init)
        self.wordDuration = wordDuration
    }

    var end: TimeInterval { start + Double(words.count) * wordDuration }
    func wordRange(_ index: Int) -> ClosedRange<TimeInterval> {
        (start + Double(index) * wordDuration) ... (start + Double(index + 1) * wordDuration)
    }
}

/// A recognizer that "hears" exactly the scripted words whose audio it was given: a word is
/// recognized only if the utterance session started before the word and was fed past its end.
/// So a session that starts late (no pre-roll) loses the first words, like a real recognizer.
final class ScriptedTranscriber: SpeechTranscribing {
    struct Behaviour: Sendable {
        var availability = TranscriptionAvailability.available
        /// The first N `beginUtterance` calls throw.
        var failingBegins = 0
        /// Sessions (by start order, 0-based) that fail as soon as they recognize a word.
        var failingSessions: Set<Int> = []
        /// `finish()` delivers no final result and no `.finished` (recognizer hangs).
        var neverFinishes = false
        /// Every final result is delivered twice.
        var duplicateFinals = false
        var confidence: Double? = 0.95
    }

    struct Counters: Sendable {
        var begins = 0
        var sessions = 0
        var prepares = 0
        var releases = 0
        var cancels = 0
        var sessionStarts: [TimeInterval] = []
    }

    let languageIdentifier = "en-US"
    let speech: [SpokenUtterance]
    private let behaviour: OSAllocatedUnfairLock<Behaviour>
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    init(speech: [SpokenUtterance], behaviour: Behaviour = Behaviour()) {
        self.speech = speech
        self.behaviour = OSAllocatedUnfairLock(initialState: behaviour)
    }

    var count: Counters { counters.withLock { $0 } }
    func update(_ change: @Sendable (inout Behaviour) -> Void) { behaviour.withLock { change(&$0) } }
    fileprivate func noteCancel() { counters.withLock { $0.cancels += 1 } }

    func availability() async -> TranscriptionAvailability { behaviour.withLock { $0.availability } }
    func prepare() async { counters.withLock { $0.prepares += 1 } }
    func releaseResources() async { counters.withLock { $0.releases += 1 } }

    func beginUtterance(at audioTime: TimeInterval, onEvent: @escaping TranscriptionEventHandler) async throws
        -> any UtteranceTranscription
    {
        let behaviour = behaviour.withLock { $0 }
        let (begin, index) = counters.withLock { counters -> (Int, Int) in
            counters.begins += 1
            guard counters.begins > behaviour.failingBegins else { return (counters.begins, -1) }
            counters.sessions += 1
            counters.sessionStarts.append(audioTime)
            return (counters.begins, counters.sessions - 1)
        }
        guard begin > behaviour.failingBegins else {
            throw TranscriptionError.unavailable(.failed("scripted start failure"))
        }
        return ScriptedSession(owner: self, speech: speech, start: audioTime, behaviour: behaviour,
                               fails: behaviour.failingSessions.contains(index), onEvent: onEvent)
    }
}

private actor ScriptedSession: UtteranceTranscription {
    private let owner: ScriptedTranscriber
    private let speech: [SpokenUtterance]
    private let start: TimeInterval
    private let behaviour: ScriptedTranscriber.Behaviour
    private let fails: Bool
    private let onEvent: TranscriptionEventHandler
    private var fed: TimeInterval
    private var lastText = ""
    private var isOver = false

    init(owner: ScriptedTranscriber, speech: [SpokenUtterance], start: TimeInterval,
         behaviour: ScriptedTranscriber.Behaviour, fails: Bool, onEvent: @escaping TranscriptionEventHandler)
    {
        self.owner = owner
        self.speech = speech
        self.start = start
        self.behaviour = behaviour
        self.fails = fails
        self.onEvent = onEvent
        fed = start
    }

    private func heard() -> (text: String, range: AudioTimeRange)? {
        var words: [String] = []
        var first: TimeInterval?
        var last: TimeInterval = 0
        for utterance in speech {
            for index in utterance.words.indices {
                let range = utterance.wordRange(index)
                guard range.lowerBound >= start - 1e-6, range.upperBound <= fed + 1e-6 else { continue }
                words.append(utterance.words[index])
                first = first ?? range.lowerBound
                last = range.upperBound
            }
        }
        guard let first else { return nil }
        return (words.joined(separator: " "), AudioTimeRange(start: first, end: last))
    }

    func append(_ samples: [Float], sampleRate: Double) async {
        guard !isOver else { return }
        fed += Double(samples.count) / sampleRate
        guard let heard = heard(), heard.text != lastText else { return }
        if fails {
            isOver = true
            await onEvent(.failed("scripted recognizer failure"))
            return
        }
        lastText = heard.text
        await onEvent(.update(TranscriptionUpdate(text: heard.text, audioTime: heard.range, isFinal: false)))
    }

    func finish() async {
        guard !isOver else { return }
        isOver = true
        guard !behaviour.neverFinishes else { return }
        if let heard = heard() {
            let update = TranscriptionUpdate(text: heard.text + ".", audioTime: heard.range, isFinal: true,
                                             meanConfidence: behaviour.confidence,
                                             minimumConfidence: behaviour.confidence)
            await onEvent(.update(update))
            if behaviour.duplicateFinals { await onEvent(.update(update)) }
        }
        await onEvent(.finished)
    }

    func cancel() async {
        guard !isOver else { return }
        isOver = true
        owner.noteCancel()
    }
}

/// A scripted language model.
final class ScriptedInterpreter: SemanticInterpreting {
    typealias Responder = @Sendable (SemanticRequest) throws -> ModelInterpretation

    private struct State {
        var availability = SemanticModelAvailability.available
        var requests: [SemanticRequest] = []
        var cancellations = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let responder: Responder
    /// Wall-clock seconds each answer takes.
    let delay: TimeInterval
    /// False: the delay ignores task cancellation (a model call that cannot be interrupted).
    let isCancellable: Bool

    init(availability: SemanticModelAvailability = .available, delay: TimeInterval = 0, isCancellable: Bool = true,
         responder: @escaping Responder)
    {
        self.responder = responder
        self.delay = delay
        self.isCancellable = isCancellable
        state.withLock { $0.availability = availability }
    }

    /// Headline = the transcript's words in Title Case (always grounded), category `.other`.
    static func echo(maxWords: Int = 6, delay: TimeInterval = 0, isCancellable: Bool = true) -> ScriptedInterpreter {
        ScriptedInterpreter(delay: delay, isCancellable: isCancellable) { request in
            let words = TranscriptText.words(in: request.transcript).prefix(maxWords)
            return ModelInterpretation(headline: words.joined(separator: " "), category: .other)
        }
    }

    var requests: [SemanticRequest] { state.withLock { $0.requests } }
    var cancellations: Int { state.withLock { $0.cancellations } }

    func availability(for languageIdentifier: String) async -> SemanticModelAvailability {
        state.withLock { $0.availability }
    }

    func prewarm() async {}

    func interpret(_ request: SemanticRequest, feedback: String?) async throws -> ModelInterpretation {
        state.withLock { $0.requests.append(request) }
        if delay > 0 {
            if isCancellable {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    state.withLock { $0.cancellations += 1 }
                    throw error
                }
            } else {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { done.resume() }
                }
            }
        }
        return try responder(request)
    }
}

/// Collects the engine's outputs as they are produced.
final class OutputRecorder: Sendable {
    private let outputs = OSAllocatedUnfairLock(initialState: [SpeechIntelligenceOutput]())
    private let task: Task<Void, Never>

    init(_ engine: SpeechIntelligenceEngine) {
        let outputs = self.outputs
        task = Task { [stream = engine.outputs] in
            for await output in stream { outputs.withLock { $0.append(output) } }
        }
    }

    deinit { task.cancel() }

    var all: [SpeechIntelligenceOutput] { outputs.withLock { $0 } }
    var results: [SpeechSemanticResult] { all.compactMap { if case .result(let result) = $0 { result } else { nil } } }
    var capabilities: [SpeechCapabilities] { all.compactMap { if case .capabilities(let value) = $0 { value } else { nil } } }
    var activity: [SpeechActivityReport] { all.compactMap { if case .activity(let value) = $0 { value } else { nil } } }
    var sessionDiagnostics: [SpeechIntelligenceDiagnostics] {
        all.compactMap { if case .sessionEnded(let value) = $0 { value } else { nil } }
    }

    /// Latest revision of every speech event, in order of first appearance.
    var latestResults: [SpeechSemanticResult] {
        var order: [SpeechEventID] = []
        var latest: [SpeechEventID: SpeechSemanticResult] = [:]
        for result in results {
            if latest[result.id] == nil { order.append(result.id) }
            latest[result.id] = result
        }
        return order.compactMap { latest[$0] }
    }

    /// Outputs are delivered by a separate task: wait until they stop arriving.
    func settle() async {
        var previous = -1
        while all.count != previous {
            previous = all.count
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    func wait(timeout: TimeInterval = 5, until condition: @Sendable ([SpeechIntelligenceOutput]) -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition(all) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition(all)
    }
}

/// Drives the engine like the app does, but on a scripted timeline: 0.25 s audio buffers through
/// the real tap and ring buffer, a classifier window every 0.75 s (1.5 s long) whose speech score
/// follows the scripted speech, and a `pump()` after every buffer.
final class Harness {
    static let sampleRate = 16_000.0
    static let step = 0.25

    let engine: SpeechIntelligenceEngine
    let transcriber: ScriptedTranscriber
    let interpreter: ScriptedInterpreter
    let recorder: OutputRecorder
    let speech: [SpokenUtterance]
    /// Music score reported in every window from now on.
    var musicScore = 0.0
    /// Overrides the speech score derived from the script (e.g. sung vocals without speech).
    var forcedSpeechScore: Double?
    private(set) var time: TimeInterval = 0
    private var sequence = 0
    private var samplePosition: Int64 = 0

    init(speech: [SpokenUtterance], behaviour: ScriptedTranscriber.Behaviour = .init(),
         interpreter: ScriptedInterpreter = .echo(), configuration: SpeechIntelligenceConfiguration = .standard,
         transcriptionEnabled: Bool = true)
    {
        self.speech = speech
        transcriber = ScriptedTranscriber(speech: speech, behaviour: behaviour)
        self.interpreter = interpreter
        engine = SpeechIntelligenceEngine(transcriber: transcriber, interpreter: interpreter,
                                          configuration: configuration, isTranscriptionEnabled: transcriptionEnabled,
                                          drivesItself: false)
        recorder = OutputRecorder(engine)
    }

    func start() async {
        engine.startSession()
        await engine.drain()
    }

    /// Advances the timeline. `draining: false` does not wait for background work (language
    /// model, recognizer finish) between steps.
    func run(until end: TimeInterval, draining: Bool = true) async {
        while time < end - 1e-9 {
            appendAudio()
            time += Self.step
            if let frame = frameIfWindowEnds() { engine.process(frame) }
            engine.pump()
            if draining { await engine.drain() } else { try? await Task.sleep(for: .milliseconds(3)) }
        }
    }

    /// Ends the session (like Stop) and waits for the outputs.
    func stop() async {
        engine.audioTap.captureDidStop()
        engine.endSession()
        await engine.drain()
        await recorder.settle()
        time = 0
        sequence = 0
    }

    func send(_ update: AcousticEventUpdate) async {
        engine.process(update)
        await engine.drain()
    }

    private func appendAudio() {
        let frames = Int(Self.sampleRate * Self.step)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0 ..< frames { buffer.floatChannelData![0][frame] = 0.01 }
        engine.audioTap.captureDidReceive(buffer, at: AVAudioTime(sampleTime: samplePosition, atRate: Self.sampleRate))
        samplePosition += Int64(frames)
    }

    private func speechScore(in window: ClosedRange<TimeInterval>) -> Double {
        if let forcedSpeechScore { return forcedSpeechScore }
        let overlap = speech.reduce(0.0) { total, utterance in
            total + max(min(utterance.end, window.upperBound) - max(utterance.start, window.lowerBound), 0)
        }
        return overlap >= 0.6 ? 0.9 : overlap >= 0.25 ? 0.4 : 0
    }

    private func frameIfWindowEnds() -> ClassificationFrame? {
        let position = (time - 1.5) / 0.75
        guard time >= 1.5 - 1e-9, abs(position - position.rounded()) < 1e-6 else { return nil }
        let range = AudioTimeRange(start: time - 1.5, duration: 1.5)
        var scores: [SoundLabel: Double] = [:]
        let speechScore = speechScore(in: range.start ... range.end)
        if speechScore > 0 { scores["speech"] = speechScore }
        if musicScore > 0 { scores["music"] = musicScore }
        let now = Date.now
        let predictions = scores.map {
            RawSoundPrediction(label: $0.key, score: ClassifierScore($0.value), audioTime: range, producedAt: now,
                               model: .appleSoundClassifierV1)
        }
        defer { sequence += 1 }
        return ClassificationFrame(sequence: sequence, audioTime: range, producedAt: now, capturedAt: now,
                                   model: .appleSoundClassifierV1, predictions: predictions, inputLevel: nil)
    }
}

func speechEvent(id: AcousticEventID = AcousticEventID(), kind: String = "speech", category: SoundCategory = .speech,
                 start: TimeInterval) -> ConfirmedAcousticEvent
{
    let date = Date(timeIntervalSince1970: 1_000_000)
    return ConfirmedAcousticEvent(
        id: id, kind: SoundEventKind(id: kind, displayName: kind.capitalized, category: category),
        source: .soundClassifier(.appleSoundClassifierV1), primaryLabel: SoundLabel(kind), phase: .confirmed,
        audioStart: start, audioConfirmed: start + 2.25, audioLastObserved: start + 2.25, startDate: date,
        confirmedDate: date, lastObservedDate: date, evidence: EventEvidence(), quality: .moderate)
}
