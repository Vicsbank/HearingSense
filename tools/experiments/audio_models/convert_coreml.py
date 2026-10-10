"""Converts the candidate classifiers to Core ML (waveform in, scores out) and compares the
converted model with the PyTorch model on identical inputs, CPU only.

Usage: .venv/bin/python -I tools/experiments/audio_models/convert_coreml.py [--seconds 1 2 5 10] [--clips 40]

Output: models/coreml_audio/<Name>.mlpackage (not committed) and
results/background_benchmark/conversion/coreml_parity.json. Forward-only; no training.
"""
import argparse
import json
import sys
import time
from pathlib import Path

import coremltools as ct
import librosa
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import candidates as c  # noqa: E402

OUTPUT = c.ROOT / "models" / "coreml_audio"
REPORT = c.ROOT / "results" / "background_benchmark" / "conversion" / "coreml_parity.json"
ESC = c.ROOT / "data" / "esc50" / "ESC-50-master" / "audio"


def folder_megabytes(path):
    return sum(f.stat().st_size for f in Path(path).rglob("*") if f.is_file()) / 1e6


def convert(name, module, samples, sample_rate, labels):
    example = torch.zeros(1, samples)
    with torch.no_grad():
        traced = torch.jit.trace(c.batch_one_copy(module), example, check_trace=False)
    model = ct.convert(traced, inputs=[ct.TensorType(name="waveform", shape=(1, samples), dtype=np.float32)],
                       outputs=[ct.TensorType(name="scores", dtype=np.float32)],
                       minimum_deployment_target=ct.target.iOS17,
                       # Float32: the power spectrum overflows half precision for loud input.
                       compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY)
    model.short_description = f"{name}: waveform ({samples} samples at {sample_rate} Hz, mono, [-1, 1]) → per-class scores"
    model.user_defined_metadata["sample_rate"] = str(sample_rate)
    model.user_defined_metadata["window_samples"] = str(samples)
    model.user_defined_metadata["labels"] = json.dumps(labels)
    path = OUTPUT / f"{name}.mlpackage"
    model.save(str(path))
    return ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY), path


def verify(module, mlmodel, samples, sample_rate, files):
    diffs, top1, top5, seconds = [], 0, [], []
    for path in files:
        wave, _ = librosa.load(path, sr=sample_rate, mono=True)
        peak = int(np.argmax(np.abs(wave)))  # a window around the loudest sample, so it is not silence
        start = min(max(peak - samples // 2, 0), max(len(wave) - samples, 0))
        window = np.zeros(samples, np.float32)
        piece = wave[start:start + samples]
        window[:len(piece)] = piece
        with torch.no_grad():
            reference = module(torch.from_numpy(window[None])).numpy()[0]
        begin = time.perf_counter()
        converted = mlmodel.predict({"waveform": window[None]})["scores"][0]
        seconds.append(time.perf_counter() - begin)
        diffs.append(float(np.abs(reference - converted).max()))
        top1 += int(reference.argmax() == converted.argmax())
        top5.append(len(set(reference.argsort()[-5:]) & set(converted.argsort()[-5:])))
    return {"clips": len(files), "max_abs_score_diff": max(diffs), "mean_max_abs_score_diff": float(np.mean(diffs)),
            "top1_agreement": top1 / len(files), "mean_top5_overlap": float(np.mean(top5)),
            "mac_cpu_only_predict_ms_median": float(np.median(seconds[3:]) * 1000)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, nargs="+", default=[1.0, 2.0, 5.0, 10.0])
    parser.add_argument("--clips", type=int, default=40)
    arguments = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    files = sorted(ESC.glob("*.wav"))
    files = files[:: len(files) // arguments.clips][: arguments.clips]

    jobs = [("YAMNet", c.load_yamnet(), c.YAMNET_PATCH_SAMPLES, c.YAMNET_SAMPLE_RATE, c.yamnet_labels())]
    for checkpoint, title in (("mn10_as", "EfficientAT_MN10"), ("dymn04_as", "EfficientAT_DyMN04")):
        module = c.load_efficientat(checkpoint)
        for seconds in arguments.seconds:
            samples = int(round(seconds * c.EFFICIENTAT_SAMPLE_RATE))
            jobs.append((f"{title}_{seconds:g}s", module, samples, c.EFFICIENTAT_SAMPLE_RATE, c.efficientat_labels()))

    report = json.loads(REPORT.read_text()) if REPORT.exists() else {}
    for name, module, samples, sample_rate, labels in jobs:
        try:
            mlmodel, path = convert(name, module, samples, sample_rate, labels)
            entry = verify(module, mlmodel, samples, sample_rate, files)
            entry.update(package_megabytes=round(folder_megabytes(path), 2), window_samples=samples,
                         sample_rate=sample_rate, classes=len(labels), precision="float32",
                         parameters=c.parameter_count(module))
        except Exception as error:  # a failed conversion is a result, not something to hide
            entry = {"conversion_failed": f"{type(error).__name__}: {str(error)[:400]}"}
        report[name] = entry
        print(name, json.dumps(entry), flush=True)
        REPORT.write_text(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
