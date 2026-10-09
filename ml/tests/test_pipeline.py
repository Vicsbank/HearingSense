"""ML 管线的单元测试（只做前向计算，不训练）。运行: .venv/bin/python -m pytest ml/tests -q"""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hearing_sense_ml import augment, datasets, interpret  # noqa: E402
from hearing_sense_ml.frontend import FRAME, HOP, MelFrontend, num_frames, reference_melbands  # noqa: E402
from hearing_sense_ml.paths import COREML_OUT, ESSENTIA_MODELS  # noqa: E402

needs_models = pytest.mark.skipif(not (ESSENTIA_MODELS / "discogs-effnet-bsdynamic-1.json").exists(),
                                  reason="先运行 tools/download_pretrained.py")


def test_frontend_matches_essentia():
    es = pytest.importorskip("essentia.standard")
    rng = np.random.default_rng(0)
    x = (rng.standard_normal(FRAME + HOP * 9) * 0.1).astype(np.float32)
    ours = reference_melbands(x)
    ref = np.stack([es.TensorflowInputMusiCNN()(x[i * HOP:i * HOP + FRAME]) for i in range(num_frames(len(x)))])
    assert np.abs(ours - ref).max() < 1e-4


def test_torch_frontend_matches_numpy_reference():
    torch = pytest.importorskip("torch")
    x = (np.random.default_rng(1).standard_normal(16000) * 0.2).astype(np.float32)
    with torch.no_grad():
        t = MelFrontend()(torch.from_numpy(x)[None])[0].numpy()
    assert t.shape == (num_frames(16000), 96)
    assert np.abs(t - reference_melbands(x)).max() < 1e-3


@needs_models
def test_binary_head_positive_classes_come_from_metadata():
    """各情绪头的类别顺序不一致，正类下标必须从 JSON 查找"""
    from hearing_sense_ml import essentia_models as em
    expected = {"happy": 0, "aggressive": 0, "danceable": 0, "sad": 1, "relaxed": 1, "party": 1, "voice": 1}
    for out, (model, pos) in em.BINARY_HEADS.items():
        assert em.metadata(model)["classes"].index(pos) == expected[out], out


def test_patch_starts_cover_window():
    from hearing_sense_ml.essentia_models import patch_starts
    starts = patch_starts(311, 128, 62)
    assert starts[0] == 0 and starts[-1] == 311 - 128
    assert max(b - a for a, b in zip(starts, starts[1:])) <= 62
    assert patch_starts(128, 128, 62) == [0]


@needs_models
def test_coreml_manifest_consistent():
    labels_file = COREML_OUT / "labels.json"
    if not labels_file.exists():
        pytest.skip("先运行 ml/export_coreml.py")
    labels = json.loads(labels_file.read_text())
    assert len(labels["styles"]) == 400
    assert labels["valence_arousal_order"] == ["valence", "arousal"]
    assert labels["moods"] == ["aggressive", "happy", "party", "relaxed", "sad", "danceable", "voice"]
    assert num_frames(labels["window_samples"]) * HOP + FRAME - HOP == labels["window_samples"]


def test_conditions_are_deterministic_and_level_controlled():
    rng_audio = np.random.default_rng(3)
    sr = 16000
    x = (np.sin(2 * np.pi * 440 * np.arange(sr * 3) / sr) * 0.3 + rng_audio.standard_normal(sr * 3) * 0.01)
    pools = {"pink": [augment.pink_noise(sr * 5, np.random.default_rng(0), sr=sr)]}
    for cond in augment.CONDITIONS:
        a = augment.apply_condition(x, cond, np.random.default_rng(7), pools, sr=sr)
        b = augment.apply_condition(x, cond, np.random.default_rng(7), pools, sr=sr)
        assert np.array_equal(a, b), cond.name
        assert a.dtype == np.float32 and len(a) == len(x)
        assert abs(20 * np.log10(augment.rms(a)) - cond.level_dbfs) < 1.5, cond.name


def test_mix_at_snr():
    rng = np.random.default_rng(0)
    clean = rng.standard_normal(16000)
    noise = rng.standard_normal(4000)
    mixed = augment.mix_at_snr(clean, noise, 10, rng)
    added = mixed - clean
    assert abs(20 * np.log10(augment.rms(clean) / augment.rms(added)) - 10) < 0.1


@needs_models
def test_genre_maps_reference_real_styles():
    styles = set(datasets._styles())
    for dataset, classes in datasets.genre_maps().items():
        for name, m in classes.items():
            assert m["styles"], (dataset, name)
            assert set(m["styles"]) <= styles, (dataset, name)
    gtzan = datasets.genre_maps()["gtzan"]
    assert not set(gtzan["metal"]["styles"]) & set(gtzan["rock"]["styles"])


@needs_models
def test_genre_summary_abstains_on_low_activation():
    styles = datasets._styles()
    low = np.full(400, 0.01, np.float32)
    assert interpret.genre_summary(low, styles)["genre"] is None
    high = low.copy()
    high[styles.index("Rock---Hard Rock")] = 0.8
    s = interpret.genre_summary(high, styles)
    assert s["genre"] == "Rock" and s["styles"][0][0] == "Hard Rock"


def test_mood_summary_separates_energy_from_valence():
    """高能量不等于正面情绪：高唤醒 + 低效价应显示为“高能量 + 偏暗”"""
    names = ["aggressive", "happy", "party", "relaxed", "sad", "danceable", "voice"]
    m = interpret.mood_summary([0.9, 0.1, 0.2, 0.05, 0.3, 0.4, 0.9], names, [3.8, 6.4])
    assert m["energy"] == "High" and m["valence"] == "Darker" and m["mood"] == "Intense / Aggressive"
