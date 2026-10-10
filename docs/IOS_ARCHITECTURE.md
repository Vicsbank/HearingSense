# Hearing Sense iOS 2.0 — Architecture

Status: Window 3 (2026-10-09; Windows 1 and 2 earlier the same day). Sections marked **Implemented** exist in code; **Planned** sections
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
│       ├── Sources/HearingSenseAudio/   Window 1 module (+ ProcessResourceUsage, W2)
│       ├── Sources/HearingSenseDomain/  Window 2: shared value types (Foundation only)
│       ├── Sources/SoundEventDetection/ Window 2: SoundAnalysis engine, taxonomy, detector
│       ├── Sources/SoundEvaluationTool/ Window 2: hs-sound-eval (macOS, forward-only)
│       ├── Sources/SpeechPipeline/      Window 3: pre-roll ring buffer, on-device transcription
│       ├── Sources/SemanticSummary/     Window 3: Foundation Models interpretation, validation, fallback
│       ├── Sources/SpeechIntelligence/  Window 3: coordinator, speech activity, relevance gate
│       ├── Sources/SpeechEvaluationTool/ Window 3: hs-speech-eval (macOS, forward-only)
│       └── Tests/{HearingSenseAudioTests, SoundEventDetectionTests, SpeechPipelineTests,
│                  SemanticSummaryTests, SpeechIntelligenceTests}/
├── docs/                            existing docs kept; new iOS docs added
│   ├── device-tests/2026-10-09/         device screenshots (evidence, W1)
│   ├── device-tests/window2-simulator/  Simulator screenshots (W2)
│   ├── device-tests/window3-simulator/  Simulator screenshots (W3)
│   ├── testing/                         device test protocols (W2), W3 test results
│   └── research/                        label inventories, category mapping, speech architecture (W3)
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
                    │                 └─▶ [Speech Pipeline]        (W3)  ─┤  pre-roll buffer + on-device
                    │                        ▲ classifier windows (W2)    │  transcription, gated by speech
                    │                        └────────────────────────────┤  activity and the relevance gate
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
| `HearingSenseDomain` | 2, 3 | Shared value types: `SoundLabel`, `ClassifierScore`, `AudioTimeRange`, `RawSoundPrediction`, `ClassificationFrame`, `SoundCategory`, `SoundEventKind`, `AcousticEventCandidate`, `ConfirmedAcousticEvent`, `AcousticEventUpdate`, `EnvironmentStatus`; W3: `SpeechSemanticResult` and its parts (`SpeechEventID`, state, level, category, transcript + quality, summary + reliability, relevance / acoustic context, latency, availability); Foundation only | — | **Implemented** |
| `SoundEventDetection` | 2 | `SoundRecognitionEngine` (`AudioStreamConsumer` → `SNAudioStreamAnalyzer`), `SoundTaxonomy` (303 labels → 50 kinds → 11 categories), `DetectionPolicy` + `SoundEventDetector` (confidence filter, k-of-n confirmation, hysteresis, timeouts), `SoundClassifierCatalog`, diagnostics | SoundAnalysis, AVFAudio, HearingSenseAudio, Domain | **Implemented** |
| `hs-sound-eval` (executable, macOS) | 2 | Forward-only offline evaluation of the production engine on local files | SoundEventDetection | **Implemented** |
| `SpeechPipeline` | 3 | `PreRollAudioBuffer` (5 s ring on the shared audio clock), `SpeechAudioTap`, `AppleSpeechTranscriber` (`SpeechAnalyzer` + `SpeechTranscriber`, one analyzer per utterance, `AssetInventory` availability and user-initiated install), `TranscriptAssembler` | Speech, AVFAudio, HearingSenseAudio, Domain | **Implemented** |
| `SemanticSummary` | 3 | `FoundationModelInterpreter` (`SystemLanguageModel`, guided generation), `SpeechSemanticAnalyzer` (unclear check → model → validation → retry → fallback), `SummaryValidator`, `RuleBasedInterpreter` | FoundationModels, Domain | **Implemented** |
| `SpeechIntelligence` | 3 | `SpeechIntelligenceEngine` (event-driven coordinator on a serial command queue), `SpeechActivityTracker` (speech candidates, music context), `SpeechRelevanceGate` (speech vs. lyrics), conversation model, diagnostics | SpeechPipeline, SemanticSummary, SoundEventDetection, Audio, Domain | **Implemented** |
| `hs-speech-eval` (executable, macOS) | 3 | Forward-only evaluation: WER, summaries, activation, relevance gate, real-time end-to-end replay | all of the above | **Implemented** |
| `AttentionEngine` | 4 | Deterministic scoring, cooldowns, confirmation windows, user preferences | Domain only | Planned |
| App target `HearingSense` | 1→5 | Orchestration (`ListeningController`), SwiftUI screens, settings; W3: `SpeechIntelligenceController`, speech card and diagnostics | all modules | Implemented (foundation, W2 recognition, W3 speech) |
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

| `ProcessResourceUsage.swift` (W2) | Process CPU time (`getrusage`), `phys_footprint`, thermal state for diagnostics |

`AudioSessionController` (W2 change): skips `setCategory` when category/mode/options already match,
skips `setActive(true)` when this controller already activated the session, skips
`setPreferredInput` when that input is already preferred, and records each step's duration
(`lastTrace`). `isActive` / `noteDeactivatedBySystem()` track activation across interruptions.

App target (`apps/ios/HearingSense/`): `ListeningController` (main-actor state machine:
idle → requestingPermission → starting → listening ⇄ interrupted; failed; permissionDenied),
`ContentView`, `StatusCard`, `LevelMeterView`, `RouteDiagnosticsView`, `DiagnosticLogView`.
Window 2 adds `Recognition/RecognitionController` (observable presentation state fed by the
engine's output stream, bounded in-memory event history, resource sampling, background counters)
and `Views/RecognitionViews.swift` (recognition card, recent events, recognition diagnostics,
classifier label inventory). `ListeningController` stays the orchestrator: it attaches the engine
to `MicrophoneCapture`, and calls `endSession()` on Stop, interruption and media-services reset.

## 3b. Implemented: Window 2 sound recognition

```
MicrophoneCapture tap thread                      analysis queue (actor SoundAnalysisWorker,
  captureDidReceive(buffer, time)                   executor = serial DispatchSerialQueue)
   ├ copy channel 0 → [Float] (Sendable)             ├ SNAudioStreamAnalyzer(format: mono, input rate)
   ├ StreamClock: segment + frame position            │   + SNClassifySoundRequest(.version1),
   │  (gaps from AVAudioTime.sampleTime)              │   window 1.5 s, overlap 0.5
   ├ backlog ≥ 50 → drop + count (never block)        ├ analyze(_:atAudioFramePosition:)  (may block)
   └ queue.async { worker.assumeIsolated {…} } ─────▶ ├ ResultObserver (SoundAnalysis thread)
                                                      │   → ResultInbox → drained in order
                                                      ├ ClassificationFrame (+ window RMS, capture time)
                                                      ├ SoundEventDetector.process(frame)
                                                      └ AsyncStream<SoundRecognitionOutput>
                                                             │  .event / .frame / .sessionEnded / .failure
                                                             ▼
                                              RecognitionController (main actor) → SwiftUI
```

- Measured (Simulator): SoundAnalysis delivers observer callbacks on its own thread, not on the
  caller's queue; the inbox + scheduled drain keeps FIFO order.
- Audio clock: seconds of captured input since Start (frames / rate), continuous across engine
  restarts; wall-clock dates come from tap arrival times.
- Restart after a route/format change starts a new analyzer *segment* but keeps the session, so
  ongoing events survive; Stop / interruption end the session (`.ended` for every active event).
- No audio is persisted; buffers live until analyzed (≤ 50 × 100 ms). Outputs are metadata.

### Threading model

- Package targets: Swift 6 language mode, no default actor isolation.
- App target: Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency,
  member-import visibility.
- The tap block is created in a `nonisolated` method of a non-actor class, so it never inherits
  main-actor isolation (avoids Swift 6 runtime isolation traps on the audio thread).
- Tap thread → `CaptureTick` (Sendable) → `Task { @MainActor … }`. UI updates are skipped while the
  app is in the background; counting continues on the audio thread.
- `AVAudioSession` calls run on the main actor (they can block briefly; acceptable for now).

## 3c. Implemented: Window 3 speech intelligence

Full description: `docs/research/SPEECH_INTELLIGENCE_ARCHITECTURE.md`. In short:

```
MicrophoneCapture ─▶ SpeechAudioTap ─▶ PreRollAudioBuffer (5 s ring, same AudioStreamClock as W2)
RecognitionController ─ classifier windows / speech events ─▶ SpeechIntelligenceEngine
   SpeechActivityTracker (candidate ≥ 0.30; stricter in a music context)
     → AppleSpeechTranscriber: one SpeechAnalyzer per utterance, started on buffered audio from the
       estimated onset, finished when the transcript is stable for 1.6 s
     → SpeechRelevanceGate: nearbySpeech / speechOverMusic / possiblyMusic (not interpreted)
     → SpeechSemanticAnalyzer: Foundation Models headline → SummaryValidator → retry → fallback
     → SpeechSemanticResult (stable SpeechEventID per conversation, revision, summaryRevision)
SpeechIntelligenceController (main actor) → SwiftUI card + diagnostics
```

- Three output levels: 1 "Nearby Speech" (no transcription), 2 transcript, 3 validated summary.
- Transcription is opt-in (switch, default off), memory-only, cleared on Stop.
- The engine serializes all state changes on one command queue; background results carry the
  session generation and are dropped when stale.
- The iOS Simulator has no `SpeechTranscriber` (level 1 only there); transcription is verified on
  the Mac with `swift test` / `hs-speech-eval`; the iPhone is pending.

## 4. Contracts for later windows

```swift
// Implemented in Window 1 — consumers attach here.
public protocol AudioStreamConsumer: AnyObject, Sendable {
    func captureDidStart(format: AVAudioFormat)
    func captureDidReceive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)   // audio thread, return fast
    func captureDidStop()
}

// Implemented in Window 2 (HearingSenseDomain) — see the source for full documentation.
public struct ConfirmedAcousticEvent: Identifiable, Hashable, Sendable, Codable {
    public let id: AcousticEventID              // stable; attach W3/W4/W5 data keyed by this id
    public let kind: SoundEventKind             // id "dog", displayName "Dog", category .animals
    public let source: AcousticEventSource      // .soundClassifier(SoundModelID) — W3 may add cases
    public var primaryLabel: SoundLabel         // original classifier identifier, e.g. "dog_bark"
    public var phase: AcousticEventPhase        // .confirmed → .ongoing → .ended
    public let audioStart, audioConfirmed: TimeInterval; public var audioLastObserved: TimeInterval
    public let startDate, confirmedDate: Date;   public var lastObservedDate: Date; public var endedDate: Date?
    public var evidence: EventEvidence          // windows, peak/mean score, per-label evidence
    public var quality: EventQuality            // weak / moderate / strong (rule-based, not a probability)
}
public enum AcousticEventUpdate { case started(ConfirmedAcousticEvent), updated(…), ended(…) }
// Producer: SoundRecognitionEngine.outputs (AsyncStream<SoundRecognitionOutput>, single consumer;
// the app's RecognitionController owns it — Window 3/4 should subscribe through the app layer,
// e.g. by forwarding .event updates, rather than creating a second engine).

// Implemented in Window 3 (HearingSenseDomain) — see the source for full documentation.
public struct SpeechSemanticResult: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeechEventID                 // one conversation; same id across updates
    public var revision: Int                     // every published change
    public var summaryRevision: Int              // only when the headline text changes
    public var sourceEventIDs: [AcousticEventID] // W2 speech events during the conversation
    public var state: SpeechProcessingState      // detected → transcribing → processing → summarized → completed | failed
    public var transcript: SpeechTranscript?     // text, language, isFinal, TranscriptQuality (recognition quality)
    public var summary: SpeechSummary?           // validated headline + SummaryReliability (interpretation quality)
    public var category: SpeechSemanticCategory  // question, request, reminder, announcement, warning, …
    public var details: SpeechSemanticDetails?   // subject, timeOrNumber, isNegated, isQuestion
    public var acousticContext: SpeechAcousticContext?  // relevance: nearbySpeech / speechOverMusic / possiblyMusic
    public var level: SpeechOutputLevel          // 1 detection, 2 transcript, 3 summary
    public var headline: String                  // summary, or "Nearby Speech" / "Speech Detected" / "Speech Unclear" / "Speech Or Music"
    …availability, latency, failure
}
// Producer: SpeechIntelligenceEngine.outputs (single consumer: the app's SpeechIntelligenceController,
// which keeps the latest revision of each event in `events`). Window 4 should read from the app layer.

// Window 4 (planned; consumes ConfirmedAcousticEvent instead of the old AcousticEvent sketch).
public protocol AttentionPolicy: Sendable {
    func evaluate(_ event: ConfirmedAcousticEvent, context: AttentionContext) -> AttentionDecision
}
public enum AttentionDecision: Sendable { case ignore, log, surfaceInApp, updateLiveActivity, alert(reason: String) }
```

Consumer guidance (applied in Window 2): `SNAudioStreamAnalyzer.analyze(_:atAudioFramePosition:)`
runs on its own serial queue; the buffer is copied before hopping. `captureDidStart(format:)` may
arrive after the first buffers, so formats are detected per buffer (`StreamClock`).
Extension points: Window 3 gates speech on classifier *windows* (speech candidates, earlier than
confirmed events) and links confirmed `speech` events through `SpeechSemanticResult.sourceEventIDs`;
Window 4 maps `kind`/`category` + `evidence` and `SpeechSemanticResult` to priorities; Window 5
renders `kind.displayName` / `category.systemImage` / `headline`. The only change Window 3 made to
SoundEventDetection was moving `StreamClock` to `HearingSenseAudio.AudioStreamClock` (a typealias keeps the old name).

## 5. Apple frameworks and availability (checked in the iOS 27.0 / macOS 27 SDKs)

| Need | API | Availability | Notes |
|---|---|---|---|
| Capture | `AVAudioEngine`, `AVAudioSession` | iOS 3+/8+ | Implemented |
| Permission | `AVAudioApplication.requestRecordPermission()` | iOS 17+ | Implemented |
| AirPods HQ mic | `.bluetoothHighQualityRecording`, `bluetoothMicrophoneExtension` | iOS 26+ (not Catalyst) | Experimental policy; device untested |
| Sendable tap | `installAudioTap(onBus:…tapProvider:)` | iOS 27+ | Adopt if the deployment target moves to 27 |
| Sound events | `SNClassifySoundRequest(classifierIdentifier: .version1)`, `SNAudioStreamAnalyzer` | iOS 15+ | **Implemented (W2)**. Only `version1` exists; 303 labels on macOS 27.2 and iOS 27.0 Simulator (iPhone pending); window 0.5–15 s (default 3 s, overlap 0.5); analyzer resamples and uses channel 0; `analyze` may block (backpressure) and must not run on a real-time thread |
| Async session activation | `AVAudioSession.activate(options:completionHandler:)`, `deactivate(options:completionHandler:)` | iOS 27+ | Not adopted (deployment target 26); candidate to remove the main-thread "hang risk" warning — see AUDIO_ROUTING_FEASIBILITY §3 |
| Speech | `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory` | `anyAppleOS 26` | **Implemented (W3)**. `SpeechTranscriber.isAvailable` is **false in the iOS 27.0 Simulator**, true on macOS 27.2; locale models are system assets (`AssetInventory`); analyzer input 16 kHz mono Int16; one analyzer per utterance with a contiguous timeline from 0 (gaps or mid-stream finalize corrupt results). `DictationTranscriber`, `SpeechDetector`, `SFSpeechRecognizer` unused |
| Summaries | `SystemLanguageModel.default`, `LanguageModelSession.respond(to:generating:)`, `@Generable` | iOS 26+ | **Implemented (W3)**. Available on macOS 27.2 and in the Simulator; unavailable reasons `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady` map to the transcript-level fallback; context size 4096 tokens; the safety guardrail can refuse a transcript (handled as fallback) |
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
- (W3, implemented) Speech transcription is off by default (a remembered switch, independent of
  sound classification) and visibly indicated; the pre-roll buffer is a fixed ring in memory,
  zeroed on Stop and unused while transcription is off; transcripts and summaries live in memory
  only (20 speech events), transcript text is removed on Stop unless a debug option keeps it, and
  switching transcription off discards all speech events; logs and shared reports carry counts,
  states and timings, never text; "Delete speech events" control.
- Planned: summaries rather than verbatim text in notifications; no transcript in Live Activities
  by default.
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
| D12 | Apple's built-in classifier only (no custom model) | Window 2 scope; no training authorized; 303 labels cover the target sounds |
| D13 | Three levels: raw label → event kind/category → confirmed event | Labels flicker between synonyms; consumers must not act on single windows |
| D14 | Analyzer on an actor whose executor is a serial `DispatchSerialQueue`; tap enqueues with `queue.async` + `assumeIsolated` | FIFO order, compiler-checked isolation of non-Sendable SoundAnalysis objects, tap never blocks |
| D15 | Mono channel-0 copy, own monotonic frame clock with gap detection | Matches the classifier's default channel; robust to buffer-size, rate and channel changes |
| D16 | Bounded backlog (50 buffers ≈ 5 s) with counted drops | Never block or grow memory without bound; drops are visible in diagnostics |
| D17 | Per-kind rules (profile defaults + overrides), all thresholds in one `DetectionPolicy` value | Explicit, testable, shared by app, tests and offline evaluator |
| D18 | Detector uses only frame timestamps (no system clock) | Deterministic replay of recorded/synthetic frame sequences |
| D19 | 1.5 s window, 50 % overlap as default | Offline comparison of 1.0 / 1.5 / 3.0 s (report §6) |
| D20 | Skip redundant AVAudioSession calls; optional "keep session active when stopped" experiment (default off) | Reduce route renegotiation without changing the verified A2DP configuration |
| D21 | (W3) Speech pipeline is a second `AudioStreamConsumer` on the existing tap, with the same `AudioStreamClock` | No second capture session (would risk disturbing media playback); classifier windows and buffered audio share one time base |
| D22 | (W3) Activate transcription on speech *candidates* (one window ≥ 0.30) and start it from a 5 s pre-roll ring | The detector confirms speech ≈ 2.25 s after onset; short sentences would be lost |
| D23 | (W3) One `SpeechAnalyzer` per utterance, contiguous timeline from 0, always finished (never cancelled for "no text yet") | Measured: gaps and mid-stream finalize corrupt results; analyzer start costs ≈ 5 ms once the model is loaded; results lag behind audio |
| D24 | (W3) Explicit endpoint: transcript unchanged for 1.6 s of audio | Natural finals can lag by seconds |
| D25 | (W3) Model headline is shown only after deterministic validation (negation, grounding, time, length); one retry, then transcript-level fallback | A language model can reverse or invent; the app must not |
| D26 | (W3) Two-stage speech relevance gate with an explicit `possiblyMusic` outcome | Vocal music scores as speech; scores cannot separate voices, so uncertainty is reported instead of hidden |
| D27 | (W3) Engine state behind one serial command queue; background results tagged with the session generation | Deterministic ordering, no actor re-entrancy, stale results dropped |
| D28 | (W3) Transcription opt-in, memory only, text never logged | Nearby conversations are private |
