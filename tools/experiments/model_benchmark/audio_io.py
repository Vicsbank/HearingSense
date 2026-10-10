"""The exact audio every model receives, shared by the Python scorers. The Swift tool
(hs-model-bench) builds the same sample ranges from the same manifest."""
import json
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "results" / "background_benchmark"
STREAM_LEAD, STREAM_TAIL, STREAM_CONTEXT = 3.0, 2.0, "5"


def manifest():
    with open(OUT / "manifest.jsonl") as file:
        return [json.loads(line) for line in file]


def context(row, key):
    """Channel 0 samples of one context at the file's own rate, zero-padded to the full length."""
    spec = row["contexts"][key]
    samples, rate = sf.read(ROOT / row["path"], dtype="float32", always_2d=True, start=spec["start_sample"],
                            frames=spec["available_samples"])
    out = np.zeros(spec["samples"], np.float32)
    out[: len(samples)] = samples[:, 0]
    return out, rate


def stream(row):
    """Event-detection stream: 3 s of digital silence, the 5 s context, 2 s of silence.
    Returns samples, rate and the event onset time inside the stream."""
    samples, rate = context(row, STREAM_CONTEXT)
    lead, tail = np.zeros(int(STREAM_LEAD * rate), np.float32), np.zeros(int(STREAM_TAIL * rate), np.float32)
    start = row["contexts"][STREAM_CONTEXT]["start_sample"] / rate
    onset = STREAM_LEAD + min(max(row["onset"] - start, 0.0), float(STREAM_CONTEXT))
    return np.concatenate([lead, samples, tail]), rate, onset
