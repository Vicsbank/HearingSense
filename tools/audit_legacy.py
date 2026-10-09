# 旧模型（科学展版本）的前向推理审计。只做推理，不做任何训练。
# 用法: .venv/bin/python tools/audit_legacy.py
# 输出: results/audit/legacy_audit.json
import json
import sys
import time
from pathlib import Path

import librosa
import numpy as np
import torch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from config import LABEL_COL, GENRE_COL, model_path_emo, model_path_genre  # noqa: E402
from emotion_model import EfficientNetModel  # noqa: E402
from genre_model import SpectrogramCNN_GRUNet, genre_melspec, GENRE_SR  # noqa: E402

OUT = ROOT / "results" / "audit"
EMO = [c.strip() for c in LABEL_COL]
SEG = GENRE_SR // 1000 * 5500  # 与 train_genre.pad_trunc 相同的长度 (242000)


def load_models():
    emo = EfficientNetModel(pretrained=False)
    emo.load_state_dict(torch.load(model_path_emo, map_location="cpu"))
    genre = SpectrogramCNN_GRUNet(len(GENRE_COL))
    genre.load_state_dict(torch.load(model_path_genre, map_location="cpu"))
    return emo.eval(), genre.eval()


def emotion_probs(model, y44):
    """与 infer.py 相同: 5 s 片段, 128 Mel, power_to_db(ref=max), 对 logits 求平均后 softmax"""
    n = 5 * 44100
    segs = [y44[i:i + n] for i in range(0, len(y44) - n + 1, n)]
    if not segs:
        return None
    mels = [librosa.power_to_db(librosa.feature.melspectrogram(y=s, sr=44100, n_mels=128, n_fft=2048, hop_length=512),
                                ref=np.max) for s in segs]
    with torch.no_grad():
        logits = model(torch.tensor(np.array(mels)).float().unsqueeze(1))
    return torch.softmax(logits.mean(0), 0).numpy()


def genre_probs_segments(model, segments):
    with torch.no_grad():
        x = torch.stack([genre_melspec(torch.tensor(s).float().unsqueeze(0)) for s in segments])
        return torch.softmax(model(x), 1).numpy()


def genre_inference_style(model, y44):
    """infer.py 的方式: 连续 5.5 s 真实音频"""
    segs = [y44[i:i + SEG] for i in range(0, len(y44) - SEG + 1, SEG)]
    return genre_probs_segments(model, segs) if segs else None


def genre_training_style(model, y44, rng):
    """train_genre.py 的方式: GTZAN 30 s 切成 10 段 = 3 s, 再随机补零到 5.5 s"""
    n3 = 3 * 44100
    segs = []
    for i in range(0, len(y44) - n3 + 1, n3):
        s = y44[i:i + n3]
        pad = SEG - len(s)
        a = rng.integers(0, pad + 1)
        segs.append(np.concatenate([np.zeros(a), s, np.zeros(pad - a)]))
    return genre_probs_segments(model, segs) if segs else None


def summarize(p, labels, k=3):
    idx = np.argsort(p)[::-1][:k]
    return [(labels[i], round(float(p[i]), 3)) for i in idx]


def synthetic_signals(sr, seconds=30, seed=0):
    rng = np.random.default_rng(seed)
    n = sr * seconds
    white = rng.standard_normal(n) * 0.05
    # 粉红噪声: 对白噪声的频谱乘 1/sqrt(f)
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / sr)
    spec[1:] /= np.sqrt(f[1:])
    pink = np.fft.irfft(spec, n)
    pink = pink / np.abs(pink).max() * 0.3
    silence = rng.standard_normal(n) * 1e-4  # 安静房间的底噪
    return {"white_noise": white, "pink_noise": pink, "near_silence": silence}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    emo, genre = load_models()
    rng = np.random.default_rng(42)
    report = {"note": "前向推理审计；不含训练。Emotify 古典曲目可能出现在旧模型的训练集中（无法确认划分），不可作为准确率证据。",
              "files": {}}

    files = sorted((ROOT / "data" / "samples").glob("*")) + sorted((ROOT / "data" / "emotify" / "audio").rglob("*.mp3")) \
        + sorted((ROOT / "data" / "test_signals").glob("*.aiff"))
    inputs = {str(f.relative_to(ROOT)): None for f in files}
    synth = synthetic_signals(44100)

    t_total = 0.0
    for name in list(inputs) + list(synth):
        y = synth[name] if name in synth else librosa.load(ROOT / name, sr=44100, mono=True)[0]
        t = time.perf_counter()
        pe = emotion_probs(emo, y)
        gi = genre_inference_style(genre, y)
        t_total += time.perf_counter() - t
        gt = genre_training_style(genre, y, rng)
        entry = {"duration_s": round(len(y) / 44100, 1)}
        if pe is not None:
            entry["emotion_top3"] = summarize(pe, EMO)
        if gi is not None:
            gi_mean = gi.mean(0)
            entry["genre_inference_style_top3"] = summarize(gi_mean, GENRE_COL)
            entry["genre_inference_style_segment_argmax"] = [GENRE_COL[i] for i in gi.argmax(1)]
        if gt is not None:
            entry["genre_training_style_top3"] = summarize(gt.mean(0), GENRE_COL)
        report["files"][name] = entry
        print(name, json.dumps(entry, ensure_ascii=False)[:400])

    # 汇总: 流派预测的分布（检验是否塌缩到少数类别）
    from collections import Counter
    seg_preds = Counter(g for e in report["files"].values() for g in e.get("genre_inference_style_segment_argmax", []))
    report["genre_segment_prediction_counts"] = dict(seg_preds)
    report["cpu_inference_seconds_total"] = round(t_total, 2)
    (OUT / "legacy_audit.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print("segment predictions:", dict(seg_preds))


if __name__ == "__main__":
    main()
