"""用随机生成的“模型输出”跑通各评估函数的代码路径（不加载模型、不读音频）。"""
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hearing_sense_ml import augment, datasets  # noqa: E402
from hearing_sense_ml.paths import ESSENTIA_MODELS  # noqa: E402

pytestmark = pytest.mark.skipif(not (ESSENTIA_MODELS / "discogs-effnet-bsdynamic-1.json").exists(),
                                reason="先运行 tools/download_pretrained.py")


def fake_cache(n_tracks, conds, rng):
    cache = {}
    for ti in range(n_tracks):
        for c in conds:
            w = int(rng.integers(1, 6))
            cache[f"{ti}|{c.name}"] = {
                "new_styles": rng.uniform(0, 0.6, (w, 400)).astype(np.float32),
                "new_moods": rng.uniform(0, 1, (w, 7)).astype(np.float32),
                "new_moodtheme": rng.uniform(0, 1, (w, 56)).astype(np.float32),
                "new_valence_arousal": rng.uniform(3, 7, (w, 2)).astype(np.float32),
                "legacy_genre": rng.dirichlet(np.ones(10), w).astype(np.float32),
            }
    return cache


def test_jamendo_and_pmemo_evaluation_paths():
    import evaluate as ev
    rng = np.random.default_rng(0)
    conds = augment.CONDITIONS[:2]
    moods = ["happy", "sad", "relaxing", "energetic", "dark", "calm", "party"]
    names = datasets._styles()
    themes = [f"t{i}" for i in range(56)]
    jam = [datasets.Track(Path(f"{i}.mp3"), "x", f"a{i % 7}",
                          {"allowed_parents": list(rng.choice(["Rock", "Pop", "Electronic"], 2, replace=False)),
                           "moods": list(rng.choice(moods + themes[:5], 2, replace=False)), "split": "test"})
           for i in range(40)]
    rep = ev.evaluate_jamendo(jam, fake_cache(len(jam), conds, rng), conds, names, themes)
    assert set(rep) == {c.name for c in conds}
    acc = rep["clean"]["genre_open_set_accuracy"]["track"]
    assert 0 <= acc[0] <= 1

    pm = [datasets.Track(Path(f"{i}.mp3"), "pmemo", f"a{i}", {"arousal": rng.uniform(0, 1), "valence": rng.uniform(0, 1)})
          for i in range(30)]
    rep = ev.evaluate_pmemo(pm, fake_cache(len(pm), conds, rng), conds)
    assert set(rep["clean"]) == {"arousal", "valence"}
    assert -1 <= rep["clean"]["arousal"]["pearson"][0] <= 1


def test_genre_evaluation_paths():
    import evaluate as ev
    rng = np.random.default_rng(1)
    conds = augment.CONDITIONS[:2]
    cmap = datasets.genre_maps()["emotify"]
    tracks = [datasets.Track(Path(f"{i}.mp3"), lab, f"g{i}") for i, lab in enumerate(list(cmap) * 5)]
    legacy = ["blues", "classical", "country", "disco", "hiphop", "jazz", "metal", "pop", "reggae", "rock"]
    rep = ev.evaluate_genre(tracks, fake_cache(len(tracks), conds, rng), conds, cmap, datasets._styles(), legacy)
    e = rep["clean"]["track"]
    assert e["new_open"]["n"] == len(tracks)
    # 旧模型没有 electronic 类，可比较子集只含 3 个类别
    assert e["legacy_on_comparable_classes"]["n"] == 15
