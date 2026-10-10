// hs-model-bench — forward-only scoring for the background-recognition research window.
//
// Runs classifier backends on exactly the sample ranges listed in
// results/background_benchmark/manifest.jsonl (tools/experiments/model_benchmark/build_manifest.py),
// so Apple's built-in classifier and the third-party models are compared on identical audio.
// Writes one JSON line per clip with raw label scores; metrics are computed in Python
// (tools/experiments/model_benchmark/evaluate.py). No training, no network, no audio written.
//
// Usage (from packages/HearingSenseKit):
//   swift run -c release hs-model-bench apple [--limit N] [--shard i/n]
//       Apple SNClassifySoundRequest(.version1): contexts of 1/2/5/10 s (one window = the whole
//       context) and the event stream with 1.5 s and 1.0 s windows, 50 % overlap.
//   swift run -c release hs-model-bench coreml --model <.mlpackage> --name <name> [--limit N] [--analysis-window S]
//       A converted model through CoreMLSoundClassifierBackend (CPU only) on the event stream:
//       checks the Swift resampling and windowing against the Python scores and times inference.
import AVFAudio
import CoreML
import Foundation
import HearingSenseDomain
import SoundEventDetection
import os

struct ContextSpec: Decodable {
    var start_sample: Int
    var samples: Int
    var available_samples: Int
}

struct ManifestRow: Decodable {
    var id: String
    var path: String
    var contexts: [String: ContextSpec]
}

struct WindowScores: Encodable {
    var start: Double
    var duration: Double
    var scores: [String: Float]
}

struct ClipScores: Encodable {
    var id: String
    var contexts: [String: [String: Float]] = [:]
    var streams: [String: [WindowScores]] = [:]
}

let repositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 5 { url.deleteLastPathComponent() }
    return url
}()
let outputDirectory = repositoryRoot.appending(path: "results/background_benchmark")
let scoreFloor = 0.002
let streamLead = 3.0, streamTail = 2.0, streamContext = "5"

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func loadManifest() throws -> [ManifestRow] {
    let text = try String(contentsOf: outputDirectory.appending(path: "manifest.jsonl"), encoding: .utf8)
    var rows = try text.split(separator: "\n").map { try JSONDecoder().decode(ManifestRow.self, from: Data($0.utf8)) }
    if let limit = argument("--limit").flatMap(Int.init), limit < rows.count {
        let step = max(rows.count / limit, 1)
        rows = stride(from: 0, to: rows.count, by: step).map { rows[$0] }
    }
    // --shard i/n: every n-th clip starting at i, to split a run over several processes.
    if let shard = argument("--shard")?.split(separator: "/").compactMap({ Int($0) }), shard.count == 2 {
        rows = rows.enumerated().filter { $0.offset % shard[1] == shard[0] }.map(\.element)
    }
    return rows
}

/// Channel 0 of one context at the file's own sample rate, zero-padded to the full length.
func context(_ row: ManifestRow, _ key: String) throws -> (samples: [Float], rate: Double) {
    let spec = row.contexts[key]!
    let file = try AVAudioFile(forReading: repositoryRoot.appending(path: row.path))
    let format = file.processingFormat
    var samples = [Float](repeating: 0, count: spec.samples)
    if spec.available_samples > 0 {
        file.framePosition = AVAudioFramePosition(spec.start_sample)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(spec.available_samples))!
        try file.read(into: buffer, frameCount: AVAudioFrameCount(spec.available_samples))
        let count = min(Int(buffer.frameLength), spec.samples)
        samples.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: buffer.floatChannelData![0], count: count) }
    }
    return (samples, format.sampleRate)
}

func stream(_ row: ManifestRow) throws -> (samples: [Float], rate: Double) {
    let (samples, rate) = try context(row, streamContext)
    return ([Float](repeating: 0, count: Int(streamLead * rate)) + samples
        + [Float](repeating: 0, count: Int(streamTail * rate)), rate)
}

/// Collects a backend's results (which may arrive on another thread).
final class Collector: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (windows: [ClassifierWindowResult](), failures: [String]()))
    var sink: ClassifierBackendSink {
        ClassifierBackendSink(result: { [state] result in state.withLock { $0.windows.append(result) } },
                              failure: { [state] message in state.withLock { $0.failures.append(message) } })
    }
    func take() -> (windows: [ClassifierWindowResult], failures: [String]) {
        state.withLock { value in
            defer { value = ([], []) }
            return (value.windows.sorted { $0.windowStart < $1.windowStart }, value.failures)
        }
    }
}

/// Feeds `samples` in 100 ms buffers, as the microphone tap would.
func run(_ backend: any AcousticClassifierBackend, samples: [Float], rate: Double, window: Double, overlap: Double,
         collector: Collector) throws -> [ClassifierWindowResult]
{
    let configuration = ClassifierConfiguration(windowDuration: window, overlapFactor: overlap, reportingFloor: 0,
                                                maxPredictionsPerFrame: .max, backlogLimit: nil)
    try backend.startSegment(sampleRate: rate, configuration: configuration, sink: collector.sink)
    let chunk = Int(rate / 10)
    var position = 0
    while position < samples.count {
        let end = min(position + chunk, samples.count)
        backend.analyze(Array(samples[position ..< end]), framePosition: Int64(position))
        position = end
    }
    backend.finishSegment()
    Thread.sleep(forTimeInterval: 0.002)  // late callbacks, if the framework delivers asynchronously
    let (windows, failures) = collector.take()
    if let failure = failures.first { throw BackendError.modelUnavailable(failure) }
    return windows
}

func compact(_ result: ClassifierWindowResult) -> [String: Float] {
    var scores: [String: Float] = [:]
    for (label, score) in result.classifications where score >= scoreFloor { scores[label] = Float(score) }
    return scores
}

func write(_ clips: [ClipScores], to name: String) throws {
    let directory = outputDirectory.appending(path: "scores")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    let lines = try clips.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    try lines.joined(separator: "\n").write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
    print("wrote \(directory.appending(path: name).path) (\(clips.count) clips)")
}

func scoreApple() throws {
    let rows = try loadManifest()
    let backend = AppleSoundAnalysisBackend()
    let collector = Collector()
    var output: [ClipScores] = []
    var missingWindows = 0
    let started = Date.now
    for (index, row) in rows.enumerated() {
        var clip = ClipScores(id: row.id)
        for key in ["1", "2", "5", "10"] {
            let (samples, rate) = try context(row, key)
            let windows = try run(backend, samples: samples, rate: rate, window: Double(key)!, overlap: 0,
                                  collector: collector)
            // One window spanning the context. If the framework reports none (or several), that is
            // recorded instead of being papered over.
            if let first = windows.first(where: { $0.windowStart < 0.01 }) {
                clip.contexts[key] = compact(first)
            } else {
                missingWindows += 1
            }
        }
        let (samples, rate) = try stream(row)
        for window in [1.5, 1.0] {
            let windows = try run(backend, samples: samples, rate: rate, window: window, overlap: 0.5,
                                  collector: collector)
            clip.streams[String(window)] = windows.map {
                WindowScores(start: $0.windowStart, duration: $0.windowDuration, scores: compact($0))
            }
        }
        output.append(clip)
        if (index + 1) % 200 == 0 {
            print("\(index + 1)/\(rows.count) clips, \(Int(Date.now.timeIntervalSince(started))) s")
        }
    }
    print("contexts without a result: \(missingWindows)")
    let shard = argument("--shard").map { "_shard" + $0.replacingOccurrences(of: "/", with: "of") } ?? ""
    try write(output, to: "apple_scores_apple_v1\(shard).jsonl")
}

func scoreCoreML() async throws {
    guard let path = argument("--model"), let name = argument("--name") else {
        print("usage: hs-model-bench coreml --model <.mlpackage> --name <name> [--limit N]")
        return
    }
    let rows = try loadManifest()
    let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: path))
    let factory = try CoreMLSoundClassifierBackend.factory(compiledModelAt: compiled, modelID: SoundModelID(rawValue: name),
                                                           analysisWindow: argument("--analysis-window").flatMap(Double.init))
    print(factory.metadata.summary)
    let backend = try factory.make()
    let collector = Collector()
    var output: [ClipScores] = []
    var timings: [Double] = []
    for row in rows {
        let (samples, rate) = try stream(row)
        let windows = try run(backend, samples: samples, rate: rate, window: 0, overlap: 0.5, collector: collector)
        timings += windows.compactMap(\.inferenceSeconds)
        var clip = ClipScores(id: row.id)
        clip.streams["swift"] = windows.map {
            WindowScores(start: $0.windowStart, duration: $0.windowDuration, scores: compact($0))
        }
        output.append(clip)
    }
    timings.sort()
    let milliseconds = { (fraction: Double) in timings[min(Int(Double(timings.count) * fraction), timings.count - 1)] * 1000 }
    print(String(format: "Mac, CPU only, %d windows: median %.2f ms, p95 %.2f ms, max %.2f ms", timings.count,
                 milliseconds(0.5), milliseconds(0.95), timings.last! * 1000))
    try write(output, to: "apple_scores_swift_\(name).jsonl")
}

/// Debug aid: writes the Swift resampler's output for one manifest stream as raw float32, so the
/// resampling can be compared with the Python reference sample by sample.
func dumpResampled() throws {
    guard let id = argument("--id"), let rate = argument("--rate").flatMap(Double.init), let out = argument("--out"),
          let row = try loadManifest().first(where: { $0.id == id })
    else {
        print("usage: hs-model-bench resample --id <clip id> --rate <Hz> --out <file.f32>")
        return
    }
    let (samples, native) = try stream(row)
    let resampler = StreamResampler(from: native, to: rate)!
    var converted: [Float] = []
    let chunk = Int(native / 10)
    for start in stride(from: 0, to: samples.count, by: chunk) {
        converted += resampler.convert(Array(samples[start ..< min(start + chunk, samples.count)]))
    }
    try converted.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: out))
    print("\(samples.count) samples at \(native) Hz → \(converted.count) at \(rate) Hz")
}

switch CommandLine.arguments.dropFirst().first {
case "resample": try dumpResampled()
case "apple": try scoreApple()
case "coreml": try await scoreCoreML()
default: print("usage: hs-model-bench apple | coreml --model <.mlpackage> --name <name> [--limit N]")
}
