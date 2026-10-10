#if DEBUG
import AVFAudio
import BackgroundTasks
import CoreML
import Foundation
import HearingSenseAudio
import SoundAnalysis
import UIKit
import os

/// Debug-only experiment (launch argument `--hs-bg-probe`), see
/// docs/research/BACKGROUND_INFERENCE_INVESTIGATION.md.
///
/// Question: when Apple's built-in sound classifier stops in the background, what exactly is
/// refused — SoundAnalysis itself, Core ML, or only some compute units? The probe runs next to
/// the unchanged production pipeline on the same microphone buffers and counts, separately for
/// the foreground, the background and the locked state:
///
/// - **direct lanes**: `MLModel.prediction` once per second with each `MLComputeUnits` setting;
/// - **SoundAnalysis lanes**: `SNAudioStreamAnalyzer` + `SNClassifySoundRequest(mlModel:)` with a
///   CPU-only and a CPU+GPU instance of the same custom model.
///
/// The model (`ProbeTiny`, tools/experiments/make_probe_model.py) has random weights: a result
/// here means "inference executed", never "a sound was recognized". Counters only; no audio and
/// no predictions are stored.
nonisolated final class BackgroundInferenceProbe: AudioStreamConsumer, @unchecked Sendable {
    static let argument = "--hs-bg-probe"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    enum AppPhase: String, CaseIterable { case foreground, background, locked }

    struct Tally {
        var succeeded = 0
        var failed = 0
        var seconds: Double = 0
        var maxSeconds: Double = 0
        var firstError: String?

        mutating func success(_ duration: Double) {
            succeeded += 1
            seconds += duration
            maxSeconds = max(maxSeconds, duration)
        }

        mutating func failure(_ error: String) {
            failed += 1
            if firstError == nil { firstError = error }
        }

        var summary: String {
            let mean = succeeded > 0 ? seconds / Double(succeeded) * 1000 : 0
            var text = "ok \(succeeded), failed \(failed)"
            if succeeded > 0 {
                text += ", mean \(mean.formatted(.number.precision(.fractionLength(2)))) ms, max "
                    + "\((maxSeconds * 1000).formatted(.number.precision(.fractionLength(2)))) ms"
            }
            if let firstError { text += " | first error: \(firstError)" }
            return text
        }
    }

    private struct Shared {
        var phase = AppPhase.foreground
        var isBackground = false
        var isLocked = false
        var buffers: [AppPhase: Int] = [:]
        var tallies: [String: [AppPhase: Tally]] = [:]
        var notes: [String] = []
    }

    private static let unitOptions: [(name: String, units: MLComputeUnits)] = [
        ("cpuOnly", .cpuOnly), ("cpuAndGPU", .cpuAndGPU), ("cpuAndNeuralEngine", .cpuAndNeuralEngine), ("all", .all),
    ]
    private static let soundAnalysisUnits: [(name: String, units: MLComputeUnits)] = [
        ("cpuOnly", .cpuOnly), ("cpuAndGPU", .cpuAndGPU),
    ]
    private static let inputSamples = 15_600

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue = DispatchQueue(label: "org.hearingsense.experiment.bg-probe", qos: .utility)
    private var observers: [any NSObjectProtocol] = []

    // Touched only on `queue`.
    private var directModels: [(name: String, model: MLModel)] = []
    private var lanes: [SoundAnalysisLane] = []
    private var recent: [Float] = []
    private var buffersSincePrediction = 0
    private var framePosition: Int64 = 0
    private var sampleRate: Double = 0

    init() {
        let center = NotificationCenter.default
        let watch: [(Notification.Name, @Sendable (inout Shared) -> Void)] = [
            (UIApplication.didEnterBackgroundNotification, { $0.isBackground = true }),
            (UIApplication.willEnterForegroundNotification, { $0.isBackground = false }),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, { $0.isLocked = true }),
            (UIApplication.protectedDataDidBecomeAvailableNotification, { $0.isLocked = false }),
        ]
        for (name, change) in watch {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [shared] _ in
                shared.withLock { state in
                    change(&state)
                    state.phase = !state.isBackground ? .foreground : (state.isLocked ? .locked : .background)
                }
            })
        }
        queue.async { [self] in loadModels() }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Setup (on `queue`)

    private func loadModels() {
        guard let url = Bundle.main.url(forResource: "ProbeTiny", withExtension: "mlmodelc") else {
            note("ProbeTiny.mlmodelc is not in the app bundle")
            return
        }
        for option in Self.unitOptions {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = option.units
            do {
                directModels.append((option.name, try MLModel(contentsOf: url, configuration: configuration)))
            } catch {
                note("direct/\(option.name): load failed: \(Self.describe(error))")
            }
            let (name, units) = option
            Task { [weak self] in
                let plan = await Self.computePlanSummary(url: url, units: units)
                self?.note("compute plan \(name): \(plan)")
            }
        }
        for option in Self.soundAnalysisUnits {
            lanes.append(SoundAnalysisLane(name: "SoundAnalysis custom/\(option.name)", modelURL: url, units: option.units,
                                           probe: self))
        }
        let resources = BGTaskScheduler.supportedResources
        note("BGTaskScheduler.supportedResources: rawValue \(resources.rawValue), gpu \(resources.contains(.gpu))")
    }

    /// Which device Core ML prefers for the model's operations under a configuration.
    private static func computePlanSummary(url: URL, units: MLComputeUnits) async -> String {
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
            guard case .program(let program) = plan.modelStructure, let main = program.functions["main"] else {
                return "not an ML program"
            }
            var counts: [String: Int] = [:]
            for operation in main.block.operations {
                guard let usage = plan.deviceUsage(for: operation) else { continue }
                let device = switch usage.preferred {
                case .cpu: "cpu"
                case .gpu: "gpu"
                case .neuralEngine: "neuralEngine"
                @unknown default: "other"
                }
                counts[device, default: 0] += 1
            }
            return counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        } catch {
            return "unavailable: \(describe(error))"
        }
    }

    // MARK: - AudioStreamConsumer

    func captureDidStart(format: AVAudioFormat) {
        queue.async { [self] in
            framePosition = 0
            for lane in lanes { lane.reset() }
        }
    }

    func captureDidReceive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        let rate = buffer.format.sampleRate
        let phase = shared.withLock { state -> AppPhase in
            state.buffers[state.phase, default: 0] += 1
            return state.phase
        }
        queue.async { [self] in process(samples, sampleRate: rate, phase: phase) }
    }

    func captureDidStop() {
        queue.async { [self] in for lane in lanes { lane.reset() } }
    }

    // MARK: - Work (on `queue`)

    private func process(_ samples: [Float], sampleRate rate: Double, phase: AppPhase) {
        if rate != sampleRate {
            sampleRate = rate
            framePosition = 0
            for lane in lanes { lane.reset() }
        }
        for lane in lanes { lane.analyze(samples, sampleRate: rate, framePosition: framePosition) }
        framePosition += Int64(samples.count)

        // The probe model's output is meaningless, so the direct lanes take the newest raw samples
        // without resampling.
        recent.append(contentsOf: samples)
        if recent.count > Self.inputSamples { recent.removeFirst(recent.count - Self.inputSamples) }
        buffersSincePrediction += 1
        guard buffersSincePrediction >= 10, recent.count == Self.inputSamples else { return }
        buffersSincePrediction = 0
        guard let input = try? MLMultiArray(shape: [NSNumber(value: Self.inputSamples)], dataType: .float32) else { return }
        recent.withUnsafeBufferPointer { source in
            input.withUnsafeMutableBytes { destination, _ in
                destination.copyMemory(from: UnsafeRawBufferPointer(source))
            }
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["audioSamples": input]) else { return }
        for (name, model) in directModels {
            let start = ContinuousClock.now
            do {
                let output = try model.prediction(from: provider)
                let elapsed = ContinuousClock.now - start
                if output.featureValue(for: "classLabel_probs")?.dictionaryValue.isEmpty == false {
                    record("direct/\(name)", phase: phase) { $0.success(Self.seconds(elapsed)) }
                } else {
                    record("direct/\(name)", phase: phase) { $0.failure("prediction returned no scores") }
                }
            } catch {
                record("direct/\(name)", phase: phase) { $0.failure(Self.describe(error)) }
            }
        }
    }

    fileprivate var currentPhase: AppPhase { shared.withLock { $0.phase } }

    fileprivate func record(_ lane: String, phase: AppPhase, _ change: @Sendable (inout Tally) -> Void) {
        shared.withLock { state in
            var tally = state.tallies[lane]?[phase] ?? Tally()
            change(&tally)
            state.tallies[lane, default: [:]][phase] = tally
        }
    }

    private func note(_ text: String) {
        shared.withLock { $0.notes.append(text) }
    }

    // MARK: - Reporting

    /// One line for the exporter's 5-second heartbeat: cumulative successes/failures per lane.
    func heartbeat() -> String {
        shared.withLock { state in
            let lanes = state.tallies.keys.sorted().map { lane -> String in
                let all = state.tallies[lane]?.values.reduce(into: (0, 0)) { $0.0 += $1.succeeded; $0.1 += $1.failed } ?? (0, 0)
                return "\(lane.replacingOccurrences(of: " ", with: "_"))=\(all.0)/\(all.1)"
            }
            return "probePhase=\(state.phase.rawValue) " + lanes.joined(separator: " ")
        }
    }

    func reportText() -> String {
        shared.withLock { state in
            var lines = ["Background inference probe (random-weight model: counts executions, not recognition)"]
            lines += state.notes.sorted()
            for phase in AppPhase.allCases {
                lines.append("-- \(phase.rawValue): \(state.buffers[phase] ?? 0) microphone buffers")
                for lane in state.tallies.keys.sorted() {
                    lines.append("   \(lane): \(state.tallies[lane]?[phase]?.summary ?? "no attempts")")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    static func describe(_ error: any Error) -> String {
        let error = error as NSError
        var text = "\(error.localizedDescription) (\(error.domain) \(error.code))"
        var underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let next = underlying {
            text += " ← \(next.localizedDescription) (\(next.domain) \(next.code))"
            underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return text
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// One `SNAudioStreamAnalyzer` with a custom-model request. Used only on the probe's queue; a
/// failed request is terminal, so the analyzer is rebuilt two seconds of audio later.
private nonisolated final class SoundAnalysisLane: NSObject, SNResultsObserving, @unchecked Sendable {
    private let name: String
    private let modelURL: URL
    private let units: MLComputeUnits
    private unowned let probe: BackgroundInferenceProbe
    private var analyzer: SNAudioStreamAnalyzer?
    private var needsRebuild = OSAllocatedUnfairLock(initialState: false)
    private var retryAtFrame: Int64 = 0

    init(name: String, modelURL: URL, units: MLComputeUnits, probe: BackgroundInferenceProbe) {
        self.name = name
        self.modelURL = modelURL
        self.units = units
        self.probe = probe
    }

    func reset() {
        analyzer?.removeAllRequests()
        analyzer = nil
        retryAtFrame = 0
    }

    func analyze(_ samples: [Float], sampleRate: Double, framePosition: Int64) {
        if needsRebuild.withLock({ flag in defer { flag = false }; return flag }) {
            analyzer = nil
            retryAtFrame = framePosition + Int64(2 * sampleRate)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        if analyzer == nil, framePosition >= retryAtFrame {
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                let request = try SNClassifySoundRequest(mlModel: MLModel(contentsOf: modelURL, configuration: configuration))
                let created = SNAudioStreamAnalyzer(format: format)
                try created.add(request, withObserver: self)
                analyzer = created
            } catch {
                probe.record(name, phase: probe.currentPhase) { $0.failure("setup: \(BackgroundInferenceProbe.describe(error))") }
                retryAtFrame = framePosition + Int64(2 * sampleRate)
            }
        }
        guard let analyzer, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0]
        else { return }
        samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        analyzer.analyze(buffer, atAudioFramePosition: framePosition)
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult, !result.classifications.isEmpty else { return }
        probe.record(name, phase: probe.currentPhase) { $0.success(0) }
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        probe.record(name, phase: probe.currentPhase) { $0.failure(BackgroundInferenceProbe.describe(error)) }
        needsRebuild.withLock { $0 = true }
    }
}
#endif
