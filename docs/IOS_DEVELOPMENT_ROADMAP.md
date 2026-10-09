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

## Window 2 — Real-Time Audio and Apple Sound Analysis

Goal: detect environmental sound events live, on device.

1. Create `HearingSenseDomain` (`AcousticEvent`, `EventCategory`, confidence, timing) — keep it small;
   Window 4 depends on it.
2. `SoundEventDetection`: an `AudioStreamConsumer` wrapping `SNAudioStreamAnalyzer` +
   `SNClassifySoundRequest(.version1)` on a dedicated serial queue; recreate on format change.
3. Enumerate `knownClassifications` **on the iPhone** and compare with
   `docs/research/sound_analysis_labels_v1_macos27.txt`.
4. Map the 303 labels to a small set of user-facing categories (speech, name-worthy voices,
   alarms/sirens, vehicles/horns, doorbell/knock, baby crying, dog, music, other). Document the map.
5. Choose window duration / overlap; measure detection latency and CPU on the device.
6. Temporal smoothing (e.g. k-of-n windows) before emitting events; never emit raw per-window noise.
7. Offline, forward-only evaluation on the Mac with existing data (DEMAND, LibriSpeech, MIT IR via
   `ml/hearing_sense_ml/augment.py`); report with confidence intervals; no training.
8. Fix or explicitly defer the 0.5 s start/stop stall (AUDIO_ROUTING_FEASIBILITY §3).
9. Finish open device tests that affect audio: long background run (≥ 15 min), phone-call
   interruption, AirPods disconnect, Apple Music.

Acceptance: live category events visible in the app on the iPhone with measured latency; label list
verified on iOS; evaluation numbers with provenance.

## Window 3 — Speech Recognition and Apple Foundation Models

Goal: event-driven speech understanding with privacy controls.

1. `SpeechPipeline`: pre-roll ring buffer (2–3 s), gate with `SpeechDetector` and/or the W2 `speech`
   category, then run `SpeechAnalyzer` + `SpeechTranscriber` only for speech segments.
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

1. `AttentionEngine` (Domain-only dependency): score = f(category priority, confidence, duration,
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

1. First initialize Git (needs the student's approval — see PROJECT_HANDOFF "Recommended next steps").
2. One branch per window (`window-2-sound-analysis`, …) and, if two windows run at once, separate
   worktrees (`git worktree add ../hs-w4 window-4-attention`).
3. Ownership to avoid conflicts: each window edits only its own module folder plus additive entries
   in `Package.swift`, the app's orchestration code, and its own section of the handoff.
   Xcode synchronized folders mean new Swift files need no `project.pbxproj` edits.
