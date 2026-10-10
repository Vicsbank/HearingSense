// hs-speech-eval gate-data — per-window classifier scores and transcript statistics for
// designing and checking the speech relevance gate (speech vs. music with vocals).
//
// Forward-only. Writes one JSON line per clip. The dump holds scores, counts and confidences;
// transcript text is not stored (music transcripts are song lyrics).
//
// Clip layouts:
// - music: a GTZAN clip as is (30 s). Songs with vocals are included; "speech" on them is
//   usually singing, not conversation.
// - speech: a LibriSpeech utterance as is.
// - bed N dB: music plays for `lead` seconds, then the utterance is added on top of the music at
//   N dB speech-to-music ratio, then `tail` seconds of music. This is the "someone talks while
//   music is playing nearby" case, with the music context established before the speech.
// - noise N dB: an utterance mixed with DEMAND cafeteria noise from t = 0.
//
// Splits: `design` (rules were chosen on it) and `holdout` (disjoint clips, used only to check).
import AVFAudio
import Foundation
import HearingSenseDomain
import SoundEventDetection
import SpeechIntelligence
import SpeechPipeline

struct GateFrame: Codable {
    var start: Double
    var end: Double
    var speech: Double
    var music: Double
    /// Best score among the vocal-music labels (singing, choir_singing, rapping, humming, yodeling).
    var vocal: Double
    /// The `music` label itself.
    var musicLabel: Double
    var top: [String]
    var topScores: [Double]
}

/// One final recognizer result: timing, size and confidence, no text.
struct GateSegment: Codable {
    var start: Double
    var end: Double
    var words: Int
    var confidence: Double?
    var minimumConfidence: Double?
}

struct GateClip: Codable {
    var split: String
    var condition: String
    var id: String
    var group: String
    var duration: Double
    var speechStart: Double?
    var speechEnd: Double?
    var frames: [GateFrame]
    var confirmedSpeechAt: Double?
    var transcribed: Bool
    var words: Int
    var meanConfidence: Double?
    var referenceWords: Int?
    var wordErrors: Int?
    var segments: [GateSegment] = []
}

/// GTZAN clips of the Window 2 standard subset (`design`) or clips disjoint from it (`holdout`).
func gtzanSplit(holdout: Bool, perGenre: Int = 30) -> [URL] {
    let root = dataRoot.appending(path: "gtzan/genres")
    let genres = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    return genres.flatMap { genre -> [URL] in
        let all = files(under: root.appending(path: genre), extension: "wav")
        let standard = evenSubset(all, count: perGenre)
        guard holdout else { return standard }
        let used = Set(standard)
        return evenSubset(all.filter { !used.contains($0) }, count: perGenre)
    }
}

/// LibriSpeech utterances: `design` = the evenly spaced subset used elsewhere, `holdout` =
/// evenly spaced utterances that are not in it.
func libriSplit(holdout: Bool, count: Int) -> [Utterance] {
    let all = libriSpeech()
    let design = evenSubset(all, count: 500)
    guard holdout else { return evenSubset(design, count: count) }
    let used = Set(design.map(\.id))
    return evenSubset(all.filter { !used.contains($0.id) }, count: count)
}

/// Music for `lead` seconds, then speech over music at `snrDB`, then `tail` seconds of music.
func speechOverMusicBed(_ speech: Audio, music: Audio, snrDB: Double, lead: Double, tail: Double, offset: Int) -> Audio {
    let bed = resample(music, to: speech.sampleRate).samples
    guard !bed.isEmpty else { return speech }
    let leadFrames = Int(lead * speech.sampleRate), tailFrames = Int(tail * speech.sampleRate)
    let total = leadFrames + speech.samples.count + tailFrames
    var mixed = (0 ..< total).map { bed[(offset + $0) % bed.count] }
    let span = leadFrames ..< leadFrames + speech.samples.count
    let speechLevel = rms(speech.samples[...]), musicLevel = rms(mixed[span])
    guard speechLevel > 0, musicLevel > 0 else { return speech }
    // Keep the music as recorded and scale the speech: a nearby talker is louder or quieter
    // relative to the music that is already playing.
    let gain = musicLevel * Float(pow(10, snrDB / 20)) / speechLevel
    for index in speech.samples.indices { mixed[leadFrames + index] += speech.samples[index] * gain }
    let peak = mixed.map(abs).max() ?? 0
    if peak > 0.98 { mixed = mixed.map { $0 * 0.98 / peak } }
    return Audio(samples: mixed, sampleRate: speech.sampleRate)
}

func runGateData(_ arguments: Arguments) async throws {
    let output = URL(fileURLWithPath: arguments.string("--out", defaultOutput.appending(path: "gate_frames.jsonl").path))
    let musicPerGenre = arguments.int("--music-per-genre", 30)
    let speechCount = arguments.int("--speech", 200)
    let bedCount = arguments.int("--bed", 100)
    let transcribeMusicEvery = max(arguments.int("--transcribe-music-every", 1), 1)
    let lead = arguments.double("--lead", 5), tail = arguments.double("--tail", 3)
    let splits = arguments.string("--splits", "design,holdout").split(separator: ",").map(String.init)

    let taxonomy = SoundTaxonomy.appleV1
    let vocalLabels: Set<SoundLabel> = ["singing", "choir_singing", "rapping", "humming", "yodeling"]
    let speechLabels = Set(taxonomy.definitions.filter { ["speech", "shouting"].contains($0.kind.id) }.flatMap(\.labels))
    let musicLabels = Set(taxonomy.definitions.filter { $0.kind.id == "music" }.flatMap(\.labels))

    let engine = SoundRecognitionEngine(configuration: ClassifierConfiguration(windowDuration: 1.5, overlapFactor: 0.5,
                                                                               backlogLimit: nil))
    var iterator = engine.outputs.makeAsyncIterator()
    let transcriber = AppleSpeechTranscriber()
    let canTranscribe = await transcriber.availability() == .available
    if canTranscribe { await transcriber.prepare() }

    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let encoder = JSONEncoder()
    var written = 0

    func record(split: String, condition: String, id: String, group: String, audio: Audio, speechSpan: (Double, Double)?,
                reference: String?, transcribe: Bool) async throws
    {
        let (frames, confirmed) = await classify(audio, padding: 1.5, engine: engine, iterator: &iterator)
        let gateFrames = frames.map { frame -> GateFrame in
            func best(_ labels: Set<SoundLabel>) -> Double {
                frame.predictions.filter { labels.contains($0.label) }.map(\.score.rawValue).max() ?? 0
            }
            let top = frame.predictions.prefix(6)
            return GateFrame(start: frame.audioTime.start, end: frame.audioTime.end, speech: best(speechLabels),
                             music: best(musicLabels), vocal: best(vocalLabels), musicLabel: best(["music"]),
                             top: top.map(\.label.rawValue), topScores: top.map(\.score.rawValue))
        }
        var clip = GateClip(split: split, condition: condition, id: id, group: group, duration: audio.duration,
                            speechStart: speechSpan?.0, speechEnd: speechSpan?.1, frames: gateFrames,
                            confirmedSpeechAt: confirmed, transcribed: false, words: 0, meanConfidence: nil,
                            referenceWords: nil, wordErrors: nil)
        if transcribe, canTranscribe {
            let transcript = await transcribeDirectly(audio, with: transcriber)
            let hypothesis = scoringWords(transcript.text)
            clip.transcribed = true
            clip.words = hypothesis.count
            clip.meanConfidence = transcript.meanConfidence
            clip.segments = transcript.segments.map {
                GateSegment(start: $0.audioTime.start, end: $0.audioTime.end, words: TranscriptText.words(in: $0.text).count,
                            confidence: $0.meanConfidence, minimumConfidence: $0.minimumConfidence)
            }
            if let reference {
                let words = scoringWords(reference)
                clip.referenceWords = words.count
                clip.wordErrors = wordErrors(reference: words, hypothesis: hypothesis)
            }
        }
        try handle.write(contentsOf: encoder.encode(clip) + Data("\n".utf8))
        written += 1
        if written % 100 == 0 { print("  \(written) clips") }
    }

    for split in splits {
        let holdout = split == "holdout"
        let music = gtzanSplit(holdout: holdout, perGenre: musicPerGenre)
        let speech = libriSplit(holdout: holdout, count: speechCount)
        print("\(split): \(music.count) music clips, \(speech.count) utterances")
        var musicAudio: [Audio] = []
        for (index, url) in music.enumerated() {
            // GTZAN contains one file that cannot be decoded (jazz.00054.wav); skip unreadable clips.
            guard let audio = try? loadAudio(url) else {
                print("  skipped unreadable \(url.lastPathComponent)")
                continue
            }
            musicAudio.append(audio)
            try await record(split: split, condition: "music", id: url.lastPathComponent,
                             group: url.deletingLastPathComponent().lastPathComponent, audio: audio, speechSpan: nil,
                             reference: nil, transcribe: index % transcribeMusicEvery == 0)
        }
        var speechAudio: [(Utterance, Audio)] = []
        for utterance in speech {
            let audio = try loadAudio(utterance.url)
            speechAudio.append((utterance, audio))
            try await record(split: split, condition: "speech", id: utterance.id, group: "clean", audio: audio,
                             speechSpan: (0, audio.duration), reference: utterance.reference, transcribe: true)
        }
        // Speech over a music bed. Utterances up to 15 s so that lead + speech + tail fits a 30 s song.
        let short = Array(speechAudio.filter { $0.1.duration <= 15 }.prefix(bedCount))
        for level in [10.0, 5.0, 0.0] {
            for (index, item) in short.enumerated() {
                let song = (index * 7 + Int(level)) % max(musicAudio.count, 1)
                let mixed = speechOverMusicBed(item.1, music: musicAudio[song], snrDB: level, lead: lead, tail: tail,
                                               offset: index * 7_919)
                try await record(split: split, condition: "bed\(Int(level))", id: item.0.id, group: "music-bed", audio: mixed,
                                 speechSpan: (lead, lead + item.1.duration), reference: item.0.reference, transcribe: true)
            }
        }
        if !holdout, let cafeteria = try? loadAudio(dataRoot.appending(path: "noise/demand/PCAFETER/PCAFETER/ch01.wav")) {
            for level in [10.0, 0.0] {
                for (index, item) in speechAudio.prefix(bedCount).enumerated() {
                    let mixed = mix(item.1, with: cafeteria, snrDB: level, offset: index * 7_919)
                    try await record(split: split, condition: "cafeteria\(Int(level))", id: item.0.id, group: "cafeteria",
                                     audio: mixed, speechSpan: (0, item.1.duration), reference: item.0.reference,
                                     transcribe: false)
                }
            }
        }
    }
    await transcriber.releaseResources()
    print("wrote \(written) clips to \(output.path)")
}

// MARK: - Relevance gate evaluation on a dump

struct RelevanceCondition: Codable {
    var split: String
    var condition: String
    var policy: String
    var clips: Int
    /// Stage A: clips in which speech activity started at all / share of classifier windows active.
    var clipsActivated: Int
    var activeWindowShare: Double
    /// Clips with speech: activity covered the speech (started no later than 1.5 s after it ended).
    var speechCovered: Int?
    var medianActivationDelay: Double?
    /// Recognizer segments that fall inside speech activity (what the app would transcribe).
    var segmentsTranscribed: Int
    /// Of those: sent to the language model (not judged "possibly music").
    var segmentsInterpreted: Int
    var segmentsHeldAsMusic: Int
    var wordsInterpretedPerMinute: Double
    /// Clips with at least one segment sent to the language model.
    var clipsInterpreted: Int
    /// The same count per clip group (music genre).
    var clipsInterpretedByGroup: [String: Int]
    /// Speech-over-music clips only: segments mostly inside the spoken part.
    var speechSegments: Int?
    var speechSegmentsInterpreted: Int?
    var speechWordsInterpretedShare: Double?
    /// Speech-over-music clips only: segments in the music-only lead and tail.
    var lyricSegments: Int?
    var lyricSegmentsInterpreted: Int?
}

struct RelevanceSummary: Codable {
    var environment: String
    var activationPolicy: String
    var relevancePolicy: String
    var conditions: [RelevanceCondition]
    var note: String
}

/// Applies the production `SpeechActivityTracker` (stage A) and `SpeechRelevanceGate` (stage B)
/// to the classifier scores and recognizer segments stored by `gate-data`.
func runRelevance(_ arguments: Arguments) async throws {
    let scratch = arguments.string("--dump", "")
    guard !scratch.isEmpty else { return print("usage: hs-speech-eval relevance --dump FILE[,FILE…]") }
    var clips: [GateClip] = []
    let decoder = JSONDecoder()
    for path in scratch.split(separator: ",") {
        let text = try String(contentsOfFile: String(path), encoding: .utf8)
        for line in text.split(separator: "\n") {
            if let clip = try? decoder.decode(GateClip.self, from: Data(line.utf8)) { clips.append(clip) }
        }
    }
    print("\(clips.count) clips")

    // The pipeline before the relevance gate: speech ≥ 0.5 in a window with music, no stage B.
    var previous = SpeechActivationPolicy()
    previous.strongSpeechScore = 0.5
    previous.speechScoreOverMusic = 0.5
    previous.maximumVocalScoreOverMusic = 1
    previous.musicContextMinimum = .max

    /// The stored scores as a classifier window. The tracker only uses the best score per label
    /// group, so one label per group reproduces its decision exactly.
    func frame(_ stored: GateFrame, index: Int) -> ClassificationFrame {
        let range = AudioTimeRange(start: stored.start, end: stored.end)
        let date = Date(timeIntervalSince1970: stored.end)
        let scores: [(SoundLabel, Double)] = [("speech", stored.speech), ("music", stored.music), ("singing", stored.vocal)]
        return ClassificationFrame(
            sequence: index, audioTime: range, producedAt: date, capturedAt: date, model: .appleSoundClassifierV1,
            predictions: scores.filter { $0.1 > 0 }.map {
                RawSoundPrediction(label: $0.0, score: ClassifierScore($0.1), audioTime: range, producedAt: date,
                                   model: .appleSoundClassifierV1)
            },
            inputLevel: nil)
    }

    func evaluate(_ group: [GateClip], split: String, condition: String, policyName: String,
                  activation: SpeechActivationPolicy, usesStageB: Bool) -> RelevanceCondition
    {
        var activated = 0, windows = 0, activeWindows = 0, covered = 0, delays: [Double] = []
        var transcribed = 0, interpreted = 0, held = 0, wordsInterpreted = 0, clipsInterpreted = 0, minutes = 0.0
        var speechSegments = 0, speechInterpreted = 0, speechWords = 0, speechWordsInterpreted = 0
        var lyricSegments = 0, lyricInterpreted = 0
        var interpretedByGroup: [String: Int] = [:]
        let hasSpeech = group.contains { $0.speechStart != nil }
        let isBed = condition.hasPrefix("bed")
        for clip in group {
            var tracker = SpeechActivityTracker(policy: activation)
            var gate = SpeechRelevanceGate()
            // Speech activity spans in audio time: from the lead-in before the first qualifying
            // window to the release.
            var spans: [(start: Double, end: Double, begin: Double)] = []
            for (index, stored) in clip.frames.enumerated() {
                let window = frame(stored, index: index)
                switch tracker.process(window) {
                case .began(let onset):
                    spans.append((onset - activation.leadIn, .infinity, window.audioTime.end))
                case .ended(let time):
                    spans[spans.count - 1].end = time
                case nil:
                    break
                }
                gate.record(window, evidence: tracker.lastEvidence)
                windows += 1
                activeWindows += tracker.isActive ? 1 : 0
            }
            activated += spans.isEmpty ? 0 : 1
            minutes += clip.duration / 60
            if let start = clip.speechStart, let end = clip.speechEnd {
                if let first = spans.first(where: { $0.begin <= end + 1.5 && $0.end > start }) {
                    covered += 1
                    delays.append(max(first.begin - start, 0))
                }
            }
            var clipInterpreted = false
            for segment in clip.segments where segment.words > 0 {
                let duration = max(segment.end - segment.start, 1e-6)
                let inside = spans.map { max(min($0.end, segment.end) - max($0.start, segment.start), 0) }.max() ?? 0
                guard inside / duration >= 0.5 else { continue }
                transcribed += 1
                let range = AudioTimeRange(start: segment.start, end: segment.end)
                let relevance = usesStageB ? gate.assess(range, meanConfidence: segment.confidence)?.relevance : nil
                let isInterpreted = relevance != .possiblyMusic
                interpreted += isInterpreted ? 1 : 0
                held += isInterpreted ? 0 : 1
                wordsInterpreted += isInterpreted ? segment.words : 0
                clipInterpreted = clipInterpreted || isInterpreted
                if isBed, let start = clip.speechStart, let end = clip.speechEnd {
                    let spoken = max(min(end, segment.end) - max(start, segment.start), 0) / duration
                    if spoken >= 0.6 {
                        speechSegments += 1
                        speechWords += segment.words
                        speechInterpreted += isInterpreted ? 1 : 0
                        speechWordsInterpreted += isInterpreted ? segment.words : 0
                    } else if spoken <= 0.1 {
                        lyricSegments += 1
                        lyricInterpreted += isInterpreted ? 1 : 0
                    }
                }
            }
            clipsInterpreted += clipInterpreted ? 1 : 0
            if clipInterpreted { interpretedByGroup[clip.group, default: 0] += 1 }
        }
        return RelevanceCondition(
            split: split, condition: condition, policy: policyName, clips: group.count, clipsActivated: activated,
            activeWindowShare: Double(activeWindows) / Double(max(windows, 1)),
            speechCovered: hasSpeech ? covered : nil, medianActivationDelay: hasSpeech ? Distribution(delays).median : nil,
            segmentsTranscribed: transcribed, segmentsInterpreted: interpreted, segmentsHeldAsMusic: held,
            wordsInterpretedPerMinute: Double(wordsInterpreted) / max(minutes, 1e-9), clipsInterpreted: clipsInterpreted,
            clipsInterpretedByGroup: interpretedByGroup,
            speechSegments: isBed ? speechSegments : nil, speechSegmentsInterpreted: isBed ? speechInterpreted : nil,
            speechWordsInterpretedShare: isBed ? Double(speechWordsInterpreted) / Double(max(speechWords, 1)) : nil,
            lyricSegments: isBed ? lyricSegments : nil, lyricSegmentsInterpreted: isBed ? lyricInterpreted : nil)
    }

    var conditions: [RelevanceCondition] = []
    for split in ["design", "holdout"] {
        for condition in ["music", "speech", "bed10", "bed5", "bed0", "cafeteria10", "cafeteria0"] {
            let group = clips.filter { $0.split == split && $0.condition == condition }
            guard !group.isEmpty else { continue }
            for (name, policy, stageB) in [("before", previous, false), ("gate", SpeechActivationPolicy.standard, true)] {
                let result = evaluate(group, split: split, condition: condition, policyName: name, activation: policy,
                                      usesStageB: stageB)
                conditions.append(result)
                var line = String(format: "%-8@ %-12@ %-6@ activated %3d/%3d  active windows %5.1f %%  transcribed %4d  → model %4d  held %4d  clips → model %3d  %5.1f words/min",
                                  split as NSString, condition as NSString, name as NSString, result.clipsActivated, result.clips,
                                  result.activeWindowShare * 100, result.segmentsTranscribed, result.segmentsInterpreted,
                                  result.segmentsHeldAsMusic, result.clipsInterpreted, result.wordsInterpretedPerMinute)
                if let covered = result.speechCovered {
                    line += String(format: "  speech covered %d (delay %.2f s)", covered, result.medianActivationDelay ?? 0)
                }
                if let spoken = result.speechSegments, let kept = result.speechSegmentsInterpreted,
                   let lyrics = result.lyricSegments, let lyricsKept = result.lyricSegmentsInterpreted
                {
                    line += String(format: "  spoken segments → model %d/%d (%.0f %% of words)  lyric segments → model %d/%d",
                                   kept, spoken, (result.speechWordsInterpretedShare ?? 0) * 100, lyricsKept, lyrics)
                }
                print(line)
                if condition == "music", name == "gate" {
                    print("           by genre: " + result.clipsInterpretedByGroup.sorted { $0.key < $1.key }
                        .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                }
            }
        }
    }
    let activation = SpeechActivationPolicy.standard, relevance = SpeechRelevancePolicy.standard
    try write(RelevanceSummary(
        environment: environmentDescription(),
        activationPolicy: "stage A: no music context → speech ≥ \(activation.candidateScore); music context (music ≥ "
            + "\(activation.musicPresentScore) now or in ≥ \(activation.musicContextMinimum) of the last "
            + "\(activation.musicContextWindows) windows) → speech ≥ \(activation.strongSpeechScore), or speech ≥ "
            + "\(activation.speechScoreOverMusic) with vocal-music score ≤ \(activation.maximumVocalScoreOverMusic)",
        relevancePolicy: "stage B: music in < \(relevance.musicContextShare) of the utterance's windows → nearby speech; "
            + "otherwise speech over music if ≥ \(relevance.minimumStrongShare) of windows have speech ≥ "
            + "\(relevance.strongSpeechScore) and confidence ≥ \(relevance.minimumConfidence), or ≥ "
            + "\(relevance.minimumClearShare) have speech ≥ \(relevance.clearSpeechScore) and confidence ≥ "
            + "\(relevance.minimumConfidenceForClearShare); otherwise possibly music (not interpreted)",
        conditions: conditions,
        note: "'before' = the pipeline before the relevance gate (speech ≥ 0.5 when music is in the window, every "
            + "utterance interpreted). Thresholds were chosen on the design split; the holdout split has disjoint songs "
            + "and utterances. Recognizer segments come from transcribing each whole clip, so segment boundaries can "
            + "differ from the live pipeline's. 'music' is GTZAN (many songs with vocals): an activation there is a "
            + "song, not a conversation, whatever the classifier calls it. bedN = LibriSpeech speech added to a song at "
            + "N dB speech-to-music ratio after 5 s of music."),
        to: "relevance_gate.json", directory: defaultOutput)
}
