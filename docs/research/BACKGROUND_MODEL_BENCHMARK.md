# Background Model Benchmark — Apple vs YAMNet vs EfficientAT on Common Data

Research window between Window 3 and Window 4. Date: 2026-10-10. Forward-only; **no training**.
All numbers in this document are **Mac measurements on recorded files** (MacBook Pro M1 Max).
None comes from the iPhone, and none from a published paper.

Raw summaries: `results/background_benchmark/benchmark_summary.json` (every per-kind number),
`confusion_matrices.json`, `manifest_summary.json`. Code: `tools/experiments/model_benchmark/`,
`packages/HearingSenseKit/Sources/ModelBenchmarkTool/`.

---

## 1. What was compared

| System | Runs as | Scored by |
|---|---|---|
| Apple SoundAnalysis v1 | `SNClassifySoundRequest(.version1)` through `AppleSoundAnalysisBackend` | `hs-model-bench apple` (Swift) |
| YAMNet | converted Core ML model, float32, CPU only | `score_models.py` (Python, Core ML) |
| EfficientAT MN10 (`mn10_as`) | converted Core ML model, float32, CPU only | same |
| EfficientAT DyMN04 (`dymn04_as`) | converted Core ML model, float32, CPU only | same |

Every system received **the same sample ranges of the same files**, defined once in
`results/background_benchmark/manifest.jsonl`. The third-party models were scored with the
converted Core ML models — the artefacts that would ship — whose agreement with their references
is documented in `AUDIO_MODEL_COMPARISON.md` §3.

## 2. Data

| Source | Clips | Ground truth | Kind(s) | License |
|---|---|---|---|---|
| ESC-50 | 1 880 of 2 000 (5 s each) | clip-level class, 47 of 50 classes | 32 kinds | CC BY-NC 3.0 (research only) |
| LibriSpeech dev-clean, utterances ≥ 10 s | 200 | read speech | `speech` | CC BY 4.0 |
| GTZAN | 200 (20 per genre) | music | `music` | research only |

- 2 280 clips, 34 Hearing Sense kinds. Skipped: 120 ESC-50 clips of three classes that have no
  defensible kind (`door_wood_creaks`, `can_opening`, `washing_machine`). Unreadable files: 0.
- **Development split** (952 clips): ESC-50 folds 1–2, half of the speakers, even-numbered GTZAN
  clips. **Test split** (1 328 clips): folds 3–5, the other speakers, odd-numbered GTZAN clips.
  ESC-50 keeps all fragments of one source recording in one fold, so the splits do not share
  recordings. Thresholds and the one model-specific choice (YAMNet's patch aggregation) were
  fixed on the development split and applied once to the test split.
- Most kinds have **24 test clips** (16 development clips). Per-kind figures therefore move in
  steps of about 4 percentage points and carry an uncertainty of roughly ± 15–20 points; the
  aggregate figures have the intervals shown.
- FSD50K was not downloaded (over 20 GB). The repository had no other labelled environmental
  audio. No music-genre label was used as ground truth for anything but "music".

### Limits of this data

- **No event timestamps.** Short contexts are placed on the loudest part of the clip (maximum
  energy of a sliding window). That guarantees sound, not the complete event. Share of a context
  above −40 dB re the clip peak: ESC-50 94 % (1 s), 90 % (2 s), 81 % (5 s).
- **The 10 s context of an ESC-50 clip is the 5 s clip plus 5 s of digital silence**, not a 10 s
  recording (40 % active on average). Read the 10 s rows as "5 s of sound in a 10 s buffer".
- Clean, close recordings from Freesound, digitally cut. No room, no distance, no phone
  microphone, no music playing at the same time. **These numbers rank the models on this data;
  they are not the recognition rates Hearing Sense will have in a pocket.**
- Apple does not publish its training data. If it included Freesound recordings, ESC-50 would
  flatter Apple's classifier; this cannot be checked. YAMNet and EfficientAT were trained on
  AudioSet (YouTube), a different source.
- One reader (Claude) wrote the label mapping; it was not reviewed independently.

## 3. Common taxonomy

All systems are judged on the existing Hearing Sense kinds (`SoundTaxonomy.appleV1`: 50 kinds).

| Mapping | Source | Size |
|---|---|---|
| Apple label → kind | the production taxonomy (`sound_analysis_labels_v1_macos27_mapped.tsv`) | 303 labels → 50 kinds |
| AudioSet class → kind | `tools/experiments/model_benchmark/taxonomy.py`, written for this window; exported to Swift as `AudioSetLabelTable` | 446 of 527 classes mapped: 259 *exact* (Apple has a label for the same concept), 187 *within* (inside the kind, no Apple label of that name) |
| Not mapped | 81 AudioSet classes: broader than a kind (`Alarm` also covers telephones and sirens; `Glass` also clinking; `Vehicle`; `Animal`) or without a kind (`Noise`, `Inside, small room`, `Television`, …) | listed with reasons in `docs/research/audioset_to_hearingsense_mapping.tsv` |
| YAMNet | lacks 6 of the 527 classes, 3 of them mapped (`Male speech`, `Female speech`, `Battle cry`) | 440 mapped |
| ESC-50 class → kind | `taxonomy.py` | 47 classes → 32 kinds |

A kind's score in a window is the highest score among its labels. Original labels and scores are
kept in the score files; nothing is renamed.

## 4. Metrics

| Metric | Definition |
|---|---|
| Top-1 accuracy, macro F1 | the kind with the highest score among the 49 kinds that can become events ("silence" is not an event kind in the app); a prediction outside the 34 evaluated kinds is an error. No thresholds |
| Detection micro / macro F1 | one threshold per kind and model, chosen on the development split (maximum F1), applied to the test split; every (clip, kind) pair is a decision |
| Priority recall | mean detection recall over the 15 kinds of the product's priority list that have ground truth |
| False alerts per hour | false positives of the 7 alert kinds per hour of **non-target benchmark audio**, i.e. per hour of back-to-back other sound events. A stress figure for comparing models, far above what quiet real life would give |
| Event recall, delay | on 10 s streams (3 s digital silence, 5 s of the clip, 2 s silence) with each model's streaming window: a kind fires when a window ending after the energy onset reaches its threshold; delay = end of that window − onset, in audio time, **without** inference time (1–14 ms on the Mac) |
| 95 % interval | bootstrap over test clips, 2 000 resamples |

Scores are model outputs, not probabilities. They are never compared across models, and no
threshold of one model is applied to another. mAP is not reported: with one positive kind per
clip it would add nothing to the ranking metrics above and invites reading it as accuracy.
Not available from this data: accuracy for overlapping sounds, for sounds under music, and any
real-world false-alert rate.

## 5. Finding: `mn10_as` breaks down on short inputs

With the EfficientAT repository's own, unmodified front end and model (PyTorch), the same dog
bark gives:

| Input length | Mean logit | Classes with score > 0.5 | Top class |
|---|---|---|---|
| 1 s | +61.7 | 527 of 527 | (all saturated at 1.000) |
| 1.5 s | +30.2 | 526 | (saturated) |
| 2 s | +13.9 | 526 | (saturated) |
| 2.5 s | −0.3 | 222 | Typewriter 0.997 |
| 3 s | −0.5 | 190 | Sawing 0.998 |
| 4 s | −5.8 | 0 | Animal 0.23 |
| 5 s | −8.1 | 0 | Dog 0.44 |

The pooled feature before the classifier is about ten times larger for the 1 s input (mean
magnitude 1.00 vs 0.09 at 5 s): with only four time steps left after the network's 32× reduction,
every position of the last 5×5 layers sits at a zero-padded border. This is the released
checkpoint's behaviour, not a conversion effect (the Core ML model reproduces it to 10⁻⁶).
`dymn04_as` degrades on short inputs without collapsing.

So the published 47.1 mAP says nothing about 1–2 s windows, where the model is unusable as
released. Two remedies that need no training were measured: put the short window inside the
10 s input, followed by silence (**pad**) or repeated (**tile**).

## 6. Results — fixed contexts (test split, 1 328 clips, 34 kinds)

"det." = detection with development-split thresholds. Intervals: 95 % bootstrap.

| Model | Context | Top-1 accuracy | Top-1 macro F1 | Det. micro F1 | Det. macro F1 | Priority recall | Alert false alerts / h (stress) |
|---|---|---|---|---|---|---|---|
| **Apple v1** | 1 s | **74.5** [72.1, 76.8] | **70.6** [67.5, 72.9] | 72.5 | 70.2 | 71.5 | 10 |
| | 2 s | **84.0** [82.0, 85.9] | **81.7** [79.3, 83.7] | 84.4 | 82.2 | 84.4 | 2 |
| | 5 s | 84.5 [82.5, 86.4] | 82.1 [79.7, 84.0] | 85.3 | 82.3 | 80.5 | 1 |
| | 10 s (5 s + silence) | 71.5 [69.1, 74.0] | 71.4 [68.6, 73.6] | 80.9 | 76.7 | 76.0 | 1 |
| YAMNet | 1 s | 64.3 [61.8, 66.8] | 59.7 [56.4, 62.2] | 68.2 | 62.0 | 68.8 | 17 |
| | 2 s | 69.4 [66.8, 71.9] | 63.3 [60.1, 65.7] | 71.2 | 67.9 | 73.8 | 7 |
| | 5 s | 72.2 [69.9, 74.8] | 66.5 [63.4, 69.0] | 69.9 | 69.3 | 72.2 | 3 |
| | 10 s | 71.8 [69.3, 74.2] | 66.2 [63.2, 68.5] | 70.3 | 70.8 | 74.5 | 1 |
| MN10, as released | 1 s | 3.6 [2.7, 4.7] | 0.2 | 5.7 | 5.6 | — | — |
| | 2 s | 0.8 [0.4, 1.4] | 0.2 | 5.6 | 5.6 | — | — |
| | 5 s | 75.5 [73.0, 77.8] | 74.0 [71.3, 76.2] | 78.5 | 76.8 | 78.1 | 4 |
| | 10 s | 82.4 [80.3, 84.4] | 78.9 [76.6, 80.9] | 84.9 | 83.2 | 88.3 | 1 |
| MN10 + pad to 10 s | 1 s | 63.6 [61.1, 66.2] | 58.1 [55.1, 60.4] | 70.6 | 67.8 | 77.0 | 13 |
| | 2 s | 75.1 [72.8, 77.4] | 70.6 [67.8, 72.7] | 80.5 | 77.6 | 79.5 | 2 |
| | 5 s | 82.4 [80.3, 84.4] | 78.9 [76.5, 80.9] | 85.1 | 83.4 | 88.2 | 1 |
| MN10 + tile to 10 s | 1 s | 57.8 [55.0, 60.5] | 53.9 [50.6, 56.3] | 68.7 | 65.7 | 66.0 | 16 |
| | 2 s | 78.2 [75.8, 80.5] | 74.4 [71.4, 76.6] | 82.0 | 77.6 | 78.5 | 4 |
| | 5 s | 82.8 [80.7, 84.9] | 79.1 [76.6, 81.2] | 85.9 | 83.3 | 84.4 | 1 |
| DyMN04, as released | 1 s | 49.0 [46.3, 51.7] | 44.3 [41.4, 46.5] | 56.6 | 55.2 | 58.3 | 34 |
| | 2 s | 70.6 [68.1, 72.9] | 67.0 [63.8, 69.2] | 75.2 | 73.0 | 77.3 | 7 |
| | 5 s | 80.5 [78.5, 82.7] | 76.4 [73.8, 78.5] | 82.7 | 80.8 | 84.9 | 1 |
| | 10 s | 77.0 [74.8, 79.3] | 71.9 [69.2, 74.0] | 81.7 | 78.3 | 82.1 | 0 |
| DyMN04 + tile to 10 s | 1 s | 56.2 [53.7, 58.9] | 50.5 [47.5, 52.9] | 67.4 | 66.4 | 68.3 | 28 |
| | 2 s | 71.5 [69.1, 73.8] | 67.7 [64.8, 69.8] | 76.4 | 74.4 | 79.5 | 7 |

(The released MN10's "recall" at 1–2 s is meaningless — every kind fires on every clip — and is
left out. YAMNet's patch aggregation chosen on the development split: mean at 1 s, max otherwise.
DyMN04 + pad was worse than as released at 2 s: 64.6.)

Reading:

1. **At 1–2 s Apple's classifier is the most accurate system here, and the gap is outside the
   intervals**: at 2 s, 84.0 [82.0, 85.9] against 78.2 [75.8, 80.5] for the best third-party
   configuration (MN10 + tile) and 69.4 [66.8, 71.9] for YAMNet.
2. From 5 s on, MN10 is level with Apple (82.4–82.8 vs 84.5; the intervals overlap). The higher
   AudioSet mAP shows where the model was trained to work — long clips — and not at 1–2 s.
3. YAMNet is the weakest of the usable systems at every length, but it is the only third-party
   model that works on one second without help, and it gains little from longer audio.
4. DyMN04 has fewer parameters than MN10, is slower on the CPU, and is less accurate at every
   length below 10 s.
5. One second is not enough for any system: every model gains 5–20 points going from 1 s to 2 s.

## 7. Results — event detection on streams (test split)

| Model | Streaming window / hop | Alert event recall (7 kinds) | Priority event recall (15) | All kinds (34) | Alert delay, median | Alert false alerts / h (stress) |
|---|---|---|---|---|---|---|
| **Apple v1** | 1.5 s / 0.75 s (the app's setting) | 85.1 | 83.1 | 81.1 | 0.82 s | 1 |
| Apple v1 | 1.0 s / 0.5 s | 81.5 | 81.7 | 78.4 | 0.92 s | 2 |
| **MN10 + tile** | 2 s / 0.5 s | 85.7 | 80.7 | 79.8 | 1.02 s | 1 |
| MN10 + tile | 1 s / 0.5 s | 69.6 | 69.0 | 71.7 | 0.85 s | 1 |
| YAMNet | 0.975 s / 0.48 s | 76.2 | 71.2 | 71.5 | 0.81 s | 2 |
| DyMN04 | 2 s / 0.5 s | 78.0 | 74.0 | 73.9 | 1.46 s | 2 |
| DyMN04 | 1 s / 0.5 s | 67.3 | 71.9 | 69.4 | 1.26 s | 3 |
| DyMN04 + tile | 1 s / 0.5 s | 72.0 | 67.8 | 69.8 | 0.80 s | 2 |
| MN10, as released | 1 s or 2 s | fires on everything (360 false alerts / h) | | | | |

Per kind, for the best configuration of each model — event recall / median delay / false alerts
per hour (24 test clips per kind, 100 for speech and music; one clip ≈ 4 points):

| Kind | Apple 1.5 s | MN10 + tile 2 s | YAMNet 0.975 s | DyMN04 2 s |
|---|---|---|---|---|
| door (knock) | 88 % / 0.70 s / 1 | 83 % / 0.69 s / 1 | 75 % / 0.38 s / 2 | 67 % / 1.86 s / 1 |
| vehicle_horn | 46 % / 0.75 s / 1 | 71 % / 1.50 s / 1 | 88 % / 0.85 s / 5 | 79 % / 2.00 s / 1 |
| siren | 88 % / 1.32 s / 1 | 100 % / 1.50 s / 1 | 92 % / 0.85 s / 2 | 83 % / 1.75 s / 0 |
| alarm | 83 % / 0.75 s / 0 | 83 % / 1.00 s / 3 | 88 % / 1.12 s / 2 | 88 % / 1.50 s / 12 |
| dog | 100 % / 0.69 s / 1 | 79 % / 0.46 s / 0 | 71 % / 0.79 s / 0 | 88 % / 0.43 s / 1 |
| glass_breaking | 92 % / 0.75 s / 1 | 96 % / 0.50 s / 0 | 54 % / 0.38 s / 1 | 50 % / 0.66 s / 0 |
| crying | 100 % / 0.75 s / 2 | 88 % / 1.49 s / 1 | 67 % / 1.29 s / 0 | 92 % / 2.00 s / 2 |
| speech | 99 % / 0.75 s / 0 | 93 % / 1.00 s / 4 | 97 % / 0.85 s / 0 | 99 % / 1.50 s / 3 |
| music | 98 % / 0.75 s / 7 | 97 % / 1.00 s / 1 | 96 % / 0.85 s / 4 | 98 % / 0.50 s / 0 |
| rain | 67 % / 1.50 s / 4 | 67 % / 1.50 s / 3 | 25 % / 2.29 s / 0 | 58 % / 2.00 s / 4 |
| thunder | 92 % / 0.75 s / 1 | 96 % / 1.43 s / 2 | 96 % / 1.33 s / 1 | 83 % / 1.50 s / 0 |
| footsteps | 79 % / 1.50 s / 2 | 83 % / 1.62 s / 2 | 71 % / 1.33 s / 1 | 25 % / 2.50 s / 0 |
| hands (clapping) | 100 % / 0.75 s / 2 | 38 % / 1.50 s / 0 | 38 % / 1.55 s / 1 | 79 % / 2.00 s / 1 |
| road_vehicle | 100 % / 1.50 s / 19 | 100 % / 1.50 s / 11 | 88 % / 1.33 s / 22 | 92 % / 2.00 s / 8 |
| wind | 17 % / 2.25 s / 6 | 38 % / 1.50 s / 13 | 25 % / 1.81 s / 5 | 29 % / 1.00 s / 11 |

Reading:

- For the alert kinds as a group, **MN10 + tile at 2 s matches Apple at 1.5 s** (85.7 vs 85.1 %)
  with about 0.2 s more delay. Their strengths differ: Apple is better on dog, clapping and
  crying; MN10 on horns and sirens. With 24 clips per kind most single differences are within
  noise; horn (46 vs 71 vs 88 %) and clapping (100 vs 38 vs 38 %) are large enough to be real.
- YAMNet reacts fastest and is good on horn, siren, alarm, thunder, speech and music, but misses
  about half of glass breaking and a third of crying and barking.
- **Speech — the trigger for the Window 3 pipeline — is found by every model** (93–99 %), within
  0.75–1.0 s. In this respect any of them could replace the missing background trigger.
- Wind and rain are weak for all systems (wind is confused with trains, aircraft and sirens; rain
  with running water). Clapping does not transfer to the AudioSet models (mostly "other").
- The streams start from digital silence. The step from silence to sound produced spurious
  one-window labels in every model (for Apple, e.g. `gunshot_gunfire` 0.97 at a helicopter
  onset). A microphone never delivers digital silence, so this artefact inflates the false-alert
  columns equally for all models.

## 8. Cost on the Mac CPU (orientation only)

Through the production `CoreMLSoundClassifierBackend`, Core ML restricted to the CPU:

| Configuration | Model call per window: median / p95 / max | Share of one Mac core at a 0.5 s hop |
|---|---|---|
| YAMNet, 0.975 s | 1.39 / 1.64 / 3.42 ms | ≈ 0.3 % |
| DyMN04, 1 s | 4.31 / 5.13 / 8.72 ms | ≈ 0.9 % |
| MN10, 1 s (unusable, for reference) | 2.86 / 3.83 / 6.83 ms | ≈ 0.6 % |
| **MN10, 2 s repeated into the 10 s input** | 13.54 / 14.41 / 17.41 ms | ≈ 2.7 % |

Repeating the window makes MN10 about ten times as expensive as YAMNet per result. On an M1 Max
that is still far from real time; whether it is acceptable on an iPhone for hours — latency,
power, heat — is not known and has to be measured there
(`docs/testing/BACKGROUND_DEVICE_TESTS.md`, B-L and B-D/E). Memory and energy were not measured
on the Mac because they would not transfer.

## 9. What was not measured

- Anything on the iPhone: latency, CPU share, memory, battery, thermal state, background behaviour.
- Recognition through the phone's microphone, at a distance, in a pocket, or with music playing.
- Overlapping sounds; sounds shorter than the context that are not the loudest part of the clip.
- The models with the app's `DetectionPolicy` (k-of-n confirmation, hysteresis): its thresholds
  were chosen for Apple's scores and are **not calibrated** for the AudioSet models. The numbers
  above use per-model thresholds from the development split, which do not exist in the app yet.
- Rolling 10 s context (the previous 10 s of the stream) as an alternative to repeating a 2 s
  window.
- Smaller EfficientAT variants (`mn04_as`, `mn05_as`) and quantized or half-precision models.

## 10. Reproduce

```bash
.venv/bin/python -I tools/experiments/audio_models/verify_parity.py          # references
.venv/bin/python -I tools/experiments/audio_models/convert_coreml.py         # Core ML + parity
.venv/bin/python -I tools/experiments/model_benchmark/build_manifest.py      # manifest
.venv/bin/python -I tools/experiments/model_benchmark/score_models.py yamnet            # ≈ 3 min, one core
.venv/bin/python -I tools/experiments/model_benchmark/score_models.py mn10_as           # ≈ 6 min
.venv/bin/python -I tools/experiments/model_benchmark/score_models.py dymn04_as         # ≈ 11 min
.venv/bin/python -I tools/experiments/model_benchmark/score_models.py mn10_as --variants  # ≈ 25 min
(cd packages/HearingSenseKit && for i in 0 1 2 3; do swift run -c release hs-model-bench apple --shard $i/4 & done; wait)  # ≈ 5 min
.venv/bin/python -I tools/experiments/model_benchmark/evaluate.py
```

The score files (≈ 600 MB) are not committed; the summaries are. The DyMN04 variant run was
stopped after its first stream configuration to keep the Mac free (its 2 s tiled stream is
therefore missing above).
