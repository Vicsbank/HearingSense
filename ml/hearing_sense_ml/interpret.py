"""把模型输出变成面向用户的标签（与 App 中 Swift 的 Interpretation.swift 逻辑一致）。

阈值都存放在导出的 labels.json 里，Python 评估和 Swift App 读取同一份配置。
这些阈值是根据少量本地样本设定的临时值，不是经过标注数据校准的结果。
"""
from collections import defaultdict

import numpy as np

# Discogs 顶层流派 -> 显示名称。Non-Music 不作为流派显示，只作为“非音乐”的辅助证据。
PARENT_DISPLAY = {
    "Blues": "Blues",
    "Brass & Military": "Brass & Military",
    "Children's": "Children's",
    "Classical": "Classical",
    "Electronic": "Electronic",
    "Folk, World, & Country": "Folk / World / Country",
    "Funk / Soul": "Funk / Soul",
    "Hip Hop": "Hip-Hop",
    "Jazz": "Jazz",
    "Latin": "Latin",
    "Non-Music": None,
    "Pop": "Pop",
    "Reggae": "Reggae",
    "Rock": "Rock",
    "Stage & Screen": "Soundtrack / Stage",
}

MOOD_DISPLAY = {
    "aggressive": "Intense / Aggressive",
    "happy": "Happy / Bright",
    "party": "Upbeat / Party",
    "relaxed": "Calm / Relaxed",
    "sad": "Sad / Melancholic",
}

DEFAULT_THRESHOLDS = {
    "genre_min_activation": 0.10,   # 最高风格激活低于此值 -> 流派“不确定”
    "mood_tag": 0.60,               # 情绪二分类器的正类概率阈值
    "arousal_low": 4.3, "arousal_high": 5.3,   # 1–9 量表
    "valence_low": 4.5, "valence_high": 5.3,
}


def parent_of(style):
    return style.split("---")[0]


def genre_summary(styles, classes, th=DEFAULT_THRESHOLDS):
    """流派分数 = 该流派下所有风格激活的最大值（比求和更不偏向风格多的流派）"""
    parent_score = defaultdict(float)
    for name, v in zip(classes, styles):
        p = parent_of(name)
        if PARENT_DISPLAY.get(p):
            parent_score[p] = max(parent_score[p], float(v))
    ranked = sorted(parent_score.items(), key=lambda kv: -kv[1])
    top_parent, top_score = ranked[0]
    in_parent = [(name.split("---")[1], float(v)) for name, v in zip(classes, styles) if parent_of(name) == top_parent]
    in_parent.sort(key=lambda kv: -kv[1])
    return {
        "genre": PARENT_DISPLAY[top_parent] if top_score >= th["genre_min_activation"] else None,
        "genre_key": top_parent,
        "score": top_score,
        "styles": in_parent[:2],
        "ranked": [(PARENT_DISPLAY[k], s) for k, s in ranked[:5]],
    }


def level(value, low, high, names):
    return names[0] if value < low else names[2] if value > high else names[1]


def mood_summary(moods, mood_names, valence_arousal, th=DEFAULT_THRESHOLDS):
    probs = dict(zip(mood_names, (float(x) for x in moods)))
    tags = sorted(((k, p) for k, p in probs.items() if k in MOOD_DISPLAY and p >= th["mood_tag"]), key=lambda kv: -kv[1])
    valence, arousal = (float(x) for x in valence_arousal)
    return {
        "mood": MOOD_DISPLAY[tags[0][0]] if tags else "Mixed / Neutral",
        "tags": [MOOD_DISPLAY[k] for k, _ in tags],
        "energy": level(arousal, th["arousal_low"], th["arousal_high"], ["Low", "Medium", "High"]),
        "valence": level(valence, th["valence_low"], th["valence_high"], ["Darker", "Neutral", "Brighter"]),
        "arousal_value": arousal,
        "valence_value": valence,
        "danceable": probs.get("danceable"),
        "vocals": probs.get("voice"),
    }


def top_k(values, names, k=5):
    idx = np.argsort(values)[::-1][:k]
    return [(names[i], float(values[i])) for i in idx]
