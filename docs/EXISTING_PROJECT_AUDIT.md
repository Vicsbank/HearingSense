# Existing Project Audit — Hearing Sense (pre-iOS 2.0)

Audit date: 2026-10-09 (Window 1). Auditor: Claude Code, working in this repository.
Scope: everything in `Music Recognition/` before the iOS 2.0 work started, with emphasis on the
"macOS Model Realization" phase completed earlier the same day.

Evidence levels used below:

- **Verified** — reproduced or directly inspected in Window 1 (command or file given).
- **Recorded** — taken from a result file written by an earlier session; spot-checked, not re-run.
- **Unverified** — claimed somewhere but not confirmed.

---

## 1. Summary

1. The repository holds two generations of **music** recognition work:
   - the original science-fair system (Windows era): two PyTorch models trained by the student, plus a FastAPI web app;
   - the macOS phase (2026-10-09): an audit of those models, a pretrained-model replacement pipeline
     (Essentia models converted to one Core ML model), and a first forward-only evaluation round.
2. **No model was trained, fine-tuned or re-trained during the macOS phase.** The repository shows
   evaluation, conversion and auditing only: `docs/audit_report.md` states that no training,
   backpropagation or parameter update was performed (“本次会话没有进行任何训练、反向传播或参数更新”),
   `docs/evaluation_results.md` states forward inference only, and `ml/` contains no optimizer or
   backward-pass code (searched in Window 1).
   The only trained-by-this-project weights are the two legacy checkpoints. This corrects the
   assumption that the macOS phase included “dataset-based training”.
3. None of the existing models addresses **environmental sound awareness**, the goal of iOS 2.0.
   Their main reusable value is the evaluation harness, the noise/reverb datasets and the Core ML
   conversion experience, not the models themselves.
4. The directory is **not a Git repository** (`git status` → “not a git repository”). Nothing is
   under version control; there is no history to recover from. See §8.
5. Window 1 changed nothing in the existing research directories; all new work is additive (§9).

---

## 2. Development environment (Verified)

| Item | Value |
|---|---|
| Machine | MacBook Pro, Apple M1 Max, 32 GB (also the student's daily school computer) |
| macOS | 27.2 (build 26B5101f) |
| Xcode | 27.0 (27A266a), installed during Window 1; iOS 27.0 SDK + iOS 27.0 Simulator runtime |
| Swift | 6.4 (Xcode toolchain and Command Line Tools) |
| Python | 3.12 virtualenv at `.venv/` (1.2 GB), pinned in `requirements.txt` (torch/torchaudio 2.7.0, coremltools 9.0, onnxruntime 1.31, essentia 2.1b6) |
| Test device | iPhone 18 Pro (iPhone19,2), iOS 27.2, Developer Mode enabled; AirPods Pro |

---

## 3. Inventory

| Path | What it is | Status |
|---|---|---|
| `src/` | Legacy science-fair code: models, training scripts, `infer.py`, FastAPI `app.py` + templates | Inference runs (Recorded, audit_report §2). Training not run (prohibited) |
| `models/emotion_efficientnet.pth` | Legacy emotion checkpoint, 17.65 MB | Present; SHA-256 `f18394a3…a927` |
| `models/genre_crnn.pth` | Legacy genre checkpoint, 1.55 MB | Present; SHA-256 `a70b5770…19f6` |
| `models/pretrained/essentia/` | 13 Essentia ONNX models + JSON metadata, `SHA256SUMS.json` | Present (git-ignored, re-downloadable with `tools/download_pretrained.py`) |
| `models/coreml/HearingSenseMusic.mlpackage` | Converted Core ML model (29 MB) + `labels.json` + `export_report.json` | Present; weight.bin SHA-256 `645e0dc8…a498` |
| `ml/` | `hearing_sense_ml` package (frontend, Essentia wrappers, datasets, augment, metrics, interpret), `evaluate.py`, `export_coreml.py`, tests | 12/12 tests pass (Verified, see §6) |
| `tools/` | `audit_legacy.py`, `download_datasets.py`, `download_pretrained.py`, `plot_mel_spectrogram.py` | Not re-run in Window 1 |
| `data/` | Emotify (12 local + full 400), GTZAN, MTG-Jamendo shard 00, PMEmo 2019, LibriSpeech dev-clean, DEMAND ×4, MIT IR survey, TTS speech, sample songs | ≈ 4.2 GB, see `data/README.md` |
| `results/emotion/` | Plots from the original emotion training (confusion matrix, ROC, curves) | Historical; generated on the original (Windows) machine |
| `results/audit/legacy_audit.json` | Forward-only audit of the legacy models | Recorded |
| `results/eval/{emotify,emotify_local,pmemo}/` | Evaluation round 1: `report.json`, `summary.md`, `cache.npz` | Recorded; headline numbers spot-checked against `docs/evaluation_results.md` (they match) |
| `docs/audit_report.md`, `docs/evaluation_results.md` | macOS-phase reports (Chinese) | Kept unchanged |
| `docs/science_fair/` | Original research plan, slides, pipeline diagram | Kept unchanged |
| `docs/diagrams/` | draw.io diagrams of both legacy models | Kept unchanged |
| `app/` | Started native **macOS** Swift package (`AudioRingBuffer`, `LevelMeter`) | **Does not build** (Verified): `Package.swift` declares targets `HearingSense`, `hs-cli`, `hs-selftest` whose source folders do not exist; `scripts/build_app.sh` referenced in a comment does not exist |

---

## 4. Models

### 4.1 Legacy emotion model (trained in the science-fair phase)

| Item | Value (source) |
|---|---|
| Architecture | `timm` EfficientNet-B0 (`efficientnet_b0.ra_in1k`, ImageNet-pretrained) + head Dropout 0.5 → Linear 1280→256 → ReLU → Dropout 0.5 → Linear 256→9 (`src/emotion_model.py`) |
| Parameters | 4.34 M (Recorded, audit_report §2) |
| Input | 44.1 kHz mono, 5 s segments, librosa Mel 128 bands, n_fft 2048, hop 512, `power_to_db(ref=max)`; 1 channel repeated to 3 (`src/infer.py`) |
| Output | 9 GEMS logits → softmax; top-3 shown; averaged over segments |
| Labels | amazement, solemnity, tenderness, nostalgia, calmness, power, joyful_activation, tension, sadness (`src/config.py`, leading spaces in CSV column names) |
| Training data | Emotify, 400 one-minute excerpts; CrossEntropy on GEMS proportions (`src/train_emotion.py`); AdamW lr 5e-4, cosine schedule, 30 epochs, batch 128 (`src/config.py`) |
| Training date / hardware | Not recorded in the repository (README: originally developed on Windows) |
| Reported metric | “Validation macro ROC AUC 0.78”, 80 tracks (README; plots in `results/emotion/`) — validation set was also used for epoch selection |
| Re-evaluation (Recorded) | Confusion diagonal 23/80 = 28.8 % vs majority baseline 26.2 % (audit V4). All-segment re-evaluation on its own 80-track validation split: top-1 42.5 % [32.5, 52.5], balanced 30.2 %, baseline 21.2 % (evaluation_results §2.3). Optimistic (same tracks chose the epoch); no independent test set exists |
| Known problems | Multi-label GEMS data trained as single-label; class imbalance (amazement argmax in 3/400 tracks); near-uniform outputs (top-1 prob 0.15–0.38); emotion confounded with genre in Emotify |

### 4.2 Legacy genre model (trained in the science-fair phase)

| Item | Value (source) |
|---|---|
| Architecture | `SpectrogramCNN_GRUNet`: 3 × (Conv3×3 32/64/128 → BN → ReLU → MaxPool 2 → Dropout 0.25) → 2 × GRU(hidden 68) → FC 68→512→10 (`src/genre_model.py`) |
| Parameters | 0.38 M (Recorded) |
| Input | 44.1 kHz mono, 5.5 s segments, torchaudio Mel 64 bands, n_fft 1024, `AmplitudeToDB(top_db=80)` |
| Output | 10 GTZAN genres: blues, classical, country, disco, hiphop, jazz, metal, pop, reggae, rock |
| Training data | GTZAN 1,000 × 30 s clips (`src/train_genre.py`) |
| Reported metric | **None saved** from the training phase |
| Known problems | Segment-level split → same song in train and test (data leakage); training pads 3 s segments to 5.5 s while inference uses continuous 5.5 s (train/inference mismatch); cannot reject non-music (white noise → pop 1.000, silence → hiphop 1.000; Recorded, audit V1–V3) |

### 4.3 macOS-phase candidate: `HearingSenseMusic.mlpackage` (converted, **not trained**)

| Item | Value (source) |
|---|---|
| Components | Essentia/MTG pretrained models: Discogs-EffNet (`discogs-effnet-bsdynamic-1`), MusiCNN (`msd-musicnn-1`), 5 mood heads, danceability, voice/instrumental, MTG-Jamendo mood/theme (56), DEAM + emoMusic valence/arousal heads |
| Conversion | ONNX → `onnx2torch` → one traced `MusicAnalyzer` (Mel front-end inside the graph) → Core ML ML Program, FP32, `minimum_deployment_target = macOS13` (`ml/export_coreml.py`) |
| Input | `waveform` float32 (1, 79,872) = 4.992 s at **16 kHz** mono |
| Outputs | `styles` (400 Discogs styles, 15 parents), `moods` (aggressive, happy, party, relaxed, sad, danceable, voice), `moodtheme` (56), `valence_arousal` (valence, arousal on 1–9), `embedding` (`models/coreml/labels.json`) |
| Parity | Max abs. difference vs ONNX Runtime reference ≤ 4.2 × 10⁻⁶ on 5 windows (`export_report.json`) |
| Latency (M1 Max, one window, median) | CPU 59 ms · CPU+GPU 22 ms · All units 21 ms (`export_report.json`) — **Mac only; not measured on iPhone** |
| License | **CC BY-NC-SA 4.0** — non-commercial; derivatives inherit the license |
| iOS status | Never loaded on iOS. Expected to be loadable on iOS 16+ (macOS 13 ML Program spec), **unverified** |

### 4.4 Evaluation round 1 (forward-only, user-approved 1-hour budget; Recorded)

Simulated conditions (phone speaker + real room IR, LibriSpeech babble, DEMAND ambience, low level).
Not real microphone recordings.

| Result | Value |
|---|---|
| Emotify genre, 4 classes, track-level, clean (201/400 tracks) | New model 64.7 % [58.2, 71.1]; Pop recall 8 % (Discogs taxonomy mismatch) |
| Comparable 3 classes, clean | New 54.2 % vs legacy 51.6 % (CIs overlap) |
| Babble 10 dB / ambient 10 dB (3 classes) | New 49.7 % vs legacy 32.7 % / new 52.9 % vs legacy 38.6 % |
| PMEmo valence/arousal (500/767 tracks), clean | Arousal r = 0.73 [0.68, 0.77], valence r = 0.59 [0.54, 0.65] |
| PMEmo with real-room reverb | Valence r = 0.14 [0.06, 0.23] (collapses) |
| Non-music rejection | Neither model rejects speech or ambient noise; a separate music/non-music gate is required |

GTZAN and MTG-Jamendo were downloaded but **not evaluated** yet.

---

## 5. Datasets (on disk, Verified sizes)

| Dataset | Size | Used for | License note |
|---|---|---|---|
| Emotify (`data/emotify/`, 400 tracks in `audio_full/`, 12 in `audio/`) | 377 MB | Legacy emotion training; evaluation | Not stated on source; academic use |
| GTZAN (`data/gtzan/genres/`) | 1.2 GB | Legacy genre training; not yet evaluated | Research only |
| MTG-Jamendo shard 00 | 505 MB | Not yet evaluated | CC BY-NC-SA (metadata) |
| PMEmo 2019 | 1.2 GB | Valence/arousal evaluation | Research |
| LibriSpeech dev-clean, DEMAND (4 scenes), MIT IR survey | 951 MB total | Noise/reverb conditions | CC BY 4.0 / CC BY 4.0 / unverified |

The environmental sets (DEMAND, LibriSpeech, MIT IR) are directly useful for evaluating Apple
SoundAnalysis and speech detection offline in later windows (forward-only).

Note: legacy training scripts expect `data/gtzan/genres_original/` and the 12-track
`data/emotify/audio/`; the downloaded GTZAN lives in `data/gtzan/genres/`. Retraining would need
path changes — not done, because training is out of scope.

---

## 6. What works (Verified in Window 1)

| Check | Command | Result |
|---|---|---|
| ML unit tests (forward-only) | `.venv/bin/python -m pytest ml/tests -q -p no:cacheprovider` | 12 passed in 21 s |
| Legacy macOS Swift package | `swift build` in `app/` (scratch dir outside repo) | Fails: missing `Sources/HearingSense` |
| Apple SoundAnalysis label enumeration (macOS) | `SNClassifySoundRequest(.version1).knownClassifications` | 303 labels; window 0.5–15 s, default 3 s, overlap 0.5 → `docs/research/sound_analysis_labels_v1_macos27.txt` |

Not re-run in Window 1: `src/infer.py`, `ml/evaluate.py`, `ml/export_coreml.py`, `tools/*`
(their earlier outputs are on disk; re-running is safe but was not needed).

---

## 7. Reuse assessment for iOS 2.0

| Asset | Reuse | Notes |
|---|---|---|
| Noise/reverb datasets + `ml/hearing_sense_ml/augment.py` conditions | **High** | Offline, forward-only evaluation of SoundAnalysis / speech detection under babble, ambience and reverb (Window 2/6) |
| `ml/hearing_sense_ml/metrics.py` (bootstrap CIs by track) | High | Same evaluation discipline for event detection |
| Core ML conversion workflow (`export_coreml.py`, parity + latency report) | Medium | Template if a custom model is ever needed; Apple's built-in classifier comes first |
| `HearingSenseMusic.mlpackage` | Low / optional | A possible “music context” detail after SoundAnalysis detects `music`; CC BY-NC-SA, noise-sensitive, unverified on iOS |
| `app/Sources/HearingSenseCore/AudioRingBuffer.swift` | Medium | Pattern for pre-roll buffering before speech detection (Window 3); copy, do not depend on the broken package |
| Legacy PyTorch models, FastAPI app, Emotify/GTZAN/PMEmo/Jamendo | Music-only | Preserve as research history; not used by the iOS app |

---

## 8. Git status and preservation

- **No Git repository exists.** All prior work is unversioned. This is the largest preservation risk.
- Recommended (needs the student's approval, not done in Window 1): `git init`, then a baseline
  commit of the current tree. `.gitignore` already excludes the large data, the virtualenv, model
  downloads and (since Window 1) Xcode per-user state. Checkpoints in `models/*.pth` (19 MB total)
  are small enough to commit; alternatively back them up separately.
- Research assets that must be preserved (do not move or overwrite): `models/*.pth`,
  `models/coreml/`, `models/pretrained/essentia/SHA256SUMS.json`, `results/`, `docs/audit_report.md`,
  `docs/evaluation_results.md`, `docs/science_fair/`, `docs/diagrams/`, `data/README.md`,
  `data/downloads/CHECKSUMS.json`, `data/emotify/*.csv`, `ml/`, `src/`, `tools/`, `requirements.txt`.

## 9. Changes made to existing files in Window 1

Only two existing files were edited; nothing was moved or deleted:

- `.gitignore` — appended entries for Xcode/SwiftPM per-user state, `.pytest_cache/`, `data/emotify/audio_full/`.
- `README.md` — added a repository overview pointing to the iOS 2.0 work; the legacy content is unchanged below it.

## 10. Open uncertainties

- Exact training date, hardware and random seeds of the legacy checkpoints are not recorded.
- Whether `HearingSenseMusic.mlpackage` loads and runs on iPhone (and its latency there) is unknown.
- Discogs-EffNet's training data is undisclosed; overlap with test sets cannot be excluded.
- Citations in the science-fair slides (“Smith & Doe, 2023” etc.) remain unverifiable (audit_report §4).
- SoundAnalysis labels were enumerated on macOS 27.2; the iOS list is expected to match for
  `version1` but has not been enumerated on the iPhone.
