"""把 MusicAnalyzer (前端 + Discogs-EffNet + MusiCNN + 各分类头) 导出为一个 Core ML 模型。

用法:
  .venv/bin/python ml/export_coreml.py                 # 默认 5 秒窗口
  .venv/bin/python ml/export_coreml.py --window 3

输出 models/coreml/:
  HearingSenseMusic.mlpackage   输入 16 kHz 单声道波形 (1, N)，输出见 OUTPUT_NAMES
  labels.json                   类别名、正类映射、阈值、窗口长度、许可信息（App 读取）
  export_report.json            PyTorch / ONNX Runtime 参考管线 / Core ML 三方一致性与延迟

只做前向推理与格式转换，不涉及任何训练。
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import coremltools as ct  # noqa: E402
import librosa  # noqa: E402
import onnxruntime as ort  # noqa: E402

from hearing_sense_ml import essentia_models as em  # noqa: E402
from hearing_sense_ml.frontend import SAMPLE_RATE, reference_melbands  # noqa: E402
from hearing_sense_ml.interpret import DEFAULT_THRESHOLDS, MOOD_DISPLAY, PARENT_DISPLAY  # noqa: E402
from hearing_sense_ml.paths import COREML_OUT, DATA, ESSENTIA_MODELS  # noqa: E402

LICENSE = ("Essentia models (Discogs-EffNet, MusiCNN, classification heads) by the Music Technology Group, "
           "Universitat Pompeu Fabra, licensed CC BY-NC-SA 4.0. Non-commercial use only; "
           "derivatives (including this Core ML conversion) must use the same license.")


def reference_pipeline(wave, analyzer):
    """不经过 PyTorch 的参考实现: NumPy float64 前端 + ONNX Runtime 模型"""
    def sess(name):
        return ort.InferenceSession(str(ESSENTIA_MODELS / f"{name}.onnx"))

    def run(s, x):
        return s.run(None, {s.get_inputs()[0].name: x})

    mel = reference_melbands(wave).astype(np.float32)
    styles, emb = run(sess(em.EFFNET), np.stack([mel[s:s + em.EFFNET_PATCH] for s in analyzer.effnet_starts]))
    moods = []
    for (name, pos), idx in zip(em.BINARY_HEADS.values(), analyzer.head_pos):
        moods.append(run(sess(name), emb)[0][:, idx])
    moods = np.stack(moods, 1)
    theme = run(sess(em.MOODTHEME), emb)[0]
    _, memb = run(sess(em.MUSICNN), np.stack([mel[s:s + em.MUSICNN_PATCH] for s in analyzer.musicnn_starts]))
    va = np.mean([run(sess(n), memb)[0] for n in em.AV_HEADS], 0)
    return [styles.mean(0), moods.mean(0), theme.mean(0), va.mean(0), emb.mean(0)]


def test_windows(n):
    """一致性检查用的真实音频窗口（本地样本 + 语音 + 噪声）"""
    waves = []
    for f in ["samples/Shattered Roads.mp3", "samples/Untitled (4).mp3", "emotify/audio/classical/1.mp3",
              "test_signals/speech_en.aiff"]:
        p = DATA / f
        if p.exists():
            y, _ = librosa.load(p, sr=SAMPLE_RATE, mono=True)
            waves.append(y[len(y) // 3: len(y) // 3 + n])
    waves.append((np.random.default_rng(0).standard_normal(n) * 0.05).astype(np.float32))
    return [w for w in waves if len(w) == n]


def labels_manifest(analyzer, n):
    styles = em.style_classes()
    return {
        "model": "HearingSenseMusic",
        "version": "1.0.0",
        "sample_rate": SAMPLE_RATE,
        "window_samples": n,
        "window_seconds": n / SAMPLE_RATE,
        "effnet_patch_starts": analyzer.effnet_starts,
        "musicnn_patch_starts": analyzer.musicnn_starts,
        "outputs": em.OUTPUT_NAMES,
        "styles": styles,
        "style_parents": sorted({s.split("---")[0] for s in styles}),
        "parent_display": PARENT_DISPLAY,
        "moods": em.MusicAnalyzer.MOOD_OUTPUTS,
        "mood_display": MOOD_DISPLAY,
        "moodtheme": em.moodtheme_classes(),
        "valence_arousal_order": ["valence", "arousal"],
        "valence_arousal_range": [1, 9],
        "thresholds": DEFAULT_THRESHOLDS,
        "sources": {name: em.metadata(name).get("link") for name in
                    [em.EFFNET, em.MUSICNN, em.MOODTHEME, *em.AV_HEADS, *(m for m, _ in em.BINARY_HEADS.values())]},
        "license": LICENSE,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window", type=float, default=5.0, help="分析窗口长度（秒）")
    ap.add_argument("--precision", choices=["fp32", "fp16"], default="fp32")
    args = ap.parse_args()

    n = em.window_samples(args.window)
    analyzer = em.MusicAnalyzer(n).eval()
    example = torch.zeros(1, n)
    with torch.no_grad():
        traced = torch.jit.trace(analyzer, example)

    # 前端的 log 输入可超过 6e8，FP16 会溢出，所以默认整体使用 FP32
    precision = ct.precision.FLOAT32 if args.precision == "fp32" else ct.precision.FLOAT16
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="waveform", shape=(1, n), dtype=np.float32)],
        outputs=[ct.TensorType(name=o) for o in em.OUTPUT_NAMES],
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS13,
        convert_to="mlprogram",
    )
    mlmodel.author = "Hearing Sense (conversion of Essentia/MTG models)"
    mlmodel.license = LICENSE
    mlmodel.short_description = (f"16 kHz mono waveform ({n} samples, {n / SAMPLE_RATE:.2f} s) -> Discogs styles, "
                                 "mood probabilities, MTG-Jamendo mood/theme tags, valence/arousal, embedding")
    COREML_OUT.mkdir(parents=True, exist_ok=True)
    out_path = COREML_OUT / "HearingSenseMusic.mlpackage"
    mlmodel.save(str(out_path))
    (COREML_OUT / "labels.json").write_text(json.dumps(labels_manifest(analyzer, n), indent=1, ensure_ascii=False))

    # 三方一致性: PyTorch vs ONNX Runtime 参考 vs Core ML
    report = {"window_samples": n, "precision": args.precision, "parity": [], "latency_ms": {}}
    loaded = {u: ct.models.MLModel(str(out_path), compute_units=getattr(ct.ComputeUnit, u))
              for u in ["CPU_ONLY", "CPU_AND_GPU", "ALL"]}
    for i, w in enumerate(test_windows(n)):
        with torch.no_grad():
            pt = [x.numpy() for x in analyzer(torch.from_numpy(w).float()[None])]
        ref = reference_pipeline(w.astype(np.float32), analyzer)
        cm = loaded["CPU_ONLY"].predict({"waveform": w[None].astype(np.float32)})
        row = {}
        for k, name in enumerate(em.OUTPUT_NAMES):
            c = np.asarray(cm[name]).reshape(-1)
            row[name] = {"torch_vs_ref": float(np.abs(pt[k] - ref[k]).max()),
                         "coreml_vs_ref": float(np.abs(c - ref[k]).max())}
        report["parity"].append(row)
        print(f"窗口 {i}: " + ", ".join(f"{k} Δ={v['coreml_vs_ref']:.1e}" for k, v in row.items()))

    x = {"waveform": np.zeros((1, n), np.float32)}
    for unit, model in loaded.items():
        for _ in range(3):
            model.predict(x)
        times = []
        for _ in range(20):
            t = time.perf_counter()
            model.predict(x)
            times.append((time.perf_counter() - t) * 1000)
        report["latency_ms"][unit] = {"median": float(np.median(times)), "p95": float(np.percentile(times, 95))}
        print(f"{unit}: 中位 {np.median(times):.1f} ms, p95 {np.percentile(times, 95):.1f} ms")
    size = sum(f.stat().st_size for f in out_path.rglob("*") if f.is_file())
    report["model_size_mb"] = size / 1e6
    (COREML_OUT / "export_report.json").write_text(json.dumps(report, indent=1))
    print(f"已保存 {out_path} ({size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
