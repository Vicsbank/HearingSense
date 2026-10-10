# Background Recognition — Decision Record

Research window between Window 3 and Window 4. Date: 2026-10-10.
Branch `experiment/background-acoustic-recognition`.

**Status: provisional.** The Mac-side evidence is complete. The physical-iPhone experiments that
decide whether *anything* classifies sound on a locked iPhone have **not been run**
(`docs/testing/BACKGROUND_DEVICE_TESTS.md`). The recommendation below is what the available
evidence supports and states exactly which device results would confirm or overturn it.

Evidence: `docs/research/BACKGROUND_INFERENCE_INVESTIGATION.md` (Apple),
`docs/research/AUDIO_MODEL_COMPARISON.md` (models, conversion),
`docs/research/BACKGROUND_MODEL_BENCHMARK.md` (accuracy on common data).

---

## 1. The six research questions

| | Question | Answer today | Basis |
|---|---|---|---|
| A | Can Apple's built-in classifier run reliably while the iPhone is locked? | **Not in the shipping configuration** (measured in Window 3). Whether the Background-processing mode changes that is untested; other developers contradict each other | Physical iPhone (W3); experiment A2 pending |
| B | Can a lightweight third-party classifier run continuously on CPU-only Core ML? | **On the Mac yes**, at 0.3–2.7 % of one core. **In the background on the iPhone: not tested** | Mac; experiment B pending |
| C | Which third-party model recognizes Hearing Sense's sounds best? | On 2-second windows: **EfficientAT MN10 with the window repeated into its 10 s input** (78 % top-1, 86 % alert-event recall). YAMNet is faster and simpler but clearly less accurate (69 %, 76 %) | Mac, recorded files |
| D | Does a third-party model keep AirPods playback undisturbed in the background? | **Not tested.** Nothing in the design touches the audio session: the model is one more consumer of the existing microphone tap | experiment B-F pending |
| E | Would replacing Apple's classifier cost accuracy, latency or power? | **Accuracy: yes at short windows** — Apple 84 % vs 78 % / 69 % top-1 at 2 s, outside the confidence intervals. Event detection for alert sounds: level for MN10 + tile. **Latency: +0.2 s** for MN10 + tile. **Power: unknown** | Mac; device pending |
| F | Apple only, third-party only, or hybrid? | **Hybrid**, if experiment B passes (§3) | this document |

## 2. Options against the criteria

| Criterion | A — Apple only | B — third-party only | C — hybrid |
|---|---|---|---|
| Background reliability | fails today; open only if A2 succeeds | untested on the iPhone; the compute units are under the app's control | as B in the background |
| Recognition quality, 1–2 s windows | best measured (84 % at 2 s) | 6 points lower (MN10 + tile) to 15 lower (YAMNet) | Apple's in the foreground, B's in the background |
| Important-event recall (alert kinds, streams) | 85 % | 86 % (MN10 + tile, 2 s), 76 % (YAMNet) | as each side |
| False alerts (stress figure) | 1 / h | 1–2 / h | as each side |
| Detection delay | 0.82 s | 1.02 s (MN10 + tile), 0.81 s (YAMNet) | as each side |
| CPU and memory | system-chosen; app CPU 8–10 % on the iPhone (W3) | Mac: 0.3 % (YAMNet) to 2.7 % (MN10 + tile) of a core; iPhone unknown | background side only while in the background |
| Battery, heat | not measured over long runs | unknown | unknown |
| License | Apple SDK | YAMNet Apache 2.0; EfficientAT MIT; both trained on AudioSet | both |
| App size | 0 | +16 MB (YAMNet) or +24 MB (MN10) | same as B |
| Integration | done | done (`CoreMLSoundClassifierBackend`); thresholds need calibration | done (`SwitchingClassifierBackend`), tested with scripted and real models on the Mac |
| Maintenance | none; behaviour can change with iOS | own model, own conversion, own thresholds | both, plus two label sets and two threshold sets |
| Consistency of events | one model | one model | an event can be confirmed by one model and continued by the other; scores are not comparable across the switch |

No single score is computed from these rows: any weighting would decide the answer, and the two
rows that matter most (background reliability, power) are still empty.

## 3. Recommendation

**Option C, hybrid: Apple SoundAnalysis in the foreground, EfficientAT MN10 (2 s window repeated
into the 10 s input, Core ML, CPU only) in the background — conditional on experiment B.**

Why not Apple only: it does not classify in the background, the built-in classifier's compute
units cannot be set, and the one configuration change with a technical rationale (A2) has
contradictory reports. If A2 works for ten minutes locked (A3), this recommendation changes to
Option A, because it would be the simplest and the most accurate. That is the first thing to
test.

Why not third-party only: on the windows the app actually uses, Apple's classifier is measurably
better (84.0 % [82.0, 85.9] against 78.2 % [75.8, 80.5] at 2 s), costs no app size and needs no
calibration. Giving that up in the foreground buys only consistency. Replacing Apple everywhere
would be justified if a third-party model matched it at 1–2 s; none tested here does.

Why MN10 + tile and not YAMNet in the background: alert-event recall 86 % against 76 %, glass
breaking 96 % against 54 %, crying 88 % against 67 %; both find speech (93 % and 97 %). The price
is ten times the CPU work per result and 0.2 s more delay. **YAMNet is the fallback** if MN10's
cost on the iPhone (B-L, B-D, B-E) is too high: it runs natively on one second, costs a tenth, and
still restores the speech trigger and the sirens, horns and alarms.

Why not DyMN04: fewer parameters, but slower than MN10 on the CPU and less accurate at every
length below 10 s.

What the recommendation rests on, and what would change it:

| Device result | Consequence |
|---|---|
| A2 / A3: built-in classifier keeps classifying when locked with the Background-processing mode | Option A; no third-party model needed. Check App Review implications of declaring a mode the app does not use for `BGProcessingTask` before shipping |
| B: CPU-only Core ML keeps producing correct results for 10 and 30 minutes locked, with AirPods and Spotify, at acceptable CPU and battery cost | Option C as recommended |
| B passes for YAMNet but MN10 is too expensive | Option C with YAMNet |
| B fails: CPU-only Core ML also stops in the background | **The blocker remains.** Neither a model change nor a supported configuration solves it; remaining routes are a non-Core-ML CPU implementation (for example a hand-written or Accelerate/BNNS network, or TensorFlow Lite), a speech-only trigger without a classifier, or foreground-only operation stated honestly |

## 4. What is already built for the recommended option

| Piece | State |
|---|---|
| `AcousticClassifierBackend` with Apple and Core ML implementations | implemented, tested |
| `SwitchingClassifierBackend`: one continuous segment and audio clock, switch on app phase, hand-over when the primary fails, primary retried only when selected again | implemented; tested with scripted backends and with the real Apple + YAMNet pair on a recording (Mac) |
| Merged taxonomy (Apple + AudioSet labels → the same 50 kinds), so one event continues across the switch | implemented, tested |
| App: `--hs-classifier hybrid-mn10 \| hybrid-yamnet \| hybrid-dymn04` (Debug builds), selection driven by the scene phase | implemented, builds; **not run on the iPhone** |
| Window 3 speech pipeline on either backend (taxonomy and vocal-music labels passed in) | implemented, builds; existing tests pass |
| Thresholds for the AudioSet models in `DetectionPolicy` | **not done**: the app uses Apple's thresholds for them (§5) |

The production default is unchanged: without a launch argument the app runs Apple's classifier
exactly as at the end of Window 3. Nothing was removed.

## 5. Known limitations and open work

1. **No device evidence yet** for anything in the background. Highest priority.
2. **Thresholds are not calibrated for the third-party models.** The benchmark used per-model,
   per-kind thresholds from a development split; the app's `DetectionPolicy` still holds Apple's
   values (enter 0.4–0.5). Speech activation (`candidateScore` 0.30, `strongSpeechScore` 0.90) and
   the speech relevance gate were also tuned on Apple's scores. Until calibrated, the background
   side can under- or over-fire. Calibration needs recordings made by the phone (authorization
   required) or at least the benchmark's development split.
3. **Two models, two behaviours.** An event confirmed in the foreground can be judged
   differently after the switch; Window 4 must not assume scores are comparable across models
   (each frame and event carries its model id).
4. **The benchmark is clean, close, single-source audio** from one dataset with 24 test clips per
   kind and no event timestamps. It ranks models; it does not predict field accuracy.
5. **Power and heat of continuous CPU inference are unknown.**
6. **MN10's short-input failure is worked around, not fixed.** Repeating a 2 s window is an
   inference-time trick that happened to work on this data. Training a short-window model would be
   the proper fix and would need a separate training approval; it is not proposed now.
7. Wind, rain and clapping are weak for the third-party models (wind and rain for Apple too).
8. The Release build currently carries the experiment's model files as inert resources (the
   switch itself is Debug-only). Remove them from the bundle or make the feature real before any
   release.

## 6. Next steps before Window 4

1. Connect the iPhone; run A1 and A2 (3 minutes each), then A3 or B according to §3.
2. If B passes: B-D (10 min), B-F (AirPods + Spotify), B-L (latency of the three models), B-E
   (30 min off the charger).
3. Fill in `docs/testing/BACKGROUND_DEVICE_TESTS.md`, then finalize this document (remove
   "provisional").
4. Calibrate thresholds for the chosen background model.
5. Decide, with the student, whether to merge this branch; then start Window 4.
