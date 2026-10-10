"""Builds the benchmark manifest: which audio, which ground-truth kind, which split, and exactly
which samples every model receives for each context length.

Sources (all already on disk; nothing is downloaded here):
  ESC-50      2 000 five-second clips, clip-level labels, 5 folds (clips from one source recording
              stay in one fold). 47 of 50 classes map to a Hearing Sense kind.
  LibriSpeech dev-clean, utterances of at least 10 s → kind "speech".
  GTZAN       30 s music clips → kind "music".

Splits: development (ESC folds 1–2, half of the speakers, even-numbered GTZAN clips) for choosing
thresholds and aggregation; test (ESC folds 3–5, the other speakers, odd-numbered GTZAN clips) is
only scored once thresholds are fixed.

Contexts of 1, 2, 5 and 10 s. No dataset here has event timestamps, so short contexts are placed
on the loudest part of the clip (maximum energy of a sliding window, 10 ms resolution). That
guarantees the context contains sound, not that it contains the whole event; `active_fraction`
records how much of each context is above −40 dB relative to the clip's peak level. ESC-50 clips
are 5 s long: their "10 s" context is the clip followed by 5 s of digital silence.

Usage: .venv/bin/python -I tools/experiments/model_benchmark/build_manifest.py
"""
import csv
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
import taxonomy  # noqa: E402

ROOT = taxonomy.ROOT
OUT = ROOT / "results" / "background_benchmark"
CONTEXTS = [1.0, 2.0, 5.0, 10.0]
SPEECH_CLIPS, MUSIC_CLIPS = 200, 200


def envelope(samples, rate):
    """RMS per 10 ms frame."""
    hop = rate // 100
    frames = len(samples) // hop
    return np.sqrt((samples[: frames * hop].reshape(frames, hop) ** 2).mean(axis=1) + 1e-12)


def place(samples, rate, seconds):
    """Start (in samples) of the `seconds`-long window with the most energy; 0 if the clip is not longer."""
    length = int(round(seconds * rate))
    if len(samples) <= length:
        return 0
    hop = rate // 100
    power = envelope(samples, rate) ** 2
    width = length // hop
    sums = np.convolve(power, np.ones(width), mode="valid")
    return int(min(int(np.argmax(sums)) * hop, len(samples) - length))


def describe(path, dataset, source_class, kind, split, group):
    samples, rate = sf.read(path, dtype="float32", always_2d=True)
    samples = samples[:, 0]  # channel 0, as the app's pipeline does
    rms = envelope(samples, rate)
    peak = float(rms.max())
    active = rms > peak * 10 ** (-40 / 20)
    onset = float(np.argmax(rms > peak * 10 ** (-30 / 20))) / 100  # first frame within 30 dB of the peak
    contexts = {}
    for seconds in CONTEXTS:
        start = place(samples, rate, seconds)
        frames = slice(start * 100 // rate, min(len(samples), start + int(seconds * rate)) * 100 // rate)
        available = min(len(samples) - start, int(round(seconds * rate)))
        contexts[f"{seconds:g}"] = {
            "start_sample": start, "samples": int(round(seconds * rate)), "available_samples": int(available),
            "active_fraction": round(float(active[frames].sum()) / max(int(seconds * 100), 1), 3)}
    return {"id": f"{dataset}/{Path(path).stem}", "dataset": dataset, "path": str(Path(path).relative_to(ROOT)),
            "source_class": source_class, "kind": kind, "split": split, "group": group, "sample_rate": rate,
            "duration": round(len(samples) / rate, 3), "onset": round(onset, 2), "peak_rms": round(peak, 5),
            "contexts": contexts}


def even(items, count):
    step = len(items) / count
    return [items[int(i * step)] for i in range(count)] if count < len(items) else items


def main():
    rows, skipped = [], []
    esc = ROOT / "data" / "esc50" / "ESC-50-master"
    with open(esc / "meta" / "esc50.csv") as file:
        for row in csv.DictReader(file):
            if row["category"] in taxonomy.ESC50_EXCLUDED:
                skipped.append((row["filename"], "class excluded from the taxonomy"))
                continue
            split = "dev" if int(row["fold"]) <= 2 else "test"
            try:
                rows.append(describe(esc / "audio" / row["filename"], "esc50", row["category"],
                                     taxonomy.ESC50_TO_KIND[row["category"]], split, row["src_file"]))
            except Exception as error:
                skipped.append((row["filename"], f"unreadable: {error}"))

    libri = sorted((ROOT / "data" / "noise" / "librispeech").rglob("*.flac"))
    long_enough = [p for p in libri if not p.name.startswith("._") and sf.info(p).duration >= 10.0]
    speakers = sorted({p.parts[-3] for p in long_enough})
    dev_speakers = set(speakers[::2])
    for path in even(long_enough, SPEECH_CLIPS):
        speaker = path.parts[-3]
        rows.append(describe(path, "librispeech", "read_speech", "speech",
                             "dev" if speaker in dev_speakers else "test", speaker))

    gtzan = sorted(p for p in (ROOT / "data" / "gtzan").rglob("*.wav") if not p.name.startswith("._"))
    for path in even(gtzan, MUSIC_CLIPS):
        number = int(path.stem.split(".")[-1])
        try:
            rows.append(describe(path, "gtzan", path.parent.name, "music", "dev" if number % 2 == 0 else "test",
                                 path.stem))
        except Exception as error:
            skipped.append((path.name, f"unreadable: {error}"))

    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / "manifest.jsonl", "w") as file:
        for row in rows:
            file.write(json.dumps(row) + "\n")
    summary = {"clips": len(rows), "skipped": len(skipped), "skipped_reasons": {},
               "by_split": {}, "by_dataset": {}, "kinds": {}}
    for _, reason in skipped:
        summary["skipped_reasons"][reason.split(":")[0]] = summary["skipped_reasons"].get(reason.split(":")[0], 0) + 1
    for row in rows:
        summary["by_split"][row["split"]] = summary["by_split"].get(row["split"], 0) + 1
        summary["by_dataset"][row["dataset"]] = summary["by_dataset"].get(row["dataset"], 0) + 1
        entry = summary["kinds"].setdefault(row["kind"], {"dev": 0, "test": 0})
        entry[row["split"]] += 1
    summary["mean_active_fraction"] = {
        dataset: {key: round(float(np.mean([r["contexts"][key]["active_fraction"] for r in rows if r["dataset"] == dataset])), 3)
                  for key in rows[0]["contexts"]} for dataset in summary["by_dataset"]}
    (OUT / "manifest_summary.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
