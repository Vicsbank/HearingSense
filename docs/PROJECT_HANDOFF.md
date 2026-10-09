# Project Handoff — Hearing Sense iOS 2.0

Last updated: 2026-10-09, end of **Window 2** (Real-Time Sound Analysis and Acoustic Event Detection).
Window 2 status: **code complete and verified on Mac + iPhone 18 Pro Simulator; no physical-iPhone
test was run in Window 2** (the student chose Simulator-only testing for this window). The open device
tests are listed in `docs/testing/WINDOW2_DEVICE_TESTS.md`.
Next window: **Window 3 — Speech Recognition and Apple Foundation Models** (not started; do not start
it without the student's instruction).

Git: initialized in Window 2. `main` = reconstructed Window 1 baseline (`7905f0b`, `679494e`);
Window 2 work is on branch `feature/window2-sound-analysis` (not merged, not pushed; no remote).

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

## 5. Repository structure (current)

```
apps/ios/                      iOS app (Xcode 27 project, synchronized folders)
  HearingSense/HearingSenseApp.swift   @main entry point
  HearingSense/Listening/      ListeningController (orchestrator), ListeningState, DeviceInfo
  HearingSense/Recognition/    RecognitionController (W2: engine outputs → UI state)
  HearingSense/Views/          ContentView, StatusCard, LevelMeterView, RouteDiagnosticsView, DiagnosticLogView,
                               RecognitionViews (W2)
  HearingSense/Assets.xcassets AppIcon (placeholder), AccentColor
  Config/HearingSense-Info.plist  UIBackgroundModes=audio (other Info keys are build settings)
packages/HearingSenseKit/      Swift package: Sources/{HearingSenseAudio, HearingSenseDomain, SoundEventDetection,
                               SoundEvaluationTool}, Tests/{HearingSenseAudioTests, SoundEventDetectionTests}
docs/                          this handoff, architecture, audit, feasibility, roadmap, WINDOW2 report,
                               device-tests/, research/, testing/
results/sound_eval_window2/    W2 offline evaluation summaries (JSON)
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

## 8. Known issues

| Issue | Impact | Suggested handling |
|---|---|---|
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

See `docs/IOS_DEVELOPMENT_ROADMAP.md`. Carried over from Window 2 (physical iPhone, one step at a
time): label inventory (L), quiet room (A, calibrate quiet threshold), speech/knock/music/overlap
(B, C, D, G), AirPods + Spotify (H), lock screen ≥ 1 min then ≥ 15 min (I), start/stop stall with
the keep-session toggle off/on (S), playback rain/wind/horn (E, F), interruptions (J, ask first);
plus Window 1's open items (calls, AirPods disconnect, Apple Music, battery/thermal).
Then Window 3 (speech + Foundation Models), which consumes `ConfirmedAcousticEvent`s.

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
```

In the Simulator the app listens through the Mac's microphone; results are Simulator evidence,
not iPhone evidence.

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
8. Code: `packages/HearingSenseKit/Sources/HearingSenseAudio/MicrophoneCapture.swift`,
   `AudioStreamConsumer.swift`, `Sources/HearingSenseDomain/AcousticEvent.swift`,
   `Sources/SoundEventDetection/{SoundRecognitionEngine, SoundAnalysisWorker, SoundEventDetector,
   DetectionPolicy, SoundTaxonomy}.swift`, `apps/ios/HearingSense/Listening/ListeningController.swift`,
   `apps/ios/HearingSense/Recognition/RecognitionController.swift`

## 12. Recommended next steps

1. Student decides whether to merge `feature/window2-sound-analysis` into `main` (not done
   automatically).
2. Run the carried-over physical-iPhone tests (one step per message; see the memory of how the
   student wants device tests run: short messages, screenshots only with the app in the foreground).
3. Adjust `DetectionPolicy.standard` (quiet threshold, alert rules) from those results; re-run
   `hs-sound-eval` to check nothing regressed.
4. Start Window 3 in a new session only when the student asks, on a new branch from the merged state.
