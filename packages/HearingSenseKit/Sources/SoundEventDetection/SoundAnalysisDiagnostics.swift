import Foundation

/// Running measurements of the classification pipeline for one listening session.
/// Metadata only (timings and counters), never audio.
public struct SoundAnalysisDiagnostics: Hashable, Sendable {
    public var windowDuration: TimeInterval = 0
    public var overlapFactor: Double = 0
    public var sampleRate: Double = 0
    public var segments = 0

    /// Buffers handed to `analyze(_:atAudioFramePosition:)`.
    public var chunksAnalyzed = 0
    /// Buffers dropped on the tap thread because the analysis backlog was full.
    public var chunksDropped = 0
    /// Input frames missing according to `AVAudioTime.sampleTime` (capture-side gaps).
    public var inputGapFrames: Int64 = 0
    public var maxBacklog = 0
    /// Seconds of audio given to the analyzer.
    public var audioSecondsAnalyzed: Double = 0

    /// Wall-clock duration of every analyze call (re-blocking, resampling and, when a window
    /// completes, model inference).
    public var analyzeCalls = TimingStatistics()
    /// Subset: analyze calls during which at least one result was delivered. Their duration is
    /// an upper bound for the model inference latency of one window.
    public var inferenceCalls = TimingStatistics()
    /// Thread CPU time spent inside analyze calls.
    public var analysisCPUSeconds: Double = 0

    public var results = 0
    /// Result delivered minus capture time of the window's last sample.
    public var resultDelay = TimingStatistics()
    /// Observer callbacks delivered synchronously on the analysis queue vs. on another thread.
    public var callbacksOnAnalysisQueue = 0
    public var callbacksOffAnalysisQueue = 0
    public var staleResultsDiscarded = 0
    public var failures = 0
    public var lastFailure: String?

    public init() {}

    /// Analysis CPU time as a fraction of the audio duration analyzed (0.01 = 1 % of one core).
    public var analysisLoad: Double {
        audioSecondsAnalyzed > 0 ? analysisCPUSeconds / audioSecondsAnalyzed : 0
    }

    public var dropRate: Double {
        let total = chunksAnalyzed + chunksDropped
        return total > 0 ? Double(chunksDropped) / Double(total) : 0
    }

    public func reportLines() -> [String] {
        let ms = { (s: Double) in (s * 1000).formatted(.number.precision(.fractionLength(1))) + " ms" }
        let sec = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        var lines = [
            "Window \(windowDuration.formatted(.number.precision(.fractionLength(1)))) s, overlap "
                + "\(overlapFactor.formatted(.percent.precision(.fractionLength(0)))), input "
                + "\((sampleRate / 1000).formatted(.number.precision(.fractionLength(0 ... 1)))) kHz",
            "Audio analyzed: \(audioSecondsAnalyzed.formatted(sec)) s in \(chunksAnalyzed) buffers "
                + "(\(segments) analyzer segment\(segments == 1 ? "" : "s"))",
            "Dropped buffers: \(chunksDropped); input gaps: \(inputGapFrames) frames; max backlog: \(maxBacklog)",
            "Results: \(results); stale discarded: \(staleResultsDiscarded); failures: \(failures)",
        ]
        if analyzeCalls.count > 0 {
            lines.append("analyze() per buffer: mean \(ms(analyzeCalls.mean)), max \(ms(analyzeCalls.max))")
        }
        if inferenceCalls.count > 0 {
            lines.append("analyze() with a result (≈ inference): mean \(ms(inferenceCalls.mean)), "
                + "p95 \(ms(inferenceCalls.p95)), max \(ms(inferenceCalls.max))")
        }
        if resultDelay.count > 0 {
            lines.append("Result delay after window end: mean \(ms(resultDelay.mean)), p95 \(ms(resultDelay.p95)), "
                + "max \(ms(resultDelay.max))")
        }
        lines.append("Analysis CPU: \(analysisCPUSeconds.formatted(.number.precision(.fractionLength(2)))) s "
            + "(\(analysisLoad.formatted(.percent.precision(.fractionLength(1)))) of audio time, one core)")
        lines.append("Observer callbacks: \(callbacksOnAnalysisQueue) on analysis queue, "
            + "\(callbacksOffAnalysisQueue) elsewhere")
        if let lastFailure { lines.append("Last failure: \(lastFailure)") }
        return lines
    }
}

/// Count, mean, max and an approximate p95 over the most recent samples.
public struct TimingStatistics: Hashable, Sendable {
    public private(set) var count = 0
    public private(set) var total: Double = 0
    public private(set) var max: Double = 0
    public private(set) var last: Double = 0
    private var recent: [Double] = []
    private static let recentCapacity = 256

    public init() {}

    public mutating func record(_ value: Double) {
        count += 1
        total += value
        max = Swift.max(max, value)
        last = value
        recent.append(value)
        if recent.count > Self.recentCapacity { recent.removeFirst(recent.count - Self.recentCapacity) }
    }

    public var mean: Double { count > 0 ? total / Double(count) : 0 }

    /// 95th percentile of the last 256 samples (nearest-rank).
    public var p95: Double {
        guard !recent.isEmpty else { return 0 }
        let sorted = recent.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
    }
}
