# Hearing Sense

This repository contains two parts:

1. **Hearing Sense iOS 2.0 — Intelligent Environmental Awareness** (active): a native SwiftUI iPhone
   app that keeps people wearing noise-cancelling headphones aware of their surroundings, using
   on-device Apple frameworks. Code in `apps/ios/` and `packages/HearingSenseKit/`.
   Start with [`docs/PROJECT_HANDOFF.md`](docs/PROJECT_HANDOFF.md); see also
   [`docs/IOS_ARCHITECTURE.md`](docs/IOS_ARCHITECTURE.md),
   [`docs/AUDIO_ROUTING_FEASIBILITY.md`](docs/AUDIO_ROUTING_FEASIBILITY.md) and
   [`docs/IOS_DEVELOPMENT_ROADMAP.md`](docs/IOS_DEVELOPMENT_ROADMAP.md).
   Status: Window 1 (audio foundation), Window 2 (real-time Apple SoundAnalysis recognition,
   [`docs/WINDOW2_SOUND_ANALYSIS_REPORT.md`](docs/WINDOW2_SOUND_ANALYSIS_REPORT.md)) and Window 3
   (on-device speech transcription and Apple Foundation Models summaries,
   [`docs/WINDOW3_SPEECH_INTELLIGENCE_REPORT.md`](docs/WINDOW3_SPEECH_INTELLIGENCE_REPORT.md)) are
   implemented. Windows 2 and 3 are verified on the Mac and in the iPhone Simulator;
   physical-device tests are still open.
   Datasets under `data/` are not versioned in Git (see `data/README.md`).
2. **Music emotion & genre recognition research** (preserved): the original science-fair system and
   the macOS evaluation/Core ML work, described below and audited in
   [`docs/EXISTING_PROJECT_AUDIT.md`](docs/EXISTING_PROJECT_AUDIT.md). Note: the "Project layout"
   section below predates `ml/`, `models/coreml/` and the evaluation results in
   `docs/evaluation_results.md`.

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
