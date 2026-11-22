# Hearing Sense

This repository contains two parts:

1. **Hearing Sense iOS 2.0 — Intelligent Environmental Awareness** (active): a native SwiftUI iPhone
   app that keeps people wearing noise-cancelling headphones aware of their surroundings. Everything
   runs on the iPhone; no audio is stored or uploaded. It is an awareness aid, not a safety or
   emergency system.
2. **Music emotion & genre recognition research** (preserved): the original science-fair system and
   the macOS evaluation/Core ML work, described in the second half of this file and audited in
   [`docs/EXISTING_PROJECT_AUDIT.md`](docs/EXISTING_PROJECT_AUDIT.md).

## Hearing Sense iOS 2.0

### What it does

| | Feature | Where the user meets it |
|---|---|---|
| Switch | Listening on / off | Long press of the Action Button, or the app |
| A | Ambient and scene awareness | The current sound's icon in the Dynamic Island; the scene ("Traffic nearby") as a second line |
| B | Prominent alerts for verified high-priority sounds (sirens, alarms, horns, knocks, glass) | A warning icon with a priority mark; the app asks iOS to expand the island |
| C | A summary of the last two minutes of conversation, on request only | "Summarize" in the expanded island or the app, then Continue (live captions) or Stop |

Sounds are recognized with Apple Sound Analysis (303 labels, 51 kinds) and ranked by a
deterministic attention engine. Speech is transcribed on the device only while the user turns
transcription on and is kept in memory for 120 seconds. Summaries are written by Qwen3.5-4B
(4-bit, Swift MLX, on the iPhone) with Apple Foundation Models as the fallback, then checked by
`SummaryPostprocessing` so that no value, name or negation is invented. The full design is in
[`docs/PRODUCT_ARCHITECTURE_FINAL.md`](docs/PRODUCT_ARCHITECTURE_FINAL.md).

### Status (Window 9)

Windows 1–9 are complete in code. The Release build is installed on an iPhone 18 Pro (iOS 27.2).
On that iPhone, the Qwen and the Apple summary paths each pass 28 of 28 checks on fixed synthetic
English input. The package tests pass (676, with 9 optional skips). Not yet verified: real
conversations, Qwen inference while the iPhone is locked or in the background, battery and heat,
and alert reliability on real sound. Details: the top of
[`docs/PROJECT_HANDOFF.md`](docs/PROJECT_HANDOFF.md),
[`docs/testing/WINDOW9_IPHONE_VALIDATION.md`](docs/testing/WINDOW9_IPHONE_VALIDATION.md) and
[`docs/testing/WINDOW9_STABILITY_VALIDATION.md`](docs/testing/WINDOW9_STABILITY_VALIDATION.md).

### Where things are

| Path | Contents |
|---|---|
| `apps/ios/HearingSense/` | The SwiftUI app: views, listening control, conversation summaries, Live Activity control, diagnostics |
| `apps/ios/HearingSenseWidgets/` | Live Activity and Dynamic Island views |
| `packages/HearingSenseKit/` | Core logic as Swift package modules, with the tests |
| `packages/QwenRuntime/` | On-device Qwen runtime and its Mac tools |
| `docs/` | Handoff, architecture, one report per window; `docs/research/` and `docs/testing/` |
| `results/` | Evaluation and device-test evidence |
| `tools/` | Evaluation, build and model-preparation scripts |

Not in Git: the datasets under `data/` (see [`data/README.md`](data/README.md)), the Qwen
checkpoint (about 2.9 GB, installed on the iPhone outside the app bundle) and
`packages/RuntimeDependencies/` (the patched MLX sources, prepared by
`tools/prepare_qwen_runtime.py`).

### Build and test

```bash
cd packages/HearingSenseKit && swift test
```

```bash
xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

More commands: [`docs/PROJECT_HANDOFF.md`](docs/PROJECT_HANDOFF.md) §10.

### Branches

`main` is the only branch and holds Window 9. Earlier windows are in its history. Work that is
not in `main` is kept as tags: `archive/window6-3-personal-relevance` (semantic-attention
research, Windows 6.1–6.3), `archive/local-model-comparison`, `archive/window5-post-r1-snapshot`
and `archive/window8-snapshot`. Older documents still name the deleted branches and
`.claude/worktrees/...` folders.

---

# Music Emotion & Genre Recognition (research, preserved)

Upload a song and get:
- **Emotion**: the top 3 of 9 GEMS emotions (amazement, solemnity, tenderness, nostalgia,
  calmness, power, joyful activation, tension, sadness)
- **Genre**: one of 10 GTZAN genres

Both models read Mel spectrograms of short audio segments and average the predictions over
the whole song.

| Task | Model | Data | Weights |
|---|---|---|---|
| Emotion | EfficientNet-B0 (ImageNet-pretrained, via `timm`) + custom head | Emotify, 400 tracks | `models/emotion_efficientnet.pth` |
| Genre | SpectrogramCNN_GRUNet (3 conv blocks + 2 GRU layers) | GTZAN, 1,000 clips | `models/genre_crnn.pth` |

## Project layout
This layout predates `ml/`, `models/coreml/` and the evaluation results in
`docs/evaluation_results.md`.
```
src/
  config.py              paths and hyperparameters
  emotion_dataset.py     Emotify dataset (5 s segments, 128-band Mel)
  emotion_model.py       EfficientNetModel
  emotion_preprocess.py  builds data/emotify/processed_data.csv from the raw annotations
  train_emotion.py       trains the emotion model, writes plots to results/emotion/
  genre_model.py         SpectrogramCNN_GRUNet + shared Mel preprocessing
  train_genre.py         trains the genre model, writes plots to results/genre/
  infer.py               runs both models on one audio file
  app.py                 FastAPI web app
  templates/             homepage.html, app.html
tools/plot_mel_spectrogram.py
data/        datasets and sample songs (see data/README.md)
models/      trained weights
results/     training curves, confusion matrix, ROC
docs/        science-fair documents and model diagrams
```

## Setup
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Usage
Predict one file:
```bash
python src/infer.py "data/samples/Shattered Roads.mp3"
```

Web app (then open http://127.0.0.1:8000):
```bash
python src/app.py
```

Retrain (download the datasets first, see `data/README.md`):
```bash
python src/emotion_preprocess.py
python src/train_emotion.py
python src/train_genre.py
```

## Current results
Emotion model (validation set, 80 tracks): macro ROC AUC 0.78. The confusion matrix diagonal
is 23/80; the model never predicts amazement, tenderness, power or sadness.
See `results/emotion/`.

No saved evaluation exists yet for the genre model.

Known limitations:
- Genre training splits clips into segments before the train/test split, so segments of the
  same song can appear in both sets.
- Emotion validation uses one random 5 s segment per track, so scores vary between runs, and
  there is no separate test set.

## History
This project started as a science-fair entry (HearingSense). That version also generated
lyrics with GPT-4o and new music with Suno; both were removed. The original research plan,
slides and pipeline diagram are kept in `docs/science_fair/` unchanged.

## License

The source code is released under the [MIT License](LICENSE).

Exceptions: the trained model weights in `models/` were trained on datasets licensed for
non-commercial research only (for example GTZAN and DEAM; see [`data/README.md`](data/README.md)).
They are not covered by the MIT License and may be used for non-commercial research only.
Third-party sources fetched by `tools/prepare_qwen_runtime.py` and the Qwen checkpoint keep their
own licenses.
