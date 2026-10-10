"""Compares the Swift pipeline (CoreMLSoundClassifierBackend: AVAudioConverter resampling,
WindowAssembler, Core ML on the CPU; written by `hs-model-bench coreml`) with a Python
computation of the same Core ML model on the same windows of the same streams (soxr resampling).
The two differ only in the resampler and the window bookkeeping, so close agreement verifies the
Swift audio preparation on real recordings.

Usage: .venv/bin/python -I tools/experiments/model_benchmark/compare_swift_python.py <swift name> <model package name>
   e.g. yamnet YAMNet
"""
import json
import sys
from pathlib import Path

import coremltools as ct
import librosa
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import audio_io  # noqa: E402


def main(swift_name, package):
    model = ct.models.MLModel(str(audio_io.ROOT / "models" / "coreml_audio" / f"{package}.mlpackage"),
                              compute_units=ct.ComputeUnit.CPU_ONLY)
    meta = model.user_defined_metadata
    rate, length, labels = int(meta["sample_rate"]), int(meta["window_samples"]), json.loads(meta["labels"])
    column = {label: i for i, label in enumerate(labels)}
    rows = {row["id"]: row for row in audio_io.manifest()}
    diffs, top1, windows, clips, silent = [], 0, 0, 0, 0
    for line in open(audio_io.OUT / "scores" / f"apple_scores_swift_{swift_name}.jsonl"):
        entry = json.loads(line)
        clips += 1
        wave, native, _ = audio_io.stream(rows[entry["id"]])
        wave = librosa.resample(wave, orig_sr=native, target_sr=rate, res_type="soxr_hq")
        for window in entry["streams"]["swift"]:
            start = int(round(window["start"] * rate))
            piece = np.zeros(length, np.float32)
            available = wave[start:start + length]
            piece[: len(available)] = available
            if np.abs(piece).max() < 1e-4:
                silent += 1  # digital silence: trivially identical, not counted
                continue
            reference = model.predict({"waveform": piece[None]})["scores"][0]
            swift = np.zeros(len(labels), np.float32)
            for label, score in window["scores"].items():
                swift[column[label]] = score
            mask = (reference >= 0.01) | (swift >= 0.01)  # the Swift dump omits scores below 0.002
            diffs.append(float(np.abs(reference - swift)[mask].max()) if mask.any() else 0.0)
            top1 += int(reference.argmax() == swift.argmax())
            windows += 1
    result = {"swift": swift_name, "model": package, "clips": clips, "windows_compared": windows,
              "silent_windows_skipped": silent, "top1_agreement": top1 / max(windows, 1),
              "max_abs_score_diff": max(diffs), "median_max_abs_score_diff": float(np.median(diffs)),
              "p95_max_abs_score_diff": float(np.percentile(diffs, 95))}
    print(json.dumps(result))
    out = audio_io.OUT / "conversion" / "swift_pipeline_parity.json"
    existing = json.loads(out.read_text()) if out.exists() else {}
    existing[swift_name] = result
    out.write_text(json.dumps(existing, indent=1))


if __name__ == "__main__":
    main(*sys.argv[1:3])
