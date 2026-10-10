import AVFAudio
import CoreMedia
import Foundation
import HearingSenseDomain
import Speech

/// On-device transcription with Apple's `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26+).
///
/// - Recognition runs on the device. `SpeechTranscriber` has no server mode, and this type never
///   falls back to `SFSpeechRecognizer` (which could use Apple's servers) or to
///   `DictationTranscriber`. If the on-device model is unavailable the pipeline degrades to
///   "speech detected" only.
/// - Model files are system assets managed by `AssetInventory`. `availability()` never downloads;
///   `installModel()` does and must only be called on an explicit user action.
/// - One `SpeechAnalyzer` per utterance. Measured on macOS 27.2 (M1 Max): creating and preparing
///   an analyzer takes ≈ 0.24 s the first time and ≈ 5 ms afterwards while the model is retained,
///   whereas reusing one analyzer across a gap in its timeline, or after a mid-stream
///   `finalize`, corrupted the next final result.
/// - The system limits how many recognizers an app holds at once. Observed on an iPhone 18 Pro
///   (iOS 27.2): with a prepared standby analyzer, one finishing utterance and one new utterance,
///   the third failed with "Maximum number of recognizers reached". `prepare()` therefore loads
///   the model with a short-lived analyzer and relies on `.processLifetime` retention (ended in
///   `releaseResources()`) instead of keeping a standby analyzer alive.
public final class AppleSpeechTranscriber: SpeechTranscribing {
    public let locale: Locale
    private let keeper = ModelKeeper()

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    public var languageIdentifier: String { locale.identifier(.bcp47) }

    /// False where Apple's on-device transcriber does not exist at all. Measured: false in the
    /// iOS 27.0 Simulator (so the Simulator can only show detection-level results), true on
    /// macOS 27.2 (Apple silicon). A physical iPhone has not been checked yet.
    public static var isSupportedOnThisDevice: Bool { SpeechTranscriber.isAvailable }

    public func availability() async -> TranscriptionAvailability {
        guard SpeechTranscriber.isAvailable else { return .unsupportedDevice }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupportedLocale(languageIdentifier)
        }
        let module = Self.makeModule(locale: supported)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return .available
        case .downloading:
            return .modelDownloading(languageIdentifier)
        case .unsupported:
            return .unsupportedLocale(languageIdentifier)
        case .supported:
            // Observed on macOS 27.2: an installed model reports `.supported` until the app asks
            // for an installation request, which returns nil when nothing needs downloading.
            let installed = await SpeechTranscriber.installedLocales
            guard installed.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }) else {
                return .modelNotInstalled(languageIdentifier)
            }
            do {
                let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
                return request == nil ? .available : .modelNotInstalled(languageIdentifier)
            } catch {
                return .failed(error.localizedDescription)
            }
        @unknown default:
            return .unsupportedLocale(languageIdentifier)
        }
    }

    /// Downloads and installs the speech model for `locale` from Apple (system asset; the audio
    /// itself is still recognized on the device). Call only on an explicit user action.
    public func installModel() async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unavailable(.unsupportedLocale(languageIdentifier))
        }
        let module = Self.makeModule(locale: supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    public func prepare() async {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        await keeper.warmUp(locale: supported)
    }

    public func releaseResources() async {
        await keeper.release()
    }

    public func beginUtterance(at audioTime: TimeInterval, onEvent: @escaping TranscriptionEventHandler) async throws
        -> any UtteranceTranscription
    {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unavailable(.unsupportedLocale(languageIdentifier))
        }
        let utterance = AppleUtteranceTranscription(locale: supported, offset: audioTime, onEvent: onEvent)
        try await utterance.start()
        return utterance
    }

    /// Volatile results give the UI text while the speaker is still talking; `fastResults`
    /// lowers their latency (≈ 1 s steps instead of ≈ 4 s, measured). Time ranges and confidence
    /// are attached to the result text.
    static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// The model stays loaded until `SpeechModels.endRetention()` (see `ModelKeeper.release()`).
    static let analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
}

/// Loads the recognition model once per listening session without occupying a recognizer slot.
private actor ModelKeeper {
    private var isWarm = false

    func warmUp(locale: Locale) async {
        guard !isWarm else { return }
        let module = AppleSpeechTranscriber.makeModule(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return }
        let analyzer = SpeechAnalyzer(modules: [module], options: AppleSpeechTranscriber.analyzerOptions)
        // Warm-up is an optimization; the first utterance reports real failures.
        isWarm = (try? await analyzer.prepareToAnalyze(in: format)) != nil
        await analyzer.cancelAndFinishNow()
    }

    func release() async {
        isWarm = false
        await SpeechModels.endRetention()
    }
}

/// One `SpeechAnalyzer` run. The analyzer timeline starts at 0 and is contiguous; `offset` maps
/// it to the session audio clock.
actor AppleUtteranceTranscription: UtteranceTranscription {
    private enum Phase { case idle, running, finishing, ended }

    private let locale: Locale
    private let offset: TimeInterval
    private let onEvent: TranscriptionEventHandler
    private var phase = Phase.idle
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var framesFed: Int64 = 0
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale, offset: TimeInterval, onEvent: @escaping TranscriptionEventHandler) {
        self.locale = locale
        self.offset = offset
        self.onEvent = onEvent
    }

    func start() async throws {
        let module = AppleSpeechTranscriber.makeModule(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriptionError.unsupportedAudioFormat("no compatible analyzer format")
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: AppleSpeechTranscriber.analyzerOptions)
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)

        self.analyzer = analyzer
        analyzerFormat = format
        input = continuation
        phase = .running

        let offset = self.offset
        let onEvent = self.onEvent
        resultsTask = Task {
            do {
                for try await result in module.results {
                    if Task.isCancelled { return }
                    let confidences = result.text.runs.compactMap(\.transcriptionConfidence)
                    let mean = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                    await onEvent(.update(TranscriptionUpdate(
                        text: String(result.text.characters),
                        audioTime: AudioTimeRange(start: offset + result.range.start.seconds,
                                                  duration: result.range.duration.seconds),
                        isFinal: result.isFinal, meanConfidence: mean, minimumConfidence: confidences.min(),
                        producedAt: .now)))
                }
                if !Task.isCancelled { await onEvent(.finished) }
            } catch {
                if !Task.isCancelled { await onEvent(.failed(error.localizedDescription)) }
            }
        }
    }

    func append(_ samples: [Float], sampleRate: Double) async {
        guard phase == .running, !samples.isEmpty, let buffer = convert(samples, sampleRate: sampleRate) else { return }
        yield(buffer)
    }

    func finish() async {
        guard phase == .running else { return }
        phase = .finishing
        if let tail = flushConverter() { yield(tail) }
        input?.finish()
        guard framesFed > 0, let analyzer else {
            // Nothing was recognized: end without asking the analyzer to finalize an empty stream.
            await end()
            await onEvent(.finished)
            return
        }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            // The results task delivers the remaining updates and then `.finished`.
            guard phase == .finishing else { return }
            phase = .ended
            self.analyzer = nil
            input = nil
            converter = nil
        } catch {
            guard phase == .finishing else { return }
            await end()
            await onEvent(.failed(error.localizedDescription))
        }
    }

    func cancel() async {
        guard phase != .ended else { return }
        await end()
    }

    private func end() async {
        phase = .ended
        resultsTask?.cancel()
        resultsTask = nil
        input?.finish()
        input = nil
        converter = nil
        if let analyzer {
            self.analyzer = nil
            await analyzer.cancelAndFinishNow()
        }
    }

    private func yield(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat else { return }
        let start = CMTime(value: framesFed, timescale: CMTimeScale(analyzerFormat.sampleRate))
        framesFed += Int64(buffer.frameLength)
        input?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
    }

    // MARK: - Sample-rate and format conversion (input rate Float32 → analyzer format)

    private func convert(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let analyzerFormat else { return nil }
        if converterInputFormat?.sampleRate != sampleRate {
            guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                return nil
            }
            converterInputFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        }
        guard let converter, let inputFormat = converterInputFormat,
              let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        source.frameLength = AVAudioFrameCount(samples.count)
        let ratio = analyzerFormat.sampleRate / sampleRate
        return run(converter, capacity: Int((Double(samples.count) * ratio).rounded(.up)) + 64, source: source)
    }

    /// Drains the resampler's remaining output at the end of the utterance.
    private func flushConverter() -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        return run(converter, capacity: 4_096, source: nil)
    }

    /// One conversion step. `source` nil signals the end of the stream.
    private func run(_ converter: AVAudioConverter, capacity: Int, source: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard let analyzerFormat,
              let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: AVAudioFrameCount(capacity))
        else { return nil }
        var pending = source
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if let buffer = pending {
                pending = nil
                inputStatus.pointee = .haveData
                return buffer
            }
            inputStatus.pointee = source == nil ? .endOfStream : .noDataNow
            return nil
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
