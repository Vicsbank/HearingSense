"""Forward-only scoring of the third-party candidates on the benchmark manifest, using the
converted Core ML models (float32, CPU only) — the artefacts that would ship. Their agreement
with the PyTorch references is measured separately (convert_coreml.py: max score difference
≈ 1e-6).

For every clip: label scores for the 1 / 2 / 5 / 10 s contexts, and per-window label scores on the
event-detection stream. Output: results/background_benchmark/scores/scores_<model>.npz (not
committed; regenerate with this script). Apple's classifier is scored on the same sample ranges by
`swift run hs-model-bench` (packages/HearingSenseKit).

Usage: .venv/bin/python -I tools/experiments/model_benchmark/score_models.py [yamnet mn10_as dymn04_as] [--limit N] [--variants]
"""
import sys
import time
from pathlib import Path

import librosa
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "audio_models"))
import audio_io  # noqa: E402
import candidates as c  # noqa: E402

CONTEXTS = ["1", "2", "5", "10"]
STREAM_HOP = 0.5


def windows(samples, length, hop):
    count = 1 + max(len(samples) - length, 0) // hop
    return np.stack([samples[i * hop: i * hop + length] for i in range(count)])


def coreml(name):
    import coremltools as ct
    return ct.models.MLModel(str(c.ROOT / "models" / "coreml_audio" / f"{name}.mlpackage"),
                             compute_units=ct.ComputeUnit.CPU_ONLY)


def predict(model, batch):
    return np.stack([model.predict({"waveform": window[None]})["scores"][0] for window in batch])


class YAMNetScorer:
    name, rate = "yamnet", c.YAMNET_SAMPLE_RATE
    stream_configs = {"0.975": (c.YAMNET_PATCH_SAMPLES, c.YAMNET_PATCH_HOP_SAMPLES)}

    def __init__(self):
        self.model, self.labels = coreml("YAMNet"), c.yamnet_labels()

    def context(self, wave):
        scores = predict(self.model, c.yamnet_patches(wave))
        return scores.mean(0), scores.max(0)  # the reference averages patches; max is the alternative

    def stream(self, wave, key):
        length, hop = self.stream_configs[key]
        return predict(self.model, windows(wave, length, hop)), length / self.rate, hop / self.rate


class EfficientATScorer:
    rate = c.EFFICIENTAT_SAMPLE_RATE
    stream_configs = {"1": (32_000, 16_000), "2": (64_000, 16_000)}
    titles = {"mn10_as": "EfficientAT_MN10", "dymn04_as": "EfficientAT_DyMN04"}

    def __init__(self, name):
        self.name, self.labels = name, c.efficientat_labels()
        self.models = {seconds: coreml(f"{self.titles[name]}_{seconds}s") for seconds in (1, 2, 5, 10)}

    def context(self, wave):
        scores = predict(self.models[len(wave) // self.rate], [wave])[0]
        return scores, scores

    def stream(self, wave, key):
        length, hop = self.stream_configs[key]
        return predict(self.models[int(key)], windows(wave, length, hop)), length / self.rate, hop / self.rate


def run(scorer, rows):
    out = {"labels": np.array(scorer.labels), "ids": np.array([r["id"] for r in rows])}
    started = time.perf_counter()
    for key in CONTEXTS:
        mean, peak = [], []
        for row in rows:
            wave, rate = audio_io.context(row, key)
            a, b = scorer.context(librosa.resample(wave, orig_sr=rate, target_sr=scorer.rate, res_type="soxr_hq"))
            mean.append(a)
            peak.append(b)
        out[f"context_{key}_mean"] = np.stack(mean).astype(np.float32)
        out[f"context_{key}_max"] = np.stack(peak).astype(np.float32)
        print(scorer.name, "context", key, "s done", round(time.perf_counter() - started, 1), "s", flush=True)
    for key in scorer.stream_configs:
        scores = []
        for row in rows:
            wave, rate, _ = audio_io.stream(row)
            s, length, hop = scorer.stream(librosa.resample(wave, orig_sr=rate, target_sr=scorer.rate,
                                                            res_type="soxr_hq"), key)
            scores.append(s)
        out[f"stream_{key}"] = np.stack(scores).astype(np.float16)
        out[f"stream_{key}_window_hop"] = np.array([length, hop])
        print(scorer.name, "stream", key, "done", round(time.perf_counter() - started, 1), "s", flush=True)
    directory = audio_io.OUT / "scores"
    directory.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(directory / f"scores_{scorer.name}.npz", **out)


def fill(wave, length, mode):
    """A short context inside a 10 s model input: followed by digital silence, or repeated."""
    if mode == "pad10":
        return np.concatenate([wave, np.zeros(length - len(wave), np.float32)])
    return np.tile(wave, int(np.ceil(length / len(wave))))[:length]


def run_variants(scorer, rows):
    """EfficientAT was trained on 10 s clips and its released checkpoints degrade (mn10_as: all
    scores saturate) on inputs of 1–2 s. Two inference-time remedies that need no training:
    present the short context inside a 10 s input, padded with silence or repeated."""
    out = {"labels": np.array(scorer.labels), "ids": np.array([r["id"] for r in rows])}
    length = 10 * scorer.rate
    started = time.perf_counter()
    for key in ("1", "2", "5"):
        for mode in ("pad10", "tile10"):
            scores = []
            for row in rows:
                wave, rate = audio_io.context(row, key)
                wave = librosa.resample(wave, orig_sr=rate, target_sr=scorer.rate, res_type="soxr_hq")
                scores.append(predict(scorer.models[10], [fill(wave, length, mode)])[0])
            out[f"context_{key}_{mode}"] = np.stack(scores).astype(np.float32)
            print(scorer.name, "context", key, mode, "done", round(time.perf_counter() - started, 1), "s", flush=True)
    for key in ("1", "2"):
        window, hop = scorer.stream_configs[key]
        scores = []
        for row in rows:
            wave, rate, _ = audio_io.stream(row)
            wave = librosa.resample(wave, orig_sr=rate, target_sr=scorer.rate, res_type="soxr_hq")
            scores.append(predict(scorer.models[10], [fill(w, length, "tile10") for w in windows(wave, window, hop)]))
        out[f"stream_{key}"] = np.stack(scores).astype(np.float16)
        out[f"stream_{key}_window_hop"] = np.array([window / scorer.rate, hop / scorer.rate])
        print(scorer.name, "stream", key, "tile10 done", round(time.perf_counter() - started, 1), "s", flush=True)
        np.savez_compressed(audio_io.OUT / "scores" / f"scores_{scorer.name}_variants.npz", **out)
    np.savez_compressed(audio_io.OUT / "scores" / f"scores_{scorer.name}_variants.npz", **out)


def main():
    arguments = sys.argv[1:]
    limit = int(arguments[arguments.index("--limit") + 1]) if "--limit" in arguments else None
    names = [a for a in arguments if a in ("yamnet", "mn10_as", "dymn04_as")] or ["yamnet", "mn10_as", "dymn04_as"]
    rows = audio_io.manifest()
    if limit:
        rows = rows[:: max(len(rows) // limit, 1)]
    for name in names:
        if "--variants" in arguments:
            if name != "yamnet":
                run_variants(EfficientATScorer(name), rows)
        else:
            run(YAMNetScorer() if name == "yamnet" else EfficientATScorer(name), rows)


if __name__ == "__main__":
    main()
