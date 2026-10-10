# Audio Classifier Candidates — Research and Conversion

Research window between Window 3 and Window 4. Date: 2026-10-10. Forward-only; **no training**.

This document describes the candidate classifiers and how they were brought to Core ML. How well
they recognize sounds on common data is in `docs/research/BACKGROUND_MODEL_BENCHMARK.md`; whether
they run on a locked iPhone is in `docs/testing/BACKGROUND_DEVICE_TESTS.md`.

Kinds of numbers, kept apart throughout:

| Kind | Meaning |
|---|---|
| **Published** | From the authors' paper or repository, on their data and protocol. Not re-measured here, and not comparable across models that used different protocols |
| **Mac** | Measured in this window on the MacBook Pro M1 Max |
| **Physical iPhone** | Measured on the iPhone 18 Pro. None in this document yet |

---

## 1. Candidates

| | Apple SoundAnalysis v1 | YAMNet | EfficientAT MN10 (`mn10_as`) | EfficientAT DyMN04 (`dymn04_as`) |
|---|---|---|---|---|
| Source | iOS (`SNClassifierIdentifier.version1`) | Google, [TF Model Garden](https://github.com/tensorflow/models/tree/master/research/audioset/yamnet) | [fschmid56/EfficientAT](https://github.com/fschmid56/EfficientAT) | same repository |
| Architecture | not published | MobileNet-v1 (depthwise-separable convolutions) | MobileNetV3, trained by distillation from transformer models | MobileNetV3 with dynamic convolutions and dynamic ReLU |
| Parameters | not published | ≈ 3.7 M (Published); 3 740 425 (Mac, counted) | 4.88 M (Published); 4 876 831 (Mac) | 1.97 M (Published); 1 961 239 (Mac) |
| Multiply–accumulates | not published | 69.2 M per 0.96 s (Published) | 0.54 G per 10 s clip (Published) | 0.12 G per 10 s clip (Published) |
| Output classes | 303 (enumerated, Window 2) | 521 AudioSet classes (527 minus 6 removed by the authors) | 527 AudioSet classes | 527 AudioSet classes |
| Training data | not published | AudioSet (YouTube) | AudioSet | AudioSet |
| Published metric | **none** | AudioSet eval, 521 classes: mAP 0.306, d′ 2.318 | AudioSet eval: mAP 47.1 | AudioSet eval: mAP 45.0 |
| Input | any rate; the framework resamples | 16 kHz mono | 32 kHz mono | 32 kHz mono |
| Analysis window | 0.5–15 s, chosen by the app (1.5 s in Hearing Sense) | 0.96 s patch (0.975 s of samples), hop 0.48 s | trained and evaluated on 10 s clips; fully convolutional | as MN10 |
| Features | inside the framework | STFT 25 ms / 10 ms, periodic Hann, 64 mel bands 125–7 500 Hz, log(mel + 0.001) | pre-emphasis 0.97, STFT 1 024 / window 800 / hop 320, 128 Kaldi mel bands 0–15 kHz, log(mel + 1e-5), (x + 4.5) / 5 | as MN10 |
| Checkpoint | part of iOS | `yamnet.h5`, 15.3 MB | `mn10_as_mAP_471.pt`, 19.7 MB | `dymn04_as.pt`, 8.1 MB |
| License, code | Apple SDK terms | Apache 2.0 (repository) | MIT (repository) | MIT |
| License, weights | — | not stated separately; distributed by Google with the code | released with the MIT repository | as MN10 |
| Compute units selectable | **no** | yes (Core ML) | yes | yes |

Notes on the published metrics:

- mAP is the mean over classes of the average precision of a ranking. It is **not** an accuracy,
  and a model with mAP 0.47 does not "get 47 % right".
- YAMNet's 0.306 and EfficientAT's 47.1 come from different label sets (521 vs 527), different
  evaluation code and different years. They show that EfficientAT is the stronger AudioSet tagger
  on 10-second clips; they do not say by how much on Hearing Sense's sounds, and nothing about
  1-second windows.
- Apple publishes no figure for its classifier. None is invented here; Apple is compared only on
  data that all models were run on (the benchmark document).
- The EfficientAT repository notes that its models were trained in half precision and that
  float32 CPU inference "may show a slight performance drop". All inference here is float32.

Other models looked at and not taken further: larger EfficientAT variants (`mn20`–`mn40`,
`dymn10`, `dymn20`: more compute for 0.6–2.7 mAP points over `mn10_as`); smaller ones (`mn04_as`
0.98 M parameters / mAP 43.2, `mn05_as` 1.43 M / 44.3: worth a look only if `mn10_as` were too slow
on the iPhone, which the Mac numbers do not suggest). No further model family was downloaded.

## 2. Downloads (approved by the student on 2026-10-10)

| File | Source | Size | SHA-256 (first 12) |
|---|---|---|---|
| `yamnet.h5` | storage.googleapis.com/audioset | 15.3 MB | `13c3308955bb` |
| `yamnet_class_map.csv` | TF Model Garden repository | 14 kB | — |
| `yamnet_classification.tflite` (int8) | tfhub.dev, `lite-model/yamnet/classification/tflite/1` | 4.1 MB | `10c95ea3eb9a` |
| `yamnet_float.tflite` | tfhub.dev, `lite-model/yamnet/tflite/1` | 16.1 MB | `141fba1cdaae` |
| EfficientAT repository, commit `a425fdc` | github.com/fschmid56/EfficientAT | 5.2 MB | — |
| `mn10_as_mAP_471.pt` | EfficientAT release v0.0.1 | 19.7 MB | `0bd7dc2443af` |
| `dymn04_as.pt` | EfficientAT release v0.0.1 | 8.1 MB | `49b0e6357702` |
| ESC-50 archive | github.com/karoldvl/ESC-50 | 646 MB (846 MB unpacked) | `805afc618aff` |
| Python packages `h5py` 3.16.0, `ai-edge-litert` 2.3.0 | PyPI, into `.venv` | ≈ 20 MB | — |

`yamnet_float.tflite` was not in the list shown before the approval: the "classification" TFLite
file turned out to be fully int8-quantized and therefore useless as an exact reference (§3.1), so
Google's float TFLite model of the same network was fetched from the same source (16 MB).
Everything is under `models/third_party/` and `data/esc50/`, outside version control. TensorFlow
was not installed.

## 3. Conversion to Core ML

Design: each model is converted as **waveform in → scores out**. The feature extraction (STFT,
mel filter bank, logarithm) is part of the Core ML graph, expressed as a strided 1-D convolution
whose kernels are window × DFT basis. The app therefore only resamples and cuts windows, and the
Python benchmark and the iPhone run the same feature code. Float32 throughout: the power spectrum
of loud audio exceeds the half-precision range.

Code: `tools/experiments/audio_models/` (`candidates.py`, `verify_parity.py`, `convert_coreml.py`).

### 3.1 Step 1 — the re-expressed model against its reference (Mac, 40 ESC-50 clips)

| Model | Compared with | Largest score difference | Same top class |
|---|---|---|---|
| YAMNet (PyTorch port loaded from `yamnet.h5`) | Google's float TFLite model | 3.8 × 10⁻⁵ | 40 / 40 |
| EfficientAT MN10 (convolution STFT) | the repository's `AugmentMelSTFT` + model | 8.3 × 10⁻⁷ (log-mel: 8.4 × 10⁻⁵) | 40 / 40 |
| EfficientAT DyMN04 (convolution STFT) | the repository's `AugmentMelSTFT` + model | 9.5 × 10⁻⁷ | 40 / 40 |

YAMNet has no PyTorch release, so the network was rebuilt from the published layer table and the
official weights. Two details mattered and are covered by the comparison: TensorFlow's "same"
padding for stride-2 convolutions pads only after the data, and the mel matrix follows
`tf.signal.linear_to_mel_weight_matrix` (HTK scale, no area normalization, DC bin excluded).

Against the int8 "classification" TFLite file the same port agreed on the top class in only 30 of
40 clips. That is the quantization of that file (61 int8 tensors), not an error in the port: the
float model of the same network matches to 10⁻⁵.

Results: `results/background_benchmark/conversion/reference_parity.json`.

### 3.2 Step 2 — Core ML against PyTorch (Mac, CPU only, 40 clips, window on the loudest part)

| Core ML model | Window | Largest score difference | Same top class | Package | Predict, median (Mac CPU) |
|---|---|---|---|---|---|
| `YAMNet` | 0.975 s | 2.7 × 10⁻⁶ | 40 / 40 | 15.9 MB | 1.5 ms |
| `EfficientAT_MN10_1s` | 1 s | 2.0 × 10⁻⁶ | 40 / 40 | 24.1 MB | 2.7 ms |
| `EfficientAT_MN10_2s` | 2 s | 3.8 × 10⁻⁶ | 40 / 40 | 24.1 MB | 4.0 ms |
| `EfficientAT_MN10_5s` | 5 s | 1.2 × 10⁻⁶ | 40 / 40 | 24.1 MB | 6.7 ms |
| `EfficientAT_MN10_10s` | 10 s | 2.2 × 10⁻⁶ | 40 / 40 | 24.1 MB | 13.6 ms |
| `EfficientAT_DyMN04_1s` | 1 s | 1.1 × 10⁻⁶ | 40 / 40 | 12.8 MB | 4.1 ms |
| `EfficientAT_DyMN04_2s` | 2 s | 1.6 × 10⁻⁶ | 40 / 40 | 12.8 MB | 6.3 ms |
| `EfficientAT_DyMN04_5s` | 5 s | 1.9 × 10⁻⁶ | 40 / 40 | 12.8 MB | 11.7 ms |
| `EfficientAT_DyMN04_10s` | 10 s | 2.7 × 10⁻⁶ | 40 / 40 | 12.8 MB | 20.2 ms |

Results: `results/background_benchmark/conversion/coreml_parity.json`.

Two things did not work at first:

- **DyMN04 would not convert.** Its dynamic convolution folds the batch into the channel
  dimension with sizes computed at run time, which the converter cannot trace
  (`TypeError: only 0-dimensional arrays can be converted`). For conversion only, the layer's
  forward pass is written for a batch of one (attention-weighted sum of the K kernels, then an
  ordinary convolution). Difference between that version and the original on the same input: 0.
- **Fewer parameters did not mean faster.** DyMN04 has 40 % of MN10's parameters and is about
  1.5 × slower per window on the Mac CPU (4.1 vs 2.7 ms at 1 s): the per-input kernel generation
  costs more than the smaller layers save.

### 3.3 Step 3 — the Swift pipeline against Python (Mac, 152 benchmark streams)

The app does not run the Python code: `CoreMLSoundClassifierBackend` resamples with
`AVAudioConverter`, cuts windows and calls Core ML. Its scores were compared, window by window,
with the same Core ML model fed by the Python resampler (soxr), on real recordings at 44.1 kHz.
Windows of digital silence are excluded (trivially identical).

| Model | Windows compared | Same top class | Median / 95th percentile / largest score difference |
|---|---|---|---|
| YAMNet, first attempt (`AVAudioConverter`, default algorithm, quality high) | 1 681 | **87.8 %** | 0.052 / 0.236 / 0.693 |
| YAMNet, final (mastering algorithm, quality max) | 1 681 | 100 % | 0.00015 / 0.0008 / 0.004 |
| EfficientAT MN10, final | 1 780 | 100 % | 5 × 10⁻⁶ / 0.009 / 0.090 |
| EfficientAT DyMN04, final | 1 780 | 99.7 % | 3 × 10⁻⁵ / 0.013 / 0.059 |

The first attempt was a real preprocessing defect. Compared with the reference resampler, the
default converter algorithm lowered the top of the new band: −1.3 dB at 5–7 kHz and −6.2 dB at
7–8 kHz for 44.1 → 16 kHz. YAMNet's highest mel bands end at 7.5 kHz, so its scores moved. The
mastering algorithm is flat up to the models' highest mel band (within 0.04 dB in every band the
models use) and costs about 36 ms more converter latency. No time offset between the two
resamplers was found (cross-correlation peak at lag 0).

Results: `results/background_benchmark/conversion/swift_pipeline_parity.json`.

### 3.4 TensorFlow Lite

Not needed. Core ML conversion is exact to 10⁻⁶ for all three models and runs on the CPU, so there
is no reason to add a second inference runtime (and its binary size) to the app. One finding is
worth keeping: Google's ready-made "classification" TFLite file for YAMNet is int8-quantized and
gives noticeably different scores from the float network. If TensorFlow Lite were ever used, the
float model would be the one to compare against, and "the same model in another runtime" must not
be assumed to give the same scores.

## 4. Suitability for short sounds — what the model designs imply

| Model | Designed context | Consequence checked in the benchmark |
|---|---|---|
| Apple v1 | app-selected, 0.5–15 s | works at 1.5 s in the app today |
| YAMNet | 0.96 s patches | built for about one second; longer audio is a series of patches |
| EfficientAT | 10 s clips | nothing in the repository documents short inputs. **Measured: `mn10_as` breaks down below about 3 s** — with the repository's own unmodified code, a 1 s input gives logits of +60 on average and all 527 scores saturate at 1.0 (`BACKGROUND_MODEL_BENCHMARK.md` §5). `dymn04_as` degrades without collapsing |

## 5. Integration in the Swift package

| Piece | File | Role |
|---|---|---|
| `AcousticClassifierBackend` | `Sources/SoundEventDetection/AcousticClassifierBackend.swift` | protocol: lifecycle per segment, audio in, window results and failures out through a sink, metadata (model, runtime, compute units), per-window inference time |
| `AppleSoundAnalysisBackend` | `…/AppleSoundAnalysisBackend.swift` | the existing built-in classifier, moved behind the protocol; behaviour unchanged (all Window 1–3 tests pass) |
| `CoreMLSoundClassifierBackend` | `…/CoreMLSoundClassifierBackend.swift` | converted model through Core ML with explicit compute units (default CPU only); `StreamResampler`, `WindowAssembler` |
| `SoundTaxonomy.audioSet(model:)` | `…/SoundTaxonomy+AudioSet.swift`, `AudioSetLabelTable.swift` (generated) | the same 50 kinds and 11 categories, fed by AudioSet class names kept verbatim |
| `DetectionPolicy.standardAudioSet` | `…/SoundTaxonomy+AudioSet.swift` | the standard policy with its one label-specific rule renamed; thresholds unchanged and **not calibrated** for these models |
| `SoundRecognitionEngine(backend:)` | `…/SoundRecognitionEngine.swift` | chooses the backend; default is Apple's |
| `hs-model-bench` | `Sources/ModelBenchmarkTool/main.swift` | scores backends on the benchmark manifest (macOS) |

Everything after the backend — `ClassificationFrame`, `SoundEventDetector`,
`ConfirmedAcousticEvent`, the speech activity tracker, the pre-roll buffer, the relevance gate —
is untouched and receives frames from either backend. The app selects a third-party model only
in Debug builds with `--hs-classifier` (`apps/ios/HearingSense/Experiments/ExperimentalClassifier.swift`);
without the argument it behaves as before.
