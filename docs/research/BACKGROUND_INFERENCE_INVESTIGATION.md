# Background Inference Investigation

Research window between Window 3 and Window 4. Branch `experiment/background-acoustic-recognition`.
Date: 2026-10-10. Forward-only inference; **no training or fine-tuning**.

Question: why does Hearing Sense stop recognizing sounds when the iPhone is locked or the app is in
the background, and what can run there instead?

Evidence classes used in this document:

| Class | Meaning |
|---|---|
| **Physical iPhone** | iPhone 18 Pro, iOS 27.2 (the student's device) |
| **Mac** | MacBook Pro M1 Max, macOS 27.2 — not an iPhone |
| **SDK** | Read from the installed iOS 27.0 SDK headers (Xcode 27.0, build 27A266a) |
| **Build** | Result of an `xcodebuild` run on this Mac |
| **Reported** | Stated by other developers or by Apple documentation; not reproduced here |

Device results of this research window are in `docs/testing/BACKGROUND_DEVICE_TESTS.md`.

---

## 1. The failure (Physical iPhone, measured in Window 3)

From `results/device_window3/*.txt` (2026-10-09), unchanged production code:

| Observation | Value |
|---|---|
| Request | `SNClassifySoundRequest(classifierIdentifier: .version1)` on `SNAudioStreamAnalyzer` |
| Error | "Error during analysis", domain `com.apple.SoundAnalysis`, code 2 (`SNErrorCode.operationFailed`), no underlying error in `userInfo` |
| When | First failure 0.44–1.0 s after `App entered background`; a new analyzer fails again every time |
| Classifier windows in the background | 0 in 48 s locked; 1 instead of ≈ 116 in 87 s in the background (unlocked) |
| Microphone capture in the same interval | continues, coverage 100 % |
| Recovery | by itself when the app returns to the foreground (2.3 s in one measurement) |
| `SpeechTranscriber`, Foundation Models | did run in the background in one trial (language model 6.1 s instead of 0.7 s) |

So background **capture** works and background **classification** does not. They are different
capabilities, and the first says nothing about the second.

## 2. What the app declares (code inspection)

| Item | Value | Source |
|---|---|---|
| `UIBackgroundModes` | `audio` only (at the time of this investigation; `audio` + `processing` since Window 4) | `apps/ios/Config/HearingSense-Info.plist` |
| Entitlements file | none | `project.pbxproj` (no `CODE_SIGN_ENTITLEMENTS`) |
| BackgroundTasks usage | none | no `BGTaskScheduler` call in the app |
| Audio session | `playAndRecord`, mode `default`, `mixWithOthers` + `allowBluetoothA2DP` + `defaultToSpeaker`, built-in microphone preferred | `AudioSessionPolicy.recommended` |
| Analysis thread | private serial queue, QoS `userInitiated`; never the audio tap thread | `SoundAnalysisWorker` |
| Retry | new analyzer after 1, 2, 4 s (back-off) | `SoundAnalysisWorker` |
| Speech watchdog | speech activity ends after 3 s of audio without a classifier window | `SpeechIntelligenceEngine` |

Nothing is missing for background *audio*: the session stays active and buffers arrive.

## 3. What the SDK offers (SDK)

| Question | Finding |
|---|---|
| Can the built-in classifier's compute units be chosen? | No. `SNClassifySoundRequest` has `overlapFactor`, `windowDuration`, `windowDurationConstraint`, `knownClassifications` and two initializers (`mlModel:` and `classifierIdentifier:`). The SoundAnalysis headers contain no mention of compute units, GPU, CPU or background |
| Can a custom model's compute units be chosen? | Yes, through `MLModelConfiguration.computeUnits` before the model is passed to `SNClassifySoundRequest(mlModel:)` or used directly |
| Error detail | `SNErrorCode` has five cases (unknown, operationFailed, invalidFormat, invalidModel, invalidFile); none says why an operation failed |
| `BGContinuedProcessingTask` (iOS 26+) | "A task meant to perform processing on behalf of a user initiated request." It presents UI while in progress, must report progress, and "may be forcibly expired". Default resources: "background CPU and network access" |
| Background GPU | `BGContinuedProcessingTaskRequest.Resources.gpu`; needs the entitlement `com.apple.developer.background-tasks.continued-processing.gpu`; "Background GPU execution is not supported on all devices"; `BGTaskScheduler.supportedResources` reports what the device supports |
| A separate background *inference* entitlement | Not present. The only `com.apple.developer.background-tasks…` string in the iOS 27.0 SDK is the `.gpu` one. `…continued-processing.inference` does not exist in this SDK |

## 4. What other developers report (Reported)

| Source | Content |
|---|---|
| [Apple forums 757715](https://developer.apple.com/forums/thread/757715) (June 2024 →) | Same symptom from iOS 18 on. Console: `Insufficient Permission (to submit GPU work from background)` … `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted` … `CoreML prediction failed`. One developer: adding the **Background processing** mode fixed it; another then ran 14 h locked on an iPhone 16, iOS 18.2 (22C152). Not reproducible in the Simulator |
| [Apple forums 765376](https://developer.apple.com/forums/thread/765376) (Oct–Dec 2024) | Same error text. Worked on iOS 15–17. The Background-processing suggestion **did not help** another developer on iOS 18.2 (22C151). Apple's engineers asked for Feedback reports (FB15361195, FB15150861, FB15747195); no cause, fix or timeline was given |
| [Apple forums 811582](https://developer.apple.com/forums/thread/811582) (Dec 2025) | `com.apple.SoundAnalysis` code 2 once per second in the background with `UIBackgroundModes = audio`; capture continues; no replies |
| [Apple forums 816774](https://developer.apple.com/forums/thread/816774) | `BGTaskScheduler.supportedResources` does not include `.gpu` on any iPhone the poster tried (15 Pro, 16 Pro); a second-hand statement that support is limited to certain iPads |

The two reports about the Background-processing mode contradict each other, on nearly the same
iOS build. That is why it is tested here (experiment A2) instead of being assumed either way.

## 5. Causes: confirmed and hypothetical

| Statement | Status |
|---|---|
| The built-in classifier fails with `SoundAnalysis` error 2 for as long as the app is in the background, on iPhone 18 Pro / iOS 27.2 | **Confirmed** (Physical iPhone, Window 3) |
| Microphone capture is not the cause | **Confirmed** (coverage 100 % in the same intervals) |
| The app's audio configuration is not the cause | **Confirmed** as far as capture is concerned; nothing is declared incorrectly |
| The underlying reason is that Core ML submits GPU work, which iOS refuses for background apps | **Hypothesis.** The error text comes from other developers' iOS 18 consoles. Our own failure carries no underlying error. Experiment A1 tests it directly (§6) |
| The built-in classifier cannot be moved to the CPU | **Confirmed** (SDK: no setting exists) |
| The Background-processing mode restores background classification | **Unknown**; contradictory reports. Experiment A2 |
| Background GPU access through `BGContinuedProcessingTask` could be used | **Not available to this project** (§7), and not designed for continuous listening |
| The behaviour is specific to iOS 27.2 or to this iPhone model | **Not supported by the evidence**: the same symptom is reported from iOS 18.0 on several devices |

## 6. Experiments on the physical iPhone

Implemented, Debug builds only, launch arguments only; the production pipeline is unchanged and
runs next to the probe on the same microphone buffers.

`apps/ios/HearingSense/Experiments/BackgroundInferenceProbe.swift` (`--hs-bg-probe`) counts,
separately for foreground, background and locked:

| Lane | What it isolates |
|---|---|
| Production pipeline: built-in classifier through SoundAnalysis | the known failure (control) |
| Direct `MLModel.prediction`, `cpuOnly` | does Core ML run at all in the background? |
| Direct, `cpuAndGPU` | is the GPU refused? with which error text? |
| Direct, `cpuAndNeuralEngine` | is the Neural Engine available in the background? |
| Direct, `all` | what the system-chosen default does |
| `SNClassifySoundRequest(mlModel:)`, model loaded `cpuOnly` | is SoundAnalysis itself restricted, or only the compute unit? |
| `SNClassifySoundRequest(mlModel:)`, model loaded `cpuAndGPU` | the same framework with GPU work |

The probe model (`ProbeTiny`, `tools/experiments/make_probe_model.py`) has **random weights**
(1.5 MB, generated locally, nothing downloaded, nothing trained). A result from it means
"inference executed". It is not evidence that any sound was recognized. On the Mac, Core ML's
compute plan puts all 16 of its operations on the GPU under `cpuAndGPU` and `all`, and on the CPU
under `cpuOnly`; the plan on the iPhone is recorded in the report at run time.

| ID | Build | Question |
|---|---|---|
| A1 | `UIBackgroundModes = audio` (the shipping configuration) | Which lanes keep producing results in the background and when locked? |
| A2 | `audio` + `processing` (`apps/ios/Config/Experiments/HearingSense-Info-processing.plist`, used with `xcodebuild INFOPLIST_FILE=…`; no `BGProcessingTask` is ever scheduled) | Does the Background-processing mode change any lane, in particular the built-in classifier? |
| A3 | the configuration that worked in A2, if any | 10 minutes locked: real classification results, correct timestamps, no growing backlog |

Stopping rule: A1 and A2 are the only Apple-native configurations with a technical reason behind
them. If the built-in classifier still fails in both, the Apple-only option is closed and the work
moves to a CPU-only model; no further background settings are tried without new evidence.

**Status: implemented and built for the Simulator; the device runs need the student and the
iPhone.** Results: `docs/testing/BACKGROUND_DEVICE_TESTS.md`.

## 7. Background GPU access (`BGContinuedProcessingTask`)

| Question | Finding | Evidence |
|---|---|---|
| Can the app get the entitlement? | **No, with the current signing.** A build with `com.apple.developer.background-tasks.continued-processing.gpu` fails: "Provisioning profile … doesn't include the Background GPU Access capability" (Personal Team profile; the profile was not modified) | Build |
| Does the iPhone 18 Pro support background GPU? | Not measured yet; the probe records `BGTaskScheduler.supportedResources` at run time. Other developers report that no iPhone they tried does | pending (Physical iPhone) / Reported |
| Would it fit Hearing Sense if it were available? | **No.** The task type is for bounded work that the user started, shows system UI with a progress bar, must report progress and can be expired by the system or the user. Continuous listening has no end and no progress. Re-submitting tasks or reporting fake progress to stay alive would be misuse of the API | SDK |
| Is there a legitimate use? | Possibly a bounded, user-started job in a later window (for example re-analyzing a saved clip). Not environmental monitoring | — |

## 8. System Sound Recognition through Shortcuts (feasibility only)

| Question | Finding | Evidence |
|---|---|---|
| Is there a sound trigger for personal automations? | Yes: Apple's Shortcuts guide lists a **Sound Recognition** trigger with one option, "Sound: Tap this option, then choose a sound to trigger your automation", and notes that Sound Recognition must be enabled in Settings ([Apple support](https://support.apple.com/guide/shortcuts/event-triggers-apd932ff833f/ios)) | Reported (Apple) |
| Which sounds? | The sounds of Accessibility → Sound Recognition (alarms, animals, household sounds, people; third-party pages count about 15). Apple's trigger page does not list them. **Not** the 303 labels of the SoundAnalysis classifier | Reported; list unverified |
| Can the automation call Hearing Sense? | An App Intent exposed by the app can be an action of the shortcut. The trigger passes the fact that it fired; nothing indicates that scores, timestamps or audio are passed | Design reasoning; not built |
| Public API for the system's recognition results? | None found | SDK search |
| Setup | By the user, per sound, in the Shortcuts app; automations cannot be shared or installed by an app | Reported |
| Lock screen / background behaviour, delay, coexistence with Hearing Sense's own microphone session | **Unknown.** Not tested | — |

Assessment: a possible *supplement* for a handful of system sounds (a smoke alarm, a doorbell)
that needs manual setup per sound and gives no speech, no music context and no scores. It cannot
replace the classifier. No proof of concept was built in this window.

## 9. Consequence for the architecture

A classifier that must run in the background has to be one whose compute units the app controls.
That excludes the built-in classifier unless A2 shows otherwise, and points to a custom Core ML
model loaded with `MLComputeUnits.cpuOnly`. Whether such a model actually keeps running when the
phone is locked is a device question (experiment B, `docs/testing/BACKGROUND_DEVICE_TESTS.md`),
and whether it recognizes sounds well enough is a separate one
(`docs/research/BACKGROUND_MODEL_BENCHMARK.md`).
