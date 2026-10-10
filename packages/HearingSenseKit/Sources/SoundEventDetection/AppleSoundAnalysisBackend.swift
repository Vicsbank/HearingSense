import AVFAudio
import CoreMedia
import Foundation
import HearingSenseDomain
import SoundAnalysis

/// Apple's built-in classifier (`SNClassifySoundRequest(.version1)`, 303 labels) behind
/// `AcousticClassifierBackend`. SoundAnalysis re-blocks and resamples the audio itself and
/// chooses the compute units; there is no setting for them.
///
/// Measured on iPhone 18 Pro, iOS 27.2: every request fails with `com.apple.SoundAnalysis` 2
/// while the app is in the background (docs/research/BACKGROUND_INFERENCE_INVESTIGATION.md).
public final class AppleSoundAnalysisBackend: AcousticClassifierBackend {
    public static let metadata = ClassifierBackendMetadata(
        model: .appleSoundClassifierV1, runtime: "SoundAnalysis", computeUnits: "system-chosen", labelCount: 303,
        modelSampleRate: nil, summary: "SNClassifySoundRequest(.version1)")

    public static let factory = ClassifierBackendFactory(metadata: metadata, taxonomy: .appleV1) {
        AppleSoundAnalysisBackend()
    }

    public var metadata: ClassifierBackendMetadata { Self.metadata }
    public private(set) var windowDuration: TimeInterval = 0
    public private(set) var overlapFactor: Double = 0

    private var format: AVAudioFormat?
    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    /// The analyzer holds its observer weakly; this keeps it alive.
    private var observer: Observer?

    public init() {}

    public func startSegment(sampleRate: Double, configuration: ClassifierConfiguration,
                             sink: ClassifierBackendSink) throws
    {
        finishSegment()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw BackendError.unsupportedSampleRate(sampleRate)
        }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: configuration.windowDuration, preferredTimescale: 48_000)
        request.overlapFactor = configuration.overlapFactor
        let observer = Observer(sink: sink)
        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: observer)
        self.format = format
        self.analyzer = analyzer
        self.request = request
        self.observer = observer
        windowDuration = request.windowDuration.seconds
        overlapFactor = request.overlapFactor
    }

    public func analyze(_ samples: [Float], framePosition: Int64) {
        guard let analyzer, let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0]
        else { return }
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        analyzer.analyze(buffer, atAudioFramePosition: framePosition)
    }

    public func finishSegment() {
        analyzer?.completeAnalysis()
        analyzer?.removeAllRequests()
        analyzer = nil
        request = nil
        observer = nil
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

    /// Receives SoundAnalysis callbacks on whatever thread the framework uses.
    private final class Observer: NSObject, SNResultsObserving, Sendable {
        private let sink: ClassifierBackendSink

        init(sink: ClassifierBackendSink) {
            self.sink = sink
        }

        func request(_ request: any SNRequest, didProduce result: any SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            sink.result(ClassifierWindowResult(
                windowStart: result.timeRange.start.seconds, windowDuration: result.timeRange.duration.seconds,
                classifications: result.classifications.map { ($0.identifier, $0.confidence) }))
        }

        func request(_ request: any SNRequest, didFailWithError error: any Error) {
            sink.failure(AppleSoundAnalysisBackend.describe(error))
        }
    }
}

public enum BackendError: LocalizedError, Equatable {
    case unsupportedSampleRate(Double)
    case modelUnavailable(String)
    case invalidModel(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSampleRate(let rate): "Unsupported sample rate \(rate) Hz"
        case .modelUnavailable(let detail): "The classifier model is not available: \(detail)"
        case .invalidModel(let detail): "The classifier model cannot be used: \(detail)"
        }
    }
}
