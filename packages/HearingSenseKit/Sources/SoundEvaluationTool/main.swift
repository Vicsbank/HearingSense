// hs-sound-eval — forward-only offline evaluation of the Window 2 sound recognition pipeline.
//
// Runs local audio files through the production SoundRecognitionEngine (same copy → analyzer →
// detector path as the app, Apple's built-in classifier), records every confirmed event and a
// few window-level score statistics, and writes JSON summaries. No training, no network.
//
// Usage (from packages/HearingSenseKit):
//   swift run -c release hs-sound-eval labels
//   swift run -c release hs-sound-eval evaluate --window 1.5 [--pad SECONDS] [--libri 500] [--gtzan 300] [--out DIR]
//   (--pad: trailing silence after each clip, default = one window; see `run`;
//    --gtzan-holdout: GTZAN clips disjoint from the standard subset)
//
// Ground truth is clip-level and only as strong as the datasets allow:
// - LibriSpeech dev-clean, macOS TTS: read speech only (speech present; music, alarms absent).
// - GTZAN: music (vocals possible, so "speech" on GTZAN is not scored as an error).
// - DEMAND ch01: scene recordings with no event annotations (rates only, not accuracy).
import AVFAudio
import Foundation
import HearingSenseDomain
import SoundEventDetection

// MARK: - Datasets

enum Truth: String, Codable {
    case speechOnly, music, scene
}

struct Clip {
    var dataset: String
    var group: String
    var url: URL
    var truth: Truth
}

let repositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 5 { url.deleteLastPathComponent() }  // main.swift → repository root
    return url
}()

func files(under directory: URL, extension ext: String) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension.lowercased() == ext && !$0.lastPathComponent.hasPrefix("._") }
        .sorted { $0.path < $1.path }
}

/// Deterministic, evenly spaced subset (every k-th item of the sorted list).
func evenSubset<T>(_ items: [T], count: Int) -> [T] {
    guard count > 0 else { return [] }
    guard count < items.count else { return items }
    let step = Double(items.count) / Double(count)
    return (0 ..< count).map { items[Int(Double($0) * step)] }
}

/// - Parameter gtzanHoldout: use GTZAN clips that are *not* in the standard subset (for checking
///   rules that were tuned on the standard subset).
func datasetClips(libri: Int, gtzan: Int, gtzanHoldout: Bool = false) -> [Clip] {
    let data = repositoryRoot.appending(path: "data")
    var clips: [Clip] = []
    let libriFiles = files(under: data.appending(path: "noise/librispeech"), extension: "flac")
    clips += evenSubset(libriFiles, count: libri).map {
        Clip(dataset: "librispeech", group: "dev-clean", url: $0, truth: .speechOnly)
    }
    clips += files(under: data.appending(path: "test_signals"), extension: "aiff").map {
        Clip(dataset: "tts", group: "macos-say", url: $0, truth: .speechOnly)
    }
    let gtzanRoot = data.appending(path: "gtzan/genres")
    let genres = ((try? FileManager.default.contentsOfDirectory(atPath: gtzanRoot.path)) ?? [])
        .filter { !$0.hasPrefix(".") }.sorted()
    for genre in genres {
        let genreFiles = files(under: gtzanRoot.appending(path: genre), extension: "wav")
        let perGenre = max(gtzan / max(genres.count, 1), 1)
        var pool = genreFiles
        if gtzanHoldout {
            let standard = Set(evenSubset(genreFiles, count: perGenre))
            pool = genreFiles.filter { !standard.contains($0) }
        }
        clips += evenSubset(pool, count: perGenre).map {
            Clip(dataset: "gtzan", group: genre, url: $0, truth: .music)
        }
    }
    for scene in ["DLIVING", "PCAFETER", "PSTATION", "STRAFFIC"] {
        let url = data.appending(path: "noise/demand/\(scene)/\(scene)/ch01.wav")
        if FileManager.default.fileExists(atPath: url.path) {
            clips.append(Clip(dataset: "demand", group: scene, url: url, truth: .scene))
        }
    }
    return clips
}

// MARK: - Running one clip through the production engine

struct EventRecord: Codable {
    var kind: String
    var category: String
    var primaryLabel: String
    var audioStart: Double
    var audioConfirmed: Double
    var audioLastObserved: Double
    var peakScore: Double
    var supportingWindows: Int
    var quality: String
}

struct ClipResult: Codable {
    var dataset: String
    var group: String
    var file: String
    var truth: Truth
    var duration: Double
    var windows: Int
    var events: [EventRecord]
    /// Best score per window for selected kinds, for threshold analysis.
    var speechScores: [Double]
    var musicScores: [Double]
    var alertScores: [Double]
    var failures: [String]
}

let alertKinds: Set<String> = ["siren", "vehicle_horn", "alarm", "reverse_beeps", "bicycle_bell"]

/// - Parameter padding: seconds of digital silence appended after the file. A file that ends
///   right after a sound gives the analyzer fewer windows than a live stream would (where audio
///   simply continues), so short clips would otherwise be under-counted.
func run(_ clip: Clip, engine: SoundRecognitionEngine, padding: Double,
         iterator: inout AsyncStream<SoundRecognitionOutput>.Iterator) async throws -> ClipResult
{
    let file = try AVAudioFile(forReading: clip.url)
    let format = file.processingFormat
    let chunk = AVAudioFrameCount((format.sampleRate * 0.1).rounded())  // 100 ms, like the iPhone tap
    engine.captureDidStart(format: format)
    var position: AVAudioFramePosition = 0
    while position < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
        try file.read(into: buffer, frameCount: chunk)
        if buffer.frameLength == 0 { break }
        engine.captureDidReceive(buffer, at: AVAudioTime(sampleTime: position, atRate: format.sampleRate))
        position += AVAudioFramePosition(buffer.frameLength)
    }
    let paddingEnd = position + AVAudioFramePosition(padding * format.sampleRate)
    while position < paddingEnd {
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
        silence.frameLength = chunk  // zero-initialized
        engine.captureDidReceive(silence, at: AVAudioTime(sampleTime: position, atRate: format.sampleRate))
        position += AVAudioFramePosition(chunk)
    }
    engine.captureDidStop()
    engine.endSession()

    let taxonomy = engine.taxonomy
    var result = ClipResult(dataset: clip.dataset, group: clip.group, file: clip.url.lastPathComponent, truth: clip.truth,
                            duration: Double(file.length) / format.sampleRate, windows: 0, events: [],
                            speechScores: [], musicScores: [], alertScores: [], failures: [])
    while let output = await iterator.next() {
        switch output {
        case .frame(let report):
            result.windows += 1
            func best(_ match: (SoundKindDefinition) -> Bool) -> Double {
                report.frame.predictions.filter { match(taxonomy.definition(for: $0.label)) }
                    .map(\.score.rawValue).max() ?? 0
            }
            result.speechScores.append(best { $0.kind.id == "speech" })
            result.musicScores.append(best { $0.kind.id == "music" })
            result.alertScores.append(best { alertKinds.contains($0.kind.id) })
        case .event(.started(let event)):
            result.events.append(EventRecord(
                kind: event.kind.id, category: event.category.rawValue, primaryLabel: event.primaryLabel.rawValue,
                audioStart: event.audioStart, audioConfirmed: event.audioConfirmed,
                audioLastObserved: event.audioLastObserved, peakScore: event.evidence.peakScore.rawValue,
                supportingWindows: event.evidence.supportingWindows, quality: event.quality.description))
        case .event(.ended(let event)):
            if let index = result.events.lastIndex(where: { $0.kind == event.kind.id }) {
                result.events[index].audioLastObserved = event.audioLastObserved
                result.events[index].peakScore = event.evidence.peakScore.rawValue
                result.events[index].supportingWindows = event.evidence.supportingWindows
                result.events[index].primaryLabel = event.primaryLabel.rawValue
                result.events[index].quality = event.quality.description
            }
        case .failure(let message):
            result.failures.append(message)
        case .sessionEnded:
            return result
        case .event(.updated), .analyzerStarted:
            break
        }
    }
    return result
}

// MARK: - Metrics

/// Wilson score interval for a binomial proportion (95 %).
func wilson(_ successes: Int, _ total: Int) -> [Double] {
    guard total > 0 else { return [0, 0] }
    let z = 1.959964, n = Double(total), p = Double(successes) / n
    let centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    let margin = z * sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return [max(0, centre - margin), min(1, centre + margin)]
}

func percentile(_ values: [Double], _ q: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[min(Int((q * Double(sorted.count)).rounded(.up)) - 1, sorted.count - 1).clamped(0, sorted.count - 1)]
}

extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

struct Rate: Codable {
    var hits: Int
    var total: Int
    var rate: Double
    var ci95: [Double]
    init(_ hits: Int, _ total: Int) {
        self.hits = hits
        self.total = total
        rate = total > 0 ? Double(hits) / Double(total) : 0
        ci95 = wilson(hits, total)
    }
}

struct DetectionSummary: Codable {
    var clips: Int
    var audioHours: Double
    var recall: Rate
    var timeToConfirmMedian: Double?
    var timeToConfirmP90: Double?
    var windowsAtOrAboveEnter: Double  // fraction of windows with score ≥ the kind's enter threshold
}

struct EventRateSummary: Codable {
    var audioHours: Double
    var clipsWithEvent: Rate
    var eventsPerHour: Double
    var kinds: [String: Int]
}

struct Summary: Codable {
    var configuration: [String: Double]
    var platform: String
    var date: String
    var wallSeconds: Double
    var audioSeconds: Double
    var speechOnSpeechOnly: DetectionSummary
    var musicOnGTZAN: DetectionSummary
    var musicPerGenre: [String: Rate]
    var musicOnSpeechOnly: EventRateSummary
    var alertsOnSpeechOnly: EventRateSummary
    var impactsOnSpeechOnly: EventRateSummary
    var alertsOnGTZAN: EventRateSummary
    var otherKindsOnSpeechOnly: [String: Int]
    var demand: [String: [String: Double]]  // scene → kind → events per hour
    var demandAlerts: [String: [String]]  // scene → alert events (label @ time)
    var windowAlertScoreAbove05: [String: Double]  // dataset → fraction of windows with an alert label ≥ 0.5
}

func detection(_ results: [ClipResult], kind: String, enter: Double, scores: (ClipResult) -> [Double]) -> DetectionSummary {
    let hits = results.compactMap { $0.events.first { $0.kind == kind } }
    let latencies = hits.map(\.audioConfirmed)
    let allScores = results.flatMap(scores)
    return DetectionSummary(clips: results.count, audioHours: results.reduce(0) { $0 + $1.duration } / 3600,
                            recall: Rate(hits.count, results.count),
                            timeToConfirmMedian: percentile(latencies, 0.5), timeToConfirmP90: percentile(latencies, 0.9),
                            windowsAtOrAboveEnter: allScores.isEmpty ? 0
                                : Double(allScores.filter { $0 >= enter }.count) / Double(allScores.count))
}

func eventRate(_ results: [ClipResult], where match: (EventRecord) -> Bool) -> EventRateSummary {
    let hours = results.reduce(0) { $0 + $1.duration } / 3600
    let events = results.flatMap { $0.events.filter(match) }
    return EventRateSummary(audioHours: hours,
                            clipsWithEvent: Rate(results.filter { $0.events.contains(where: match) }.count, results.count),
                            eventsPerHour: hours > 0 ? Double(events.count) / hours : 0,
                            kinds: Dictionary(grouping: events, by: \.kind).mapValues(\.count))
}

// MARK: - Commands

func evaluate(window: Double, overlap: Double = 0.5, padding: Double, libri: Int, gtzan: Int, gtzanHoldout: Bool, outDirectory: URL) async throws {
    let configuration = ClassifierConfiguration(windowDuration: window, overlapFactor: overlap, backlogLimit: nil)
    var policy = DetectionPolicy.standard
    if arguments.contains("--no-suppressions") { policy.suppressions = [] }
    let engine = SoundRecognitionEngine(configuration: configuration, policy: policy)
    var iterator = engine.outputs.makeAsyncIterator()
    let clips = datasetClips(libri: libri, gtzan: gtzan, gtzanHoldout: gtzanHoldout)
    print("Evaluating \(clips.count) clips, window \(window) s, overlap \(overlap) …")
    let start = Date()
    var results: [ClipResult] = []
    for (index, clip) in clips.enumerated() {
        do {
            results.append(try await run(clip, engine: engine, padding: padding, iterator: &iterator))
        } catch {
            print("  skipped \(clip.url.lastPathComponent): \(error.localizedDescription)")
        }
        if (index + 1) % 100 == 0 { print("  \(index + 1)/\(clips.count)") }
    }
    let wall = Date().timeIntervalSince(start)

    let speechOnly = results.filter { $0.truth == .speechOnly }
    let music = results.filter { $0.truth == .music }
    let taxonomy = engine.taxonomy
    let speechEnter = policy.rule(for: taxonomy.definition(for: "speech")).enterScore
    let musicEnter = policy.rule(for: taxonomy.definition(for: "music")).enterScore
    let alertCategories: Set<String> = [SoundCategory.alerts.rawValue]

    var demand: [String: [String: Double]] = [:]
    var demandAlerts: [String: [String]] = [:]
    for result in results where result.truth == .scene {
        let hours = result.duration / 3600
        demand[result.group] = Dictionary(grouping: result.events, by: \.kind).mapValues { Double($0.count) / hours }
        demandAlerts[result.group] = result.events.filter { alertCategories.contains($0.category) }
            .map { "\($0.primaryLabel)@\(Int($0.audioStart))s peak \(String(format: "%.2f", $0.peakScore))" }
    }
    var windowAlerts: [String: Double] = [:]
    for (dataset, group) in Dictionary(grouping: results, by: \.dataset) {
        let scores = group.flatMap(\.alertScores)
        windowAlerts[dataset] = scores.isEmpty ? 0 : Double(scores.filter { $0 >= 0.5 }.count) / Double(scores.count)
    }
    var otherKinds: [String: Int] = [:]
    for event in speechOnly.flatMap(\.events) where event.kind != "speech" { otherKinds[event.kind, default: 0] += 1 }

    let summary = Summary(
        configuration: ["windowDuration": window, "overlapFactor": overlap, "hop": configuration.hop,
                        "trailingSilencePadding": padding, "gtzanHoldout": gtzanHoldout ? 1 : 0,
                        "suppressions": Double(policy.suppressions.count)],
        platform: ProcessInfo.processInfo.operatingSystemVersionString,
        date: Date.now.formatted(.iso8601),
        wallSeconds: wall,
        audioSeconds: results.reduce(0) { $0 + $1.duration },
        speechOnSpeechOnly: detection(speechOnly, kind: "speech", enter: speechEnter, scores: \.speechScores),
        musicOnGTZAN: detection(music, kind: "music", enter: musicEnter, scores: \.musicScores),
        musicPerGenre: Dictionary(grouping: music, by: \.group).mapValues { group in
            Rate(group.filter { $0.events.contains { $0.kind == "music" } }.count, group.count)
        },
        musicOnSpeechOnly: eventRate(speechOnly) { $0.kind == "music" },
        alertsOnSpeechOnly: eventRate(speechOnly) { alertCategories.contains($0.category) },
        impactsOnSpeechOnly: eventRate(speechOnly) { $0.category == SoundCategory.impacts.rawValue },
        alertsOnGTZAN: eventRate(music) { alertCategories.contains($0.category) },
        otherKindsOnSpeechOnly: otherKinds,
        demand: demand,
        demandAlerts: demandAlerts,
        windowAlertScoreAbove05: windowAlerts)

    try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let tag = "window_\(String(format: "%.1f", window))"
    try encoder.encode(summary).write(to: outDirectory.appending(path: "summary_\(tag).json"))
    encoder.outputFormatting = [.sortedKeys]
    let lines = try results.map { result -> String in
        var compact = result
        compact.speechScores = []
        compact.musicScores = []
        compact.alertScores = []
        return String(decoding: try encoder.encode(compact), as: UTF8.self)
    }
    try lines.joined(separator: "\n").write(to: outDirectory.appending(path: "clips_\(tag).jsonl"), atomically: true,
                                            encoding: .utf8)
    print(String(decoding: try JSONEncoder.pretty.encode(summary), as: UTF8.self))
    print("Wrote \(outDirectory.path) (\(Int(wall)) s wall for \(Int(summary.audioSeconds)) s of audio)")
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}

switch arguments.first {
case "labels":
    let catalog = try SoundClassifierCatalog.load()
    print(catalog.reportText(platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"))
case "evaluate":
    let window = Double(option("--window") ?? "1.5") ?? 1.5
    let out = option("--out").map { URL(fileURLWithPath: $0) }
        ?? repositoryRoot.appending(path: "results/sound_eval_window2")
    let padding = Double(option("--pad") ?? "") ?? window
    let overlap = Double(option("--overlap") ?? "0.5") ?? 0.5
    try await evaluate(window: window, overlap: overlap, padding: padding, libri: Int(option("--libri") ?? "500") ?? 500,
                       gtzan: Int(option("--gtzan") ?? "300") ?? 300,
                       gtzanHoldout: arguments.contains("--gtzan-holdout"), outDirectory: out)
default:
    print("usage: hs-sound-eval labels | evaluate [--window 1.5] [--overlap 0.5] [--pad S] [--libri 500] [--gtzan 300] [--gtzan-holdout] [--no-suppressions] [--out DIR]")
}
