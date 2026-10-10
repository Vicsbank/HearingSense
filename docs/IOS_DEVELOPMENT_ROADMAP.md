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

## Window 3 — Speech Recognition and Apple Foundation Models ◐ (2026-10-09, code complete; physical-iPhone tests pending)

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

## Window 4 — Attention Priority Engine

Goal: decide what deserves attention, deterministically.

1. `AttentionEngine` (Domain-only dependency) consuming `ConfirmedAcousticEvent` /
   `AcousticEventUpdate` and (W3) `SpeechSemanticResult`: score = f(category/kind priority,
   `EventQuality`, confidence, duration, novelty, repetition, recency, user preferences, context
   such as "media playing"). For speech: `level`, `category`, `details`, `summary.reliability`,
   `transcript.quality`, `acousticContext.relevance` (`possiblyMusic` → lowest priority), keyed by
   `SpeechEventID`, notifying on `summaryRevision` changes only.
2. Temporal confirmation, per-category cooldowns, rate limiting, quiet hours.
3. Configuration as data (JSON/Codable) with a settings UI hook.
4. Exhaustive unit tests with scripted event sequences (runs on the Mac via `swift test`).
5. Optional: LLM output may add context but never overrides the deterministic decision.

Acceptance: documented scoring table; tests covering cooldown, escalation and suppression.

## Window 5 — Dynamic Island and Native iOS Experience

Goal: present decisions without overwhelming the user.

1. Widget extension target with `ActivityAttributes`; Lock Screen + Dynamic Island
   (compact/minimal/expanded) views; event-driven updates only.
2. Start the Live Activity on Start Listening (foreground); update from the background session;
   verify behaviour while Spotify's Now Playing occupies the Island.
3. Haptics, accessible event history, settings (categories, sensitivity, transcription opt-in).
4. Verify Live Activity limits (lifetime, update budget) against current Apple documentation.
5. App icon/branding refresh (current icon is a placeholder).

Acceptance: real events from W2–W4 appear on Lock Screen / Dynamic Island on the iPhone.

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
