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

## Window 3 — Speech Recognition and Apple Foundation Models

Goal: event-driven speech understanding with privacy controls.

1. `SpeechPipeline`: pre-roll ring buffer (2–3 s; W2 speech events confirm ≈ 2.25 s after onset),
   gate with `SpeechDetector` and/or W2 `speech` events (`ConfirmedAcousticEvent.kind.id == "speech"`), then run `SpeechAnalyzer` + `SpeechTranscriber` only for speech segments.
2. Locale/asset management with `AssetInventory`; handle "model not installed" states.
3. Opt-in transcription toggle (off by default), in-memory transcripts with retention limit, delete-all.
4. `SemanticSummary`: check `SystemLanguageModel.default.availability`; guided generation of 2–3 word
   labels and one-line summaries; deterministic fallback (keyword rules) when unavailable.
   Do not use `PrivateCloudComputeLanguageModel`.
5. Measure on device: transcription latency, battery impact of gating vs. always-on.

Acceptance: speech near the user produces a short on-device summary or a clear fallback; nothing is
persisted unless the user opts in.

## Window 4 — Attention Priority Engine

Goal: decide what deserves attention, deterministically.

1. `AttentionEngine` (Domain-only dependency) consuming `ConfirmedAcousticEvent` /
   `AcousticEventUpdate`: score = f(category/kind priority, `EventQuality`, confidence, duration,
   novelty, repetition, recency, user preferences, context such as "media playing").
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
2. One branch per window (`feature/window2-sound-analysis`, `feature/window3-…`, …) and, if two windows run at once, separate
   worktrees (`git worktree add ../hs-w4 window-4-attention`).
3. Ownership to avoid conflicts: each window edits only its own module folder plus additive entries
   in `Package.swift`, the app's orchestration code, and its own section of the handoff.
   Xcode synchronized folders mean new Swift files need no `project.pbxproj` edits.
