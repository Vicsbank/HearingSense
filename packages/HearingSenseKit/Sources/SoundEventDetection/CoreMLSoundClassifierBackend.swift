import AVFAudio
import CoreML
import Foundation
import HearingSenseDomain

/// A converted third-party sound classifier run with Core ML directly (no SoundAnalysis), on
/// explicitly chosen compute units — CPU only by default, because GPU work is refused while an
/// iOS app is in the background.
///
/// Model contract (tools/experiments/audio_models/convert_coreml.py): input `waveform`
/// `[1, window_samples]` float32 mono in [-1, 1] at `sample_rate`; output `scores`
/// `[1, classes]`; metadata keys `sample_rate`, `window_samples`, `labels` (JSON array). The
/// feature extraction (STFT, mel, log) is inside the model, so this type only resamples and
/// cuts windows.
///
/// ```
/// analyze(samples @ capture rate) ─▶ StreamResampler ─▶ WindowAssembler ─▶ MLModel.prediction ─▶ sink
/// ```
public final class CoreMLSoundClassifierBackend: AcousticClassifierBackend {
    /// What the model file says about itself.
    public struct ModelInfo: Sendable, Hashable {
        public var compiledModelURL: URL
        public var sampleRate: Double
        public var windowSamples: Int
        public var labels: [String]
        /// Samples of new audio per result; less than `windowSamples` when a short window is
        /// repeated to fill the model's input.
        public var analysisSamples: Int

        public var windowDuration: TimeInterval { Double(analysisSamples) / sampleRate }
    }

    public static func inspect(compiledModelAt url: URL) throws -> ModelInfo {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model: MLModel
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw BackendError.modelUnavailable(error.localizedDescription)
        }
        let user = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard let rate = user["sample_rate"].flatMap(Double.init), rate > 0,
              let window = user["window_samples"].flatMap(Int.init), window > 0,
              let labelData = user["labels"]?.data(using: .utf8),
              let labels = try? JSONDecoder().decode([String].self, from: labelData), !labels.isEmpty
        else { throw BackendError.invalidModel("missing sample_rate / window_samples / labels metadata") }
        guard model.modelDescription.inputDescriptionsByName["waveform"] != nil,
              model.modelDescription.outputDescriptionsByName["scores"] != nil
        else { throw BackendError.invalidModel("expected input 'waveform' and output 'scores'") }
        return ModelInfo(compiledModelURL: url, sampleRate: rate, windowSamples: window, labels: labels,
                         analysisSamples: window)
    }

    /// - Parameters:
    ///   - modelID: identifies the model in stored predictions and selects nothing else.
    ///   - analysisWindow: seconds of audio per result when that is shorter than the model's
    ///     input; the audio is then repeated to fill the input. Needed for EfficientAT `mn10_as`,
    ///     which was trained on 10 s clips and gives saturated scores on 1–2 s inputs: a 2 s
    ///     window repeated into its 10 s input restores it
    ///     (docs/research/BACKGROUND_MODEL_BENCHMARK.md §5). nil = the model's own window.
    public static func factory(compiledModelAt url: URL, modelID: SoundModelID, computeUnits: MLComputeUnits = .cpuOnly,
                               analysisWindow: TimeInterval? = nil) throws -> ClassifierBackendFactory
    {
        var inspected = try inspect(compiledModelAt: url)
        if let analysisWindow {
            inspected.analysisSamples = min(max(Int((analysisWindow * inspected.sampleRate).rounded()), 1),
                                            inspected.windowSamples)
        }
        let info = inspected
        let metadata = ClassifierBackendMetadata(
            model: modelID, runtime: "Core ML", computeUnits: describe(computeUnits), labelCount: info.labels.count,
            modelSampleRate: info.sampleRate,
            summary: "\(modelID.rawValue) via Core ML (\(describe(computeUnits))), "
                + "\(info.windowDuration.formatted(.number.precision(.fractionLength(0 ... 3)))) s windows at "
                + "\(Int(info.sampleRate)) Hz"
                + (info.analysisSamples < info.windowSamples
                    ? " repeated into a \(Int(Double(info.windowSamples) / info.sampleRate)) s input" : "")
                + ", \(info.labels.count) classes")
        return ClassifierBackendFactory(metadata: metadata, taxonomy: .audioSet(model: modelID)) {
            try CoreMLSoundClassifierBackend(info: info, metadata: metadata, computeUnits: computeUnits)
        }
    }

    public static func describe(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: "cpuOnly"
        case .cpuAndGPU: "cpuAndGPU"
        case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
        case .all: "all"
        @unknown default: "unknown"
        }
    }

    public let metadata: ClassifierBackendMetadata
    public var windowDuration: TimeInterval { info.windowDuration }
    public private(set) var overlapFactor: Double = 0.5

    private let info: ModelInfo
    private let model: MLModel
    private let input: MLMultiArray
    private let provider: MLDictionaryFeatureProvider
    private var resampler: StreamResampler?
    private var assembler: WindowAssembler
    private var sink: ClassifierBackendSink?
    private var captureRate: Double = 0
    private var expectedFramePosition: Int64 = 0

    init(info: ModelInfo, metadata: ClassifierBackendMetadata, computeUnits: MLComputeUnits) throws {
        self.info = info
        self.metadata = metadata
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        do {
            model = try MLModel(contentsOf: info.compiledModelURL, configuration: configuration)
            input = try MLMultiArray(shape: [1, NSNumber(value: info.windowSamples)], dataType: .float32)
            provider = try MLDictionaryFeatureProvider(dictionary: ["waveform": input])
        } catch {
            throw BackendError.modelUnavailable(error.localizedDescription)
        }
        assembler = WindowAssembler(length: info.analysisSamples, hop: info.analysisSamples / 2)
    }

    public func startSegment(sampleRate: Double, configuration: ClassifierConfiguration,
                             sink: ClassifierBackendSink) throws
    {
        guard let resampler = StreamResampler(from: sampleRate, to: info.sampleRate) else {
            throw BackendError.unsupportedSampleRate(sampleRate)
        }
        // The window length belongs to the model; only the overlap is configurable.
        overlapFactor = min(max(configuration.overlapFactor, 0), 0.9)
        let hop = max(Int((Double(info.analysisSamples) * (1 - overlapFactor)).rounded()), 1)
        assembler = WindowAssembler(length: info.analysisSamples, hop: hop)
        self.resampler = resampler
        self.sink = sink
        captureRate = sampleRate
        expectedFramePosition = 0
    }

    public func analyze(_ samples: [Float], framePosition: Int64) {
        guard let resampler, sink != nil, !samples.isEmpty else { return }
        if framePosition != expectedFramePosition {
            // Buffers were dropped upstream (or the stream jumped): do not splice unrelated audio
            // into one window. Start again at the new position.
            resampler.reset()
            assembler.reset(at: Int64((Double(framePosition) * info.sampleRate / captureRate).rounded()))
        }
        expectedFramePosition = framePosition + Int64(samples.count)
        assembler.append(resampler.convert(samples)) { start, window in classify(window, start: start) }
    }

    public func finishSegment() {
        if sink != nil {
            assembler.flush(minimumNewSamples: Int(info.sampleRate / 10)) { start, window in
                classify(window, start: start)
            }
        }
        resampler = nil
        sink = nil
    }

    private func classify(_ window: [Float], start: Int64) {
        guard let sink else { return }
        window.withUnsafeBufferPointer { source in
            input.withUnsafeMutableBytes { destination, _ in
                // Repeats the window until the model's input is full (once when they are equal).
                var offset = 0
                while offset < info.windowSamples {
                    let count = min(window.count, info.windowSamples - offset)
                    let stride = MemoryLayout<Float>.stride
                    let target = UnsafeMutableRawBufferPointer(rebasing: destination[offset * stride ..< (offset + count) * stride])
                    target.copyMemory(from: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: source[0 ..< count])))
                    offset += count
                }
            }
        }
        let began = ContinuousClock.now
        do {
            let output = try model.prediction(from: provider)
            guard let scores = output.featureValue(for: "scores")?.multiArrayValue, scores.count == info.labels.count
            else {
                sink.failure("The model returned no scores")
                return
            }
            let elapsed = ContinuousClock.now - began
            var classifications: [(label: String, score: Double)] = []
            classifications.reserveCapacity(scores.count)
            scores.withUnsafeBufferPointer(ofType: Float.self) { values in
                for (index, value) in values.enumerated() {
                    classifications.append((info.labels[index], Double(value)))
                }
            }
            classifications.sort { $0.score > $1.score }  // highest first, as SoundAnalysis reports
            var result = ClassifierWindowResult(windowStart: Double(start) / info.sampleRate,
                                                windowDuration: info.windowDuration, classifications: classifications)
            result.inferenceSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            sink.result(result)
        } catch {
            let error = error as NSError
            sink.failure("\(error.localizedDescription) (\(error.domain) \(error.code))")
        }
    }
}

/// Converts a mono float stream to another sample rate with `AVAudioConverter`, keeping the
/// converter's state between buffers so consecutive buffers join without a seam.
public final class StreamResampler {
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    public init?(from inputRate: Double, to outputRate: Double) {
        guard inputRate > 0, outputRate > 0,
              let input = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)
        else { return nil }
        inputFormat = input
        outputFormat = output
        ratio = outputRate / inputRate
        if inputRate == outputRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
            // Measured against a reference resampler (soxr) on recordings: the default algorithm
            // attenuates the top of the new band (−1.3 dB at 5–7 kHz, −6 dB at 7–8 kHz for
            // 44.1 → 16 kHz), which changes YAMNet's upper mel bands and its scores. The mastering
            // algorithm is flat to the models' highest mel band (within 0.04 dB) at the cost of
            // ≈ 36 ms more converter latency.
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            self.converter = converter
        }
    }

    public func reset() {
        converter?.reset()
    }

    public func convert(_ samples: [Float]) -> [Float] {
        guard let converter else { return samples }
        guard !samples.isEmpty,
              let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 64)
        else { return [] }
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        source.frameLength = AVAudioFrameCount(samples.count)
        var consumed = false
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow  // more audio follows in the next call
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, let channel = target.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(target.frameLength)))
    }
}

/// Cuts a sample stream into windows of `length` samples that start every `hop` samples.
/// Positions are sample indices in the (resampled) segment.
struct WindowAssembler {
    let length: Int
    let hop: Int
    private var pending: [Float] = []
    /// Stream index of `pending[0]`; always the start of the next window.
    private var pendingStart: Int64 = 0
    /// End of the last sample that an emitted window covered.
    private var coveredUntil: Int64 = 0

    init(length: Int, hop: Int) {
        precondition(length > 0 && hop > 0)
        self.length = length
        self.hop = hop
    }

    mutating func reset(at position: Int64) {
        pending.removeAll(keepingCapacity: true)
        pendingStart = position
        coveredUntil = position
    }

    mutating func append(_ samples: [Float], emit: (Int64, [Float]) -> Void) {
        pending.append(contentsOf: samples)
        while pending.count >= length {
            emit(pendingStart, Array(pending[0 ..< length]))
            coveredUntil = pendingStart + Int64(length)
            let advance = min(hop, pending.count)
            pending.removeFirst(advance)
            pendingStart += Int64(advance)
        }
    }

    /// End of the stream: emits one zero-padded window if at least `minimumNewSamples` samples
    /// have not been part of any window yet.
    mutating func flush(minimumNewSamples: Int, emit: (Int64, [Float]) -> Void) {
        let end = pendingStart + Int64(pending.count)
        if end - coveredUntil >= Int64(max(minimumNewSamples, 1)) {
            emit(pendingStart, pending + [Float](repeating: 0, count: length - pending.count))
        }
        reset(at: 0)
    }
}
