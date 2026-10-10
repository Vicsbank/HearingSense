import Darwin
import Foundation
import HearingSenseDomain
import os

/// Everything a pipeline consumer receives, in order.
public enum SoundRecognitionOutput: Sendable {
    /// A classifier analyzer started for a new segment (capture start, restart or format change).
    case analyzerStarted(sampleRate: Double, windowDuration: TimeInterval, overlapFactor: Double)
    /// An acoustic event started, changed or ended.
    case event(AcousticEventUpdate)
    /// One classifier window was processed (emitted after that window's event updates).
    case frame(FrameReport)
    /// The listening session ended; all events have been ended.
    case sessionEnded(SoundAnalysisDiagnostics)
    /// The classifier failed. The analyzer is recreated for the next segment.
    case failure(String)
}

/// One processed classifier window with the detector's view of the moment.
public struct FrameReport: Sendable {
    public var frame: ClassificationFrame
    public var status: EnvironmentStatus
    public var candidates: [AcousticEventCandidate]
    public var activeEvents: [ConfirmedAcousticEvent]
    public var detectorStatistics: SoundEventDetector.Statistics
    public var diagnostics: SoundAnalysisDiagnostics
}

/// Owns the classifier backend (Apple SoundAnalysis or a Core ML model) and the event detector.
///
/// Isolation: an actor whose executor is a private serial dispatch queue. The tap thread
/// enqueues work with `queue.async { worker.assumeIsolated { … } }`, which keeps FIFO order
/// (unlike creating a Task per buffer) and lets the compiler check that the non-Sendable
/// backend objects are only touched on that queue. `analyze` may block for backpressure,
/// which is why it never runs on the audio tap thread.
actor SoundAnalysisWorker {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let continuation: AsyncStream<SoundRecognitionOutput>.Continuation
    private let inbox = ResultInbox()
    private let taxonomy: SoundTaxonomy
    private var configuration: ClassifierConfiguration
    private var detector: SoundEventDetector
    private let backendFactory: ClassifierBackendFactory
    /// Created on first use and kept for the worker's lifetime (a Core ML model loads once).
    private var backend: (any AcousticClassifierBackend)?
    private var analysis: ActiveAnalysis?
    private let queueKey = DispatchSpecificKey<Bool>()
    /// After a classifier failure: the audio time before which no new analyzer is created, and
    /// the next delay. Observed on iPhone: the built-in classifier fails for as long as the app
    /// is in the background, so restarting it with every buffer only wastes work.
    private var retryNotBefore: TimeInterval?
    private var retryDelay = SoundAnalysisWorker.initialRetryDelay
    private var latestChunkEnd: TimeInterval = 0
    static let initialRetryDelay: TimeInterval = 1
    static let maximumRetryDelay: TimeInterval = 4
    private var generation = 0
    private var sequence = 0
    private var levelMarks: [LevelMark] = []
    private var diagnostics = SoundAnalysisDiagnostics()

    init(configuration: ClassifierConfiguration, taxonomy: SoundTaxonomy, policy: DetectionPolicy,
         backend: ClassifierBackendFactory, continuation: AsyncStream<SoundRecognitionOutput>.Continuation)
    {
        queue = DispatchSerialQueue(label: "org.hearingsense.sound-analysis", qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: true)
        backendFactory = backend
        self.configuration = configuration
        self.taxonomy = taxonomy
        detector = SoundEventDetector(taxonomy: taxonomy, policy: policy)
        self.continuation = continuation
    }

    /// Runs `body` on the worker's queue, in submission order.
    nonisolated func enqueue(_ body: @escaping @Sendable (isolated SoundAnalysisWorker) -> Void) {
        queue.async { self.assumeIsolated { body($0) } }
    }

    // MARK: - Commands (on the worker queue)

    func setConfiguration(_ newValue: ClassifierConfiguration) {
        configuration = newValue  // applies from the next analyzer segment
    }

    func analyze(_ chunk: AudioChunk) {
        guard chunk.placement.generation == generation else {
            diagnostics.staleResultsDiscarded += 1
            return
        }
        latestChunkEnd = chunk.endTime
        if let current = analysis, current.segmentID != chunk.placement.segmentID { finishSegment() }
        if analysis == nil, chunk.startTime >= retryNotBefore ?? 0 {
            retryNotBefore = nil
            startSegment(for: chunk.placement)
        }
        diagnostics.chunksDropped = chunk.droppedChunksSoFar
        diagnostics.inputGapFrames = chunk.gapFramesSoFar
        diagnostics.maxBacklog = max(diagnostics.maxBacklog, chunk.backlogAtEnqueue)
        levelMarks.append(LevelMark(start: chunk.startTime, end: chunk.endTime, capturedAt: chunk.capturedAt,
                                    power: chunk.rms * chunk.rms, peak: chunk.peak))
        guard analysis != nil, let backend else { return }

        let resultsBefore = inbox.deliveredCount
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wallStart = ContinuousClock.now
        backend.analyze(chunk.samples, framePosition: chunk.placement.framePosition)
        let wall = Self.seconds(ContinuousClock.now - wallStart)
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9

        diagnostics.chunksAnalyzed += 1
        diagnostics.audioSecondsAnalyzed += Double(chunk.frameCount) / chunk.placement.sampleRate
        diagnostics.analyzeCalls.record(wall)
        diagnostics.analysisCPUSeconds += cpu
        if inbox.deliveredCount > resultsBefore { diagnostics.inferenceCalls.record(wall) }
        drainInbox()
    }

    /// Capture stopped or is restarting: flush the analyzer's pending window(s).
    func endSegment() {
        finishSegment()
        resetRetry()
    }

    private func resetRetry() {
        retryNotBefore = nil
        retryDelay = Self.initialRetryDelay
    }

    /// The user stopped listening (or iOS interrupted it): end all events, start a new session.
    func endSession(at date: Date, nextGeneration: Int) {
        finishSegment()
        resetRetry()
        for update in detector.finish(at: date) { continuation.yield(.event(update)) }
        continuation.yield(.sessionEnded(diagnostics))
        generation = nextGeneration
        sequence = 0
        levelMarks.removeAll()
        diagnostics = SoundAnalysisDiagnostics()
    }

    /// Delivers results that the observer received on another thread.
    func drainInbox() {
        for item in inbox.takeAll() {
            switch item {
            case .result(let result): handle(result)
            case .failure(let message, let resultGeneration):
                guard resultGeneration == generation else { continue }
                diagnostics.failures += 1
                diagnostics.lastFailure = message
                analysis = nil  // the request is terminal; a new analyzer starts after `retryDelay`
                retryNotBefore = latestChunkEnd + retryDelay
                retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
                continuation.yield(.failure(message))
            }
        }
    }

    // MARK: - Analyzer lifecycle

    private func startSegment(for placement: StreamClock.Placement) {
        do {
            let backend = try self.backend ?? backendFactory.make()
            self.backend = backend
            try backend.startSegment(sampleRate: placement.sampleRate, configuration: configuration,
                                     sink: makeSink(segmentStart: placement.segmentStart))
            analysis = ActiveAnalysis(segmentID: placement.segmentID)
            diagnostics.segments += 1
            diagnostics.sampleRate = placement.sampleRate
            diagnostics.windowDuration = backend.windowDuration
            diagnostics.overlapFactor = backend.overlapFactor
            continuation.yield(.analyzerStarted(sampleRate: placement.sampleRate,
                                                windowDuration: backend.windowDuration,
                                                overlapFactor: backend.overlapFactor))
        } catch {
            reportFailure("Could not create the sound classifier: \(error.localizedDescription)")
            retryNotBefore = latestChunkEnd + retryDelay
            retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
        }
    }

    /// Backend output arrives on any thread; it is stamped with the session generation and the
    /// segment's start and handed to the worker queue. If the backend calls back synchronously
    /// inside `analyze` (on the worker queue), the worker drains the inbox right after that
    /// call, preserving order; otherwise a drain is scheduled.
    private func makeSink(segmentStart: TimeInterval) -> ClassifierBackendSink {
        let inbox = self.inbox
        let generation = self.generation
        let queueKey = self.queueKey
        return ClassifierBackendSink(
            result: { [weak self] result in
                let onQueue = DispatchQueue.getSpecific(key: queueKey) == true
                inbox.append(.result(AnalyzerResult(
                    generation: generation, segmentStart: segmentStart, windowStart: result.windowStart,
                    windowDuration: result.windowDuration, classifications: result.classifications,
                    deliveredAt: result.deliveredAt, onAnalysisQueue: onQueue,
                    inferenceSeconds: result.inferenceSeconds, model: result.model)))
                if !onQueue { self?.enqueue { $0.drainInbox() } }
            },
            failure: { [weak self] message in
                inbox.append(.failure(message, generation: generation))
                if DispatchQueue.getSpecific(key: queueKey) != true { self?.enqueue { $0.drainInbox() } }
            })
    }

    private func finishSegment() {
        guard analysis != nil else { return }
        backend?.finishSegment()
        drainInbox()
        analysis = nil
    }

    private func reportFailure(_ message: String) {
        diagnostics.failures += 1
        diagnostics.lastFailure = message
        continuation.yield(.failure(message))
    }

    // MARK: - Results

    private func handle(_ result: AnalyzerResult) {
        guard result.generation == generation else {
            diagnostics.staleResultsDiscarded += 1
            return
        }
        if result.onAnalysisQueue {
            diagnostics.callbacksOnAnalysisQueue += 1
        } else {
            diagnostics.callbacksOffAnalysisQueue += 1
        }
        let audioTime = AudioTimeRange(start: result.segmentStart + result.windowStart, duration: result.windowDuration)
        let capturedAt = levelMarks.first { $0.end >= audioTime.end - 1e-3 }?.capturedAt
        let model = result.model ?? backendFactory.metadata.model
        let predictions = result.classifications
            .lazy
            .filter { $0.score >= self.configuration.reportingFloor }
            .prefix(configuration.maxPredictionsPerFrame)
            .map { RawSoundPrediction(label: SoundLabel($0.label), score: ClassifierScore($0.score),
                                      audioTime: audioTime, producedAt: result.deliveredAt, model: model) }
        let frame = ClassificationFrame(sequence: sequence, audioTime: audioTime, producedAt: result.deliveredAt,
                                        capturedAt: capturedAt, model: model, predictions: Array(predictions),
                                        inputLevel: level(over: audioTime))
        sequence += 1
        diagnostics.results += 1
        retryDelay = Self.initialRetryDelay
        if let delay = frame.resultDelay { diagnostics.resultDelay.record(delay) }
        if let inference = result.inferenceSeconds { diagnostics.modelInference.record(inference) }

        let output = detector.process(frame)
        for update in output.updates { continuation.yield(.event(update)) }
        continuation.yield(.frame(FrameReport(frame: frame, status: output.status, candidates: output.candidates,
                                              activeEvents: detector.activeEvents,
                                              detectorStatistics: detector.statistics, diagnostics: diagnostics)))
        // Keep enough history for the longest supported window (15 s) plus result delay.
        levelMarks.removeAll { $0.end < audioTime.end - 20 }
    }

    /// Mean power and maximum peak of the buffers overlapping `range`, in dBFS.
    private func level(over range: AudioTimeRange) -> WindowInputLevel? {
        let marks = levelMarks.filter { $0.end > range.start && $0.start < range.end }
        guard !marks.isEmpty else { return nil }
        let meanPower = marks.reduce(0) { $0 + $1.power } / Float(marks.count)
        let peak = marks.reduce(0) { max($0, $1.peak) }
        return WindowInputLevel(rmsDBFS: Self.decibels(sqrt(meanPower)), peakDBFS: Self.decibels(peak))
    }

    // MARK: - Helpers

    private static func decibels(_ amplitude: Float) -> Float {
        amplitude > 1e-6 ? max(20 * log10(amplitude), -120) : -120
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

// MARK: - Supporting types

private struct ActiveAnalysis {
    let segmentID: Int
}

private struct LevelMark {
    var start: TimeInterval
    var end: TimeInterval
    var capturedAt: Date
    var power: Float
    var peak: Float
}

/// A classifier result converted to Sendable values on the observer's thread.
struct AnalyzerResult: Sendable {
    var generation: Int
    var segmentStart: TimeInterval
    var windowStart: TimeInterval
    var windowDuration: TimeInterval
    var classifications: [(label: String, score: Double)]
    var deliveredAt: Date
    var onAnalysisQueue: Bool
    var inferenceSeconds: TimeInterval?
    var model: SoundModelID?
}

/// Thread-safe hand-off from the backend's sink (whatever thread it is called on) to the worker.
final class ResultInbox: Sendable {
    enum Item: Sendable {
        case result(AnalyzerResult)
        case failure(String, generation: Int)
    }

    private struct State {
        var items: [Item] = []
        var delivered = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ item: Item) {
        state.withLock {
            $0.items.append(item)
            $0.delivered += 1
        }
    }

    var deliveredCount: Int { state.withLock { $0.delivered } }

    func takeAll() -> [Item] {
        state.withLock { state in
            defer { state.items.removeAll() }
            return state.items
        }
    }
}
