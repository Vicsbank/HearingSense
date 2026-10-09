"""评估数据集适配器与标签映射。

每个数据集返回 Track 列表；label 使用数据集自己的标签名，
再通过 GENRE_MAPS 映射到 Discogs 风格集合（新模型）或旧模型的 GTZAN 类别。

映射原则（写在这里，便于审查）：
- 新模型对数据集类别 g 的得分 = g 对应的 Discogs 风格集合中的最大激活值；闭集预测 = 得分最高的类别。
- “开放集”预测 = App 实际会显示的顶层流派（在全部 14 个可显示流派中取最大），
  看它是否属于该类别允许的顶层流派。这更接近真实使用。
"""
import json
from dataclasses import dataclass, field
from pathlib import Path

import pandas as pd

from .paths import DATA, ESSENTIA_MODELS


@dataclass
class Track:
    path: Path
    label: str
    group: str            # 用于分组统计/防泄漏，例如艺人或曲目编号
    meta: dict = field(default_factory=dict)


def _styles():
    return json.loads((ESSENTIA_MODELS / "discogs-effnet-bsdynamic-1.json").read_text())["classes"]


def _parent(s):
    return s.split("---")[0]


def _by_parent(*parents, exclude=()):
    return [s for s in _styles() if _parent(s) in parents and s not in exclude]


def _metal():
    return [s for s in _styles() if s.startswith("Rock---") and "Metal" in s]


def genre_maps():
    """数据集 -> {类别: {"styles": 风格集合, "parents": 开放集允许的顶层流派, "legacy": 旧模型中对应的类别}}"""
    metal = _metal()
    disco = [s for s in _styles() if "Disco" in s.split("---")[1]]
    country = ["Folk, World, & Country---Country", "Folk, World, & Country---Bluegrass",
               "Folk, World, & Country---Honky Tonk", "Folk, World, & Country---Hillbilly", "Rock---Country Rock"]
    gtzan = {
        "blues": {"styles": _by_parent("Blues"), "parents": ["Blues"]},
        "classical": {"styles": _by_parent("Classical"), "parents": ["Classical"]},
        "country": {"styles": country, "parents": ["Folk, World, & Country"]},
        "disco": {"styles": disco, "parents": ["Electronic", "Funk / Soul"]},
        "hiphop": {"styles": _by_parent("Hip Hop"), "parents": ["Hip Hop"]},
        "jazz": {"styles": _by_parent("Jazz"), "parents": ["Jazz"]},
        "metal": {"styles": metal, "parents": ["Rock"]},
        "pop": {"styles": _by_parent("Pop") + ["Electronic---Dance-pop", "Electronic---Synth-pop"], "parents": ["Pop"]},
        "reggae": {"styles": _by_parent("Reggae"), "parents": ["Reggae"]},
        "rock": {"styles": _by_parent("Rock", exclude=metal + ["Rock---Country Rock"]), "parents": ["Rock"]},
    }
    for g, m in gtzan.items():
        m["legacy"] = [g]
    emotify = {
        "classical": {"styles": _by_parent("Classical"), "parents": ["Classical"], "legacy": ["classical"]},
        "rock": {"styles": _by_parent("Rock"), "parents": ["Rock"], "legacy": ["rock", "metal"]},
        "pop": {"styles": _by_parent("Pop"), "parents": ["Pop"], "legacy": ["pop", "disco"]},
        # 旧模型 (GTZAN 10 类) 没有电子音乐类别，无法正确预测这一类
        "electronic": {"styles": _by_parent("Electronic"), "parents": ["Electronic"], "legacy": []},
    }
    return {"gtzan": gtzan, "emotify": emotify}


def emotify(local_only=False):
    """Emotify: 400 首 1 分钟片段，4 个流派各 100 首，带 GEMS 诱发情绪标注"""
    df = pd.read_csv(DATA / "emotify" / "processed_data.csv")
    gems = [c for c in df.columns if c.strip() in
            ["amazement", "solemnity", "tenderness", "nostalgia", "calmness", "power", "joyful_activation",
             "tension", "sadness"]]
    # 完整音频包 (tools/download_datasets.py) 优先；原有的 12 首与完整包中对应文件逐字节相同
    full = DATA / "emotify" / "audio_full"
    audio_dir = full if (full / ".extracted_ok").exists() else DATA / "emotify" / "audio"
    tracks = []
    for _, r in df.iterrows():
        p = audio_dir / r["original_path"]
        if local_only and not p.exists():
            continue
        tracks.append(Track(p, r[" genre"].strip(), f"emotify-{r['track id']}",
                            {"track_id": int(r["track id"]), "gems": {c.strip(): float(r[c]) for c in gems}}))
    return tracks


# 已知损坏、无法解码的文件（libsndfile: "bad data offset"），评估时排除，因此 jazz 只有 99 段
GTZAN_CORRUPT = {"jazz.00054"}


def gtzan():
    """GTZAN: 10 流派 × 100 段 30 秒。已知有重复、错误标注和同一艺人大量重复 (Sturm 2013)。"""
    roots = [DATA / "gtzan" / "genres_original", DATA / "gtzan" / "genres"]
    root = next((r for r in roots if r.exists()), None)
    if root is None:
        raise FileNotFoundError("未找到 GTZAN，见 data/README.md")
    tracks = []
    for genre_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        for f in sorted(genre_dir.glob("*")):
            # 跳过 macOS 压缩时附带的 “._” 元数据文件
            if f.suffix.lower() in (".wav", ".au") and not f.name.startswith("._") and f.stem not in GTZAN_CORRUPT:
                tracks.append(Track(f, genre_dir.name, f.stem))
    return tracks


def samples():
    """data/samples：无标签，只用于观察稳定性"""
    return [Track(p, "unlabeled", p.stem) for p in sorted((DATA / "samples").glob("*"))
            if p.suffix.lower() in (".mp3", ".wav")]


# MTG-Jamendo 流派标签（上传者自填，多标签）-> 允许的 Discogs 顶层流派，多个标签取并集。
# 含义模糊或不是流派的标签（experimental、atmospheric、80s、90s 等）不映射；没有可映射标签的曲目不参与流派评估。
JAMENDO_GENRE_TO_PARENTS = {
    "rock": ["Rock"], "alternative": ["Rock"], "punkrock": ["Rock"], "hardrock": ["Rock"], "metal": ["Rock"],
    "progressive": ["Rock"], "psychedelic": ["Rock"], "postrock": ["Rock"], "gothic": ["Rock"],
    "poprock": ["Rock", "Pop"], "indie": ["Rock", "Pop"], "newwave": ["Rock", "Electronic"],
    "pop": ["Pop"], "instrumentalpop": ["Pop"], "popfolk": ["Pop", "Folk, World, & Country"],
    "synthpop": ["Electronic", "Pop"], "electropop": ["Electronic", "Pop"],
    "singersongwriter": ["Folk, World, & Country", "Pop", "Rock"],
    "electronic": ["Electronic"], "ambient": ["Electronic"], "chillout": ["Electronic"], "dance": ["Electronic"],
    "trance": ["Electronic"], "house": ["Electronic"], "deephouse": ["Electronic"], "techno": ["Electronic"],
    "downtempo": ["Electronic"], "triphop": ["Electronic", "Hip Hop"], "minimal": ["Electronic"],
    "industrial": ["Electronic", "Rock"], "dubstep": ["Electronic"], "eurodance": ["Electronic"], "edm": ["Electronic"],
    "club": ["Electronic"], "electronica": ["Electronic"], "darkambient": ["Electronic"], "darkwave": ["Electronic", "Rock"],
    "newage": ["Electronic"], "lounge": ["Electronic", "Jazz", "Rock"], "easylistening": ["Jazz", "Pop"],
    "classical": ["Classical"], "orchestral": ["Classical", "Stage & Screen"], "symphonic": ["Classical"],
    "choir": ["Classical"], "medieval": ["Classical"], "contemporary": ["Classical"],
    "soundtrack": ["Stage & Screen"],
    "hiphop": ["Hip Hop"], "rap": ["Hip Hop"],
    "jazz": ["Jazz"], "fusion": ["Jazz"], "acidjazz": ["Jazz", "Electronic"], "swing": ["Jazz"], "improvisation": ["Jazz"],
    "bossanova": ["Latin", "Jazz"], "latin": ["Latin"],
    "folk": ["Folk, World, & Country"], "world": ["Folk, World, & Country"], "country": ["Folk, World, & Country"],
    "ethno": ["Folk, World, & Country"],
    "blues": ["Blues"], "reggae": ["Reggae"], "rnb": ["Funk / Soul"], "funk": ["Funk / Soul"], "soul": ["Funk / Soul"],
}


def _read_jamendo_tsv(path):
    rows = {}
    with open(path) as f:
        next(f)
        for line in f:
            parts = line.rstrip("\n").split("\t")
            rows[parts[0]] = {"artist": parts[1], "path": parts[3], "tags": parts[5:]}
    return rows


def mtg_jamendo():
    """MTG-Jamendo 情绪/主题子集中已下载分片的曲目（CC 授权音乐，标签由上传者填写，缺失标签不代表否定）。
    meta["split"] 标出官方 split-0 划分：mtg_jamendo_moodtheme 分类头只能在 test 曲目上公平评估；
    Discogs-EffNet 与其他情绪头未使用 Jamendo 训练，可以用全部曲目。"""
    root = DATA / "mtg_jamendo"
    tags = _read_jamendo_tsv(root / "meta" / "autotagging.tsv")
    mood = _read_jamendo_tsv(root / "meta" / "autotagging_moodtheme.tsv")
    split = {}
    for name in ("train", "validation", "test"):
        for k in _read_jamendo_tsv(root / "meta" / f"autotagging_moodtheme-{name}.tsv"):
            split[k] = name
    tracks = []
    for tid, row in sorted(mood.items()):
        stem = Path(row["path"])
        candidates = [root / "audio" / stem.parent / f"{stem.stem}.low.mp3", root / "audio" / stem]
        path = next((c for c in candidates if c.exists()), None)
        if path is None:
            continue
        genres = [t.split("---")[1] for t in tags.get(tid, {"tags": []})["tags"] if t.startswith("genre---")]
        parents = sorted({p for g in genres for p in JAMENDO_GENRE_TO_PARENTS.get(g, [])})
        moods = [t.split("---")[1] for t in row["tags"] if t.startswith("mood/theme---")]
        tracks.append(Track(path, "|".join(parents) if parents else "unmapped", row["artist"],
                            {"track_id": tid, "genres": genres, "allowed_parents": parents, "moods": moods,
                             "split": split.get(tid)}))
    return tracks


def pmemo():
    """PMEmo 2019：794 首流行歌的副歌片段，静态效价/唤醒度标注（取值 0–1）。
    新模型的效价/唤醒度回归头由 DEAM 与 emoMusic 训练，未使用 PMEmo，因此这是公平测试。"""
    root = DATA / "pmemo"
    ann = next(root.rglob("static_annotations.csv"), None)
    meta = next(root.rglob("metadata.csv"), None)
    if ann is None:
        raise FileNotFoundError("未找到 PMEmo 的 static_annotations.csv，见 data/README.md")
    a = pd.read_csv(ann)
    cols = {c.lower().replace(" ", ""): c for c in a.columns}
    aro, val = cols.get("arousal(mean)"), cols.get("valence(mean)")
    if aro is None or val is None:
        raise ValueError(f"PMEmo 标注列名与预期不符: {list(a.columns)}")
    artists = {}
    if meta is not None:
        m = pd.read_csv(meta)
        if "artist" in m.columns:
            artists = dict(zip(m["musicId"], m["artist"]))
    chorus = {int(f.stem): f for f in root.rglob("*.mp3") if f.stem.isdigit()}
    tracks = []
    for _, r in a.iterrows():
        mid = int(r["musicId"])
        if mid in chorus:
            tracks.append(Track(chorus[mid], "pmemo", str(artists.get(mid, mid)),
                                {"music_id": mid, "arousal": float(r[aro]), "valence": float(r[val])}))
    return tracks


LOADERS = {"emotify": emotify, "emotify_local": lambda: emotify(local_only=True), "gtzan": gtzan,
           "samples": samples, "mtg_jamendo": mtg_jamendo,
           "pmemo": pmemo}
