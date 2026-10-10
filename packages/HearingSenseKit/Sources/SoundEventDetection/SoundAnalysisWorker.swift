import AVFAudio
import CoreMedia
import Darwin
import Foundation
import HearingSenseDomain
import SoundAnalysis
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

/// Owns the `SNAudioStreamAnalyzer` and the event detector.
///
/// Isolation: an actor whose executor is a private serial dispatch queue. The tap thread
/// enqueues work with `queue.async { worker.assumeIsolated { … } }`, which keeps FIFO order
/// (unlike creating a Task per buffer) and lets the compiler check that the non-Sendable
/// SoundAnalysis objects are only touched on that queue. `analyze` may block for backpressure,
/// which is why it never runs on the audio tap thread.
actor SoundAnalysisWorker {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let continuation: AsyncStream<SoundRecognitionOutput>.Continuation
    private let inbox = ResultInbox()
    private let taxonomy: SoundTaxonomy
    private var configuration: ClassifierConfiguration
    private var detector: SoundEventDetector
    private var analysis: ActiveAnalysis?
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
         continuation: AsyncStream<SoundRecognitionOutput>.Continuation)
    {
        queue = DispatchSerialQueue(label: "org.hearingsense.sound-analysis", qos: .userInitiated)
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
        guard let analyzer = analysis?.analyzer, let format = analysis?.format,
              let buffer = Self.makeBuffer(chunk.samples, format: format)
        else { return }

        let resultsBefore = inbox.deliveredCount
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wallStart = ContinuousClock.now
        analyzer.analyze(buffer, atAudioFramePosition: chunk.placement.framePosition)
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
        let format = AVAudioFormat(standardFormatWithSampleRate: placement.sampleRate, channels: 1)
        guard let format else {
            reportFailure("Unsupported sample rate \(placement.sampleRate) Hz")
            return
        }
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: configuration.windowDuration, preferredTimescale: 48_000)
            request.overlapFactor = configuration.overlapFactor
            let observer = ResultObserver(
                inbox: inbox, worker: self, generation: generation, segmentStart: placement.segmentStart)
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)
            analysis = ActiveAnalysis(segmentID: placement.segmentID, format: format, analyzer: analyzer,
                                      request: request, observer: observer)
            diagnostics.segments += 1
            diagnostics.sampleRate = placement.sampleRate
            diagnostics.windowDuration = request.windowDuration.seconds
            diagnostics.overlapFactor = request.overlapFactor
            continuation.yield(.analyzerStarted(sampleRate: placement.sampleRate,
                                                windowDuration: request.windowDuration.seconds,
                                                overlapFactor: request.overlapFactor))
        } catch {
            reportFailure("Could not create the sound classifier: \(error.localizedDescription)")
        }
    }

    private func finishSegment() {
        guard let current = analysis else { return }
        current.analyzer.completeAnalysis()
        drainInbox()
        current.analyzer.removeAllRequests()
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
        let model = SoundModelID.appleSoundClassifierV1
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

    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

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
    let format: AVAudioFormat
    let analyzer: SNAudioStreamAnalyzer
    let request: SNClassifySoundRequest
    /// The analyzer holds its observer weakly; this keeps it alive.
    let observer: ResultObserver
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
}

/// Thread-safe hand-off from the observer (whatever thread SoundAnalysis uses) to the worker.
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

/// Receives SoundAnalysis callbacks. Holds only immutable Sendable state.
///
/// If SoundAnalysis calls back synchronously inside `analyze` (on the worker queue), the worker
/// drains the inbox right after that call, preserving order. Otherwise a drain is scheduled on
/// the worker queue.
final class ResultObserver: NSObject, SNResultsObserving, Sendable {
    private let inbox: ResultInbox
    private let worker: SoundAnalysisWorker
    private let generation: Int
    private let segmentStart: TimeInterval
    private let queueKey = DispatchSpecificKey<Bool>()

    init(inbox: ResultInbox, worker: SoundAnalysisWorker, generation: Int, segmentStart: TimeInterval) {
        self.inbox = inbox
        self.worker = worker
        self.generation = generation
        self.segmentStart = segmentStart
        super.init()
        worker.queue.setSpecific(key: queueKey, value: true)
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let onQueue = DispatchQueue.getSpecific(key: queueKey) == true
        inbox.append(.result(AnalyzerResult(
            generation: generation, segmentStart: segmentStart,
            windowStart: result.timeRange.start.seconds, windowDuration: result.timeRange.duration.seconds,
            classifications: result.classifications.map { ($0.identifier, $0.confidence) },
            deliveredAt: .now, onAnalysisQueue: onQueue)))
        if !onQueue { worker.enqueue { $0.drainInbox() } }
    }

    /// Message with the error domain, code and underlying error: SoundAnalysis reports most
    /// failures only as "Error during analysis".
    static func describe(_ error: any Error) -> String {
        let error = error as NSError
        var text = "\(error.localizedDescription) (\(error.domain) \(error.code))"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(underlying.localizedDescription) (\(underlying.domain) \(underlying.code))"
        }
        return text
    }

    func request(_ request: SNRequest, didFailWithError error: any Error) {
        inbox.append(.failure(Self.describe(error), generation: generation))
        if DispatchQueue.getSpecific(key: queueKey) != true { worker.enqueue { $0.drainInbox() } }
    }
}
