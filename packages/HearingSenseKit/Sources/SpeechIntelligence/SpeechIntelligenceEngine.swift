import Foundation
import HearingSenseDomain
import SemanticSummary
import SoundEventDetection
import SpeechPipeline
import os

/// Event-driven speech intelligence: nearby speech → on-device transcript → short summary.
///
/// ```
/// MicrophoneCapture tap ─▶ SpeechAudioTap ─▶ PreRollAudioBuffer (last 5 s, memory only)
///                                                   │ read from the estimated speech onset
/// classifier windows ─▶ SpeechActivityTracker ──────┤ (speech candidate, not confirmed event)
///   (Window 2 frames)                               ▼
///                                 UtteranceTranscription (SpeechAnalyzer, one per utterance)
///                                                   │ partial / final text
///                                                   ▼
///                         conversation (stable SpeechEventID, bounded transcript)
///                                                   │ final utterance
///                                                   ▼
///                         SpeechSemanticAnalyzer (Foundation Models + validation + fallback)
///                                                   ▼
///                              outputs: SpeechSemanticResult updates
/// ```
///
/// Usage: `capture.addConsumer(engine.audioTap)`; forward the sound engine's classifier frames
/// and event updates with `process(_:)`; iterate `outputs` (single consumer); call
/// `startSession()` / `endSession()` around listening.
///
/// Concurrency: every input becomes a command on one serial queue (an `AsyncStream` consumed by
/// a single task), so the pipeline state is never touched concurrently and commands take effect
/// in the order they were sent. Slow work (finishing a recognizer, the language model) runs in
/// child tasks that report back through the same queue, tagged with the session generation;
/// results of an ended session are dropped. The audio tap only writes to the ring buffer.
///
/// Privacy: audio lives only in the ring buffer (zeroed on stop), transcripts only in the
/// current conversation (dropped on stop or when transcription is switched off). Nothing is
/// written to disk, logged or sent off the device.
public final class SpeechIntelligenceEngine: Sendable {
    public let outputs: AsyncStream<SpeechIntelligenceOutput>
    /// Attach to `MicrophoneCapture` next to the sound recognition engine.
    public let audioTap: SpeechAudioTap
    public let configuration: SpeechIntelligenceConfiguration

    private let commands: AsyncStream<Command>.Continuation
    private let outputContinuation: AsyncStream<SpeechIntelligenceOutput>.Continuation
    private let buffer: PreRollAudioBuffer
    private let pumpGate: PumpGate
    private let runLoop: Task<Void, Never>

    /// - Parameters:
    ///   - isTranscriptionEnabled: initial state of the user's transcription switch (off by default).
    ///   - drivesItself: true for live use (a timer feeds the recognizer while an utterance is
    ///     active). False for deterministic replay: the host calls `pump()` after appending audio.
    public init(transcriber: any SpeechTranscribing, interpreter: any SemanticInterpreting,
                configuration: SpeechIntelligenceConfiguration = .standard, taxonomy: SoundTaxonomy = .appleV1,
                isTranscriptionEnabled: Bool = false, drivesItself: Bool = true)
    {
        let (outputs, outputContinuation) = AsyncStream.makeStream(of: SpeechIntelligenceOutput.self,
                                                                   bufferingPolicy: .bufferingNewest(1_000))
        let (commandStream, commands) = AsyncStream.makeStream(of: Command.self)
        let buffer = PreRollAudioBuffer(capacitySeconds: configuration.preRollSeconds)
        buffer.setEnabled(isTranscriptionEnabled)
        let pumpGate = PumpGate()
        let core = Core(transcriber: transcriber,
                        analyzer: SpeechSemanticAnalyzer(interpreter: interpreter, policy: configuration.summary),
                        buffer: buffer, configuration: configuration, taxonomy: taxonomy,
                        isTranscriptionEnabled: isTranscriptionEnabled, drivesItself: drivesItself, pumpGate: pumpGate,
                        post: { commands.yield($0) }, emit: { outputContinuation.yield($0) })
        self.outputs = outputs
        self.outputContinuation = outputContinuation
        self.commands = commands
        self.buffer = buffer
        self.pumpGate = pumpGate
        self.configuration = configuration
        audioTap = SpeechAudioTap(buffer: buffer)
        runLoop = Task {
            for await command in commandStream { await core.handle(command) }
        }
    }

    deinit {
        commands.finish()
        outputContinuation.finish()
    }

    /// Listening is about to start: checks model availability and prepares the recognizer.
    public func startSession() {
        commands.yield(.startSession)
    }

    /// Listening stopped (user, interruption or failure), after capture stopped: cancels pending
    /// work, discards audio and transcripts, restarts the audio clock at 0.
    public func endSession() {
        audioTap.resetSession()
        buffer.clear()
        commands.yield(.endSession)
    }

    /// The user's switch for speech transcription. Off: no audio is buffered and nothing is
    /// transcribed; speech is still reported as "Nearby Speech" from the sound classifier.
    public func setTranscriptionEnabled(_ isEnabled: Bool) {
        buffer.setEnabled(isEnabled)
        commands.yield(.setTranscriptionEnabled(isEnabled))
    }

    /// Re-checks transcription and language-model availability (e.g. after a model download).
    public func refreshAvailability() {
        commands.yield(.refreshAvailability)
    }

    /// A classifier window from the sound recognition engine.
    public func process(_ frame: ClassificationFrame) {
        commands.yield(.frame(frame))
    }

    /// A confirmed sound event update; speech events are linked to the current conversation.
    public func process(_ update: AcousticEventUpdate) {
        commands.yield(.soundEvent(update))
    }

    /// Hands newly captured audio to the active recognizer and checks for the end of the
    /// utterance. Only needed when `drivesItself` is false.
    public func pump() {
        if pumpGate.claim() { commands.yield(.pump) }
    }

    /// Waits until everything sent so far, and the background work it started, has been
    /// processed (offline evaluation and tests).
    public func drain() async {
        await withCheckedContinuation { commands.yield(.barrier($0)) }
    }
}

// MARK: - Commands

private enum Command: Sendable {
    case startSession
    case endSession
    case setTranscriptionEnabled(Bool)
    case refreshAvailability
    case frame(ClassificationFrame)
    case soundEvent(AcousticEventUpdate)
    case pump
    case transcription(generation: Int, token: Int, TranscriptionEvent)
    case finalizationDeadline(generation: Int, token: Int)
    case semantic(generation: Int, id: SpeechEventID, token: Int, SemanticOutcome, completedAt: Date)
    case operationEnded
    case barrier(CheckedContinuation<Void, Never>)
}

/// At most one `.pump` command is queued at a time, so a slow recognizer cannot build a backlog
/// of feed requests.
private final class PumpGate: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        pending.withLock { pending in
            if pending { return false }
            pending = true
            return true
        }
    }

    func release() {
        pending.withLock { $0 = false }
    }
}

// MARK: - Core

/// Pipeline state. Its methods are only called by the engine's run loop, one command at a time.
private actor Core {
    private struct ActiveUtterance {
        let token: Int
        let session: any UtteranceTranscription
        var cursor: PreRollAudioBuffer.Cursor
        let startTime: TimeInterval
        var fedThrough: TimeInterval
        var lastTextChange: TimeInterval
        var assembler = TranscriptAssembler()
        var committedSegments = 0
        var countedDuplicates = 0
    }

    private struct PendingStart {
        var from: TimeInterval
        var trigger: Date?
        var retry: Int
    }

    private struct FinalUtterance {
        var index: Int
        var text: String
        var audioTime: AudioTimeRange
        var quality: TranscriptQuality
        /// Speech, speech over music, or possibly lyrics (nil: no classifier window to judge by).
        var context: SpeechAcousticContext?

        var isPossiblyMusic: Bool { context?.relevance == .possiblyMusic }
    }

    private struct Conversation {
        var result: SpeechSemanticResult
        var utterances: [FinalUtterance] = []
        var totalUtterances = 0
        /// Utterances with an index below this value were already given to the language model.
        var summarizedCount = 0
        var semanticToken = 0
        /// The latest utterances were either interpreted or deliberately left uninterpreted.
        var hasInterpretation = false
        /// At least one utterance of this conversation was interpreted as speech.
        var hasSpokenInterpretation = false
        var semanticInFlight = false
        var needsSummary = false
        var lastSemanticAudioTime: TimeInterval?
        var lastSpeechEndDate: Date?
        /// Audio clock time at which the conversation completes unless speech resumes.
        var closeAt: TimeInterval?
        var exceededMaximumDuration = false
        var hadTranscriptionFailure = false
    }

    private let transcriber: any SpeechTranscribing
    private let analyzer: SpeechSemanticAnalyzer
    /// The utterances finalized since the last published result.
    private var pendingUtterances: [SpeechUtterance] = []
    private let buffer: PreRollAudioBuffer
    private let configuration: SpeechIntelligenceConfiguration
    private let drivesItself: Bool
    private let pumpGate: PumpGate
    private let post: @Sendable (Command) -> Void
    private let emit: @Sendable (SpeechIntelligenceOutput) -> Void

    private var generation = 0
    private var isSessionActive = false
    private var isTranscriptionEnabled: Bool
    private var capabilities: SpeechCapabilities
    private var tracker: SpeechActivityTracker
    private var relevance: SpeechRelevanceGate
    private var conversation: Conversation?
    private var utterance: ActiveUtterance?
    private var finishing: [Int: ActiveUtterance] = [:]
    /// A recognizer start that failed and is tried again; its audio waits in the pre-roll buffer.
    private var pendingStart: PendingStart?
    private var activeSoundEvents: [AcousticEventID: TimeInterval] = [:]
    private var nextToken = 0
    /// Audio up to this session time has been given to a recognizer and is never given again.
    private var transcribedThrough: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private var consecutiveFailures = 0
    private var pendingOperations = 0
    private var diagnostics = SpeechIntelligenceDiagnostics()
    private var pumpTimer: Task<Void, Never>?
    private var semanticTask: Task<Void, Never>?

    init(transcriber: any SpeechTranscribing, analyzer: SpeechSemanticAnalyzer, buffer: PreRollAudioBuffer,
         configuration: SpeechIntelligenceConfiguration, taxonomy: SoundTaxonomy, isTranscriptionEnabled: Bool,
         drivesItself: Bool, pumpGate: PumpGate, post: @escaping @Sendable (Command) -> Void,
         emit: @escaping @Sendable (SpeechIntelligenceOutput) -> Void)
    {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.buffer = buffer
        self.configuration = configuration
        self.isTranscriptionEnabled = isTranscriptionEnabled
        self.drivesItself = drivesItself
        self.pumpGate = pumpGate
        self.post = post
        self.emit = emit
        tracker = SpeechActivityTracker(policy: configuration.activation, taxonomy: taxonomy)
        relevance = SpeechRelevanceGate(policy: configuration.relevance)
        capabilities = SpeechCapabilities(isTranscriptionEnabled: isTranscriptionEnabled,
                                          transcription: isTranscriptionEnabled ? .unknown : .disabledByUser,
                                          language: transcriber.languageIdentifier)
    }

    func handle(_ command: Command) async {
        switch command {
        case .startSession:
            await startSession()
        case .endSession:
            await endSession()
        case .setTranscriptionEnabled(let isEnabled):
            await setTranscriptionEnabled(isEnabled)
        case .refreshAvailability:
            consecutiveFailures = 0
            await refreshCapabilities()
        case .frame(let frame):
            await process(frame)
        case .soundEvent(let update):
            process(update)
        case .pump:
            pumpGate.release()
            await pump()
        case .transcription(let generation, let token, let event):
            await handleTranscription(event, generation: generation, token: token)
        case .finalizationDeadline(let generation, let token):
            await handleFinalizationDeadline(generation: generation, token: token)
        case .semantic(let generation, let id, let token, let outcome, let completedAt):
            handleSemantic(outcome, generation: generation, id: id, token: token, completedAt: completedAt)
        case .operationEnded:
            pendingOperations -= 1
        case .barrier(let continuation):
            if pendingOperations == 0, finishing.isEmpty {
                continuation.resume()
            } else {
                let post = self.post
                Task {
                    try? await Task.sleep(for: .milliseconds(2))
                    post(.barrier(continuation))
                }
            }
        }
    }

    // MARK: - Session

    private func startSession() async {
        generation += 1
        isSessionActive = true
        resetSessionState()
        diagnostics = SpeechIntelligenceDiagnostics()
        buffer.setEnabled(isTranscriptionEnabled)
        await refreshCapabilities()
        prepareRecognizerIfUsable()
    }

    private func endSession() async {
        guard isSessionActive else { return }
        isSessionActive = false
        generation += 1  // results still in flight belong to the ended session
        await cancelActiveWork()
        resetSessionState()
        buffer.clear()
        await transcriber.releaseResources()
        emit(.sessionEnded(diagnostics))
    }

    private func setTranscriptionEnabled(_ isEnabled: Bool) async {
        guard isEnabled != isTranscriptionEnabled else { return }
        isTranscriptionEnabled = isEnabled
        buffer.setEnabled(isEnabled)
        if !isEnabled {
            generation += 1
            await cancelActiveWork()
            conversation = nil
            transcribedThrough = 0
            await transcriber.releaseResources()
            emit(.speechDataCleared)
        }
        // Ongoing speech re-activates on the next classifier window under the new setting. If no
        // further speech arrives, the open speech event still has to end.
        tracker.reset()
        if conversation != nil, conversation?.closeAt == nil {
            conversation?.closeAt = lastFrameTime + configuration.conversationGap
        }
        await refreshCapabilities()
        if isSessionActive { prepareRecognizerIfUsable() }
    }

    private func refreshCapabilities() async {
        var updated = SpeechCapabilities(isTranscriptionEnabled: isTranscriptionEnabled,
                                         language: transcriber.languageIdentifier)
        updated.transcription = isTranscriptionEnabled ? await transcriber.availability() : .disabledByUser
        updated.model = await analyzer.availability(for: transcriber.languageIdentifier)
        capabilities = updated
        emit(.capabilities(updated))
    }

    private func prepareRecognizerIfUsable() {
        guard canTranscribe else { return }
        let transcriber = self.transcriber
        Task { await transcriber.prepare() }
    }

    private var canTranscribe: Bool {
        isSessionActive && capabilities.isTranscriptionEnabled && capabilities.transcription.isUsable
    }

    private func cancelActiveWork() async {
        stopPumpTimer()
        semanticTask?.cancel()
        semanticTask = nil
        if let utterance { await utterance.session.cancel() }
        for entry in finishing.values { await entry.session.cancel() }
        utterance = nil
        finishing = [:]
        pendingStart = nil
    }

    private func resetSessionState() {
        tracker.reset()
        relevance.reset()
        conversation = nil
        activeSoundEvents = [:]
        transcribedThrough = 0
        lastFrameTime = 0
        consecutiveFailures = 0
    }

    // MARK: - Speech activity

    private func process(_ frame: ClassificationFrame) async {
        guard isSessionActive else { return }
        lastFrameTime = frame.audioTime.end
        diagnostics.windows += 1
        let transition = tracker.process(frame)
        relevance.record(frame, evidence: tracker.lastEvidence)
        if tracker.lastEvidence.isSpeech { diagnostics.speechWindows += 1 }
        diagnostics.windowsSuppressedByMusic = tracker.windowsSuppressedByMusic

        switch transition {
        case .began(let onset):
            diagnostics.activations += 1
            ensureConversation(startingAt: onset)
            conversation?.closeAt = nil
            if canTranscribe, utterance == nil, pendingStart == nil {
                await startUtterance(from: onset - configuration.activation.leadIn, trigger: frame.producedAt)
            }
            publish()
        case .ended(let time):
            if utterance != nil { await finishUtterance(continueIfSpeechActive: false) }
            conversation?.closeAt = time + configuration.conversationGap
        case nil:
            break
        }
        await retryPendingStart()

        if conversation?.needsSummary == true { scheduleSemantic(now: lastFrameTime, force: false) }
        completeConversationIfDue()
        emit(.activity(SpeechActivityReport(audioTime: frame.audioTime, evidence: tracker.lastEvidence,
                                            isSpeechActive: tracker.isActive, isTranscribing: utterance != nil,
                                            preRoll: buffer.status, diagnostics: diagnostics)))
    }

    private func process(_ update: AcousticEventUpdate) {
        let event = update.event
        guard isSessionActive, configuration.activation.speechKindIDs.contains(event.kind.id) else { return }
        switch update {
        case .started, .updated:
            activeSoundEvents[event.id] = event.audioStart
            guard conversation != nil, conversation?.result.sourceEventIDs.contains(event.id) == false else { return }
            conversation?.result.sourceEventIDs.append(event.id)
            publish()
        case .ended:
            activeSoundEvents[event.id] = nil
        }
    }

    // MARK: - Utterances

    /// Starts a recognizer on buffered audio beginning at `requested` (clamped to audio that is
    /// still buffered and has not been transcribed yet), then keeps feeding live audio.
    private func startUtterance(from requested: TimeInterval, trigger: Date?, retry: Int = 0) async {
        let wanted = max(requested, transcribedThrough, 0)
        guard let cursor = buffer.cursor(at: wanted), let start = buffer.time(of: cursor) else { return }
        if start - wanted > 0.05 { diagnostics.preRollShortfalls += 1 }

        let token = nextToken
        nextToken += 1
        let generation = self.generation
        let post = self.post
        let session: any UtteranceTranscription
        do {
            session = try await transcriber.beginUtterance(at: start) { event in
                post(.transcription(generation: generation, token: token, event))
            }
        } catch {
            if retry < configuration.maximumRecognizerStartRetries {
                diagnostics.recognizerStartRetries += 1
                pendingStart = PendingStart(from: wanted, trigger: trigger, retry: retry + 1)
            } else {
                noteTranscriptionFailure(error.localizedDescription)
            }
            return
        }
        if retry > 0 { diagnostics.recognizerStartsRecovered += 1 }
        utterance = ActiveUtterance(token: token, session: session, cursor: cursor, startTime: start,
                                    fedThrough: start, lastTextChange: start)
        diagnostics.utterancesStarted += 1
        if let trigger {
            let delay = max(Date.now.timeIntervalSince(trigger), 0)
            let preRoll = max((buffer.status.newestTime ?? start) - start, 0)
            diagnostics.activationToTranscription.record(delay)
            diagnostics.preRollUsed.record(preRoll)
            conversation?.result.latency.activationToTranscription = delay
            conversation?.result.latency.preRollUsed = preRoll
        }
        if capabilities.model.isUsable {
            let analyzer = self.analyzer
            Task { await analyzer.prewarm() }
        }
        await pump()
        if retry > 0, utterance != nil, !tracker.isActive {
            // The speech ended while the start was being retried: everything buffered has been
            // fed, so ask for the final result now.
            await finishUtterance(continueIfSpeechActive: false)
        }
        if utterance != nil { startPumpTimer() }
    }

    /// Tries a failed recognizer start again. Called on every classifier window and whenever an
    /// earlier recognizer has finished (which frees a recognizer slot).
    private func retryPendingStart() async {
        guard let pending = pendingStart else { return }
        pendingStart = nil
        guard canTranscribe, utterance == nil else { return }
        await startUtterance(from: pending.from, trigger: pending.trigger, retry: pending.retry)
        publish()
    }

    /// Feeds everything captured since the last call and decides whether the utterance is over.
    private func pump() async {
        guard var current = utterance else { return }
        var streamRestarted = false
        feeding: while true {
            switch buffer.read(from: current.cursor, maxFrames: 48_000) {
            case .chunk(let chunk, let next):
                diagnostics.overrunFrames += chunk.skippedFrames
                await current.session.append(chunk.samples, sampleRate: chunk.sampleRate)
                current.cursor = next
                current.fedThrough = chunk.endTime
                transcribedThrough = max(transcribedThrough, chunk.endTime)
                diagnostics.audioSecondsTranscribed += chunk.duration
            case .empty:
                break feeding
            case .discontinuity:
                streamRestarted = true
                break feeding
            }
        }
        utterance = current

        if tracker.isActive, current.fedThrough - lastFrameTime >= configuration.classifierStallTimeout {
            // No classifier window for a while (the classifier is not running, e.g. in the
            // background on iPhone): nothing confirms that speech is still going on, so stop
            // transcribing instead of transcribing everything the microphone hears.
            diagnostics.classifierStalls += 1
            tracker.reset()
            conversation?.closeAt = lastFrameTime
            await finishUtterance(continueIfSpeechActive: false)
        } else if streamRestarted {
            // Capture restarted (route change): the recognizer's timeline cannot continue.
            await finishUtterance(continueIfSpeechActive: true)
        } else if !current.assembler.isEmpty,
                  current.fedThrough - current.lastTextChange >= configuration.endpointSilence
        {
            diagnostics.utterancesEndedByEndpoint += 1
            await finishUtterance(continueIfSpeechActive: true)
        } else if current.fedThrough - current.startTime >= configuration.maximumUtteranceDuration {
            diagnostics.utterancesEndedByDuration += 1
            await finishUtterance(continueIfSpeechActive: true)
        }
    }

    /// Stops feeding the active utterance and asks the recognizer for its final result (handled
    /// when `.finished` arrives). The recognizer is always finished, never cancelled, even when
    /// no text has arrived yet: results lag behind the audio, so "no text so far" does not mean
    /// "no speech". While speech activity continues, a new utterance starts where this one
    /// stopped, so no audio is skipped.
    private func finishUtterance(continueIfSpeechActive: Bool) async {
        guard let current = utterance else { return }
        utterance = nil
        finishing[current.token] = current
        pendingOperations += 1
        let post = self.post
        let generation = self.generation
        let timeout = configuration.finalizationTimeout
        Task {
            await current.session.finish()
            post(.operationEnded)
        }
        Task {
            try? await Task.sleep(for: .seconds(timeout))
            post(.finalizationDeadline(generation: generation, token: current.token))
        }
        if continueIfSpeechActive, tracker.isActive, canTranscribe {
            await startUtterance(from: current.fedThrough, trigger: nil)
        }
        if utterance == nil { stopPumpTimer() }
        publish()
    }

    private func handleTranscription(_ event: TranscriptionEvent, generation: Int, token: Int) async {
        guard generation == self.generation else {
            diagnostics.staleResultsDropped += 1
            return
        }
        if var current = utterance, current.token == token {
            switch event {
            case .update(let update):
                if current.assembler.apply(update) { current.lastTextChange = current.fedThrough }
                commitFinalSegments(of: &current)
                utterance = current
                publish()
            case .finished:
                // The recognizer ended on its own.
                utterance = nil
                commitFinalSegments(of: &current)
                diagnostics.utterancesFinished += 1
                await restartAfterUnexpectedEnd(from: current.fedThrough)
            case .failed(let message):
                utterance = nil
                await current.session.cancel()
                current.assembler.promoteVolatile()
                commitFinalSegments(of: &current)
                noteTranscriptionFailure(message)
                await restartAfterUnexpectedEnd(from: current.fedThrough)
            }
        } else if var done = finishing[token] {
            switch event {
            case .update(let update):
                done.assembler.apply(update)
                commitFinalSegments(of: &done)
                finishing[token] = done
                publish()
            case .finished:
                finishing[token] = nil
                if !done.assembler.hasFinalText { done.assembler.promoteVolatile() }
                commitFinalSegments(of: &done)
                diagnostics.utterancesFinished += 1
                if done.assembler.isEmpty { diagnostics.emptyUtterances += 1 }
                consecutiveFailures = 0
                await retryPendingStart()
                publish()
                completeConversationIfDue()
            case .failed(let message):
                finishing[token] = nil
                done.assembler.promoteVolatile()
                commitFinalSegments(of: &done)
                noteTranscriptionFailure(message)
                await retryPendingStart()
                publish()
                completeConversationIfDue()
            }
        } else {
            diagnostics.staleResultsDropped += 1
        }
    }

    private func restartAfterUnexpectedEnd(from time: TimeInterval) async {
        if tracker.isActive, canTranscribe { await startUtterance(from: time, trigger: nil) }
        if utterance == nil { stopPumpTimer() }
        publish()
        completeConversationIfDue()
    }

    /// The recognizer did not deliver its final result in time: use the partial text.
    private func handleFinalizationDeadline(generation: Int, token: Int) async {
        guard generation == self.generation, var late = finishing[token] else { return }
        finishing[token] = nil
        diagnostics.finalizationTimeouts += 1
        await late.session.cancel()
        late.assembler.promoteVolatile()
        commitFinalSegments(of: &late)
        await retryPendingStart()
        publish()
        completeConversationIfDue()
    }

    private func noteTranscriptionFailure(_ message: String) {
        diagnostics.transcriptionFailures += 1
        diagnostics.lastTranscriptionFailure = message
        consecutiveFailures += 1
        conversation?.hadTranscriptionFailure = true
        conversation?.result.failure = "Transcription failed: \(message)"
        if consecutiveFailures >= configuration.maximumConsecutiveFailures {
            capabilities.transcription = .failed(message)
            emit(.capabilities(capabilities))
        }
    }

    // MARK: - Conversation

    private func ensureConversation(startingAt time: TimeInterval) {
        guard conversation == nil else { return }
        let now = Date.now
        let result = SpeechSemanticResult(
            sourceEventIDs: activeSoundEvents.sorted { $0.value < $1.value }.map(\.key), state: .detected,
            audioTime: AudioTimeRange(start: max(time, 0), duration: 0),
            startDate: buffer.date(forAudioTime: time) ?? now, updatedDate: now,
            transcriptionAvailability: capabilities.transcription, modelAvailability: capabilities.model)
        conversation = Conversation(result: result)
        diagnostics.conversationsStarted += 1
    }

    /// Moves the utterance's new final segments into the conversation and requests a summary.
    private func commitFinalSegments(of utterance: inout ActiveUtterance) {
        let segments = utterance.assembler.segments
        // Repeated finals that the assembler dropped since the last commit.
        diagnostics.duplicateTranscriptsDropped += utterance.assembler.duplicatesDropped - utterance.countedDuplicates
        utterance.countedDuplicates = utterance.assembler.duplicatesDropped
        guard utterance.committedSegments < segments.count else { return }
        for segment in segments[utterance.committedSegments...] { addFinalSegment(segment) }
        utterance.committedSegments = segments.count
    }

    private func addFinalSegment(_ segment: TranscriptAssembler.Segment) {
        ensureConversation(startingAt: segment.audioTime.start)
        guard var current = conversation else { return }
        if let last = current.utterances.last,
           TranscriptText.normalized(last.text) == TranscriptText.normalized(segment.text),
           segment.audioTime.start - last.audioTime.end < 2
        {
            diagnostics.duplicateTranscriptsDropped += 1
            return
        }
        let quality = TranscriptQuality.assess(meanConfidence: segment.meanConfidence,
                                               minimumConfidence: segment.minimumConfidence,
                                               wordCount: TranscriptText.words(in: segment.text).count)
        // Stage B of the speech relevance gate: was this spoken, or is it probably part of music?
        let context = relevance.assess(segment.audioTime, meanConfidence: segment.meanConfidence)
        switch context?.relevance {
        case .possiblyMusic: diagnostics.utterancesPossiblyMusic += 1
        case .speechOverMusic: diagnostics.utterancesOverMusic += 1
        case .nearbySpeech, nil: break
        }
        current.utterances.append(FinalUtterance(index: current.totalUtterances, text: segment.text,
                                                 audioTime: segment.audioTime, quality: quality, context: context))
        // Window 6: the utterance on its own, for captions, recaps and semantic attention.
        let now = Date.now
        pendingUtterances.append(SpeechUtterance(
            index: current.totalUtterances, text: segment.text,
            startDate: buffer.date(forAudioTime: segment.audioTime.start) ?? now,
            endDate: buffer.date(forAudioTime: segment.audioTime.end) ?? now, quality: quality.rating,
            isPossiblyMusic: context?.relevance == .possiblyMusic))
        current.totalUtterances += 1
        if current.utterances.count > configuration.maximumUtterancesKept {
            current.utterances.removeFirst(current.utterances.count - configuration.maximumUtterancesKept)
        }
        diagnostics.finalSegments += 1
        current.result.utteranceCount = current.totalUtterances
        current.result.audioTime = AudioTimeRange(start: current.result.audioTime.start,
                                                  end: max(current.result.audioTime.end, segment.audioTime.end))
        if let captured = buffer.date(forAudioTime: segment.audioTime.end) {
            let delay = max(Date.now.timeIntervalSince(captured), 0)
            diagnostics.speechEndToFinalTranscript.record(delay)
            current.result.latency.speechEndToFinalTranscript = delay
            current.lastSpeechEndDate = captured
        }
        if current.result.audioTime.duration > configuration.maximumConversationDuration {
            current.exceededMaximumDuration = true
        }
        conversation = current
        // A conversation past its maximum duration is summarized now and then completed.
        scheduleSemantic(now: segment.audioTime.end, force: current.exceededMaximumDuration)
    }

    /// Sends the utterances that were not interpreted yet to the semantic analyzer. One request
    /// at a time per conversation; requests closer together than `minimumSummaryInterval` are
    /// merged into the next one.
    private func scheduleSemantic(now: TimeInterval, force: Bool) {
        guard var current = conversation else { return }
        let pending = current.utterances.filter { $0.index >= current.summarizedCount }
        guard !pending.isEmpty else {
            current.needsSummary = false
            conversation = current
            return
        }
        let tooSoon = current.lastSemanticAudioTime.map { now - $0 < configuration.minimumSummaryInterval } ?? false
        if current.semanticInFlight || (tooSoon && !force) {
            current.needsSummary = true
            conversation = current
            return
        }
        // Utterances that are probably lyrics are not interpreted: no language-model call, no
        // summary. Their transcript stays visible, marked as uncertain.
        let interpretable = pending.filter { !$0.isPossiblyMusic }
        guard let newest = interpretable.last else {
            current.summarizedCount = current.totalUtterances
            current.needsSummary = false
            current.hasInterpretation = true
            if !current.hasSpokenInterpretation {
                current.result.summary = nil
                current.result.category = .unknown
                current.result.details = nil
                current.result.isUnclear = false
                current.result.failure = nil
                current.result.acousticContext = pending.last?.context
            }
            // Otherwise something in this conversation was interpreted as speech: a lyric line
            // heard afterwards does not replace that summary.
            conversation = current
            diagnostics.modelCallsAvoidedForMusic += 1
            publish()
            if current.exceededMaximumDuration { completeConversation() } else { completeConversationIfDue() }
            return
        }
        let context = current.utterances.filter { $0.index < current.summarizedCount && !$0.isPossiblyMusic }
            .suffix(configuration.summaryContextUtterances).map(\.text)
        let quality = interpretable.map(\.quality).min { $0.rating < $1.rating } ?? .unknown
        let request = SemanticRequest(transcript: interpretable.map(\.text).joined(separator: " "), context: context,
                                      languageIdentifier: capabilities.language, quality: quality)
        current.result.acousticContext = newest.context
        current.summarizedCount = current.totalUtterances
        current.semanticToken += 1
        current.semanticInFlight = true
        current.needsSummary = false
        current.lastSemanticAudioTime = now
        conversation = current
        diagnostics.semanticRequests += 1
        pendingOperations += 1

        let analyzer = self.analyzer
        let post = self.post
        let generation = self.generation
        let id = current.result.id
        let token = current.semanticToken
        semanticTask = Task {
            let outcome = await analyzer.analyze(request)
            post(.semantic(generation: generation, id: id, token: token, outcome, completedAt: .now))
        }
        publish()
    }

    private func handleSemantic(_ outcome: SemanticOutcome, generation: Int, id: SpeechEventID, token: Int,
                                completedAt: Date)
    {
        pendingOperations -= 1
        guard generation == self.generation, var current = conversation, current.result.id == id,
              current.semanticToken == token
        else {
            diagnostics.staleResultsDropped += 1
            return
        }
        current.semanticInFlight = false
        current.hasInterpretation = true
        current.hasSpokenInterpretation = true
        diagnostics.modelAttempts += outcome.attempts
        diagnostics.summaryRejections += outcome.rejections.count
        if outcome.attempts > 0 { diagnostics.semanticProcessing.record(outcome.duration) }

        current.result.category = outcome.category
        current.result.details = outcome.details
        current.result.isUnclear = outcome.isUnclear
        current.result.failure = outcome.failure
        current.result.latency.semanticProcessing = outcome.duration
        if outcome.modelAvailability != .unknown {
            current.result.modelAvailability = outcome.modelAvailability
            if capabilities.model != outcome.modelAvailability {
                capabilities.model = outcome.modelAvailability
                emit(.capabilities(capabilities))
            }
        }
        if let summary = outcome.summary {
            if let existing = current.result.summary,
               TranscriptText.normalized(existing.text) == TranscriptText.normalized(summary.text)
            {
                // Same headline again: not a new summary for consumers.
                diagnostics.duplicateSummariesSuppressed += 1
            } else {
                current.result.summary = summary
                current.result.summaryRevision += 1
                diagnostics.summariesProduced += 1
            }
        } else {
            // An older headline would describe speech that is no longer the latest.
            current.result.summary = nil
            if outcome.isUnclear {
                diagnostics.unclearTranscripts += 1
            } else if outcome.attempts > 0 {
                diagnostics.summaryFallbacks += 1
                diagnostics.lastSemanticFailure = outcome.failure
            }
        }
        if let end = current.lastSpeechEndDate {
            let delay = max(completedAt.timeIntervalSince(end), 0)
            current.result.latency.speechEndToSummary = delay
            if outcome.summary != nil { diagnostics.speechEndToSummary.record(delay) }
        }
        conversation = current
        publish()
        if current.exceededMaximumDuration {
            if current.needsSummary {
                scheduleSemantic(now: lastFrameTime, force: true)
            } else {
                completeConversation()
            }
        } else {
            completeConversationIfDue()
        }
    }

    /// Completes the conversation when speech has been over for `conversationGap` and nothing is
    /// pending for it.
    private func completeConversationIfDue() {
        guard let current = conversation, let closeAt = current.closeAt, lastFrameTime >= closeAt,
              utterance == nil, finishing.isEmpty, pendingStart == nil, !current.semanticInFlight
        else { return }
        if current.needsSummary {
            scheduleSemantic(now: lastFrameTime, force: true)
            return
        }
        completeConversation()
    }

    private func completeConversation() {
        guard var current = conversation else { return }
        current.result.state = current.hadTranscriptionFailure && current.totalUtterances == 0 ? .failed : .completed
        conversation = nil
        diagnostics.conversationsCompleted += 1
        emitResult(&current)
    }

    // MARK: - Publishing

    /// Publishes the current conversation with its derived state and transcript.
    private func publish() {
        guard var current = conversation else { return }
        let partial = utterance?.assembler.volatileText ?? ""
        // The transcript belongs to the headline: spoken utterances if there are any, otherwise
        // the lines that are probably lyrics.
        let spoken = current.utterances.filter { !$0.isPossiblyMusic }
        let shown = (spoken.isEmpty ? current.utterances : spoken).suffix(configuration.transcriptUtterances)
        var parts = shown.map(\.text)
        if !partial.isEmpty { parts.append(partial) }
        if parts.isEmpty {
            current.result.transcript = nil
        } else {
            let start = shown.first?.audioTime.start ?? utterance?.assembler.audioTime?.start
                ?? current.result.audioTime.start
            let end = max(shown.last?.audioTime.end ?? start, utterance?.assembler.audioTime?.end ?? start)
            current.result.transcript = SpeechTranscript(
                text: parts.joined(separator: " "), language: capabilities.language, isFinal: partial.isEmpty,
                quality: shown.last?.quality ?? .unknown,
                audioTime: AudioTimeRange(start: start, end: end))
        }

        if current.semanticInFlight {
            current.result.state = .processing
        } else if !partial.isEmpty || (utterance != nil && current.totalUtterances == 0) {
            current.result.state = .transcribing
        } else if current.totalUtterances > 0, current.hasInterpretation {
            current.result.state = .summarized
        } else if !finishing.isEmpty || current.totalUtterances > 0 {
            current.result.state = .transcribing
        } else {
            current.result.state = .detected
        }
        current.result.transcriptionAvailability = capabilities.transcription
        if current.result.transcript != nil {
            if !pendingUtterances.isEmpty { current.result.recentUtterances = pendingUtterances }
            current.result.volatileText = partial.isEmpty ? nil : partial
        }
        pendingUtterances.removeAll()
        emitResult(&current)
        conversation = current
    }

    private func emitResult(_ conversation: inout Conversation) {
        conversation.result.revision += 1
        conversation.result.updatedDate = .now
        emit(.result(conversation.result))
    }

    // MARK: - Feed timer

    private func startPumpTimer() {
        guard drivesItself, pumpTimer == nil else { return }
        let post = self.post
        let gate = pumpGate
        let interval = configuration.feedInterval
        pumpTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                if gate.claim() { post(.pump) }
            }
        }
    }

    private func stopPumpTimer() {
        pumpTimer?.cancel()
        pumpTimer = nil
    }
}
