# Hearing Sense iOS 2.0 — Development Roadmap

Six development windows, each a separate Claude Code session without shared memory. The repository
is the source of truth: every window starts by reading `docs/PROJECT_HANDOFF.md` and ends by updating
it. Module names refer to `docs/IOS_ARCHITECTURE.md` §2.

Global rules for every window: no model training or fine-tuning without a separate written approval
request (model, data, M1 Max time estimates best/conservative, resources, benefit, checkpoint plan,
maximum time requested); no large downloads without approval; no fabricated results; distinguish
Simulator, Mac and physical-iPhone evidence.

---

## Window 1 — Repository Audit, Redesign, Native iOS Foundation ✅ (2026-10-09)

Delivered: audit, architecture, `HearingSenseAudio` module + tests, SwiftUI app with real microphone
capture, level meter, route diagnostics, event log, four session policies, background-audio mode;
device tests T1–T4 on iPhone 18 Pro + AirPods Pro + Spotify. See `PROJECT_HANDOFF.md`.

## Window 2 — Real-Time Sound Analysis and Acoustic Event Detection ◐ (2026-10-09, code complete; device tests open)

Delivered (details: `docs/WINDOW2_SOUND_ANALYSIS_REPORT.md`):

1. ✅ `HearingSenseDomain`: raw predictions, classification frames, categories, event kinds,
   candidates, confirmed events, updates, environment status.
2. ✅ `SoundEventDetection`: `SoundRecognitionEngine` (`AudioStreamConsumer` →
   `SNAudioStreamAnalyzer` + `SNClassifySoundRequest(.version1)` on an actor-isolated serial queue;
   new analyzer segment on format change), taxonomy, detection policy, temporal detector,
   label catalog, diagnostics.
3. ◐ Label inventory: macOS 27.2 and iOS 27.0 Simulator = 303 labels = taxonomy; **iPhone not yet**.
4. ✅ 303 labels → 50 kinds → 11 categories (`docs/research/SOUND_CATEGORY_MAPPING.md`).
5. ◐ Window 1.5 s / overlap 0.5 chosen offline (1.0/1.5/3.0 compared); latency/CPU measured in the
   Simulator only.
6. ✅ Temporal confirmation (k-of-n, single-window instant confirm, hysteresis, per-kind timeouts,
   competing-label suppression); 37 deterministic tests.
7. ✅ Offline forward-only evaluation (`hs-sound-eval`) on LibriSpeech/GTZAN/DEMAND with Wilson CIs;
   no annotated environmental-event data → no accuracy for alerts/knocks/animals/weather.
8. ◐ Start/stop stall: redundant session calls removed, keep-session experiment added, **not
   measured on the device**.
9. ❌ Open device tests (Window 1 list + Window 2 A–J, L, S): see `docs/testing/WINDOW2_DEVICE_TESTS.md`.

Carry-over before or at the start of Window 3: run the physical tests L, A, B, C, D, H, I, S (one step
at a time) and calibrate the quiet threshold and alert rules from the results.

## Window 3 — Speech Recognition and Apple Foundation Models ◐ (2026-10-09, code complete; works on the iPhone with the screen on; background detection is an open problem)

Device result (2026-10-09, `docs/testing/WINDOW3_TEST_RESULTS.md` §10): live transcript and validated
summary ≈ 2 s after the speech on the iPhone 18 Pro with the screen on. **With the screen locked or
the app in the background Apple's built-in sound classifier fails, so neither Window 2 events nor
speech are detected.** A decision on background detection (options in `docs/PROJECT_HANDOFF.md` §8)
is needed before Window 5 can meet its acceptance criterion.

Delivered (details: `docs/WINDOW3_SPEECH_INTELLIGENCE_REPORT.md`,
`docs/research/SPEECH_INTELLIGENCE_ARCHITECTURE.md`, `docs/testing/WINDOW3_TEST_RESULTS.md`):

1. ✅ `SpeechPipeline`: `PreRollAudioBuffer` (5 s ring on the shared audio clock, as a second consumer
   of the existing microphone tap), `AppleSpeechTranscriber` (`SpeechAnalyzer` + `SpeechTranscriber`,
   one analyzer per utterance), `TranscriptAssembler`.
2. ✅ Activation on speech *candidates* (one classifier window ≥ 0.30) instead of confirmed events,
   starting transcription from buffered audio before the trigger; explicit endpoint (transcript
   stable for 1.6 s).
3. ✅ Model availability and assets: `SpeechTranscriber.isAvailable`, `AssetInventory`; download only
   on a user action. **The iOS Simulator has no `SpeechTranscriber`.**
4. ✅ `SemanticSummary`: Foundation Models guided generation (`SystemLanguageModel.default` only),
   deterministic `SummaryValidator` (negation, grounding, time, length), one corrective retry,
   rule-based transcript-level fallback. `PrivateCloudComputeLanguageModel` is not used.
5. ✅ `SpeechIntelligence`: event-driven coordinator, conversation model with stable `SpeechEventID`,
   duplicate suppression, cancellation and stale-result handling, three output levels.
6. ✅ Speech relevance gate (speech vs. vocal music): stricter activation in a music context and a
   per-utterance `nearbySpeech / speechOverMusic / possiblyMusic` estimate; utterances that are
   probably lyrics are not sent to the language model.
7. ✅ Opt-in transcription switch (off by default), in-memory results with bounded retention, text
   removed on Stop, no text in logs; debug UI (speech card, diagnostics).
8. ✅ Tests (pre-roll buffer, assembler, validator, analyzer, tracker, gate, engine with scripted
   recognizer and model, real recognizer on synthetic speech) and forward-only evaluation
   (`hs-speech-eval`): WER on LibriSpeech, summaries, relevance gate on design/holdout clips,
   real-time end-to-end replay. All on the Mac.
9. ❌ Physical iPhone: nothing in Window 3 has run on the device (availability of both models,
   latency, CPU/memory/battery, AirPods + Spotify, lock screen, Foundation Models in the
   background). Protocol: `docs/testing/WINDOW3_TEST_RESULTS.md` §9.

Carry-over: the Window 2 device tests are still open as well (`docs/testing/WINDOW2_DEVICE_TESTS.md`).

## Research window — Background Acoustic Inference and Model Benchmark ◐ (2026-10-10, Mac work complete; first device runs done, not replicated)

Branch `experiment/background-acoustic-recognition`. Goal: recognize sounds while the iPhone is
locked. Delivered: investigation of the built-in classifier's background failure; YAMNet,
EfficientAT MN10 and DyMN04 converted to Core ML and verified; a common benchmark on 2 280 clips;
`AcousticClassifierBackend` with Apple, Core ML (CPU only) and switching (hybrid) implementations;
Debug-only device experiments. Provisional decision: hybrid (`docs/BACKGROUND_RECOGNITION_DECISION.md`).

**First device runs (2026-10-10, one each):** with the Background-processing mode the built-in
classifier kept running in the background and locked (A2: 342 of ≈ 342 windows in 256.5 s); without
it it failed (A1); CPU-only EfficientAT MN10 kept running but labelled 0 of 6 played clips
(`docs/testing/BACKGROUND_DEVICE_TESTS.md` §7). Window 4 adopted the mode in the app's Info.plist.
**Open:** a repeat (A1 → A2 → A1), the 10-minute run A3, off the charger, with AirPods and Spotify.

## Window 4 — Context-Aware Attention Priority Engine ◐ (2026-10-10, code complete; synthetic evaluation only)

Branch `feature/window4-attention-priority` (from the research branch; device results committed
there first). Delivered: `Attention` module (deterministic engine: priority assessment with reason
codes, three modes, preferences, temporal fusion, deduplication, cooldowns, presentation budget,
scheduler decisions SHOW / UPDATE / SUPPRESS / DEFER / RESOLVE / EXPIRE), the output contract
`AttentionEvent` / `AttentionPresentationIntent`, `AttentionReplay` + `hs-attention-eval` (18
scripted scenes, generated long scene, baseline, metrics), app integration (`AttentionController`,
attention card, settings, decisions screen with synthetic injection), 65 tests. The
Background-processing mode from experiment A2 is now in the app's Info.plist.
Report: `docs/WINDOW4_ATTENTION_PRIORITY_REPORT.md`.

**Open:** no physical-iPhone test of Window 4; all evaluation input is synthetic. Before Window 5
relies on the lock screen: repeat A1 → A2, run A3 (10 minutes locked) with the new default build,
and one live session with real sounds (each needs the student's authorization).

## Window 5 — Dynamic Island and Native iOS Experience ◐ (2026-10-10, code complete; Mac and Simulator with synthetic events only)

Branch `feature/window5-dynamic-island` (from the Window 4 branch). Delivered, following the
student's two briefs of 2026-10-10 (two-channel presentation; never wake a locked screen):
`IslandPresentation` (SF Symbol catalog for all 303 labels, `AmbientIconStream`, `IslandPipeline`,
`AlertGate`), `IslandViews` (activity attributes and the shared SwiftUI pieces), the widget
extension target `HearingSenseWidgets`, `LiveActivityController` with settings, an in-app mirror
and mic-free demo scenes, `hs-attention-eval island`, 47 tests. Ordinary sounds are an icon;
attention episodes carry text in the expanded island; the Lock Screen is icon-only; updates are
silent; automatic expansion is off by default because the lock state can only be estimated.
Report: `docs/WINDOW5_DYNAMIC_ISLAND_REPORT.md`; results and device protocol:
`docs/testing/WINDOW5_TEST_RESULTS.md`.

Device steps D1–D4 (synthetic demo scenes, microphone off) were run on the iPhone 18 Pro on
2026-10-10: rendering as designed, locked screen not woken.

**Open:** the acceptance criterion below asks for real events; D5–D8 need the student's microphone
authorization. Not done from the list below: haptics (left out on purpose), app icon.

Original scope:

Goal: present decisions without overwhelming the user.

1. Widget extension target with `ActivityAttributes`; Lock Screen + Dynamic Island
   (compact/minimal/expanded) views; event-driven updates only.
2. Start the Live Activity on Start Listening (foreground); update from the background session;
   verify behaviour while Spotify's Now Playing occupies the Island.
3. Haptics, accessible event history, settings (categories, sensitivity, transcription opt-in).
4. Verify Live Activity limits (lifetime, update budget) against current Apple documentation.
5. App icon/branding refresh (current icon is a placeholder).

Acceptance: real events from W2–W4 appear on Lock Screen / Dynamic Island on the iPhone.

Input: `AttentionController.onIntent` / `.presented` (Window 4; contract in
`docs/research/ATTENTION_ENGINE_ARCHITECTURE.md` §8). Show `title` / `subtitle` on the lock screen;
`privateDetail` only with the user's opt-in. The decisions screen can drive the presentation with
synthetic events.

Depends on background recognition: one device run (A2) showed the built-in classifier running on a
locked iPhone with the Background-processing mode, which the app now declares. Repeat it and run A3
before treating the lock screen as working (otherwise restrict the acceptance criterion to the
foreground).

## Window 6 — Integration, Evaluation and Optimization

1. End-to-end scenarios on the device (street, café, home, announcements) with written protocols.
2. Battery, thermal, memory over 60 min; background survival.
3. Accuracy/latency report with honest limitations; science-fair materials.
4. Optional: `HearingSenseMusic.mlpackage` as a "music context" detail (CC BY-NC-SA), only if useful.

---

## Dependencies between windows

```
W1 ──▶ W2 ──▶ W3 ──┐
        │          ├──▶ W5 ──▶ W6
        └──▶ W4 ───┘
```

- W2 must land `HearingSenseDomain` first; W4 can then proceed in parallel with W3.
- W5 needs W4's decisions (can prototype with scripted events earlier).

## Parallel development

1. Git initialized in Window 2 (baseline commits on `main`; Window 2 on `feature/window2-sound-analysis`).
2. One branch per window (`feature/window2-sound-analysis`, `feature/window3-speech-intelligence` (branched from the Window 2 branch), …) and, if two windows run at once, separate
   worktrees (`git worktree add ../hs-w4 window-4-attention`).
3. Ownership to avoid conflicts: each window edits only its own module folder plus additive entries
   in `Package.swift`, the app's orchestration code, and its own section of the handoff.
   Xcode synchronized folders mean new Swift files need no `project.pbxproj` edits.
