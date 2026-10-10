import AVFAudio
import CoreML
import Foundation
import HearingSenseDomain
import Testing
@testable import SoundEventDetection

// Background-recognition research window: the classifier backend seam, the Core ML backend's
// audio preparation and the AudioSet taxonomy. Synthetic inputs check that the software is
// correct; they say nothing about how well any model recognizes real sounds.

@Suite struct WindowAssemblerTests {
    static func ramp(_ range: Range<Int>) -> [Float] { range.map(Float.init) }

    @Test func emitsOverlappingWindowsWithoutLosingOrRepeatingSamples() {
        var assembler = WindowAssembler(length: 8, hop: 4)
        var windows: [(Int64, [Float])] = []
        // Irregular buffer sizes, as a resampler produces.
        for range in [0 ..< 3, 3 ..< 10, 10 ..< 11, 11 ..< 26] {
            assembler.append(Self.ramp(range)) { windows.append(($0, $1)) }
        }
        #expect(windows.map(\.0) == [0, 4, 8, 12, 16])
        for (start, samples) in windows {
            #expect(samples == Self.ramp(Int(start) ..< Int(start) + 8))  // contiguous, correctly placed
        }
    }

    @Test func aHopLongerThanTheWindowIsNotNeededButAHopEqualToItTilesTheStream() {
        var assembler = WindowAssembler(length: 4, hop: 4)
        var starts: [Int64] = []
        assembler.append(Self.ramp(0 ..< 13)) { start, _ in starts.append(start) }
        #expect(starts == [0, 4, 8])
    }

    @Test func flushPadsTheTailOnlyWhenItHoldsEnoughNewAudio() {
        var assembler = WindowAssembler(length: 8, hop: 4)
        var windows: [(Int64, [Float])] = []
        assembler.append(Self.ramp(0 ..< 11)) { windows.append(($0, $1)) }  // one window (0..<8); 3 new samples left
        assembler.flush(minimumNewSamples: 4) { windows.append(($0, $1)) }
        #expect(windows.count == 1)

        assembler.append(Self.ramp(0 ..< 11)) { windows.append(($0, $1)) }
        assembler.flush(minimumNewSamples: 2) { windows.append(($0, $1)) }
        #expect(windows.count == 3)
        #expect(windows[2].0 == 4)
        #expect(windows[2].1 == [4, 5, 6, 7, 8, 9, 10, 0])  // zero-padded to the window length
    }

    @Test func resetStartsAgainAtTheGivenPosition() {
        var assembler = WindowAssembler(length: 4, hop: 2)
        var starts: [Int64] = []
        assembler.append(Self.ramp(0 ..< 5)) { start, _ in starts.append(start) }
        assembler.reset(at: 100)  // e.g. buffers were dropped upstream
        assembler.append(Self.ramp(0 ..< 4)) { start, _ in starts.append(start) }
        #expect(starts == [0, 100])
    }
}

@Suite struct StreamResamplerTests {
    static func sine(_ frequency: Double, rate: Double, count: Int, offset: Int = 0) -> [Float] {
        (0 ..< count).map { Float(0.5 * sin(2 * .pi * frequency * Double($0 + offset) / rate)) }
    }

    /// Dominant frequency by counting upward zero crossings.
    static func frequency(of samples: [Float], rate: Double) -> Double {
        let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) * rate / Double(samples.count)
    }

    @Test(arguments: [(48_000.0, 16_000.0), (48_000.0, 32_000.0), (44_100.0, 16_000.0), (44_100.0, 32_000.0)])
    func keepsDurationFrequencyAndLevel(rates: (Double, Double)) throws {
        let (input, output) = rates
        let resampler = try #require(StreamResampler(from: input, to: output))
        var converted: [Float] = []
        let chunk = Int(input / 10)  // 100 ms buffers, as the tap delivers
        for index in 0 ..< 20 {
            converted += resampler.convert(Self.sine(1000, rate: input, count: chunk, offset: index * chunk))
        }
        let expected = 2.0 * output
        #expect(abs(Double(converted.count) - expected) < 0.05 * output)  // short only by the converter's latency (< 50 ms)
        let steady = Array(converted[converted.count / 4 ..< converted.count * 3 / 4])
        #expect(abs(Self.frequency(of: steady, rate: output) - 1000) < 10)
        let peak = steady.map(abs).max() ?? 0
        #expect(abs(peak - 0.5) < 0.02)
    }

    @Test func consecutiveBuffersJoinWithoutASeam() throws {
        // A seam (dropped or repeated samples at a buffer boundary) would show as a jump much
        // larger than the largest step of a 1 kHz sine at 16 kHz (≈ 0.19 for amplitude 0.5).
        let steady = try #require(StreamResampler(from: 48_000, to: 16_000))
        var tone: [Float] = []
        var offset = 0
        for index in 0 ..< 30 {
            let count = [4800, 4096, 4801, 1024][index % 4]
            tone += steady.convert(Self.sine(1000, rate: 48_000, count: count, offset: offset))
            offset += count
        }
        let body = tone.dropFirst(800)
        let largestStep = zip(body, body.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(largestStep < 0.21)
        #expect(abs(Double(tone.count) - Double(offset) / 3) < 800)  // converter latency (< 50 ms)
    }

    @Test func attenuatesContentAboveTheNewNyquistFrequency() throws {
        // 12 kHz cannot be represented at 16 kHz; without a low-pass filter it would alias to 4 kHz
        // at full level.
        let resampler = try #require(StreamResampler(from: 48_000, to: 16_000))
        let converted = resampler.convert(Self.sine(12_000, rate: 48_000, count: 48_000))
        let steady = converted[converted.count / 4 ..< converted.count * 3 / 4]
        #expect((steady.map(abs).max() ?? 1) < 0.05)
    }

    @Test func equalRatesPassThroughUnchanged() throws {
        let resampler = try #require(StreamResampler(from: 16_000, to: 16_000))
        let samples = Self.sine(440, rate: 16_000, count: 1600)
        #expect(resampler.convert(samples) == samples)
    }
}

@Suite struct AudioSetTaxonomyTests {
    let taxonomy = SoundTaxonomy.audioSet(model: .yamnet)

    @Test func hasTheSameKindsAndCategoriesAsTheAppleTaxonomy() {
        #expect(taxonomy.definitions.map(\.kind) == SoundTaxonomy.appleV1.definitions.map(\.kind))
        #expect(taxonomy.definitions.map(\.profile) == SoundTaxonomy.appleV1.definitions.map(\.profile))
        #expect(taxonomy.model == .yamnet)
    }

    @Test func keepsOriginalLabelsAndMapsThemToTheExpectedKinds() {
        let expected: [SoundLabel: String] = [
            "Speech": "speech", "Narration, monologue": "speech", "Shout": "shouting", "Music": "music",
            "Singing": "music", "Knock": "door", "Doorbell": "door", "Vehicle horn, car horn, honking": "vehicle_horn",
            "Siren": "siren", "Smoke detector, smoke alarm": "alarm", "Fire alarm": "alarm", "Bark": "dog",
            "Shatter": "glass_breaking", "Rain": "rain", "Wind": "wind", "Thunder": "thunder",
            "Walk, footsteps": "footsteps", "Applause": "crowd", "Clapping": "hands", "Baby cry, infant cry": "crying",
            "Church bell": "bell", "Bicycle bell": "bicycle_bell", "Silence": "silence",
        ]
        for (label, kind) in expected {
            #expect(taxonomy.definition(for: label).kind.id == kind, "\(label)")
            #expect(taxonomy.displayName(for: label) == label.rawValue)
        }
    }

    @Test func broaderAndUnrelatedAudioSetClassesStayUnmapped() {
        // "Alarm" also covers telephones and sirens, "Glass" also clinking, "Vehicle" everything
        // that moves: mapping them would merge different kinds.
        for label: SoundLabel in ["Alarm", "Glass", "Vehicle", "Animal", "Noise", "Inside, small room", "Television"] {
            #expect(!taxonomy.isMapped(label), "\(label)")
            #expect(taxonomy.definition(for: label).kind.id == "unmapped")
        }
    }

    @Test func everyTableEntryNamesAnExistingKindAndNoLabelIsListedTwice() {
        let kinds = Set(SoundTaxonomy.appleV1.definitions.map(\.kind.id))
        var seen = Set<String>()
        for (kind, entry) in AudioSetLabelTable.byKind {
            #expect(kinds.contains(kind), "\(kind)")
            for label in entry.exact + entry.within { #expect(seen.insert(label).inserted, "\(label)") }
        }
        #expect(seen.count == taxonomy.mappedLabels.count)
    }

    @Test func theAudioSetPolicyOnlyRenamesTheLabelSpecificRule() {
        var renamed = DetectionPolicy.standardAudioSet
        #expect(renamed.suppressions.map(\.label) == ["Foghorn"])
        #expect(taxonomy.definition(for: "Foghorn").kind.id == "vehicle_horn")
        renamed.suppressions = DetectionPolicy.standard.suppressions
        #expect(renamed == DetectionPolicy.standard)
        #expect(SoundTaxonomy.audioSetVocalMusicLabels.allSatisfy { taxonomy.definition(for: $0).kind.id == "music" })
    }
}

/// A backend that reports scripted windows: one window per second of audio, with a label chosen
/// by the test. Synthetic stand-in for a model.
final class ScriptedBackend: AcousticClassifierBackend {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ entry: String) { lock.withLock { storage.append(entry) } }
        var entries: [String] { lock.withLock { storage } }
    }

    static let model = SoundModelID(rawValue: "test.scripted")
    static func factory(log: Log, model: SoundModelID = ScriptedBackend.model, taxonomy: SoundTaxonomy? = nil,
                        failingStarts: Int = 0, failAtSecond: Int? = nil,
                        label: @escaping @Sendable (Int) -> String = { _ in "Speech" }) -> ClassifierBackendFactory
    {
        let metadata = ClassifierBackendMetadata(model: model, runtime: "test", computeUnits: "none", labelCount: 2,
                                                 modelSampleRate: nil, summary: "scripted \(model.rawValue)")
        return ClassifierBackendFactory(metadata: metadata, taxonomy: taxonomy ?? .audioSet(model: model)) {
            ScriptedBackend(log: log, model: model, failingStarts: failingStarts, failAtSecond: failAtSecond, label: label)
        }
    }

    let metadata: ClassifierBackendMetadata
    let windowDuration: TimeInterval = 1
    let overlapFactor: Double = 0
    private let log: Log
    private var failingStarts: Int
    private var failAtSecond: Int?
    private let label: @Sendable (Int) -> String
    private var sink: ClassifierBackendSink?
    private var rate = 0.0
    private var emitted = 0

    init(log: Log, model: SoundModelID = ScriptedBackend.model, failingStarts: Int, failAtSecond: Int?,
         label: @escaping @Sendable (Int) -> String)
    {
        metadata = ClassifierBackendMetadata(model: model, runtime: "test", computeUnits: "none", labelCount: 2,
                                             modelSampleRate: nil, summary: "scripted \(model.rawValue)")
        self.log = log
        self.failingStarts = failingStarts
        self.failAtSecond = failAtSecond
        self.label = label
    }

    func startSegment(sampleRate: Double, configuration: ClassifierConfiguration, sink: ClassifierBackendSink) throws {
        if failingStarts > 0 {
            failingStarts -= 1
            log.add("start failed")
            throw BackendError.modelUnavailable("scripted start failure")
        }
        log.add("start")
        self.sink = sink
        rate = sampleRate
        emitted = 0
    }

    func analyze(_ samples: [Float], framePosition: Int64) {
        guard let sink else { return }
        let end = Double(framePosition + Int64(samples.count)) / rate
        while Double(emitted + 1) <= end + 1e-9 {
            if failAtSecond == emitted {
                failAtSecond = nil
                log.add("failed at \(emitted)")
                self.sink = nil
                sink.failure("scripted failure")
                return
            }
            var result = ClassifierWindowResult(windowStart: Double(emitted), windowDuration: 1,
                                                classifications: [(label(emitted), 0.9), ("Silence", 0.01)])
            result.inferenceSeconds = 0.001
            sink.result(result)
            emitted += 1
        }
    }

    func finishSegment() {
        log.add("finish")
        sink = nil
    }
}

@Suite(.serialized) struct ClassifierBackendPipelineTests {
    static let configuration = ClassifierConfiguration(windowDuration: 1, overlapFactor: 0, backlogLimit: nil)
    static func tone(_ index: Int) -> Float { 0.1 * sin(2 * .pi * 440 * Float(index) / 48_000) }

    static func frames(_ outputs: [SoundRecognitionOutput]) -> [ClassificationFrame] {
        outputs.compactMap { if case .frame(let report) = $0 { report.frame } else { nil } }
    }

    @Test func framesCarryTheBackendsModelLabelsAndTimestamps() async {
        let log = ScriptedBackend.Log()
        let engine = SoundRecognitionEngine(configuration: Self.configuration, backend: ScriptedBackend.factory(log: log))
        #expect(engine.backend.model == ScriptedBackend.model)
        #expect(engine.taxonomy.model == ScriptedBackend.model)  // the factory's taxonomy is used by default
        _ = SoundRecognitionEngineTests.feed(engine, seconds: 4, signal: Self.tone)
        engine.captureDidStop()
        let outputs = await SoundRecognitionEngineTests.collect(engine)
        let frames = Self.frames(outputs)
        #expect(frames.count == 4)
        #expect(frames.map(\.sequence) == [0, 1, 2, 3])
        #expect(frames.map { $0.audioTime.start } == [0, 1, 2, 3])
        #expect(frames.allSatisfy { $0.model == ScriptedBackend.model && $0.top?.label == "Speech" })
        #expect(frames.allSatisfy { $0.inputLevel != nil && $0.capturedAt != nil })
        // The unchanged detector turns the AudioSet label into the existing "speech" kind.
        let started = outputs.compactMap { if case .event(.started(let event)) = $0 { event } else { nil } }
        #expect(started.map(\.kind.id) == ["speech"])
        #expect(started.first?.primaryLabel == "Speech")
        guard case .sessionEnded(let diagnostics) = outputs.last else {
            Issue.record("missing sessionEnded")
            return
        }
        #expect(diagnostics.results == 4 && diagnostics.failures == 0)
        #expect(diagnostics.modelInference.count == 4)
        #expect(log.entries == ["start", "finish"])
    }

    @Test func aRestartedCaptureContinuesTheAudioClockInANewSegment() async {
        let log = ScriptedBackend.Log()
        let engine = SoundRecognitionEngine(configuration: Self.configuration, backend: ScriptedBackend.factory(log: log))
        _ = SoundRecognitionEngineTests.feed(engine, seconds: 2, signal: Self.tone)
        engine.captureDidStop()
        _ = SoundRecognitionEngineTests.feed(engine, seconds: 2, signal: Self.tone)
        engine.captureDidStop()
        let frames = Self.frames(await SoundRecognitionEngineTests.collect(engine))
        #expect(frames.map { $0.audioTime.start } == [0, 1, 2, 3])
        #expect(log.entries == ["start", "finish", "start", "finish"])  // one backend object, two segments
    }

    @Test func aFailingSegmentIsRetriedAfterABackOffAndRecovers() async {
        let log = ScriptedBackend.Log()
        let engine = SoundRecognitionEngine(configuration: Self.configuration,
                                            backend: ScriptedBackend.factory(log: log, failAtSecond: 1))
        _ = SoundRecognitionEngineTests.feed(engine, seconds: 6, signal: Self.tone)
        engine.captureDidStop()
        let outputs = await SoundRecognitionEngineTests.collect(engine)
        let failures = outputs.filter { if case .failure = $0 { true } else { false } }
        #expect(failures.count == 1)
        // Window 0, failure at 1 s, a new segment after the 1 s back-off: windows resume and their
        // timestamps stay on the session clock.
        let starts = Self.frames(outputs).map { $0.audioTime.start }
        #expect(starts.first == 0)
        #expect(starts.count >= 3)
        #expect(starts == starts.sorted())
        #expect(log.entries.filter { $0 == "start" }.count == 2)
    }

    @Test func aBackendThatCannotStartIsReportedAndRetriedWithoutCrashing() async {
        let log = ScriptedBackend.Log()
        let engine = SoundRecognitionEngine(configuration: Self.configuration,
                                            backend: ScriptedBackend.factory(log: log, failingStarts: 1))
        _ = SoundRecognitionEngineTests.feed(engine, seconds: 5, signal: Self.tone)
        engine.captureDidStop()
        let outputs = await SoundRecognitionEngineTests.collect(engine)
        #expect(outputs.contains { if case .failure(let message) = $0 { message.contains("scripted start failure") } else { false } })
        #expect(!Self.frames(outputs).isEmpty)
        #expect(log.entries.first == "start failed")
    }

    @Test func endingTheSessionDiscardsLateResultsOfTheOldSession() async {
        let log = ScriptedBackend.Log()
        let engine = SoundRecognitionEngine(configuration: Self.configuration, backend: ScriptedBackend.factory(log: log))
        _ = SoundRecognitionEngineTests.feed(engine, seconds: 2, signal: Self.tone)
        let first = await SoundRecognitionEngineTests.collect(engine)  // ends the session
        #expect(Self.frames(first).count == 2)
        _ = SoundRecognitionEngineTests.feed(engine, seconds: 2, signal: Self.tone)
        engine.captureDidStop()
        let second = Self.frames(await SoundRecognitionEngineTests.collect(engine))
        #expect(second.map(\.sequence) == [0, 1])  // a fresh session: sequence and clock restart
        #expect(second.map { $0.audioTime.start } == [0, 1])
    }
}

/// The hybrid arrangement with two scripted classifiers: "apple" reports Apple's label `speech`,
/// "cpu" reports AudioSet's `Speech`. Synthetic; the real pair is tested on the iPhone.
@Suite(.serialized) struct SwitchingClassifierBackendTests {
    static let apple = SoundModelID(rawValue: "test.apple")
    static let cpu = SoundModelID(rawValue: "test.cpu")

    static func engine(selection: ClassifierBackendSelection, primaryLog: ScriptedBackend.Log,
                       secondaryLog: ScriptedBackend.Log, primaryFailsAt: Int? = nil) -> SoundRecognitionEngine
    {
        let primary = ScriptedBackend.factory(log: primaryLog, model: apple, taxonomy: .appleV1,
                                              failAtSecond: primaryFailsAt) { _ in "speech" }
        let secondary = ScriptedBackend.factory(log: secondaryLog, model: cpu) { _ in "Speech" }
        return SoundRecognitionEngine(configuration: ClassifierBackendPipelineTests.configuration, policy: .standardHybrid,
                                      backend: SwitchingClassifierBackend.factory(primary: primary, secondary: secondary,
                                                                                 selection: selection))
    }

    /// Feeds one second at a time so the selection can change between seconds.
    static func feedSeconds(_ engine: SoundRecognitionEngine, _ seconds: Range<Int>, start: Bool) async {
        if start { engine.captureDidStart(format: SoundRecognitionEngineTests.format) }
        for second in seconds {
            for index in 0 ..< 10 {
                let buffer = AVAudioPCMBuffer(pcmFormat: SoundRecognitionEngineTests.format, frameCapacity: 4800)!
                buffer.frameLength = 4800
                for i in 0 ..< 4800 { buffer.floatChannelData![0][i] = ClassifierBackendPipelineTests.tone(i) }
                let position = Int64(second * 48_000 + index * 4800)
                engine.captureDidReceive(buffer, at: AVAudioTime(sampleTime: position, atRate: 48_000))
            }
        }
        await engine.drain()
    }

    @Test func switchingKeepsOneClockOneSegmentAndOneEvent() async {
        let selection = ClassifierBackendSelection()
        let (primaryLog, secondaryLog) = (ScriptedBackend.Log(), ScriptedBackend.Log())
        let engine = Self.engine(selection: selection, primaryLog: primaryLog, secondaryLog: secondaryLog)
        await Self.feedSeconds(engine, 0 ..< 3, start: true)   // foreground
        selection.prefersSecondary = true                       // app entered the background
        await Self.feedSeconds(engine, 3 ..< 6, start: false)
        selection.prefersSecondary = false                      // foreground again
        await Self.feedSeconds(engine, 6 ..< 8, start: false)
        engine.captureDidStop()
        let outputs = await SoundRecognitionEngineTests.collect(engine)
        let frames = ClassifierBackendPipelineTests.frames(outputs)
        #expect(frames.map { $0.audioTime.start } == [0, 1, 2, 3, 4, 5, 6, 7])  // no gap, no restart, no duplicate
        #expect(frames.map(\.model) == [Self.apple, Self.apple, Self.apple, Self.cpu, Self.cpu, Self.cpu, Self.apple, Self.apple])
        #expect(frames.map { $0.top?.label } == ["speech", "speech", "speech", "Speech", "Speech", "Speech", "speech", "speech"])
        // One speech event across both classifiers: started once, never ended in between.
        let started = outputs.compactMap { if case .event(.started(let event)) = $0 { event } else { nil } }
        let ended = outputs.compactMap { if case .event(.ended(let event)) = $0 { event } else { nil } }
        #expect(started.map(\.kind.id) == ["speech"])
        #expect(ended.count == 1 && ended.first?.id == started.first?.id)
        #expect(!outputs.contains { if case .failure = $0 { true } else { false } })
        #expect(outputs.filter { if case .analyzerStarted = $0 { true } else { false } }.count == 1)
        #expect(primaryLog.entries == ["start", "finish", "start", "finish"])
        #expect(secondaryLog.entries == ["start", "finish"])
    }

    @Test func aFailingPrimaryHandsOverWithoutAPipelineFailureAndIsRetriedOnlyWhenSelectedAgain() async {
        let selection = ClassifierBackendSelection()
        let (primaryLog, secondaryLog) = (ScriptedBackend.Log(), ScriptedBackend.Log())
        // The primary fails at its third window, as Apple's classifier does once the app is in
        // the background, before anything told the backend about the background.
        let engine = Self.engine(selection: selection, primaryLog: primaryLog, secondaryLog: secondaryLog, primaryFailsAt: 2)
        await Self.feedSeconds(engine, 0 ..< 6, start: true)
        var frames = ClassifierBackendPipelineTests.frames([])
        selection.prefersSecondary = true    // the app reports the background a little later
        await Self.feedSeconds(engine, 6 ..< 7, start: false)
        selection.prefersSecondary = false   // foreground: the primary gets another chance
        await Self.feedSeconds(engine, 7 ..< 9, start: false)
        engine.captureDidStop()
        let outputs = await SoundRecognitionEngineTests.collect(engine)
        frames = ClassifierBackendPipelineTests.frames(outputs)
        #expect(!outputs.contains { if case .failure = $0 { true } else { false } })  // no back-off, no retry storm
        let models = frames.map(\.model)
        #expect(Array(models.prefix(2)) == [Self.apple, Self.apple])
        #expect(models.contains(Self.cpu))
        #expect(models.last == Self.apple)
        // The window in which the primary failed is lost; nothing else is, and time never goes back.
        let starts = frames.map { $0.audioTime.start }
        #expect(starts == starts.sorted() && Set(starts).count == starts.count)
        #expect(starts.count >= 8)
        #expect(primaryLog.entries.filter { $0 == "start" }.count == 2)
    }

    @Test func theMergedTaxonomyReadsBothLabelSets() {
        let merged = SoundTaxonomy.merged(.appleV1, .audioSet(model: .yamnet), model: .hybrid(background: .yamnet))
        #expect(merged.definition(for: "dog_bark").kind.id == "dog")
        #expect(merged.definition(for: "Bark").kind.id == "dog")
        #expect(merged.definition(for: "knock").kind.id == merged.definition(for: "Knock").kind.id)
        #expect(merged.silenceLabels == ["silence", "Silence"])
        #expect(merged.definitions.map(\.kind) == SoundTaxonomy.appleV1.definitions.map(\.kind))
        #expect(merged.mappedLabels.count == SoundTaxonomy.appleV1.mappedLabels.count
            + SoundTaxonomy.audioSet(model: .yamnet).mappedLabels.count)
        #expect(Set(DetectionPolicy.standardHybrid.suppressions.map(\.label)) == ["foghorn", "Foghorn"])
    }
}

/// The real converted model (forward-only), when it has been generated locally with
/// tools/experiments/audio_models/convert_coreml.py. Skipped otherwise.
@Suite(.serialized) struct CoreMLSoundClassifierBackendTests {
    static let package = RepositoryPaths.root.appending(path: "models/coreml_audio/YAMNet.mlpackage")
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: package.path) }

    @Test(.enabled(if: isAvailable)) func readsTheModelContractFromItsMetadata() async throws {
        let compiled = try await MLModel.compileModel(at: Self.package)
        let info = try CoreMLSoundClassifierBackend.inspect(compiledModelAt: compiled)
        #expect(info.sampleRate == 16_000 && info.windowSamples == 15_600 && info.labels.count == 521)
        #expect(info.labels.first == "Speech")
        let factory = try CoreMLSoundClassifierBackend.factory(compiledModelAt: compiled, modelID: .yamnet)
        #expect(factory.metadata.computeUnits == "cpuOnly" && factory.metadata.runtime == "Core ML")
    }

    @Test(.enabled(if: isAvailable)) func classifiesAStreamOnTheCPUWithCorrectWindowTiming() async throws {
        let compiled = try await MLModel.compileModel(at: Self.package)
        let factory = try CoreMLSoundClassifierBackend.factory(compiledModelAt: compiled, modelID: .yamnet)
        let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5,
                                                                                   backlogLimit: nil),
                                            policy: .standardAudioSet, backend: factory)
        let buffers = SoundRecognitionEngineTests.feed(engine, seconds: 6) { _ in 0 }
        engine.captureDidStop()
        let outputs = await SoundRecognitionEngineTests.collect(engine)
        let frames = ClassifierBackendPipelineTests.frames(outputs)
        // 0.975 s windows every 0.4875 s over 6 s: starts 0, 0.4875, … ≤ 5.025 → 11 full windows
        // (+ a flushed, zero-padded tail).
        #expect(frames.count >= 11)
        #expect(abs(frames[0].audioTime.duration - 0.975) < 1e-6)
        #expect(abs(frames[1].audioTime.start - frames[0].audioTime.start - 0.4875) < 1e-3)
        #expect(frames.allSatisfy { $0.model == .yamnet })
        #expect(frames.allSatisfy { $0.top?.label == "Silence" })  // digital silence in, "Silence" out
        guard case .sessionEnded(let diagnostics) = outputs.last else {
            Issue.record("missing sessionEnded")
            return
        }
        #expect(diagnostics.chunksAnalyzed == buffers && diagnostics.failures == 0)
        #expect(diagnostics.modelInference.count == frames.count)
        #expect(diagnostics.modelInference.max < 0.2)  // far faster than the 0.49 s between windows
    }

    @Test(.enabled(if: isAvailable && FileManager.default.fileExists(atPath: RepositoryPaths.speechSample.path)))
    func realSpeechRecordingProducesASpeechEventThroughTheUnchangedDetector() async throws {
        let compiled = try await MLModel.compileModel(at: Self.package)
        let factory = try CoreMLSoundClassifierBackend.factory(compiledModelAt: compiled, modelID: .yamnet)
        let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5,
                                                                                   backlogLimit: nil),
                                            policy: .standardAudioSet, backend: factory)
        let file = try AVAudioFile(forReading: RepositoryPaths.speechSample)
        let format = file.processingFormat
        engine.captureDidStart(format: format)
        var position: Int64 = 0
        while position < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            try file.read(into: buffer, frameCount: 4800)
            if buffer.frameLength == 0 { break }
            engine.captureDidReceive(buffer, at: AVAudioTime(sampleTime: position, atRate: format.sampleRate))
            position += Int64(buffer.frameLength)
        }
        engine.captureDidStop()
        let outputs = await SoundRecognitionEngineTests.collect(engine)
        let started = outputs.compactMap { if case .event(.started(let event)) = $0 { event } else { nil } }
        #expect(started.contains { $0.kind.id == "speech" })
        #expect(started.allSatisfy { $0.source == .soundClassifier(.yamnet) })
    }

    /// The real pair of the hybrid arrangement on a recording: Apple's classifier for the first
    /// half, YAMNet on the CPU for the second (as after the app entered the background).
    @Test(.enabled(if: isAvailable && FileManager.default.fileExists(atPath: RepositoryPaths.speechSample.path)))
    func theRealHybridKeepsRecognizingSpeechAcrossTheSwitch() async throws {
        let compiled = try await MLModel.compileModel(at: Self.package)
        let selection = ClassifierBackendSelection()
        let factory = SwitchingClassifierBackend.factory(
            primary: AppleSoundAnalysisBackend.factory,
            secondary: try CoreMLSoundClassifierBackend.factory(compiledModelAt: compiled, modelID: .yamnet),
            selection: selection)
        let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5,
                                                                                   backlogLimit: nil),
                                            policy: .standardHybrid, backend: factory)
        let file = try AVAudioFile(forReading: RepositoryPaths.speechSample)
        let format = file.processingFormat
        engine.captureDidStart(format: format)
        var position: Int64 = 0
        while position < file.length {
            if selection.prefersSecondary == false, position >= file.length / 2 {
                await engine.drain()
                selection.prefersSecondary = true
            }
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            try file.read(into: buffer, frameCount: 4800)
            if buffer.frameLength == 0 { break }
            engine.captureDidReceive(buffer, at: AVAudioTime(sampleTime: position, atRate: format.sampleRate))
            position += Int64(buffer.frameLength)
        }
        engine.captureDidStop()
        let outputs = await SoundRecognitionEngineTests.collect(engine)
        let frames = ClassifierBackendPipelineTests.frames(outputs)
        let half = Double(file.length / 2) / format.sampleRate
        #expect(frames.contains { $0.model == .appleSoundClassifierV1 && $0.top?.label == "speech" })
        #expect(frames.contains { $0.model == .yamnet && $0.top?.label == "Speech" })
        #expect(frames.filter { $0.model == .yamnet }.allSatisfy { $0.audioTime.start >= half - 0.01 })
        #expect(frames.filter { $0.model == .appleSoundClassifierV1 }.allSatisfy { $0.audioTime.start < half })
        let starts = frames.map { $0.audioTime.start }
        #expect(starts == starts.sorted())
        #expect(!outputs.contains { if case .failure = $0 { true } else { false } })
        // The speech event confirmed by Apple's classifier is still the one being updated after
        // the switch: it was started once and ends only with the session.
        let speechStarts = outputs.compactMap { if case .event(.started(let event)) = $0, event.kind.id == "speech" { event } else { nil } }
        #expect(speechStarts.count == 1)
    }

    /// EfficientAT MN10 with a 2 s analysis window repeated into its 10 s input.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: RepositoryPaths.root.appending(path: "models/coreml_audio/EfficientAT_MN10_10s.mlpackage").path)
            && FileManager.default.fileExists(atPath: RepositoryPaths.speechSample.path)))
    func aShortAnalysisWindowIsRepeatedIntoTheModelInput() async throws {
        let compiled = try await MLModel.compileModel(at: RepositoryPaths.root.appending(path: "models/coreml_audio/EfficientAT_MN10_10s.mlpackage"))
        let factory = try CoreMLSoundClassifierBackend.factory(compiledModelAt: compiled, modelID: .efficientATMN10,
                                                               analysisWindow: 2)
        let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.75,
                                                                                   backlogLimit: nil),
                                            policy: .standardAudioSet, backend: factory)
        let file = try AVAudioFile(forReading: RepositoryPaths.speechSample)
        let format = file.processingFormat
        engine.captureDidStart(format: format)
        var position: Int64 = 0
        while position < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            try file.read(into: buffer, frameCount: 4800)
            if buffer.frameLength == 0 { break }
            engine.captureDidReceive(buffer, at: AVAudioTime(sampleTime: position, atRate: format.sampleRate))
            position += Int64(buffer.frameLength)
        }
        engine.captureDidStop()
        let frames = ClassifierBackendPipelineTests.frames(await SoundRecognitionEngineTests.collect(engine))
        #expect(abs(frames[0].audioTime.duration - 2) < 1e-6)                                   // 2 s of audio per result
        #expect(abs(frames[1].audioTime.start - frames[0].audioTime.start - 0.5) < 1e-3)       // every 0.5 s
        // Not saturated (the failure of the unrepeated short input) and recognizably speech.
        #expect(frames.allSatisfy { $0.predictions.count < 10 || ($0.predictions.last?.score.rawValue ?? 0) < 0.9 })
        let taxonomy = SoundTaxonomy.audioSet(model: .efficientATMN10)
        let speechFrames = frames.filter { $0.top.map { taxonomy.definition(for: $0.label).kind.id == "speech" } ?? false }
        #expect(speechFrames.count > frames.count / 2, "top labels: \(Set(frames.compactMap { $0.top?.label.rawValue }))")
    }

    @Test func aMissingModelIsAnErrorNotACrash() {
        #expect(throws: BackendError.self) {
            _ = try CoreMLSoundClassifierBackend.factory(compiledModelAt: URL(fileURLWithPath: "/nonexistent.mlmodelc"),
                                                         modelID: .yamnet)
        }
    }
}
