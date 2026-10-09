# Hearing Sense iOS 2.0 — Architecture

Status: Window 1 (2026-10-09). Sections marked **Implemented** exist in code; **Planned** sections
are contracts for later windows and may be refined by them (record changes here).

Goal: on-device environmental awareness for people wearing noise-cancelling headphones. The iPhone
listens to its surroundings, recognizes sound events with Apple's frameworks, optionally transcribes
and summarizes nearby speech, decides what deserves attention, and presents it in the app, a Live
Activity and the Dynamic Island. No remote inference.

---

## 1. Repository layout (incremental migration)

```
Music Recognition/
├── apps/
│   └── ios/                         NEW  iOS app (Xcode project)
│       ├── HearingSense.xcodeproj       file-system-synchronized groups (Xcode 16+ format)
│       ├── HearingSense/                app target sources: App, Listening/, Views/, Assets
│       └── Config/HearingSense-Info.plist   only UIBackgroundModes; other keys are build settings
├── packages/
│   └── HearingSenseKit/             NEW  local Swift package (iOS 26 + macOS 15)
│       ├── Sources/HearingSenseAudio/   Window 1 module
│       └── Tests/HearingSenseAudioTests/
├── docs/                            existing docs kept; new iOS docs added
│   ├── device-tests/2026-10-09/         device screenshots (evidence)
│   └── research/                        API research outputs (SoundAnalysis labels)
├── app/                             LEGACY macOS Swift scaffold (does not build; untouched)
├── src/  ml/  tools/                LEGACY / RESEARCH Python (untouched, still functional)
├── models/  results/  data/         RESEARCH ASSETS (untouched)
└── README.md  requirements.txt  .gitignore
```

Decision: keep the Python research where it is. `ml/hearing_sense_ml/paths.py` and `src/config.py`
resolve paths relative to the repository root, so moving them would break reproducibility for no
gain. New code goes into new top-level folders (`apps/`, `packages/`), which gives clear ownership
without relocating datasets or checkpoints.

Optional, reversible later moves (not executed; only after Git exists and with approval):
`app/` → `apps/macos-legacy/`; `src/` → `research/legacy_src/` (would require fixing `ROOT`).

## 2. Layers and module map

```
 Microphone ─▶ [Audio Input] ─▶ AudioStreamConsumer fan-out
                    │                 ├─▶ [Sound Event Detection]  (W2)  ─┐
                    │                 └─▶ [Speech Pipeline]        (W3)  ─┤  AcousticEvent stream
                    │                                                     ▼
                    │                               [Semantic Summary] (W3, optional, on-device LLM)
                    │                                                     ▼
                    │                               [Attention Priority Engine] (W4, deterministic)
                    │                                                     ▼
                    └─ diagnostics ─────────────▶  [Presentation] app UI · Live Activity · Dynamic Island (W5)
```

| Module (SwiftPM target unless noted) | Window | Owns | Depends on | Status |
|---|---|---|---|---|
| `HearingSenseAudio` | 1 | Mic permission, `AVAudioSession` policies, `AVAudioEngine` capture, level metering, route snapshots, session events, diagnostic log, throughput accounting | AVFAudio, Accelerate | **Implemented** |
| `HearingSenseDomain` | 2 (create first) | Shared value types: `AcousticEvent`, `EventCategory`, `Confidence`, time stamps; no framework imports beyond Foundation | — | Planned |
| `SoundEventDetection` | 2 | `SNAudioStreamAnalyzer` consumer, label → category mapping, temporal smoothing, `AcousticEvent` emission | SoundAnalysis, HearingSenseAudio, Domain | Planned |
| `SpeechPipeline` | 3 | `SpeechDetector` gating, pre-roll ring buffer, `SpeechAnalyzer` + `SpeechTranscriber`, asset installation (`AssetInventory`) | Speech, HearingSenseAudio, Domain | Planned |
| `SemanticSummary` | 3 | `SystemLanguageModel` availability check, guided generation of short summaries, fallback when unavailable | FoundationModels, Domain | Planned |
| `AttentionEngine` | 4 | Deterministic scoring, cooldowns, confirmation windows, user preferences | Domain only | Planned |
| App target `HearingSense` | 1→5 | Orchestration (`ListeningController`), SwiftUI screens, settings | all modules | Implemented (foundation) |
| Widget extension target (Live Activity) | 5 | ActivityKit `ActivityAttributes`, Lock Screen + Dynamic Island views | ActivityKit, WidgetKit, Domain | Planned |

Rules: modules communicate through `HearingSenseDomain` types and small protocols; only the app
target knows about all of them. `AttentionEngine` must not import Apple ML frameworks, so it stays
fast to unit-test on the Mac.

## 3. Implemented: `HearingSenseAudio`

| File | Responsibility |
|---|---|
| `MicrophoneCapture.swift` | `AVAudioEngine` input tap (format `nil` = current hardware format), per-buffer `LevelMeter`, consumer fan-out, `CaptureThroughput` counting on the audio thread, restart after `AVAudioEngineConfigurationChange` |
| `AudioStreamConsumer.swift` | **Extension seam** for Windows 2–3 (see §4) and `CaptureFormat` |
| `AudioLevel.swift` | `AudioLevel` (RMS/peak dBFS), `LevelMeter` (vDSP; loudest channel; rejects non-float buffers) |
| `AudioSessionPolicy.swift` | Four named session configurations; mapping to `AVAudioSession.CategoryOptions` (iOS only) |
| `AudioSessionController.swift` | setCategory → setActive → setPreferredInput; deactivate with `notifyOthersOnDeactivation`; snapshots (iOS only) |
| `AudioRouteSnapshot.swift` | Platform-independent route model + `reportText()`; iOS capture incl. data sources and iOS 26 Bluetooth microphone capabilities |
| `RouteAssessment.swift` | Verdict: target route / HFP / high-quality Bluetooth / no input / other |
| `AudioSessionEvent.swift` | Interruption, route change, media-services and silence-secondary-hint notifications → Sendable enum; `AudioSessionObserver` |
| `DiagnosticEventLog.swift` | Bounded in-memory log (no audio, no transcripts) |
| `CaptureThroughput.swift` | Buffers/frames delivered; background coverage = captured seconds / wall-clock seconds |

App target (`apps/ios/HearingSense/`): `ListeningController` (main-actor state machine:
idle → requestingPermission → starting → listening ⇄ interrupted; failed; permissionDenied),
`ContentView`, `StatusCard`, `LevelMeterView`, `RouteDiagnosticsView`, `DiagnosticLogView`.

### Threading model

- Package targets: Swift 6 language mode, no default actor isolation.
- App target: Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency,
  member-import visibility.
- The tap block is created in a `nonisolated` method of a non-actor class, so it never inherits
  main-actor isolation (avoids Swift 6 runtime isolation traps on the audio thread).
- Tap thread → `CaptureTick` (Sendable) → `Task { @MainActor … }`. UI updates are skipped while the
  app is in the background; counting continues on the audio thread.
- `AVAudioSession` calls run on the main actor (they can block briefly; acceptable for now).

## 4. Contracts for later windows (Planned)

```swift
// Implemented in Window 1 — consumers attach here.
public protocol AudioStreamConsumer: AnyObject, Sendable {
    func captureDidStart(format: AVAudioFormat)
    func captureDidReceive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)   // audio thread, return fast
    func captureDidStop()
}

// Window 2 creates HearingSenseDomain. Sketch:
public struct AcousticEvent: Sendable, Identifiable, Hashable {
    public enum Source: Sendable { case soundClassifier(label: String), speech, semantic }
    public let id: UUID
    public let category: EventCategory          // e.g. .speech, .alarm, .vehicle, .animal, .music, .other
    public let source: Source
    public let confidence: Double               // 0...1, as reported by the producer
    public let start: Date
    public var end: Date?
    public var detail: String?                  // e.g. "Someone said your name" (W3) — never raw audio
}

// Window 4.
public protocol AttentionPolicy: Sendable {
    func evaluate(_ event: AcousticEvent, context: AttentionContext) -> AttentionDecision
}
public enum AttentionDecision: Sendable { case ignore, log, surfaceInApp, updateLiveActivity, alert(reason: String) }
```

Consumer guidance: `SNAudioStreamAnalyzer.analyze(_:atAudioFramePosition:)` should run on its own
serial queue; copy or retain the buffer before hopping. Use `captureDidStart(format:)` to recreate
analyzers when the format changes after a route change.

## 5. Apple frameworks and availability (checked in the iOS 27.0 / macOS 27 SDKs)

| Need | API | Availability | Notes |
|---|---|---|---|
| Capture | `AVAudioEngine`, `AVAudioSession` | iOS 3+/8+ | Implemented |
| Permission | `AVAudioApplication.requestRecordPermission()` | iOS 17+ | Implemented |
| AirPods HQ mic | `.bluetoothHighQualityRecording`, `bluetoothMicrophoneExtension` | iOS 26+ (not Catalyst) | Experimental policy; device untested |
| Sendable tap | `installAudioTap(onBus:…tapProvider:)` | iOS 27+ | Adopt if the deployment target moves to 27 |
| Sound events | `SNClassifySoundRequest(classifierIdentifier: .version1)` | iOS 15+ | Only `version1` exists; 303 labels; window 0.5–15 s (default 3 s, overlap 0.5) — enumerated on macOS, `docs/research/` |
| Speech | `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber`, `SpeechDetector`, `AssetInventory` | `anyAppleOS 26` | Locale models must be installed via `AssetInventory`; check `SpeechTranscriber.isAvailable` / `supportedLocales` |
| Summaries | `SystemLanguageModel.default.availability` | iOS 26+ | Unavailable reasons: `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady` — must have a non-LLM fallback |
| (forbidden) | `PrivateCloudComputeLanguageModel` | iOS 27+ | Server-side inference — **do not use** (project requires on-device only) |
| Live Activity | ActivityKit + WidgetKit extension | iOS 16.1+ | Window 5 |

Deployment target **iOS 26.0**: the Speech and Foundation Models APIs the design depends on start
there. The test iPhone runs iOS 27.2.

## 6. Presentation constraints (honest expectations for Window 5)

- Live Activities need a separate widget extension target and user permission (Settings toggle).
- The app cannot force the Dynamic Island to expand. The system chooses compact/minimal/expanded
  presentations; an update with an `AlertConfiguration` may be shown prominently, at the system's
  discretion. When Spotify is playing, its Now Playing activity already occupies the Island (seen in
  the device test), so Hearing Sense will often appear in the minimal presentation.
- Updates must be event-driven (no per-second refresh). The system may throttle frequent updates and
  limits Live Activity lifetime (hours, not days); exact limits to be confirmed in Window 5 against
  current documentation.
- Starting a Live Activity is expected to require the app in the foreground; plan to start it when
  the user taps Start Listening, then update it from the running background session (verify).

## 7. Privacy design

- Audio is processed in memory only; nothing is written to disk or uploaded (true in Window 1:
  no file, network or persistence code exists in the app).
- Microphone use is explicit (Start/Stop), visible (status card, “MIC ON”, system orange dot) and
  explained in `NSMicrophoneUsageDescription`.
- Diagnostics contain routing metadata only; sharing is user-initiated via the share sheet.
- Planned: speech transcription off by default and opt-in per session; transcripts kept in memory
  with a short retention window; summaries rather than verbatim text in notifications; a single
  “Delete all” control; no transcript in Live Activities by default.
- The app is an awareness aid, **not** a certified safety or emergency detection system; UI and docs
  must say so (Window 1 main screen already does).

## 8. Accessibility design

- Status never relies on color alone (symbol + text + “MIC ON” badge).
- Dynamic Type: system text styles; buttons stack vertically at accessibility sizes.
- VoiceOver: combined elements with labels/values (meter value in dB), hints on controls,
  announcements on start/stop/interruption/resume.
- Planned: haptics for high-priority events, captions-first presentation for deaf/hard-of-hearing users.

## 9. Decision log

| ID | Decision | Rationale |
|---|---|---|
| D1 | Additive, incremental layout (`apps/`, `packages/`); research untouched | Preserve reproducibility; no large moves |
| D2 | Local SwiftPM package for non-UI code | Fast `swift test` on the Mac, clear module ownership, iOS tests via xcodebuild |
| D3 | iOS 26.0 deployment target, iPhone only, portrait | Speech/FoundationModels availability; focus |
| D4 | Swift 6; app default MainActor; package nonisolated | Data-race safety with audio callbacks |
| D5 | `playAndRecord` + `mixWithOthers` + `allowBluetoothA2DP` + `defaultToSpeaker`, iPhone mic | Verified on device to keep Spotify on AirPods A2DP while recording |
| D6 | AirPods microphone only as an experiment | HFP degrades media; HQ Bluetooth recording untested |
| D7 | No audio persistence, no network code | Privacy by construction |
| D8 | Attention decisions deterministic and testable; LLM only summarizes | Predictability; LLM may be unavailable |
| D9 | No Private Cloud Compute model | On-device requirement |
| D10 | Xcode file-system-synchronized groups | New files in later windows need no `project.pbxproj` edits |
| D11 | Placeholder bundle ID `org.hearingsense.HearingSense`; team chosen locally in Xcode | No shared signing credentials in the repo (the team ID Xcode writes is not a secret) |
