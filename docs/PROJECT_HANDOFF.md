# Project Handoff — Hearing Sense iOS 2.0

Last updated: 2026-10-09, end of **Window 3** (On-Device Speech Intelligence and Apple Foundation Models).
Window 3 status: **code complete; verified on the Mac (unit tests, real recognizer and language
model on files), on the iPhone 18 Pro Simulator (unit tests, app build, level-1 live check) and,
after the student authorized it on 2026-10-09, on the physical iPhone 18 Pro with the screen on
(live transcript and validated summary ≈ 2 s after the speech).** Two defects found on the device
were fixed. **Open problem found on the device: with the screen locked or the app in the
background Apple's built-in sound classifier fails, so neither sounds nor speech are recognized
there** (§8, first row; `docs/testing/WINDOW3_TEST_RESULTS.md` §10.6). Window 2's device tests
(`docs/testing/WINDOW2_DEVICE_TESTS.md`) are still open.
Next window: **Window 4 — Attention Priority Engine** (not started; do not start it without the
student's instruction).

Git: `main` = reconstructed Window 1 baseline (`7905f0b`, `679494e`); Window 2 on
`feature/window2-sound-analysis` (`6f41d90`); Window 3 on `feature/window3-speech-intelligence`,
branched from the Window 2 branch. Nothing is merged or pushed; there is no remote. Merging is the
student's decision.

**Research window (2026-10-10), branch `experiment/background-acoustic-recognition`** (from the
Window 3 branch): background sound recognition. Mac work complete and committed; **no
physical-iPhone test of this window has been run** (approved by the student "for later"; the
phone was not connected). Read `docs/BACKGROUND_RECOGNITION_DECISION.md` first, then
`docs/testing/BACKGROUND_DEVICE_TESTS.md` (the next thing to do), `docs/research/
BACKGROUND_INFERENCE_INVESTIGATION.md`, `AUDIO_MODEL_COMPARISON.md`, `BACKGROUND_MODEL_BENCHMARK.md`.
Summary: Apple's classifier is still the default and still fails in the background; a CPU-only
Core ML backend (YAMNet / EfficientAT) and a hybrid switching backend exist behind
`AcousticClassifierBackend` and are selectable in Debug builds with `--hs-classifier`; on recorded
files Apple is the most accurate at 1–2 s, EfficientAT MN10 needs a 2 s window repeated into its
10 s input to work at all on short audio and then matches Apple on alert events. Provisional
decision: hybrid. Third-party models and ESC-50 are downloaded under `models/third_party/` and
`data/esc50/` (not committed); regenerate the Core ML models with
`tools/experiments/audio_models/convert_coreml.py` and copy them into the app with
`install_app_models.sh` before building. Tests: `swift test` 191 (190 passed, 1 opt-in skipped).
Do not start Window 4 before the device tests unless the student says so.

**Research window, second session (2026-10-10): first device runs** — A1, A2 and a short CPU-only
run, once each, on the iPhone 18 Pro (`docs/testing/BACKGROUND_DEVICE_TESTS.md` §7, raw
diagnostics in `results/device_background/`; documentation and result files only, no code change,
not committed at the time of writing). Results: (1) with `UIBackgroundModes = audio` the built-in
classifier fails in the background and when locked, as in Window 3; (2) **with `audio` +
`processing` (experiment build, `INFOPLIST_FILE=Config/Experiments/HearingSense-Info-processing.plist`)
it kept running in both — 342 of ≈ 342 windows in 256 s — and recognized a dog bark, a siren and a
knock played while the phone was locked**; (3) the CPU-only EfficientAT MN10 keeps running when
locked (32.8 ms per window) but labelled 0 of 6 played clips correctly; (4) the probe could not
test the GPU hypothesis, because the iPhone places the probe model on the CPU under every compute
unit setting. One run per configuration, on USB and charging: **not replicated, no 10-minute run
(A3), no battery data.** The shipping Info.plist is unchanged (`audio` only) and
`docs/BACKGROUND_RECOGNITION_DECISION.md` (hybrid with MN10) predates these runs; whether to adopt
the Background-processing mode instead is the student's decision. Next: §7.7 of the device test
document (repeat A1 → A2, then A3), each needing the student's microphone authorization. The
iPhone was driven with iphone-use (approved by the student; rules in the session memory) and
`devicectl`. The app's "Transcribe nearby speech" switch persists between launches and was found
on: check that it is off before any run that is meant to be without transcription.

Each Claude Code window starts without memory of earlier windows. Read this file first, then the
files listed in §11. Update this file at the end of every window.

---

## 1. Objective

Hearing Sense iOS 2.0 — *Intelligent Environmental Awareness*: an iPhone app that keeps people who
wear noise-cancelling headphones (AirPods) aware of their surroundings. While the user plays
Spotify / Apple Music, the app listens through the iPhone microphone, recognizes sound events with
Apple's Sound Analysis, transcribes and summarizes relevant speech on device (Speech, Foundation
Models), ranks events with a deterministic Attention Priority Engine, and shows what matters in the
app, a Live Activity and the Dynamic Island. Everything runs on the iPhone; no remote AI inference.
It is an awareness aid, not a safety or emergency system.

## 2. Hard constraints

- **No model training or fine-tuning** (including resuming, pilot runs, background or scheduled
  training) without a separate approval request: model + dataset, M1 Max best/conservative time
  estimates, resources, expected benefit, checkpoint/recovery plan, and the student's maximum
  allowed time. Forward-only inference, evaluation and model inspection are allowed.
- The Mac (M1 Max, 32 GB) is the student's daily school computer: no long or background workloads
  without approval; large downloads need approval with sizes shown.
- Do not delete, move or overwrite research assets (`models/`, `results/`, `data/`, `docs/` reports,
  `ml/`, `src/`, `tools/`). See `docs/EXISTING_PROJECT_AUDIT.md` §8.
- Do not fabricate results. Label evidence as Mac / Simulator / physical iPhone; never claim device
  validation from the Simulator.
- Apple-native frameworks first; no new third-party dependencies without a reason.
- Privacy: no audio persistence or upload; transcripts opt-in and minimal; diagnostics carry metadata only.
- (W3) **No microphone recording or transcription of real conversations without the student's
  authorization.** The Mac/Simulator microphone picks up real speech in the student's room; sound
  classification there was done before, transcription was deliberately not attempted.
- (W3) Physical-iPhone tests stay pending until the student explicitly authorizes them.
- Communicate with the student in Chinese; code, comments and docs in English.

## 3. Existing codebase (before iOS 2.0)

Music genre/emotion research, preserved unchanged (details: `docs/EXISTING_PROJECT_AUDIT.md`):

- Legacy science-fair models (trained in the original Windows phase): EfficientNet-B0 emotion
  (9 GEMS, Emotify) and CNN+GRU genre (10 GTZAN), FastAPI web app — `src/`, `models/*.pth`.
- macOS phase (2026-10-09, **evaluation and conversion only — no training**): Essentia pretrained
  models converted to `models/coreml/HearingSenseMusic.mlpackage` (16 kHz, 4.992 s window, CC BY-NC-SA),
  evaluation round 1 (`docs/evaluation_results.md`, `results/eval/`), forward-only ML tests (12/12 pass).
- `app/`: an abandoned macOS Swift package scaffold that does not build.

## 4. Completed in Window 1

1. Audit of the repository and the macOS phase → `docs/EXISTING_PROJECT_AUDIT.md`.
2. Architecture and decision log → `docs/IOS_ARCHITECTURE.md`.
3. Audio routing analysis with device results → `docs/AUDIO_ROUTING_FEASIBILITY.md`.
4. Roadmap for Windows 2–6 → `docs/IOS_DEVELOPMENT_ROADMAP.md`.
5. `packages/HearingSenseKit` — module `HearingSenseAudio` (capture, levels, session policies, route
   snapshots/assessment, session events, diagnostic log, throughput) + 26 tests.
6. `apps/ios/HearingSense.xcodeproj` — SwiftUI app: branding, Start/Stop, permission handling,
   status card with “MIC ON”, real level meter + 10 s history, route summary, policy picker,
   route diagnostics (share report), event log, interruption/route-change/media-reset handling,
   background-coverage measurement, `UIBackgroundModes = audio`, placeholder app icon.
7. Apple SoundAnalysis label list enumerated via the real API on macOS →
   `docs/research/sound_analysis_labels_v1_macos27.txt` (303 labels).
8. Physical-device tests on iPhone 18 Pro + AirPods Pro + Spotify (§7), screenshots in
   `docs/device-tests/2026-10-09/`.
9. `.gitignore` extended (Xcode/SwiftPM user state); `README.md` gained a repository overview.

## 4b. Completed in Window 2

1. `HearingSenseDomain` (Foundation only): `SoundLabel`, `ClassifierScore`, `AudioTimeRange`,
   `RawSoundPrediction`, `ClassificationFrame`, `SoundCategory` (11), `SoundEventKind`,
   `AcousticEventCandidate`, `ConfirmedAcousticEvent`, `AcousticEventUpdate`, `EnvironmentStatus`.
2. `SoundEventDetection`: `SoundRecognitionEngine` (real-time `SNAudioStreamAnalyzer` consumer of
   `MicrophoneCapture`), `SoundTaxonomy.appleV1` (303 labels → 50 kinds → 11 categories),
   `DetectionPolicy.standard` + `SoundEventDetector` (thresholds, k-of-n, instant confirm,
   hysteresis, timeouts, foghorn-vs-music suppression), `SoundClassifierCatalog`, diagnostics.
3. `hs-sound-eval` (macOS): forward-only evaluation of the production engine on local files;
   results in `results/sound_eval_window2/`.
4. App: `RecognitionController`, recognition card (status, current sound, category, score, top-3 raw
   labels, input level, result delay, candidates), recent events, event history, recognition
   diagnostics (pipeline timings, drops, detector counters, CPU/memory/thermal, window picker,
   stall experiment, share report), classifier-label screen (per-device inventory + share).
5. `AudioSessionController`: skips redundant session calls, logs step timings; opt-in "keep session
   active when stopped" experiment (default off).
6. Docs: `WINDOW2_SOUND_ANALYSIS_REPORT.md`, `research/IOS_SOUND_CLASSIFICATIONS.md`,
   `research/SOUND_CATEGORY_MAPPING.md`, `research/sound_analysis_labels_v1_macos27_mapped.tsv`,
   `testing/WINDOW2_DEVICE_TESTS.md`, Simulator screenshots in `device-tests/window2-simulator/`;
   architecture, roadmap, routing feasibility updated.
7. Git initialized; `.gitignore` excludes all dataset content and per-clip evaluation dumps.

## 4c. Completed in Window 3

Full report: `docs/WINDOW3_SPEECH_INTELLIGENCE_REPORT.md`; architecture:
`docs/research/SPEECH_INTELLIGENCE_ARCHITECTURE.md`; numbers and methods:
`docs/testing/WINDOW3_TEST_RESULTS.md`.

1. `HearingSenseDomain`: `SpeechSemanticResult` and its parts (speech event id, state, output level,
   category, transcript + recognition quality, summary + reliability, details, acoustic context /
   speech relevance, latency, model availability).
2. `HearingSenseAudio`: `AudioStreamClock` (moved from SoundEventDetection; shared time base).
3. `SpeechPipeline`: `PreRollAudioBuffer` (5 s ring), `SpeechAudioTap`, `AppleSpeechTranscriber`
   (`SpeechAnalyzer` + `SpeechTranscriber`, one analyzer per utterance), `TranscriptAssembler`.
4. `SemanticSummary`: `FoundationModelInterpreter` (`SystemLanguageModel.default`, guided
   generation), `SpeechSemanticAnalyzer`, `SummaryValidator`, `UtteranceAnalysis`, `RuleBasedInterpreter`.
5. `SpeechIntelligence`: `SpeechIntelligenceEngine` (serial command queue), `SpeechActivityTracker`
   (speech candidates, music context), `SpeechRelevanceGate` (speech / speech over music / possibly
   music), configuration, diagnostics.
6. `hs-speech-eval` (macOS): forward-only evaluation; summaries in `results/speech_eval_window3/`.
7. App: `Speech/SpeechIntelligenceController`, `Views/SpeechIntelligenceViews` (card + diagnostics);
   `ListeningController` attaches the speech tap and session calls; `RecognitionController` forwards
   classifier windows and events; `NSSpeechRecognitionUsageDescription` added.
8. Tests: 103 new package tests (pre-roll buffer, assembler, validator, analyzer, tracker, relevance
   gate, engine with scripted recognizer/model, real recognizer on synthetic speech).
9. Tools/data: `tools/make_speech_test_signals.sh` + `tools/speech_test_sentences.tsv` (20 synthetic
   sentences in `data/test_signals/window3/`, not committed).

## 5. Repository structure (current)

```
apps/ios/                      iOS app (Xcode 27 project, synchronized folders)
  HearingSense/HearingSenseApp.swift   @main entry point
  HearingSense/Listening/      ListeningController (orchestrator), ListeningState, DeviceInfo
  HearingSense/Recognition/    RecognitionController (W2: engine outputs → UI state; W3: forwards to speech)
  HearingSense/Speech/         SpeechIntelligenceController (W3: speech engine outputs → UI state, privacy)
  HearingSense/Views/          ContentView, StatusCard, LevelMeterView, RouteDiagnosticsView, DiagnosticLogView,
                               RecognitionViews (W2), SpeechIntelligenceViews (W3)
  HearingSense/Assets.xcassets AppIcon (placeholder), AccentColor
  Config/HearingSense-Info.plist  UIBackgroundModes=audio (other Info keys are build settings)
packages/HearingSenseKit/      Swift package (iOS 26, macOS 26): Sources/{HearingSenseAudio, HearingSenseDomain,
                               SoundEventDetection, SoundEvaluationTool, SpeechPipeline, SemanticSummary,
                               SpeechIntelligence, SpeechEvaluationTool}, Tests/{HearingSenseAudioTests,
                               SoundEventDetectionTests, SpeechPipelineTests, SemanticSummaryTests,
                               SpeechIntelligenceTests}
docs/                          this handoff, architecture, audit, feasibility, roadmap, WINDOW2 and WINDOW3 reports,
                               device-tests/, research/, testing/
results/sound_eval_window2/    W2 offline evaluation summaries (JSON)
results/speech_eval_window3/   W3 evaluation summaries (JSON; no music transcripts)
tools/                         + make_speech_test_signals.sh, speech_test_sentences.tsv (W3)
src/ ml/ tools/ models/ results/ data/ app/   legacy & research assets (unchanged)
```

## 6. Main technical decisions

Full list: `docs/IOS_ARCHITECTURE.md` §9. Most important:

- Session policy (verified on device): `playAndRecord`, mode `default`, options `mixWithOthers`,
  `allowBluetoothA2DP`, `defaultToSpeaker`; preferred input = built-in mic; no HFP, no ducking.
- Deployment target iOS 26.0, iPhone only, Swift 6 (app default MainActor, package nonisolated).
- Extension seam: `AudioStreamConsumer` on `MicrophoneCapture` (audio thread, return fast).
- Attention decisions deterministic; Foundation Models only for summaries, with fallback; never
  `PrivateCloudComputeLanguageModel`.
- Xcode file-system-synchronized groups: add Swift files to folders; no `project.pbxproj` edits needed
  (new *package products* still need entries — Window 2 added HearingSenseDomain and SoundEventDetection).
- (W2) Sound pipeline: tap copies channel 0 → actor on a serial `DispatchSerialQueue` owns the
  analyzer (FIFO via `queue.async` + `assumeIsolated`); never blocks the tap; bounded backlog with
  counted drops. Classifier window **1.5 s, overlap 0.5** (result every 0.75 s).
- (W2) Three levels: raw label → kind/category → confirmed event. Consumers act only on
  `ConfirmedAcousticEvent`. All thresholds live in `DetectionPolicy.standard` (provisional).
- (W2) Detector is deterministic (frame timestamps only); test with scripted frames
  (`Tests/SoundEventDetectionTests/FrameScript.swift`).
- (W3) The speech pipeline is a second consumer of the same microphone tap (no second capture
  session) and uses the same `AudioStreamClock`, so classifier windows address buffered audio.
- (W3) Transcription starts on speech *candidates* (one window ≥ 0.30) from a 5 s pre-roll buffer;
  measured on 30 short human utterances: first word kept 29/30 with the buffer, 1/30 without.
- (W3) One `SpeechAnalyzer` per utterance with a contiguous timeline from 0. Do **not** reuse an
  analyzer across a gap or after a mid-stream `finalize` (corrupt results, measured). Use
  `finalizeAndFinishThroughEndOfInput()`; `finalize(through: time)` hung in a probe.
- (W3) **The iOS Simulator has no `SpeechTranscriber`** (`isAvailable == false`); Foundation Models
  works there. Verify transcription on the Mac (`swift test`, `hs-speech-eval`) or on the iPhone.
- (W3) A model headline is shown only after deterministic validation; otherwise the result stays at
  transcript level. Never `PrivateCloudComputeLanguageModel`, never `SFSpeechRecognizer`.
- (W3) Speech vs. music is an explicit estimate (`SpeechRelevance`); probable lyrics are not sent
  to the language model.
- (W3) Engine state changes only on one serial command queue; background results carry the
  session generation. Tests drive it with `drivesItself: false`, `pump()` and `drain()`.
- (W3) All speech thresholds live in `SpeechIntelligenceConfiguration` (`activation`, `relevance`,
  `summary`, endpoint and conversation timings); provisional until device data exists.

## 7. Verification results (Window 1)

(Window 2 results follow in §7b.)

### Build and tests

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | macOS 27.2, Swift 6.4 | **21/21 passed** (iOS-only tests excluded on macOS) |
| `xcodebuild test -scheme HearingSenseKit` | iOS 27.0 Simulator, iPhone 17 | **26/26 passed** |
| App build, Debug | iOS 27.0 Simulator | **Succeeded**, no Swift warnings |
| App build, Release, unsigned | generic iOS device | **Succeeded** |
| App launch | iOS 27.0 Simulator (simctl, screenshot) | Launches; UI renders |
| Install + run, Debug, Personal Team signing | **iPhone 18 Pro, iOS 27.2** | **Succeeded** |
| ML unit tests | `.venv` Python 3.12 | 12/12 passed (forward-only) |
| Legacy `app/` package | `swift build` | Fails (missing sources) — pre-existing |

### Physical-device tests — 2026-10-09, iPhone 18 Pro (iOS 27.2), AirPods Pro, Spotify

| # | Scenario | Result |
|---|---|---|
| T1 | Built-in mic, no AirPods: permission, start, level follows speech/claps, stop | **Pass** (meter behaviour observed by the student) |
| T2 | AirPods Pro + ANC, start listening | **Pass — target route**: in = iPhone Microphone (Bottom data source), out = AirPods Pro **Bluetooth A2DP** (2 ch); capture 48 kHz mono; IO buffer 10 ms; input latency 11.9 ms; output latency 163 ms |
| T2 | AirPods capabilities | iOS reports high-quality Bluetooth recording **supported** and far-field capture **supported** (not used) |
| T3a | Listening, then Spotify plays | **Pass**: both run; music quality normal (student), route unchanged (screenshot) |
| T3b | Spotify playing, Stop/Start listening | **Pass with glitch**: Spotify never paused; **~0.5 s music stall at each start and stop** (student); `routeConfigurationChange` logged each time |
| T4 | Screen locked while listening + Spotify | **Pass for ≤ 40 s**: 7.3 s → 100 % coverage (73 buffers); 39.7 s → 100 % coverage (397 buffers); no interruptions; music continued |

Measured: tap buffers arrive as 4 800 frames (100 ms) at 48 kHz although 4 096 were requested.

### Not verified

- Simulator microphone capture (skipped; device test done instead).
- Background/lock longer than 40 s (the student chose 40 s as sufficient for Window 1).
- Apple Music; phone-call / Siri interruptions; AirPods disconnect or ANC/Transparency switching
  mid-session; the three experimental policies; battery and thermal impact.
- Whether AirPods produced an audible click when listening started (asked in T2, not answered).
- SoundAnalysis label list on iOS (only macOS enumerated).

## 7b. Verification results (Window 2)

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | macOS 27.2, Swift 6.4 | **58/58 passed** (37 new SoundEventDetection + 21 Window 1) |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27.0 Simulator, **iPhone 18 Pro** | **63/63 passed** (37 + 26) |
| App build, Debug | iOS 27.0 Simulator, iPhone 18 Pro | **Succeeded**, 0 Swift warnings |
| Live listening (Mac mic) | iPhone 18 Pro Simulator | Works: 37 s, 370 buffers, 0 dropped, 48 windows; result delay ≈ 11 ms after window end; process CPU 7.7 % of one core, 31 MB (Mac hardware) |
| Label inventory | macOS 27.2; iOS 27.0 Simulator | **303 labels, exact match with the taxonomy** |
| Label inventory | physical iPhone | **Not run** |
| Offline evaluation, 1.5 s windows | Recorded files (Mac) | Speech recall 99.8 % [98.9, 100] (510 utterances); music recall 100 % [98.7, 100] (300 GTZAN); music falsely confirmed on speech 0.2 %; 0/510 alert events on speech; alert events on held-out music clips 1.0 % [0.3, 2.9] after the foghorn rule. **No accuracy for alerts/knocks/animals/weather** (no annotated data) |
| Any physical-iPhone test (AirPods/Spotify, lock screen, stall, interruptions) | iPhone 18 Pro | **Not run in Window 2** |

## 7c. Verification results (Window 3)

Details and methods: `docs/testing/WINDOW3_TEST_RESULTS.md`. All measurements are from the Mac.

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | macOS 27.2, Swift 6.4 | **160 passed, 1 skipped** (opt-in real-model test) of 161: 103 new + 58 from Windows 1–2 |
| `HS_RUN_MODEL_TESTS=1 swift test --filter realModel` | Mac, real language model | passed |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27.0 Simulator, iPhone 18 Pro | **162 passed, 4 skipped** of 166 (3 recognizer tests: no `SpeechTranscriber` in the Simulator; 1 opt-in) |
| App build, Debug / Release unsigned | Simulator / generic iOS device | **Succeeded**, 0 Swift warnings |
| Speech recognition, LibriSpeech dev-clean, 200 utterances | Recorded files (Mac) | WER 1.60 % clean; 2.66 % cafeteria +10 dB; 5.26 % traffic 0 dB; 15.4 % cafeteria 0 dB; 3.06 % / 17.4 % music +10 / 0 dB |
| Pre-roll buffer, 30 shortest human utterances, real time | Recorded files (Mac) | First word kept 29/30 with 5 s pre-roll vs 1/30 with 0.25 s; WER 3.8 % vs 43.8 % |
| End to end, 20 synthetic sentences, real time | Synthetic speech (Mac) | 20/20 transcript and validated summary; final transcript 0.93 s and summary 3.14 s (median) after the end of speech |
| Summaries, 38 sentences as text | Real language model (Mac) | 37 shown, 1 guardrail fallback; 14/14 negated sentences keep a negation (rule check); manual review: 30 faithful, 4 incomplete, 3 ambiguous, 0 reversed |
| Speech relevance gate, holdout clips | Recorded files (Mac) | Songs with anything sent to the language model 170/299 → 18/299; spoken words kept 99 % at +10 and +5 dB over music, 84 % at 0 dB; clean speech unchanged |
| Complete pipeline in real time with music | Recorded files (Mac) | 1 of 20 songs treated as conversation; 12/15 summaries for speech over music at +10 dB, 10/15 at 0 dB |
| Live microphone, transcription off | Simulator | "Nearby Speech" (level 1) shown; screenshots in `docs/device-tests/window3-simulator/` |
| Live transcription and summary, screen on | **Physical iPhone** | Works: final transcript 0.81 s, language model 0.68 s, summary 2.00 s after the speech (means; n = 22 / 15 / 14); first words of "Yes." / "Watch out!" kept; AirPods Pro + Spotify fine |
| Locked screen / app in background | **Physical iPhone** | **0 of 3 sentences detected** (3 of 3 with the screen on): the built-in sound classifier fails in the background |
| Music from a loudspeaker | **Physical iPhone** | 3 clips: sung pop → nothing or one text-less "Nearby Speech"; rap → "Speech Unclear" without a summary; relevance labels differ from the file-based evaluation |
| Noisy place, 15 min battery/thermal, text removed after Stop | Physical iPhone | **Not run** |

## 8. Known issues

| Issue | Impact | Suggested handling |
|---|---|---|
| **(W2+W3) Nothing is recognized in the background or with the screen locked** | Measured on the iPhone 18 Pro (iOS 27.2): `SNClassifySoundRequest(.version1)` fails with `com.apple.SoundAnalysis` error 2 from 0.44 s after the app enters the background until it returns; capture continues. No sound events, no speech activation. Blocks the pocket / lock-screen use case and Window 5's purpose. Other developers report the same (Apple forums 811582, 757715, 765376; GPU work not permitted in the background — unverified here) | **The student has to choose** (not decided): (a) a speech trigger that does not need the classifier in the background, e.g. signal level or the Speech framework's voice-activity module, with the recognizer as the check — speech only, no music gate, more recognizer use; (b) a different sound classifier as a Core ML model on CPU / Neural Engine — needs a model (download or training, both need approval) and forum reports say even CPU-only custom models failed for some; (c) accept foreground-only for now and say so; (d) file Feedback with Apple. `SpeechTranscriber` and Foundation Models did run in the background in one trial (model 6.1 s instead of 0.7 s). **Update 2026-10-10 (device, one run):** adding the Background-processing mode to `UIBackgroundModes` made the built-in classifier run in the background and when locked; not replicated yet and not adopted — see `docs/testing/BACKGROUND_DEVICE_TESTS.md` §7 |
| (W3) Device validation is thin | A few sessions, one speaker near the phone, loudspeaker playback, on a charger | Open: P7, P8, P9 in `docs/testing/WINDOW3_TEST_RESULTS.md` §9; other speakers need their consent |
| (W3) A recognition error reversed the meaning once on the iPhone ("not" → "now") | The validator cannot catch errors made before the summary | Keep the transcript visible with every summary; Window 4 must not treat a headline as fact; show recognition quality |
| (W3) Relevance-gate labels differ on the device | Speech over a pop song was labelled plain "nearby speech"; a rap clip was not labelled "possibly music" (it ended as "Speech Unclear") | Re-calibrate with recordings made by the phone (needs authorization to record) |
| (W3) Simulator cannot transcribe | Levels 2–3 cannot be exercised in the Simulator; recognizer tests are skipped there | Use the Mac for recognizer tests; optionally run the app as "My Mac (Designed for iPhone)" (needs the Mac registered in the student's developer account — their decision) |
| (W3) ≈ 2 s from the end of a sentence to its summary on the iPhone (≈ 3 s on the Mac) | Slower than a glance-and-go alert | ≈ 0.8 s is the wait for the final transcript, ≈ 0.7 s the language model; consider showing the transcript-level result first, or a shorter endpoint |
| (W3) Summaries can be incomplete or ambiguous although validated | 3 of 37 manually reviewed headlines were ambiguous ("Store Won't Open Ten") | Keep the transcript reachable from any summary; Window 4 should not treat a headline as fact |
| (W3) Speech vs. music is an estimate | ≈ 6 % of songs still produce something for the language model (mostly rap); ≈ 16 % of spoken words at 0 dB over music are held as "possibly music"; TV/podcast speech counts as nearby speech | Window 4: lowest priority for `possiblyMusic`, lower for `speechOverMusic`; re-tune with device recordings |
| (W3) English only; validator rules are English keyword rules | Other languages get no validated summaries | Add per-language rules or restrict the feature to English; Chinese needs the speech model downloaded |
| (W3) Categories are often debatable (model overuses "reminder") | Weak signal for prioritization | Prefer rule-based `details` (negation, question, time) and keywords in Window 4 |
| (W3) `NSSpeechRecognitionUsageDescription` added defensively | The student reported no prompt on the iPhone | Keep the key |
| (W3) Recognizer limit on the iPhone | "Maximum number of recognizers reached" with three analyzers; limit inferred to be two | Fixed by dropping the standby analyzer and retrying starts; do not add further concurrent analyzers (e.g. a second language) without testing on the device |
| (W3) Thresholds chosen on read/synthetic speech and GTZAN, on the Mac | May not transfer to a phone on a table or in a pocket | Re-run `hs-speech-eval` after collecting device data (with authorization) |
| ~0.5 s media stall at Start/Stop listening | Noticeable but acceptable for manual start/stop | W2: redundant calls skipped + keep-session experiment added; **effect not measured** — device Test S (feasibility §3) |
| No physical-device validation of Window 2 | Thresholds, quiet level, latency, CPU on iPhone unknown | Run `docs/testing/WINDOW2_DEVICE_TESTS.md` (L, A, B, C, D, H, I, S first) |
| Thresholds provisional; no event-annotated environmental data | Alert/knock/animal/weather reliability unknown | Device tests with controlled playback; consider a small annotated set (download needs approval) |
| Minor kinds fire on clean speech (`click`, `mosquito_buzz`, `writing`, `sigh`) | Noise in the event list | Window 4 should give these kinds low priority; or raise their thresholds after device data |
| Quiet threshold −60 dBFS is a guess | Simulator room noise (−53 dBFS) shows as "sound present, not recognized" | Calibrate in Test A |
| Engine output is a single-consumer `AsyncStream` | Later modules cannot subscribe directly | Forward `.event` updates from `RecognitionController` (app layer) |
| Git identity is repo-local (`vicwei`, account email) | Commit author name may not be what the student wants | `git config user.name "…"` in the repo |
| Personal Team signing | App expires after 7 days; re-run from Xcode to reinstall | Fine for development |
| Xcode wrote the student's `DEVELOPMENT_TEAM` into `project.pbxproj` | Other machines must pick their own team | Acceptable; not a secret |
| `AVAudioSession` calls on the main actor | Simulator logs a runtime "hang risk" warning for `setActive` | iOS 27 `activate(options:completionHandler:)` is available (needs `#available`); adopt only after device testing |
| App scheme has no test action | `xcodebuild test -scheme HearingSense` fails (“no test bundles”) | Run package tests from `packages/HearingSenseKit` (§10); the package scheme is now `HearingSenseKit-Package` |
| Interruption ended without `shouldResume` keeps state “Paused” | Untested path | Test with a phone call in Window 2 |
| Navigation title duplicates the brand header | Cosmetic | Window 5 UI pass |
| Placeholder app icon | Cosmetic | Window 5 |

## 9. Remaining tasks (by window)

See `docs/IOS_DEVELOPMENT_ROADMAP.md`. First: the student's decision on background detection (§8,
first row). Carried over from Window 3 (physical iPhone): P7–P9 in
`docs/testing/WINDOW3_TEST_RESULTS.md` §9. Carried over from
Window 2 (physical iPhone, one step at a time): label inventory (L), quiet room (A, calibrate quiet threshold), speech/knock/music/overlap
(B, C, D, G), AirPods + Spotify (H), lock screen ≥ 1 min then ≥ 15 min (I), start/stop stall with
the keep-session toggle off/on (S), playback rain/wind/horn (E, F), interruptions (J, ask first);
plus Window 1's open items (calls, AirPods disconnect, Apple Music, battery/thermal).
Then Window 4 (Attention Priority Engine), which consumes `ConfirmedAcousticEvent`s and
`SpeechSemanticResult`s (contract: `docs/research/SPEECH_INTELLIGENCE_ARCHITECTURE.md` §11).

## 10. How to build, test and run

```bash
# Package tests on the Mac (fast)
cd packages/HearingSenseKit && swift test

# Package tests on the iOS Simulator (includes iOS-only tests; the student uses the iPhone 18 Pro Simulator)
cd packages/HearingSenseKit && xcodebuild test -scheme HearingSenseKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro'

# App build for the Simulator
xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense -destination 'platform=iOS Simulator,name=iPhone 18 Pro'

# Offline sound evaluation (forward-only, ~2 min on the M1 Max; needs data/ downloaded)
cd packages/HearingSenseKit && swift run -c release hs-sound-eval evaluate --window 1.5
swift run -c release hs-sound-eval labels     # label inventory with taxonomy mapping

# Window 3: synthetic test sentences (macOS text-to-speech), then speech evaluation (forward-only)
tools/make_speech_test_signals.sh
cd packages/HearingSenseKit
swift run -c release hs-speech-eval availability            # which on-device models exist here
swift run -c release hs-speech-eval transcribe --libri 200  # WER on LibriSpeech (~1 min)
swift run -c release hs-speech-eval summarize --repeat 2    # Foundation Models on 38 sentences (~4 min)
swift run -c release hs-speech-eval pipeline --set tts      # real-time end to end, 20 sentences (~4 min)
HS_RUN_MODEL_TESTS=1 swift test --filter realModel          # opt-in real language-model test
```

Recognizer tests need macOS (they are reported as skipped in the Simulator) and the synthetic
test signals; without the signals they are skipped too.

In the Simulator the app listens through the Mac's microphone; results are Simulator evidence,
not iPhone evidence.

Device tests from the Mac without touching the phone (Debug builds; the phone must be unlocked for
`launch`):

```bash
D=<UDID>   # xcrun devicectl list devices
xcodebuild -project apps/ios/HearingSense.xcodeproj -scheme HearingSense -configuration Debug \
  -destination "id=$D" -derivedDataPath <dir> -allowProvisioningUpdates build
xcrun devicectl device install app --device $D <dir>/Build/Products/Debug-iphoneos/HearingSense.app
# start listening right after launch and export metadata-only diagnostics every 5 s
xcrun devicectl device process launch --device $D --terminate-existing org.hearingsense.HearingSense \
  --hs-autostart --hs-export-diagnostics
xcrun devicectl device copy from --device $D --domain-type appDataContainer \
  --domain-identifier org.hearingsense.HearingSense \
  --source Documents/hearing-sense-diagnostics.txt --destination diag.txt   # works while locked
xcrun devicectl device process launch --device $D --terminate-existing org.hearingsense.HearingSense  # mic off
```

The export (`apps/ios/HearingSense/Diagnostics/DebugDiagnosticsExporter.swift`, `#if DEBUG`) holds
states, counters, timings and the event log — no audio, no transcripts, no summaries. Locking,
unlocking and tapping still need the student. Ask before playing sounds through the Mac speakers.

On the iPhone: open `apps/ios/HearingSense.xcodeproj` in Xcode, Signing & Capabilities → Team =
the student's Personal Team, select the iPhone as destination, Run. Device screenshots:
`xcrun devicectl device capture screenshot --device <UDID> --destination shot.png`
(take them only while Hearing Sense is in the foreground). In the app, **Audio route diagnostics →
Share** exports the route snapshot and event log as text.

## 11. Files to read first (in order)

1. `docs/PROJECT_HANDOFF.md` (this file)
2. `docs/IOS_ARCHITECTURE.md` — module map, contracts (§4), constraints
3. `docs/AUDIO_ROUTING_FEASIBILITY.md` — verified routing behaviour and open device tests
4. `docs/IOS_DEVELOPMENT_ROADMAP.md` — your window's scope and acceptance criteria
5. `docs/EXISTING_PROJECT_AUDIT.md` — what the research assets are and what must be preserved
6. `docs/WINDOW2_SOUND_ANALYSIS_REPORT.md` — sound pipeline, rules, evaluation, limitations
7. `docs/testing/WINDOW2_DEVICE_TESTS.md` — open device tests
8. `docs/WINDOW3_SPEECH_INTELLIGENCE_REPORT.md`, `docs/research/SPEECH_INTELLIGENCE_ARCHITECTURE.md`,
   `docs/testing/WINDOW3_TEST_RESULTS.md` — speech pipeline, measurements, limitations, pending device tests
9. Code (W3): `Sources/HearingSenseDomain/SpeechSemantics.swift`, `Sources/SpeechIntelligence/
   {SpeechIntelligenceEngine, SpeechActivityTracker, SpeechRelevanceGate, SpeechIntelligenceTypes}.swift`,
   `Sources/SpeechPipeline/{PreRollAudioBuffer, AppleSpeechTranscriber}.swift`, `Sources/SemanticSummary/
   {SpeechSemanticAnalyzer, SummaryValidator, FoundationModelInterpreter}.swift`,
   `apps/ios/HearingSense/Speech/SpeechIntelligenceController.swift`
10. Code (W1–W2): `packages/HearingSenseKit/Sources/HearingSenseAudio/MicrophoneCapture.swift`,
   `AudioStreamConsumer.swift`, `Sources/HearingSenseDomain/AcousticEvent.swift`,
   `Sources/SoundEventDetection/{SoundRecognitionEngine, SoundAnalysisWorker, SoundEventDetector,
   DetectionPolicy, SoundTaxonomy}.swift`, `apps/ios/HearingSense/Listening/ListeningController.swift`,
   `apps/ios/HearingSense/Recognition/RecognitionController.swift`

## 12. Recommended next steps

1. Student decides whether to merge `feature/window2-sound-analysis` and
   `feature/window3-speech-intelligence` into `main` (not done automatically; nothing is pushed).
2. When the student authorizes device testing: Window 3 tests P0–P9 and the open Window 2 tests,
   one step per message, screenshots only with the app in the foreground, the student decides what
   is spoken.
3. Re-tune `SpeechIntelligenceConfiguration` and `DetectionPolicy.standard` from device results and
   re-run `hs-speech-eval` / `hs-sound-eval` to check nothing regressed.
4. Start Window 4 in a new session only when the student asks, on a new branch from the Window 3
   branch (or from `main` after merging).
