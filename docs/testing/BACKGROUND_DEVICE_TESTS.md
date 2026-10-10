# Background Recognition — Physical-Device Tests

Device: iPhone 18 Pro (iPhone19,2), iOS 27.2, AirPods Pro, Spotify. Mac: MacBook Pro M1 Max.
Branch `experiment/background-acoustic-recognition`.

**Status on 2026-10-10 (second session): A1, A2 and a short CPU-only run (parts of B-A, B-C, B-L)
were run once each on the physical iPhone; results in §7, raw diagnostics in
`results/device_background/`.** Everything else (A3, B-B, B-D to B-H, the other two models) has
not been run. A row is a result only where its "Result" cell is filled in from a diagnostics file.

Headline: with `UIBackgroundModes = audio` Apple's built-in classifier fails in the background and
when locked (as in Window 3); **with `audio` + `processing` it kept working in both** and
recognized three played sounds while the iPhone was locked. The CPU-only EfficientAT MN10 kept
running when locked but did not label the same three sounds correctly. One run per configuration;
not replicated yet.

Simulator and Mac runs are not a substitute: other developers report that the background failure
does not occur in the Simulator.

---

## 1. Rules for these tests

- One manual step per message to the student (lock, unlock, put AirPods in).
- The microphone is on only during a run the student has agreed to; each run is started from the
  Mac and ended from the Mac (`--terminate-existing` relaunch without `--hs-autostart`).
- Speech transcription stays **off** (the app default). No transcript can be produced or stored.
- Sounds are played from the Mac's speakers only after asking; they are dataset clips or synthetic
  sentences, never a conversation.
- The export holds counters, timings, states and the event log. No audio, no transcripts.
- Screenshots only while Hearing Sense is in the foreground.

## 2. Tooling

| Tool | Purpose |
|---|---|
| `--hs-autostart` | start listening right after launch (Debug builds) |
| `--hs-export-diagnostics` | rewrite `Documents/hearing-sense-diagnostics.txt` every 5 s; readable from the Mac while the phone is locked |
| `--hs-bg-probe` | background inference probe (random-weight model; counts executions per compute unit and per app phase) |
| `--hs-classifier yamnet \| mn10 \| dymn04` | run a converted third-party model through `CoreMLSoundClassifierBackend` (Core ML, CPU only) instead of Apple's classifier |
| `--hs-classifier hybrid-mn10 \| hybrid-yamnet \| hybrid-dymn04` | Apple's classifier in the foreground, the third-party model in the background (`SwitchingClassifierBackend`); the heartbeat's `model=` field shows which one produced the latest window |
| `tools/experiments/audio_models/install_app_models.sh` | copy the converted models into the app before building (they are not in the repository) |
| `apps/ios/Config/Experiments/HearingSense-Info-processing.plist` | Info.plist variant with the Background-processing mode, used with `xcodebuild INFOPLIST_FILE=…` |

Each 5-second heartbeat line carries: app state, lock state, classifier windows, analyzer
segments, classifier failures, mean model inference time, dropped buffers, largest backlog,
process CPU since the previous heartbeat (100 % = one core), memory footprint, thermal state,
battery level and charging state, and the probe's per-lane success/failure counts.

```bash
D=<UDID>                                    # xcrun devicectl list devices
tools/experiments/audio_models/install_app_models.sh
xcodebuild -project apps/ios/HearingSense.xcodeproj -scheme HearingSense -configuration Debug \
  -destination "id=$D" -derivedDataPath <dir> -allowProvisioningUpdates build
xcrun devicectl device install app --device $D <dir>/Build/Products/Debug-iphoneos/HearingSense.app
# A1: shipping configuration + probe
xcrun devicectl device process launch --device $D --terminate-existing org.hearingsense.HearingSense \
  --hs-autostart --hs-export-diagnostics --hs-bg-probe
# put the app in the background from the Mac (the phone must be unlocked)
xcrun devicectl device process launch --device $D com.apple.Preferences
# read the diagnostics (works while locked)
xcrun devicectl device copy from --device $D --domain-type appDataContainer \
  --domain-identifier org.hearingsense.HearingSense \
  --source Documents/hearing-sense-diagnostics.txt --destination a1.txt
# B: third-party model on the CPU
xcrun devicectl device process launch --device $D --terminate-existing org.hearingsense.HearingSense \
  --hs-autostart --hs-export-diagnostics --hs-classifier yamnet
# microphone off
xcrun devicectl device process launch --device $D --terminate-existing org.hearingsense.HearingSense
```

## 3. What counts as success

A background test passes only if, for the whole background or locked interval, **all** of these
hold in the diagnostics file:

1. microphone buffers keep arriving (capture coverage ≈ 100 %);
2. the number of classifier windows grows at the expected rate (interval ÷ hop);
3. classifier failures do not grow;
4. window timestamps continue on the session audio clock (no restart, no gap);
5. dropped buffers stay 0 and the largest backlog stays small (no growing queue);
6. for the third-party model: a known sound played during the interval appears as a classifier
   window with the matching label (real recognition, not only "a result arrived").

Buffers arriving (1) without (2) is the failure seen in Window 3, not a pass.

## 4. Experiment A — Apple's classifier and the probe

Purpose and lanes: `docs/research/BACKGROUND_INFERENCE_INVESTIGATION.md` §6. Each run: 60 s in the
foreground, 60 s in the background (another app in front, unlocked), 60 s locked, back to the
foreground. Room sound only; no AirPods or Spotify needed.

| ID | Build | Lane | Foreground | Background | Locked | Result |
|---|---|---|---|---|---|---|
| A1 | `audio` | Built-in classifier (production) | works | **fails** | **fails** | error 2 from 0.8 s after entering the background; 1 window of ≈ 277 expected in 208 s (background + locked); 45 failures; recovered 4.6 s after returning |
| A1 | `audio` | Direct Core ML, `cpuOnly` | 94 / 0 | 118 / 0 | 90 / 0 | runs everywhere |
| A1 | `audio` | Direct Core ML, `cpuAndGPU` | 94 / 0 | 118 / 0 | 90 / 0 | runs everywhere, **but on the CPU** (see §7.3) |
| A1 | `audio` | Direct Core ML, `cpuAndNeuralEngine` | 94 / 0 | 118 / 0 | 90 / 0 | runs everywhere, on the CPU (§7.3) |
| A1 | `audio` | Direct Core ML, `all` | 94 / 0 | 118 / 0 | 90 / 0 | runs everywhere, on the CPU (§7.3) |
| A1 | `audio` | SoundAnalysis + custom model, `cpuOnly` | 193 / 0 | 239 / 0 | 186 / 0 | runs everywhere |
| A1 | `audio` | SoundAnalysis + custom model, `cpuAndGPU` | 192 / 0 | 240 / 0 | 186 / 0 | runs everywhere, on the CPU (§7.3) |
| A1 | `audio` | `BGTaskScheduler.supportedResources` contains `.gpu` | — | — | — | **no** (rawValue 0) |
| A2 | `audio` + `processing` | Built-in classifier (production) | works | **works** | **works** | 342 windows of ≈ 342 expected in 256.5 s (background + locked), 0 failures, 12 events confirmed |
| A2 | `audio` + `processing` | the six probe lanes | 86 / 0 (direct), 176 / 0 (SoundAnalysis) | 81 / 0, 168 / 0 | 175 / 0, 357 / 0 | unchanged from A1: all run, no failure |
| A3 | `audio` + `processing` | built-in classifier, 10 min locked | | | | **not run** |

Cells are "succeeded / failed" executions of the probe model. Each configuration was run once.

## 5. Experiment B — third-party model, Core ML, CPU only

Model: the one recommended in `docs/BACKGROUND_RECOGNITION_DECISION.md`; the others only if the
first fails or for the latency table.

| ID | Scenario | Duration | AirPods / Spotify | What is recorded | Result |
|---|---|---|---|---|---|
| B-A | Foreground inference on real microphone audio; a dog bark, a knock, a siren and a spoken sentence from the Mac speakers | 2 min | no | windows, labels of the played sounds, inference time | **partly run** (MN10, ≈ 70 s, three clips, no sentence): inference fine, 0 of 3 clips labelled correctly (§7.4) |
| B-B | Start, then another app in front | 2 min | no | criteria 1–6 | **not run** |
| B-C | Start, then lock | 2 min | no | criteria 1–6 | **partly run** (MN10, ≈ 65 s locked): criteria 1–5 met, criterion 6 **not met** (0 of 3 clips, §7.4) |
| B-D | Locked | 10 min | no | criteria 1–5, CPU, memory, thermal state | **not run** |
| B-E | Locked, **off the charger** | 30 min | no | as B-D plus battery level at start and end | **not run** (only if B-D passes) |
| B-F | Locked, AirPods Pro with noise cancellation, Spotify playing | 5 min | yes | criteria 1–6; whether the music stutters (student); whether the route stays A2DP | **not run** |
| B-G | Hybrid (`hybrid-mn10`): foreground → locked → foreground | 3 min | no | `model=` changes to the CPU model within about a second of the background and back; windows keep their rate; one audio clock; no duplicated events; no classifier failure logged | **not run** |
| B-H | Interruption (a phone call or Siri) and AirPods removed mid-session | — | yes | recovery; only with the student's separate agreement | **not run** |
| B-L | Inference time of the three models on the iPhone CPU (foreground) | 1 min each | no | mean / median / p95 / max per window | **MN10 only**: 32.8 / 33.0 / 35.6 / 41.6 ms over 156 windows (foreground, background and locked together); YAMNet and DyMN04 not run |

At least B-D is launched with `devicectl` and no debugger attached (that is how all runs above are
started; Xcode is not involved).

## 6. Measurements available without the iPhone (Mac, for orientation only)

These are **Mac** numbers (M1 Max, Core ML restricted to the CPU, one prediction at a time). They
show that the models are far faster than real time on a laptop CPU; they do not predict iPhone
latency, power or thermal behaviour.

| Model | Window | Hop used | Inference per window, median / p95 / max | Share of one core at that hop |
|---|---|---|---|---|
| YAMNet | 0.975 s | 0.4875 s | 1.39 / 1.64 / 3.42 ms | ≈ 0.3 % |
| EfficientAT MN10, 1 s (unusable: scores saturate; for reference) | 1 s | 0.5 s | 2.86 / 3.83 / 6.83 ms | ≈ 0.6 % |
| EfficientAT DyMN04 | 1 s | 0.5 s | 4.31 / 5.13 / 8.72 ms | ≈ 0.9 % |
| EfficientAT MN10, 2 s window repeated into its 10 s input (the recommended configuration; the app's `mn10`) | 2 s | 0.5 s | 13.54 / 14.41 / 17.41 ms | ≈ 2.7 % |

Source: `swift run -c release hs-model-bench coreml …` through the production
`CoreMLSoundClassifierBackend` on 152 benchmark streams (≈ 2 900–3 000 windows each). The share of
a core counts the model call only, not resampling or the detector.

## 7. Results of 2026-10-10 (physical iPhone 18 Pro, iOS 27.2)

Three runs, one each, started from the Mac with `devicectl`; no debugger. The iPhone stayed on USB
(charging, battery 100 %), so there are no battery figures. Room sound only, plus dataset clips
from the Mac speakers where stated (the student agreed to both, and to the microphone, in this
session). Speech transcription was off. Foreground checks, the transcription switch and returning
to the app were done with iphone-use; locking and unlocking by the student. Times are UTC.

| Run | File in `results/device_background/` | Build | Launch arguments | Foreground / background / locked |
|---|---|---|---|---|
| A1 | `01_a1_audio_only.txt` | `audio` | `--hs-autostart --hs-export-diagnostics --hs-bg-probe` | ≈ 70 s / ≈ 120 s / ≈ 85 s, then ≈ 20 s foreground |
| A2 | `02_a2_audio_processing.txt`, `02_a2_playback_locked.log` | `audio` + `processing` (`INFOPLIST_FILE=Config/Experiments/HearingSense-Info-processing.plist`) | the same | ≈ 70 s / ≈ 80 s / ≈ 170 s, then ≈ 20 s foreground |
| B (MN10) | `03_mn10_cpu_only.txt`, `03_mn10_playback_*.log` | `audio` | `--hs-autostart --hs-export-diagnostics --hs-classifier mn10` | ≈ 65 s / ≈ 10 s / ≈ 80 s |

`00_a1_aborted_start.txt` is the first start of A1, stopped after about 17 s because the app's
"Transcribe nearby speech" switch was still on from Window 3. That file shows 0 activations and
0.0 s of audio transcribed. The switch was turned off before the runs above and is off on the
phone now.

### 7.1 Apple's built-in classifier

| | A1 (`audio`) | A2 (`audio` + `processing`) |
|---|---|---|
| Foreground | ≈ 1.33 windows/s, 0 failures | the same |
| Background + locked | `com.apple.SoundAnalysis` error 2, first 0.8 s after `App entered background`; 1 window of ≈ 277 expected in 208.0 s; a new analyzer about every 4.8 s, each failing | 342 windows of ≈ 342 expected in 256.5 s; 1 analyzer segment for the whole run; 0 failures |
| Microphone capture in that interval | coverage 100 %, 0 dropped buffers | coverage 100 %, 0 dropped buffers |
| Events confirmed in that interval | 0 | 12 |
| Return to the foreground | recovered after 4.6 s (45 failures counted) | nothing to recover |
| Inference per window (foreground + where it ran) | mean 16.9 ms, p95 23.0 ms | mean 14.3 ms, p95 17.3 ms |
| Largest backlog | 5 (at recovery) | 1 |

A1 reproduces the Window 3 failure. A2 meets criteria 1–5 of §3 for the built-in classifier.

### 7.2 Recognition while locked

One round of three ESC-50 clips (5 s each, 5 s apart) from the Mac's built-in speakers at output
volume 75 % (the distance to the phone was not measured). `1-100032-A-0.wav` (dog), `1-31482-A-42.wav` (siren),
`1-101336-A-30.wav` (door knock).

| Clip | Built-in classifier, A2, locked | MN10 CPU-only, `audio` build, foreground | MN10 CPU-only, `audio` build, locked |
|---|---|---|---|
| dog | Dog [`dog`] peak 0.72 | no event | Wild animal [`Frog`] 0.69 |
| siren | Siren [`emergency_vehicle`] peak 0.96 | no event | no event |
| door knock | Door or knock [`knock`] peak 0.98; also Music [`music`] 0.63 | Music [`Music`] 0.77 | Music [`Music`] 0.74 |
| correct | 3 of 3 (one extra event) | 0 of 3 | 0 of 3 |

The built-in classifier was not given the clips in the foreground in this session, and A1 has no
locked recognition to compare (the classifier does not run there). Room sounds were also confirmed
while locked in A2 (for example `nose_blowing` 0.74, `door` 0.57); their ground truth is unknown.

This is one clip per class through a loudspeaker. It shows that MN10 as configured (2 s window
repeated into the 10 s input, the detection policy written for Apple's labels) is not usable as it
stands on live microphone audio; it is not a measurement of the model's accuracy. Why it differs
from the file benchmark (`docs/research/BACKGROUND_MODEL_BENCHMARK.md`) is not known: candidates
are the acoustic path (speaker, room, iPhone microphone, 48 → 32 kHz resampling) and the event
thresholds. Per-window top labels are not in the export, so this run cannot tell them apart.

### 7.3 The probe and the GPU hypothesis

All six probe lanes ran in the foreground, in the background and when locked, in both builds,
without a single failure. **This does not show that GPU work is allowed in the background.** On the
iPhone, `MLComputePlan` assigns all 16 operations of `ProbeTiny` to the CPU under every setting
(`cpuOnly`, `cpuAndGPU`, `cpuAndNeuralEngine`, `all`); on the Mac the same model goes to the GPU.
So no lane submitted GPU or Neural Engine work, and the hypothesis in
`BACKGROUND_INFERENCE_INVESTIGATION.md` §5 is neither confirmed nor refuted.

What the probe does show:

- Core ML on the CPU runs in the background and when locked with `audio` alone.
- SoundAnalysis itself is not restricted: `SNClassifySoundRequest(mlModel:)` with a custom model
  kept producing results in A1 while `SNClassifySoundRequest(classifierIdentifier: .version1)`
  failed on the same buffers. The restriction concerns the built-in classifier.
- `BGTaskScheduler.supportedResources` is empty (no `.gpu`) on the iPhone 18 Pro, iOS 27.2.
- The Background-processing mode changes the built-in classifier's behaviour and nothing else that
  was measured.

Direct-lane inference time of the probe model, mean per phase (A1): `cpuOnly` 7.5 / 7.7 / 5.5 ms,
`cpuAndGPU` 5.1 / 5.4 / 4.6 ms, `cpuAndNeuralEngine` 5.8 / 4.8 / 4.4 ms, `all` 4.6 / 4.5 / 4.6 ms
(foreground / background / locked). The lanes differ although the plan names the CPU for all of
them; the reason was not investigated.

### 7.4 CPU-only EfficientAT MN10 (`audio` build)

| Measure | Value |
|---|---|
| Windows | 156 in 157.1 s of audio (1 per second, 2 s window, 50 % overlap); same rate in the foreground, in the background and when locked |
| Failures, dropped buffers, largest backlog | 0, 0, 1 |
| Model inference per window | mean 32.8 ms, median 33.0 ms, p95 35.6 ms, max 41.6 ms (Mac: median 13.5 ms) |
| Result delay after the window end | mean 136.6 ms, p95 153.6 ms |
| Analysis CPU | 5.9 % of audio time on one core |
| Recognition of the played clips | 0 of 6 (§7.2) |

### 7.5 Process CPU, memory, thermal state

Mean of the 5-second heartbeats; 100 % = one core. The probe adds load in A1 and A2 that the
shipping app does not have, so the rows are not a comparison of the classifiers.

| Run | Foreground | Background | Locked | Memory (locked) | Thermal |
|---|---|---|---|---|---|
| A1 (classifier failing in the background) | 15.9 % | 7.7 % | 6.1 % | ≈ 42 MB | nominal |
| A2 (classifier running) | 16.5 % | 9.6 % | 8.2 % | ≈ 42 MB | nominal |
| MN10, no probe | 13.9 % | 7.0 % (2 heartbeats) | 6.9 % | ≈ 36 MB | nominal |

### 7.6 Limits of these results

- One run per configuration, A1 before A2, minutes not hours. The A2 result has not been repeated
  and the 10-minute run (A3) has not been done. Other developers report both outcomes for the
  Background-processing mode (`BACKGROUND_INFERENCE_INVESTIGATION.md` §4).
- On USB and charging throughout. Behaviour on battery, off the cable, in Low Power Mode or after
  a long time locked is not known.
- No `BGProcessingTask` is scheduled; the mode is only declared. Whether App Review accepts that
  was not looked into.
- No AirPods, no Spotify.
- GPU and Neural Engine execution in the background were not exercised (§7.3).

### 7.7 Open after this session

1. Repeat A1 → A2 (ideally A1 → A2 → A1) to rule out an order effect, then A3 (10 min locked).
2. A2 off the cable and off the charger; then with AirPods and Spotify (B-F with the built-in
   classifier).
3. If a CPU-only model is still wanted: export per-window top labels, run YAMNet and DyMN04 on the
   same clips, and compare with the same clips fed to the model from files.
4. A probe model whose operations the iPhone actually places on the GPU, if the cause is to be
   established rather than worked around.
5. `docs/BACKGROUND_RECOGNITION_DECISION.md` (hybrid with MN10) was written before these runs and
   is the student's to revise.
