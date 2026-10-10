"""Checks the re-expressed models against their reference implementations on identical audio.

  YAMNet:      PyTorch (weights from yamnet.h5, conv STFT)  vs  Google's official float TFLite model
  EfficientAT: conv-STFT front end + backbone               vs  repository AugmentMelSTFT + backbone

Usage: .venv/bin/python -I tools/experiments/audio_models/verify_parity.py [n_clips]
"""
import json
import sys
from pathlib import Path

import librosa
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import candidates as c  # noqa: E402

ESC = c.ROOT / "data" / "esc50" / "ESC-50-master" / "audio"


def clips(count):
    files = sorted(ESC.glob("*.wav"))
    step = len(files) // count
    return files[::step][:count]


def compare(a, b):
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    return {"max_abs_diff": float(np.abs(a - b).max()), "mean_abs_diff": float(np.abs(a - b).mean()),
            "top1_agree": bool(a.mean(0).argmax() == b.mean(0).argmax()),
            "top5_overlap": len(set(a.mean(0).argsort()[-5:]) & set(b.mean(0).argsort()[-5:]))}


def summarize(name, rows):
    out = {"model": name, "clips": len(rows),
           "max_abs_diff": max(r["max_abs_diff"] for r in rows),
           "mean_abs_diff": float(np.mean([r["mean_abs_diff"] for r in rows])),
           "top1_agreement": sum(r["top1_agree"] for r in rows) / len(rows),
           "mean_top5_overlap": float(np.mean([r["top5_overlap"] for r in rows]))}
    print(json.dumps(out))
    return out


@torch.no_grad()
def main(count):
    files = clips(count)
    results = []

    from ai_edge_litert.interpreter import Interpreter
    yamnet = c.load_yamnet()
    rows = []
    for path in files:
        wave, _ = librosa.load(path, sr=16_000, mono=True)
        # Google's float TFLite model takes the whole waveform and pads its end, so it can return
        # one more patch than the unpadded framing used here; the common patches are compared.
        # (The "classification" TFLite variant is fully int8-quantized and is not an exact reference.)
        interpreter = Interpreter(str(c.YAMNET_DIR / "yamnet_float.tflite"))
        entry = interpreter.get_input_details()[0]
        interpreter.resize_tensor_input(entry["index"], [len(wave)])
        interpreter.allocate_tensors()
        interpreter.set_tensor(entry["index"], wave.astype(np.float32))
        interpreter.invoke()
        ours = yamnet(torch.from_numpy(c.yamnet_patches(wave))).numpy()
        reference = interpreter.get_tensor(interpreter.get_output_details()[0]["index"])[: len(ours)]
        assert reference.shape == ours.shape, (reference.shape, ours.shape)
        rows.append(compare(reference, ours))
    results.append(summarize("yamnet: torch port vs official float tflite", rows))

    frontend = c.load_efficientat_reference_frontend()
    for name in c.EFFICIENTAT_WEIGHTS:
        model = c.load_efficientat(name)
        rows, feature_diff = [], 0.0
        for path in files:
            wave, _ = librosa.load(path, sr=32_000, mono=True)
            wave = torch.from_numpy(wave[None])
            spec = frontend(wave)
            feature_diff = max(feature_diff, float((spec - model.features(wave)).abs().max()))
            reference = torch.sigmoid(model.backbone(spec.unsqueeze(0))[0]).numpy()
            rows.append(compare(reference, model(wave).numpy()))
        out = summarize(f"{name}: conv-STFT front end vs repository front end", rows)
        out["max_abs_log_mel_diff"] = feature_diff
        out["parameters"] = c.parameter_count(model.backbone)
        print(json.dumps({"max_abs_log_mel_diff": feature_diff, "parameters": out["parameters"]}))
        results.append(out)
    results.append({"yamnet_parameters": c.parameter_count(yamnet)})
    print(json.dumps(results[-1]))
    output = c.ROOT / "results" / "background_benchmark" / "conversion"
    output.mkdir(parents=True, exist_ok=True)
    (output / "reference_parity.json").write_text(json.dumps(results, indent=1))
    return results


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 40)
