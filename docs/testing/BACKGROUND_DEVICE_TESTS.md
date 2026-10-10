# Background Recognition — Physical-Device Tests

Device: iPhone 18 Pro (iPhone19,2), iOS 27.2, AirPods Pro, Spotify. Mac: MacBook Pro M1 Max.
Branch `experiment/background-acoustic-recognition`.

**Status on 2026-10-10: no test in this document has been run.** The student approved the tests
"for later" on 2026-10-10; the iPhone was not connected to the Mac when the software was ready
(`xcrun devicectl list devices` reported it as *unavailable*). Everything below is the plan and
the tooling. No row may be read as a result until its "Result" cell is filled in from a
diagnostics file of an actual run.

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
| A1 | `audio` | Built-in classifier (production) | | | | **not run** |
| A1 | `audio` | Direct Core ML, `cpuOnly` | | | | **not run** |
| A1 | `audio` | Direct Core ML, `cpuAndGPU` | | | | **not run** |
| A1 | `audio` | Direct Core ML, `cpuAndNeuralEngine` | | | | **not run** |
| A1 | `audio` | Direct Core ML, `all` | | | | **not run** |
| A1 | `audio` | SoundAnalysis + custom model, `cpuOnly` | | | | **not run** |
| A1 | `audio` | SoundAnalysis + custom model, `cpuAndGPU` | | | | **not run** |
| A1 | `audio` | `BGTaskScheduler.supportedResources` contains `.gpu` | | | | **not run** |
| A2 | `audio` + `processing` | all lanes above | | | | **not run** |
| A3 | configuration that worked in A2, if any | built-in classifier, 10 min locked | | | | **not run** |

## 5. Experiment B — third-party model, Core ML, CPU only

Model: the one recommended in `docs/BACKGROUND_RECOGNITION_DECISION.md`; the others only if the
first fails or for the latency table.

| ID | Scenario | Duration | AirPods / Spotify | What is recorded | Result |
|---|---|---|---|---|---|
| B-A | Foreground inference on real microphone audio; a dog bark, a knock, a siren and a spoken sentence from the Mac speakers | 2 min | no | windows, labels of the played sounds, inference time | **not run** |
| B-B | Start, then another app in front | 2 min | no | criteria 1–6 | **not run** |
| B-C | Start, then lock | 2 min | no | criteria 1–6 | **not run** |
| B-D | Locked | 10 min | no | criteria 1–5, CPU, memory, thermal state | **not run** |
| B-E | Locked, **off the charger** | 30 min | no | as B-D plus battery level at start and end | **not run** (only if B-D passes) |
| B-F | Locked, AirPods Pro with noise cancellation, Spotify playing | 5 min | yes | criteria 1–6; whether the music stutters (student); whether the route stays A2DP | **not run** |
| B-G | Hybrid (`hybrid-mn10`): foreground → locked → foreground | 3 min | no | `model=` changes to the CPU model within about a second of the background and back; windows keep their rate; one audio clock; no duplicated events; no classifier failure logged | **not run** |
| B-H | Interruption (a phone call or Siri) and AirPods removed mid-session | — | yes | recovery; only with the student's separate agreement | **not run** |
| B-L | Inference time of the three models on the iPhone CPU (foreground) | 1 min each | no | mean / median / p95 / max per window | **not run** |

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
