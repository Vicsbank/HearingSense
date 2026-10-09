# Window 2 Report — Real-Time Sound Analysis and Acoustic Event Detection

Date: 2026-10-09. Branch `feature/window2-sound-analysis`. No model training or fine-tuning was
performed; all model use was forward-only inference with Apple's pretrained classifier.

**Evidence classes** used below: *Mac* (macOS 27.2, M1 Max), *Simulator* (Xcode iPhone 18 Pro
Simulator, iOS 27.0, Mac microphone and Mac hardware), *Recorded file* (offline evaluation on the
Mac). **No physical-iPhone test was run in Window 2**: the student chose to use the Simulator only
in this window; all physical tests are listed as open in `docs/testing/WINDOW2_DEVICE_TESTS.md`.

---

## 1. Apple APIs used

| API | Use | Verified signature (iOS 27.0 SDK) |
|---|---|---|
| `SNClassifySoundRequest(classifierIdentifier: .version1)` | Apple's built-in classifier (only identifier in the SDK) | `init(classifierIdentifier:) throws` |
| `.windowDuration`, `.overlapFactor`, `.windowDurationConstraint`, `.knownClassifications` | 1.5 s window, 0.5 overlap; label enumeration | `windowDurationConstraint` is a Swift enum (`.durationRange` / `.enumeratedDurations`) |
| `SNAudioStreamAnalyzer(format:)`, `add(_:withObserver:)`, `analyze(_:atAudioFramePosition:)`, `completeAnalysis()`, `removeAllRequests()` | Streaming analysis | Header: `analyze` "may block as a means of indicating backpressure … not safe to call from a realtime audio context" |
| `SNResultsObserving.request(_:didProduce:)`, `request(_:didFailWithError:)` | Results / terminal errors | Swift names differ from older examples (`didProduceResult` is obsolete) |
| `SNClassificationResult.classifications`, `.timeRange` | Scores sorted high→low; window range as `CMTime` (frames, client sample rate) | — |

The SoundAnalysis types carry no `Sendable` annotations; the design isolates them (§2).

## 2. How streaming audio reaches the classifier

```
AVAudioEngine input tap (Window 1, ~4 800 frames / 100 ms at 48 kHz, actual size not assumed)
 └ SoundRecognitionEngine.captureDidReceive  — tap thread, returns in microseconds
     • copy channel 0 to [Float] (the classifier analyzes channel 0 by default; any channel count,
       interleaved or not); reject non-float buffers (counted)
     • StreamClock: monotonic frame position per analyzer segment; gaps detected from
       AVAudioTime.sampleTime advance the clock (timestamps stay aligned with real input)
     • backlog ≥ 50 buffers (≈ 5 s) → drop and count instead of blocking or growing memory
     • queue.async { worker.assumeIsolated { $0.analyze(chunk) } }  (FIFO)
 └ SoundAnalysisWorker — actor whose executor is a private serial DispatchSerialQueue
     • new segment (start, restart after route change, sample-rate change) → new analyzer with a
       mono Float32 format at the input rate (the framework resamples internally)
     • analyze(buffer, atAudioFramePosition:) — timed (wall + thread CPU)
     • ResultObserver converts SNClassificationResult → Sendable values → ResultInbox → drained in
       order on the worker queue (callbacks arrive on SoundAnalysis' own thread: 0 of 48 on our
       queue in the Simulator run)
     • ClassificationFrame: audio range on the session clock, capture time of the window's last
       sample, labels ≥ 0.05 (max 10), window RMS/peak from the real samples
     • SoundEventDetector.process(frame) → event updates + EnvironmentStatus
     • AsyncStream<SoundRecognitionOutput> → RecognitionController (main actor) → SwiftUI
```

Swift 6: package targets in Swift 6 language mode; the app with main-actor default isolation. No
`@unchecked Sendable` and no `nonisolated(unsafe)` were added; non-Sendable framework objects live
only in actor-isolated state. Builds have zero compiler warnings.

Lifecycle: *Stop* and interruptions call `endSession()` → `completeAnalysis()`, every active event
ends (`.ended`), clock and generation reset (late results of an old session are discarded and
counted). An engine restart after `AVAudioEngineConfigurationChange` starts a new analyzer segment
but keeps the session, so ongoing events survive route changes. Media-services reset re-attaches
the engine to the new capture object.

## 3. Mapping classifications to categories

`SoundTaxonomy.appleV1`: 303 labels → 50 event kinds → 11 categories (speech, alerts,
transportation, household, impacts, human activity, animals, music, weather & nature, crowd, other).
Labels are kept verbatim; kinds group synonyms (`dog`, `dog_bark`, `dog_growl` → kind `dog`); unknown
labels map to `other` instead of disappearing. Full table, deviations from the suggested taxonomy
and difficult labels: `docs/research/SOUND_CATEGORY_MAPPING.md`. Label inventory and verification:
`docs/research/IOS_SOUND_CLASSIFICATIONS.md`.

## 4. Data model for later windows (HearingSenseDomain, Foundation only)

`RawSoundPrediction` (label, score, audio range, producedAt, model) → `ClassificationFrame` (one
window, all labels ≥ floor, input level) → `AcousticEventCandidate` (detector-internal evidence,
hits vs. required) → `ConfirmedAcousticEvent` (stable `AcousticEventID`, kind/category, primary
label, phase confirmed/ongoing/ended, audio-clock and wall-clock times, `EventEvidence` with
per-label counts/peaks/means, rule-based `EventQuality`) → `AcousticEventUpdate`
(`.started/.updated/.ended`). `EnvironmentStatus` distinguishes warming up, quiet, sound present but
unclassified, uncertain ("maybe X") and recognized. `ClassifierScore` documents that scores are not
calibrated probabilities.

## 5. Confidence filtering and temporal confirmation

Per window, for each kind: best score among its labels after (a) dropping labels below the kind's
sustain threshold and (b) competing-classification suppression. Then:

| Profile (default rule) | Enter (hit) | Hits needed / look-back | Single-window confirm | Sustain (hysteresis) | End after |
|---|---|---|---|---|---|
| continuous (speech, music, traffic, rain, crowd…) | 0.50 | 2 within 2.0 s | — | 0.30 | 3.0 s |
| intermittent (siren, alarm, dog, laughter, phone…) | 0.45 | 2 within 3.0 s | ≥ 0.80 | 0.30 | 5.0 s |
| transient (knock/door, glass, clap, small objects…) | 0.40 | 2 within 2.0 s | ≥ 0.65 | 0.30 | 2.0 s |
| overrides: `vehicle_horn`, `bang` | 0.50 | 2 within 2.0 s | ≥ 0.85 | 0.35 | 2.0 s |
| overrides: `siren`, `alarm` | 0.50 | 2 within 3.0 s | ≥ 0.85 | 0.35 | 5.0 s |

- Look-back is measured between window end times on the audio clock (with 0.75 s hops, 2.0 s
  covers three windows).
- Suppression: `foghorn` is ignored in windows where `music` ≥ 0.5 (see §6.3).
- Candidates that do not meet their rule within the look-back are rejected (counted).
- Active events publish `.updated` only when the primary label or quality changes, or every 5 s of
  audio; one event per kind at a time, so label flicker does not create new events.
- The detector uses only frame timestamps → deterministic replay; 37 package tests in
  `SoundEventDetectionTests` (taxonomy coverage incl. the live classifier, confirmation/hysteresis/
  timeouts, suppression, status, clock and gap handling, buffer copying, backlog dropping, the real
  engine on generated audio and on a real speech file).

**These thresholds are provisional operating points.** They were chosen from the offline
evaluation below, not optimized on a labeled environmental-event dataset (none is available
locally), and have not yet been validated on the physical iPhone.

## 6. Offline evaluation (recorded files, forward-only)

Tool: `swift run -c release hs-sound-eval evaluate --window 1.5` (package `HearingSenseKit`). It feeds
each file in 100 ms buffers through the **production** `SoundRecognitionEngine` (same copy →
analyzer → detector path as the app) on macOS. Outputs: `results/sound_eval_window2/` (summaries
committed; per-clip dumps regenerable).

### 6.1 What the local data can and cannot support

| Data | Ground truth used | Valid metrics |
|---|---|---|
| LibriSpeech dev-clean, 500 utterances (evenly spaced subset, 1.06 h) + 10 macOS TTS files | Read speech only; no music, alarms or impacts | Speech recall; false music/alert/impact events |
| GTZAN, 300 clips (30/genre, 2.5 h) + 299 disjoint holdout clips | Music | Music recall; false alert events (speech is *not* scored: songs contain vocals) |
| DEMAND ch01, 4 scenes × 5 min | Scene name only, no event annotations | Event rates only — **not accuracy** |

The music-genre datasets are used only as "music present" positives and as music-only negatives
for alerts. There is no locally available, event-annotated environmental dataset (sirens, horns,
knocks, dogs…), so **precision/recall for those categories, macro-F1 over categories and a
category confusion matrix could not be computed** and are not reported. Each clip is followed by one
window of digital silence so a short clip gets the windows it would get in a continuous stream
(without padding, 22 of 81 utterances shorter than 3 s produced only one 1.5 s window; unpadded
results are kept in `results/sound_eval_window2/unpadded/`). Clip-level rates with 95 % Wilson
intervals.

### 6.2 Window length comparison (before the foghorn rule)

| Window (50 % overlap) | Speech recall (510) | Music recall (300) | Time to confirm (audio, median) | Music falsely confirmed on speech-only clips | Non-speech events on speech-only (1.06 h) | Alert events on music clips |
|---|---|---|---|---|---|---|
| 1.0 s | 100 % [99.3, 100] | 100 % [98.7, 100] | 1.5 s | 4.3 % [2.9, 6.4] | 274 | 4.7 % of clips |
| **1.5 s** | 99.8 % [98.9, 100] | 100 % [98.7, 100] | **2.25 s** | **0.2 % [0.0, 1.1]** | 117 | 5.0 % of clips |
| 3.0 s | 97.1 % [95.2, 98.2] | 100 % [98.7, 100] | 4.5 s | 0.6 % [0.2, 1.7] | 49 | 0.7 % of clips |

Choice: **1.5 s** (shipped default; selectable 1.0/1.5/3.0 s in the debug UI). 1.0 s confirms 0.75 s
earlier but produces 20× more false music confirmations on speech; 3.0 s halves the spurious minor
events but doubles the latency and misses short utterances. Time to confirm = window + one hop for
two-window rules; it is a floor set by the model's context, not processing time. No alert event was
confirmed on any speech-only clip at any window length (0/510, 95 % upper bound 0.7 %).

Non-speech events on speech-only clips at 1.5 s were mostly `click` (35), `mosquito_buzz` (27),
`writing` (25), `sigh` (18) — some may be real (mouth clicks, page turns, sighs in audiobooks), some
are not (buzz); all are low-relevance kinds.

### 6.3 Competing classification: `foghorn` on music

At 1.5 s, 20 of 22 `vehicle_horn` events on GTZAN were `foghorn` in classical/jazz/country (peak
0.61–0.98), i.e. low brass/bass notes. Rule added: ignore `foghorn` in windows where `music` ≥ 0.5
(car/air/train horns unaffected). Because the rule was derived from the standard subset, it was
checked on 299 **disjoint** GTZAN clips:

| | Music clips with a false alert event | Music recall |
|---|---|---|
| Standard subset, without → with rule | 5.0 % → 2.3 % | 100 % → 100 % |
| **Holdout, without → with rule** | **6.7 % [4.4, 10.1] → 1.0 % [0.3, 2.9]** | 100 % → 100 % |

Remaining holdout alerts: `foghorn` (country, 0.86), `car_horn` (jazz, 0.91), `emergency_vehicle`
(pop, 0.95) — possibly real samples in the songs (not verified).

### 6.4 DEMAND scenes (rates, unverified)

1.5 s, final rules, events started per hour: STRAFFIC road vehicle 60; PCAFETER kitchen 72, music 36,
speech 12 (one long merged event), bell/farm animal/impact 12 each; PSTATION farm animal, water 12
each; DLIVING music 36, insect 24, `foghorn` 12. With 1.0 s windows STRAFFIC produced 9 `air_horn`
events (peaks 0.54–0.87); with 1.5 s none — whether those were real horns is unknown.

### 6.5 Throughput on the Mac

3.9 h of audio in 109 s wall time (≈ 130× real time, single process, including file decoding).

## 7. What was verified where

| Item | Mac | Simulator | Physical iPhone |
|---|---|---|---|
| Package builds and tests (58 tests: 37 new + 21 Window 1) | ✅ `swift test` | ✅ `xcodebuild test` incl. iOS-only tests | — |
| App builds (Swift 6, 0 warnings) | — | ✅ iPhone 18 Pro Simulator | not rebuilt for device |
| Live microphone → classifier → UI | — | ✅ (Mac mic, 48 kHz mono, 37 s; S0 in the test doc) | ❌ not run |
| Label inventory 303 = taxonomy | ✅ | ✅ | ❌ not run |
| Speech / music detection | ✅ files (§6) | ⚪ no deliberate sounds played | ❌ |
| Knock, rain/wind, car horn | ❌ no annotated data | ❌ | ❌ |
| AirPods + Spotify, lock screen, interruptions | — | — | ❌ |
| Start/stop stall | — | — | ❌ |

### Categories successfully detected (evidence: recorded files)
Speech (99.8 % of utterances) and music (100 % of clips); traffic (`road_vehicle`) in the street
scene, kitchen sounds and speech in the cafeteria (unverified rates).

### Categories with unreliable or unknown results
- Alerts: horns confused with brass (mitigated), possible `air_horn` on traffic noise with short
  windows; sirens/alarms/knocks/dogs/rain **have no evaluation data** — reliability unknown.
- Minor kinds (`click`, `mosquito_buzz`, `writing`, `sigh`, `insect`) fire on clean speech.
- "Quiet" uses −60 dBFS; the Simulator's Mac mic sat at −51…−53 dBFS in a normal room, which is
  reported as "sound present, not recognized". The iPhone's noise floor needs Test A.

## 8. Latency

| Measure | Value | Evidence |
|---|---|---|
| Classifier context per result | 1.5 s window; results every 0.75 s | Configuration, verified in tests and Simulator (48 windows / 37 s) |
| Result delay after the window's last sample | mean 10.7 ms, p95 13.5 ms, max 14.8 ms | Simulator (Mac hardware) |
| analyze() call that produced a result (≈ inference upper bound) | mean 10.0 ms, p95 13.4 ms | Simulator |
| analyze() per 100 ms buffer | mean 1.6 ms | Simulator |
| Event confirmation, audio time from start of first supporting window | 2.25 s typical (two windows); 1.5 s for a single strong window | Files (§6.2) and unit tests |
| End-to-end on iPhone | **not measured** | — |

So end-to-end detection is dominated by the model's window, not by inference. Sub-second
recognition is not realistic with this classifier at useful accuracy.

## 9. CPU and memory

Simulator (Mac hardware; not representative of iPhone power): analysis thread CPU 1.3 % of audio
time (0.48 s CPU for 37 s); process CPU 7.7 % of one core while listening with the UI visible;
`phys_footprint` 31 MB; thermal nominal; 0 dropped buffers, max backlog 1. iPhone CPU, memory,
battery and thermal behaviour are **not yet measured** (the app shows them under Recognition
diagnostics → Process).

## 10. Known limitations

1. No physical-device validation of anything in Window 2 (see §7).
2. No event-annotated environmental dataset → no accuracy numbers for alerts, knocks, animals,
   weather; thresholds for those kinds are provisional.
3. Scores are uncalibrated; `EventQuality` is a rule-based indicator only.
4. One event per kind: two simultaneous dogs are one event; a horn and a siren are separate kinds.
5. Event start time is the start of the first supporting window (up to 1.5 s before the actual
   onset).
6. Quiet threshold (−60 dBFS) is a guess until Test A.
7. The analyzer only uses channel 0 (as the framework does by default).
8. `AVAudioSession` activation still runs synchronously on the main actor; iOS logs a "hang risk"
   runtime warning (Simulator). iOS 27 adds asynchronous `activate`/`deactivate`; not adopted.
9. The engine's output stream has a single consumer (the app); later windows should subscribe via
   the app layer.

## 11. Audio routing changes

- The verified session configuration (playAndRecord, default mode, mixWithOthers +
  allowBluetoothA2DP + defaultToSpeaker, built-in mic) is **unchanged**.
- `AudioSessionController` now skips calls that would not change anything (`setCategory` when
  category/mode/options match, `setActive(true)` when already active, `setPreferredInput` when the
  same input is preferred) and logs which steps ran with their durations.
- New opt-in experiment "Keep audio session active when stopped" (default **off**): Stop still
  removes the tap and stops the engine (microphone off), but the session stays active.
- Effect on the ~0.5 s Spotify stall: **not measured** (needs the device; Test S). Details and
  hypotheses: `docs/AUDIO_ROUTING_FEASIBILITY.md` §3.

## 12. Remaining work

Window 2 leftovers (physical iPhone, in this order): L (labels), A (quiet → calibrate quiet
threshold), B/C/D/G, H (AirPods + Spotify), I (lock ≥ 1 min, then 15 min), S (stall before/after),
E/F (playback), J (interruptions, ask first). Then tune thresholds with device results.

For Window 3: subscribe to `.event` updates in the app layer; gate speech transcription on active
`speech` events (kind id `speech`; `shouting` optional); keep a pre-roll buffer in the speech
pipeline because the speech event confirms ≈ 2.25 s after onset; attach transcripts keyed by
`AcousticEventID`; extend `AcousticEventSource` if speech-derived events are added.
