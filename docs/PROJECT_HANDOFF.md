# Project Handoff — Hearing Sense iOS 2.0

Last updated: 2026-10-09, end of **Window 1** (Repository Audit, Redesign, Native iOS Foundation).
Next window: **Window 2 — Real-Time Audio and Apple Sound Analysis** (not started).

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

## 5. Repository structure (current)

```
apps/ios/                      iOS app (Xcode 27 project, synchronized folders)
  HearingSense/HearingSenseApp.swift   @main entry point
  HearingSense/Listening/      ListeningController (orchestrator), ListeningState, DeviceInfo
  HearingSense/Views/          ContentView, StatusCard, LevelMeterView, RouteDiagnosticsView, DiagnosticLogView
  HearingSense/Assets.xcassets AppIcon (placeholder), AccentColor
  Config/HearingSense-Info.plist  UIBackgroundModes=audio (other Info keys are build settings)
packages/HearingSenseKit/      Swift package: Sources/HearingSenseAudio, Tests/HearingSenseAudioTests
docs/                          this handoff, architecture, audit, feasibility, roadmap, device-tests/, research/
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
- Xcode file-system-synchronized groups: add Swift files to folders; no `project.pbxproj` edits needed.

## 7. Verification results (Window 1)

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

## 8. Known issues

| Issue | Impact | Suggested handling |
|---|---|---|
| ~0.5 s media stall at Start/Stop listening | Noticeable but acceptable for manual start/stop | Window 2: avoid redundant session reconfiguration; keep session active across short pauses (feasibility §3) |
| No Git repository | No history or rollback for any work | Initialize Git + baseline commit (needs approval) |
| Personal Team signing | App expires after 7 days; re-run from Xcode to reinstall | Fine for development |
| Xcode wrote the student's `DEVELOPMENT_TEAM` into `project.pbxproj` | Other machines must pick their own team | Acceptable; not a secret |
| `AVAudioSession` calls on the main actor | Possible brief UI hitch on start | Move off-main if it becomes visible |
| App scheme has no test action | `xcodebuild test -scheme HearingSense` fails (“no test bundles”) | Run package tests from `packages/HearingSenseKit` (§10) |
| Interruption ended without `shouldResume` keeps state “Paused” | Untested path | Test with a phone call in Window 2 |
| Navigation title duplicates the brand header | Cosmetic | Window 5 UI pass |
| Placeholder app icon | Cosmetic | Window 5 |

## 9. Remaining tasks (by window)

See `docs/IOS_DEVELOPMENT_ROADMAP.md`. Immediately next (Window 2): create `HearingSenseDomain`,
implement the Sound Analysis consumer, verify the label list on the iPhone, map labels to user
categories, measure latency/CPU on device, evaluate offline (forward-only) with existing noise data,
address the start/stop stall, and finish the open device tests that affect audio (long background,
calls, AirPods disconnect, Apple Music).

## 10. How to build, test and run

```bash
# Package tests on the Mac (fast)
cd packages/HearingSenseKit && swift test

# Package tests on the iOS Simulator (includes iOS-only tests)
cd packages/HearingSenseKit && xcodebuild test -scheme HearingSenseKit -destination 'platform=iOS Simulator,name=iPhone 17'

# App build for the Simulator
xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense -destination 'platform=iOS Simulator,name=iPhone 17'
```

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
6. Code: `packages/HearingSenseKit/Sources/HearingSenseAudio/MicrophoneCapture.swift`,
   `AudioStreamConsumer.swift`, `apps/ios/HearingSense/Listening/ListeningController.swift`

## 12. Recommended next steps

1. **Initialize Git** (student approval needed): `git init`, review `git status`, baseline commit of
   the current tree. Then use one branch (and optionally a worktree) per window.
2. Start Window 2 in a new session with this handoff.
3. Optional before Window 2: one long lock-screen run (10–15 min) to confirm background survival.
