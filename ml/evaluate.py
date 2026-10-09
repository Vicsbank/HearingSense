"""模型准确度与噪声鲁棒性评估（只做前向推理，不训练）。

用法:
  .venv/bin/python ml/evaluate.py --dataset emotify_local            # 本地 12 首古典曲目（冒烟测试）
  .venv/bin/python ml/evaluate.py --dataset emotify --conditions clean,phone_room_1m,phone_babble_0dB
  .venv/bin/python ml/evaluate.py --dataset gtzan --max-per-class 20

流程:
  1. 每首曲目在 44.1 kHz 下施加录音条件（augment.CONDITIONS），再分别送入新模型 (16 kHz Core ML) 和旧模型 (44.1 kHz)
  2. 逐窗口原始输出缓存到 results/eval/<dataset>/cache.npz
  3. 计算指标写入 results/eval/<dataset>/report.json 与 summary.md

报告区分三种层级:
  window  单个 5 秒窗口的预测（App 不做平滑时用户看到的）
  track   整段平均（相当于长时间平滑，片段 30–60 秒）
  并且每个指标按录音条件分别列出，干净音频与带噪音频绝不混在一起。
"""
import argparse
import hashlib
import json
import sys
import time
from collections import defaultdict
from pathlib import Path

import librosa
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hearing_sense_ml import augment, datasets, metrics  # noqa: E402
from hearing_sense_ml.interpret import PARENT_DISPLAY, genre_summary  # noqa: E402
from hearing_sense_ml.paths import COREML_OUT, DATA, RESULTS  # noqa: E402
from hearing_sense_ml.predictors import CoreMLMusicModel, LegacyEmotion, LegacyGenre  # noqa: E402

SR = 44100
GEMS = ["amazement", "solemnity", "tenderness", "nostalgia", "calmness", "power", "joyful_activation", "tension",
        "sadness"]


def stable_seed(*parts):
    return int(hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()[:8], 16)


def load_noise_pools():
    """真实噪声优先（LibriSpeech、DEMAND），没有下载时退回到合成替代品，并在报告中注明"""
    rng = np.random.default_rng(0)
    pools, sources = {}, {}
    # 每位说话人取 5 段（dev-clean 共 40 人，男女各半），避免只覆盖排序靠前的几个人
    by_speaker = defaultdict(list)
    for f in sorted((DATA / "noise" / "librispeech").rglob("*.flac")):
        by_speaker[f.relative_to(DATA / "noise" / "librispeech").parts[2]].append(f)
    speech_files = [f for files in by_speaker.values() for f in files[:5]]
    if speech_files:
        speech = [librosa.load(f, sr=SR, mono=True)[0] for f in speech_files]
        sources["babble"] = f"LibriSpeech dev-clean ({len(speech_files)} 段，{len(by_speaker)} 位说话人)"
    else:
        speech = [librosa.load(f, sr=SR, mono=True)[0] for f in sorted((DATA / "test_signals").glob("*.aiff"))]
        sources["babble"] = f"macOS 合成语音 TTS ({len(speech)} 段) —— 合成替代品，真实性有限"
    pools["babble"] = [augment.make_babble(speech, rng, n_talkers=4, seconds=40, sr=SR) for _ in range(6)]
    pools["speech"] = speech

    # 每个环境单独解压在 demand/<环境>/ 下；只取 16 声道阵列中的第 1 声道
    demand = sorted((DATA / "noise" / "demand").rglob("ch01.wav"))
    if demand:
        pools["ambient"] = [librosa.load(f, sr=SR, mono=True)[0] for f in demand]
        sources["ambient"] = "DEMAND: " + ", ".join(f.parent.name for f in demand)
    else:
        pools["ambient"] = [augment.pink_noise(SR * 40, rng, sr=SR) for _ in range(4)]
        sources["ambient"] = "合成粉红噪声 —— 合成替代品，真实性有限"
    pools["pink"] = [augment.pink_noise(SR * 40, rng, sr=SR)]

    rirs = sorted(f for f in (DATA / "noise" / "mit_rir").rglob("*.wav") if "__MACOSX" not in f.parts)
    if rirs:
        pools["rir"] = []
        for f in rirs:
            h = librosa.load(f, sr=SR, mono=True)[0]
            onset = int(np.argmax(np.abs(h)))  # 从直达声峰值开始，去掉前面的传播延迟
            pools["rir"].append(h[onset:] / (np.abs(h[onset]) + 1e-12))
        sources["rir"] = f"MIT IR Survey ({len(rirs)} 个实测房间脉冲响应)"
    else:
        sources["rir"] = "无实测脉冲响应，phone_realroom 退化为合成混响"
    return pools, sources


def load_excerpt(path, max_seconds):
    """超过 max_seconds 的曲目只取正中间一段（MTG-Jamendo 有长达 21 分钟的完整曲目）"""
    import soundfile as sf
    try:
        duration = sf.info(str(path)).duration
    except Exception:  # noqa: BLE001  个别格式拿不到时长时整段读取
        duration = None
    if max_seconds and duration and duration > max_seconds:
        return librosa.load(path, sr=SR, mono=True, offset=(duration - max_seconds) / 2, duration=max_seconds)[0]
    return librosa.load(path, sr=SR, mono=True)[0]


START = time.time()


def mmss(sec):
    sec = max(0, int(sec))
    return f"{sec // 60:02d}:{sec % 60:02d}"


def balanced_order(tracks, priority=None, seed=0):
    """各类别轮流排列（类内随机，固定种子），这样即使因时间上限提前停止，已完成部分的类别也大致均衡。
    priority(track) 为 True 的曲目排在最前（例如旧情感模型的验证集曲目）。"""
    rng = np.random.default_rng(seed)
    tiers = defaultdict(lambda: defaultdict(list))
    for t in tracks:
        tiers[0 if priority and priority(t) else 1][t.label].append(t)
    out = []
    for tier in sorted(tiers):
        by = tiers[tier]
        for lab in sorted(by):
            idx = rng.permutation(len(by[lab]))
            by[lab] = [by[lab][i] for i in idx]
        while any(by.values()):
            for lab in sorted(by):
                if by[lab]:
                    out.append(by[lab].pop(0))
    return out


def live_stats(dataset, tracks, cache, k, conditions, style_names):
    """每处理一批曲目打印一次当前的整段准确率 / 相关系数，方便实时观察（最终结果以报告为准）"""
    lines = []
    if dataset.startswith("emotify"):
        cmap = datasets.genre_maps()["emotify"]
        for cond in conditions:
            ok = [open_set_parent(cache[f"{i}|{cond.name}"]["new_styles"].mean(0), style_names)
                  in cmap[tracks[i].label]["parents"] for i in range(k) if len(cache[f"{i}|{cond.name}"]["new_styles"])]
            lines.append(f"     {cond.name[:20]:20s} 新模型 {np.mean(ok):4.0%}")
    elif dataset == "pmemo" and k >= 10:
        from scipy import stats
        for cond in conditions:
            va = np.array([cache[f"{i}|{cond.name}"]["new_valence_arousal"].mean(0) for i in range(k)])
            a = stats.pearsonr(va[:, 1], [tracks[i].meta["arousal"] for i in range(k)]).statistic
            v = stats.pearsonr(va[:, 0], [tracks[i].meta["valence"] for i in range(k)]).statistic
            lines.append(f"     {cond.name[:20]:20s} r唤醒 {a:+.2f} r效价 {v:+.2f}")
    if lines:
        print(f"  —— 目前 {k} 首的整段结果 ——", flush=True)
        print("\n".join(lines), flush=True)


def predict(tracks, conditions, pools, legacy_emotion_for=None, max_seconds=60, deadline=None,
            dataset="", style_names=None):
    """返回 (cache, 实际完成的曲目数)。deadline 是绝对时间：预计下一首会超时就停止，不再开始新曲目。
    legacy_emotion_for(track) 为 True 的曲目才运行旧情感模型（它只能在自己的验证集上公平评估）。"""
    new = CoreMLMusicModel()
    legacy_g = LegacyGenre()
    legacy_e = LegacyEmotion() if legacy_emotion_for else None
    cache = defaultdict(dict)
    t0 = time.time()
    budget = (deadline - START) if deadline else None
    done = 0
    try:
        for ti, tr in enumerate(tracks):
            if deadline and ti > 0:
                per = (time.time() - t0) / ti
                if time.time() + per > deadline:
                    print(f"\n  ⏱ 时间上限将到，停止开始新曲目：已完成 {ti}/{len(tracks)} 首", flush=True)
                    break
            y = load_excerpt(tr.path, max_seconds)
            run_legacy_e = legacy_e is not None and legacy_emotion_for(tr)
            for cond in conditions:
                rng = np.random.default_rng(stable_seed(tr.group, cond.name))
                yc = augment.apply_condition(y, cond, rng, pools, sr=SR)
                y16 = librosa.resample(yc, orig_sr=SR, target_sr=16000, res_type="soxr_hq")
                key = f"{ti}|{cond.name}"
                cache[key].update({f"new_{k}": v for k, v in new.predict_windows(y16).items() if k != "embedding"})
                cache[key]["legacy_genre"] = legacy_g.predict_windows(yc)
                if run_legacy_e:
                    cache[key]["legacy_emotion_logits"] = legacy_e.predict_logits(yc)
            done = ti + 1
            per = (time.time() - t0) / done
            elapsed = time.time() - START
            print(f"[{done:3d}/{len(tracks)}] {tr.label[:9]:9s} 已用 {mmss(elapsed)}"
                  + (f"/{mmss(budget)}" if budget else "") + f"  {per:4.1f}s/首", flush=True)
            if done % 25 == 0 and style_names is not None:
                live_stats(dataset, tracks, cache, done, conditions, style_names)
    except KeyboardInterrupt:
        print(f"\n  已手动中断：用已完成的 {done} 首计算结果", flush=True)
    return cache, done


def predict_nonmusic(conditions, pools):
    """非音乐片段（语音、环境噪声、近乎静音）经过同样的房间与麦克风链路，用于检验“会不会把一切都当成音乐”"""
    new = CoreMLMusicModel()
    legacy_g = LegacyGenre()
    rng = np.random.default_rng(1)
    clips = {"speech": [s for s in pools["speech"] if len(s) > SR * 6][:20],
             "ambient": pools["ambient"],
             "silence": [np.zeros(SR * 20, np.float32)]}
    out = defaultdict(list)
    for kind, items in clips.items():
        for i, clip in enumerate(items):
            # 非音乐声源就在房间里（不经过手机扬声器）
            y = augment.convolve_rir(np.asarray(clip, np.float64), augment.synthetic_rir(0.4, rng, drr_db=6, sr=SR))
            y = augment.normalize_level(y, -28 if kind != "silence" else -120)
            y = augment.laptop_mic(y, rng, sr=SR).astype(np.float32)
            y16 = librosa.resample(y, orig_sr=SR, target_sr=16000, res_type="soxr_hq")
            out[kind].append({"new_styles": new.predict_windows(y16)["styles"],
                              "legacy_genre": legacy_g.predict_windows(y)})
    return out


def genre_scores(styles, class_map, style_names):
    idx = {s: i for i, s in enumerate(style_names)}
    cols = [[idx[s] for s in m["styles"]] for m in class_map.values()]
    return np.stack([styles[:, c].max(1) for c in cols], 1)


def open_set_parent(styles_row, style_names):
    return genre_summary(styles_row, style_names)["genre_key"]


def evaluate_genre(tracks, cache, conditions, class_map, style_names, legacy_classes):
    classes = list(class_map)
    comparable = [c for c in classes if class_map[c]["legacy"]]
    report = {}
    for cond in conditions:
        res = {lvl: defaultdict(list) for lvl in ("window", "track")}
        flicker = {"new_open": [], "legacy": []}
        for ti, tr in enumerate(tracks):
            c = cache[f"{ti}|{cond.name}"]
            st, lg = c["new_styles"], c["legacy_genre"]
            allowed, legacy_ok = class_map[tr.label]["parents"], class_map[tr.label]["legacy"]

            def add_new(lvl, rows):
                for row, g in zip(rows, genre_scores(rows, class_map, style_names)):
                    o = open_set_parent(row, style_names)
                    res[lvl]["truth_new"].append(tr.label)
                    res[lvl]["group_new"].append(ti)
                    res[lvl]["new_closed"].append(classes[int(np.argmax(g))])
                    res[lvl]["new_open"].append(tr.label if o in allowed else f"other:{o}")

            def add_legacy(lvl, probs):
                for p in probs:
                    lab = legacy_classes[int(np.argmax(p))]
                    res[lvl]["truth_legacy"].append(tr.label)
                    res[lvl]["group_legacy"].append(ti)
                    res[lvl]["legacy"].append(tr.label if lab in legacy_ok else f"other:{lab}")

            if len(st):
                add_new("window", st)
                add_new("track", st.mean(0, keepdims=True))
                flicker["new_open"].append(metrics.flicker_rate([open_set_parent(r, style_names) for r in st]))
            if len(lg):
                add_legacy("window", lg)
                add_legacy("track", lg.mean(0, keepdims=True))
                flicker["legacy"].append(metrics.flicker_rate([legacy_classes[i] for i in lg.argmax(1)]))

        def rep(truth, pred, keep, groups):
            idx = [i for i, t in enumerate(truth) if t in keep]
            return metrics.classification_report([truth[i] for i in idx], [pred[i] for i in idx], list(keep),
                                                  groups=[groups[i] for i in idx])

        report[cond.name] = {}
        for lvl, r in res.items():
            report[cond.name][lvl] = {
                "new_open": rep(r["truth_new"], r["new_open"], classes, r["group_new"]),
                "new_closed": rep(r["truth_new"], r["new_closed"], classes, r["group_new"]),
                "new_open_on_comparable_classes": rep(r["truth_new"], r["new_open"], comparable, r["group_new"]),
                "legacy_on_comparable_classes": rep(r["truth_legacy"], r["legacy"], comparable, r["group_legacy"]),
            }
        report[cond.name]["flicker_rate"] = {k: float(np.mean([v for v in vals if v is not None]))
                                             for k, vals in flicker.items() if any(v is not None for v in vals)}
    return report


def legacy_validation_ids():
    """复现旧训练脚本的划分 train_test_split(test_size=0.2, random_state=42)，返回验证集的 track id"""
    import pandas as pd
    from sklearn.model_selection import train_test_split
    df = pd.read_csv(DATA / "emotify" / "processed_data.csv")
    _, val_df = train_test_split(df, test_size=0.2, random_state=42)
    return set(val_df["track id"].astype(int))


def evaluate_emotify_emotion(tracks, cache, conditions, legacy_classes):
    """GEMS 是“诱发情绪”的多选比例，不是效价/唤醒度；这里检验相关方向是否合理，
    并按流派做组内相关，避免“古典=平静”这类流派混淆。"""
    import pandas as pd
    from sklearn.model_selection import train_test_split
    df = pd.read_csv(DATA / "emotify" / "processed_data.csv")
    # 复现旧训练脚本的划分 (train_test_split(test_size=0.2, random_state=42))，旧情感模型只在验证集上评估
    _, val_df = train_test_split(df, test_size=0.2, random_state=42)
    val_ids = set(val_df["track id"].astype(int))
    expected = {  # (模型输出, GEMS 维度, 预期方向)
        ("arousal", "power", +1), ("arousal", "joyful_activation", +1), ("arousal", "calmness", -1),
        ("valence", "joyful_activation", +1), ("valence", "sadness", -1),
        ("sad", "sadness", +1), ("relaxed", "calmness", +1), ("happy", "joyful_activation", +1),
        ("aggressive", "tension", +1), ("party", "joyful_activation", +1),
    }
    mood_names = ["aggressive", "happy", "party", "relaxed", "sad", "danceable", "voice"]
    report = {}
    for cond in conditions:
        feats, gems, genres, legacy = defaultdict(list), defaultdict(list), [], []
        for ti, tr in enumerate(tracks):
            c = cache[f"{ti}|{cond.name}"]
            if len(c["new_moods"]) == 0:
                continue
            va = c["new_valence_arousal"].mean(0)
            mo = c["new_moods"].mean(0)
            feats["valence"].append(va[0])
            feats["arousal"].append(va[1])
            for k, v in zip(mood_names, mo):
                feats[k].append(v)
            for g in GEMS:
                gems[g].append(tr.meta["gems"][g])
            genres.append(tr.label)
            if "legacy_emotion_logits" in c and tr.meta["track_id"] in val_ids and len(c["legacy_emotion_logits"]):
                logits = c["legacy_emotion_logits"].mean(0)
                p = np.exp(logits - logits.max())
                legacy.append((p / p.sum(), np.array([tr.meta["gems"][g] for g in GEMS])))
        genres = np.array(genres)
        entry = {"n_tracks": len(genres), "expected_direction_checks": []}
        for f, g, sign in sorted(expected):
            overall = metrics.correlation(feats[f], gems[g]) if len(genres) > 4 else None
            within = {}
            for gen in sorted(set(genres)):
                m = genres == gen
                if m.sum() > 8:
                    within[gen] = metrics.correlation(np.array(feats[f])[m], np.array(gems[g])[m])
            entry["expected_direction_checks"].append(
                {"model_output": f, "gems": g, "expected_sign": sign, "spearman_overall": overall,
                 "spearman_within_genre": within})
        if legacy:
            preds = np.stack([p for p, _ in legacy])
            targ = np.stack([t for _, t in legacy])
            top1 = [GEMS[i] for i in preds.argmax(1)]
            true = [GEMS[i] for i in targ.argmax(1)]
            prior_pred = [GEMS[int(np.argmax(df[[" " + g for g in GEMS]].drop(val_df.index).mean().values))]] * len(true)
            entry["legacy_on_its_validation_split"] = {
                "note": "旧情感模型在其验证集(80 首)上评估。该验证集曾用于挑选最佳 epoch，因此结果略偏乐观。",
                "top1_vs_argmax_gems": metrics.classification_report(true, top1, GEMS),
                "baseline_always_predict_training_mean": metrics.classification_report(true, prior_pred, GEMS),
                "mean_spearman_pred_vs_gems_profile": float(np.nanmean(
                    [np.corrcoef(np.argsort(np.argsort(p)), np.argsort(np.argsort(t)))[0, 1] for p, t in legacy])),
            }
        report[cond.name] = entry
    return report


# MTG-Jamendo 情绪标签 -> 对应的模型输出。正例 = 带这些标签的曲目；负例 = 不带的曲目
# （上传者标签缺失不代表否定，所以这是偏保守的弱标签检验）。效价只比较明确正面与明确负面的曲目。
MOOD_TAG_CHECKS = [
    ("happy", {"happy"}, None),
    ("relaxed", {"relaxing", "calm", "meditative"}, None),
    ("sad", {"sad", "melancholic"}, None),
    ("party", {"party", "fun", "upbeat"}, None),
    ("aggressive", {"heavy", "powerful", "action"}, None),
    ("arousal", {"energetic", "powerful", "action", "upbeat", "fast"}, {"calm", "relaxing", "meditative", "slow", "soft"}),
    ("valence", {"happy", "positive", "uplifting", "fun", "hopeful"}, {"sad", "dark", "melancholic"}),
]


def _auc_with_ci(scores, labels):
    from sklearn.metrics import roc_auc_score
    scores, labels = np.asarray(scores), np.asarray(labels)
    if labels.sum() < 3 or (1 - labels).sum() < 3:
        return None
    return metrics.bootstrap_ci(lambda i: roc_auc_score(labels[i], scores[i]), len(labels))


def evaluate_jamendo(tracks, cache, conditions, style_names, moodtheme_names):
    mood_names = ["aggressive", "happy", "party", "relaxed", "sad", "danceable", "voice"]
    parents = sorted({p for t in tracks for p in t.meta["allowed_parents"]})
    report = {}
    for cond in conditions:
        res = {lvl: {"truth": [], "pred": []} for lvl in ("window", "track")}
        parent_scores, parent_truth = defaultdict(list), defaultdict(list)
        feats, tag_sets, theme_rows, theme_truth = defaultdict(list), [], [], []
        for ti, tr in enumerate(tracks):
            c = cache[f"{ti}|{cond.name}"]
            st = c["new_styles"]
            if len(st) == 0:
                continue
            allowed = tr.meta["allowed_parents"]
            if allowed:
                for lvl, rows in (("window", st), ("track", st.mean(0, keepdims=True))):
                    for r in rows:
                        top = open_set_parent(r, style_names)
                        res[lvl]["truth"].append("match")
                        res[lvl]["pred"].append("match" if top in allowed else "mismatch")
                track_styles = st.mean(0)
                for p in parents:
                    idx = [i for i, sname in enumerate(style_names) if sname.split("---")[0] == p]
                    parent_scores[p].append(float(track_styles[idx].max()))
                    parent_truth[p].append(int(p in allowed))
            va = c["new_valence_arousal"].mean(0)
            feats["valence"].append(va[0])
            feats["arousal"].append(va[1])
            for k, v in zip(mood_names, c["new_moods"].mean(0)):
                feats[k].append(v)
            tag_sets.append(set(tr.meta["moods"]))
            if tr.meta.get("split") == "test":
                theme_rows.append(c["new_moodtheme"].mean(0))
                theme_truth.append([int(m in tr.meta["moods"]) for m in moodtheme_names])
        entry = {
            "genre_open_set_accuracy": {lvl: metrics.bootstrap_ci(
                lambda i, r=r: float(np.mean(np.array(r["pred"])[i] == "match")), len(r["pred"])) if r["pred"] else None
                for lvl, r in res.items()},
            "genre_parent_roc_auc": {p: _auc_with_ci(parent_scores[p], parent_truth[p]) for p in parents},
            "mood_tag_roc_auc": {},
        }
        for out, pos, neg in MOOD_TAG_CHECKS:
            if neg is None:
                labels = [int(bool(t & pos)) for t in tag_sets]
                scores = feats[out]
            else:
                keep = [i for i, t in enumerate(tag_sets) if bool(t & pos) != bool(t & neg)]
                labels = [int(bool(tag_sets[i] & pos)) for i in keep]
                scores = [feats[out][i] for i in keep]
            entry["mood_tag_roc_auc"][f"{out} vs {sorted(pos)}" + (f" / {sorted(neg)}" if neg else "")] = \
                {"auc": _auc_with_ci(scores, labels), "n_pos": int(sum(labels)), "n": len(labels)}
        if theme_rows:
            from sklearn.metrics import roc_auc_score
            tr_ = np.array(theme_truth)
            sc = np.array(theme_rows)
            cols = [j for j in range(tr_.shape[1]) if tr_[:, j].sum() >= 3 and (1 - tr_[:, j]).sum() >= 3]
            entry["moodtheme_head_macro_roc_auc_test_split"] = {
                "value": float(np.mean([roc_auc_score(tr_[:, j], sc[:, j]) for j in cols])) if cols else None,
                "n_tracks": len(theme_rows), "n_tags_evaluated": len(cols),
                "note": "官方 split-0 测试集曲目；作者报告的全测试集 ROC-AUC 为 0.76"}
        report[cond.name] = entry
    return report


def evaluate_pmemo(tracks, cache, conditions):
    """效价/唤醒度回归。PMEmo 标注取值 0–1，模型输出 1–9：
    Pearson/Spearman 与量纲无关，是主要指标；CCC 先把模型输出线性换算到 0–1 ((x-1)/8) 再计算。
    另报告“高于/低于中位数”的 ROC-AUC，对应 App 中“高/低能量”“偏亮/偏暗”的二分判断。"""
    from scipy import stats
    report = {}
    for cond in conditions:
        pred, truth = defaultdict(list), defaultdict(list)
        for ti, tr in enumerate(tracks):
            va = cache[f"{ti}|{cond.name}"]["new_valence_arousal"]
            if len(va) == 0:
                continue
            v, a = va.mean(0)
            pred["valence"].append(v)
            pred["arousal"].append(a)
            truth["valence"].append(tr.meta["valence"])
            truth["arousal"].append(tr.meta["arousal"])
        entry = {}
        for dim in ("arousal", "valence"):
            p_, t_ = np.array(pred[dim]), np.array(truth[dim])
            if len(p_) < 5:
                continue
            reg = metrics.regression_report((p_ - 1) / 8, t_)
            entry[dim] = {
                "n": len(p_),
                "pearson": reg["pearson"],
                "spearman": metrics.correlation(p_, t_),
                "ccc_scaled": reg["ccc"],
                "mae_scaled": reg["mae"],
                "above_median_roc_auc": _auc_with_ci(p_, (t_ > np.median(t_)).astype(int)),
                "prediction_range": [float(p_.min()), float(p_.max())],
            }
        report[cond.name] = entry
    return report


def evaluate_nonmusic(nonmusic, style_names, legacy_classes):
    """非音乐输入时：旧模型给出的流派置信度、新模型的最高可显示流派激活值"""
    from hearing_sense_ml.interpret import DEFAULT_THRESHOLDS
    out = {}
    for kind, items in nonmusic.items():
        legacy_conf = [float(x["legacy_genre"].max(1).mean()) for x in items if len(x["legacy_genre"])]
        new_top = []
        for x in items:
            for row in x["new_styles"]:
                new_top.append(genre_summary(row, style_names)["score"])
        out[kind] = {
            "n_clips": len(items),
            "legacy_mean_top1_confidence": float(np.mean(legacy_conf)) if legacy_conf else None,
            "new_windows": len(new_top),
            "new_mean_top_genre_activation": float(np.mean(new_top)) if new_top else None,
            "new_fraction_windows_above_genre_threshold": float(np.mean(
                np.array(new_top) >= DEFAULT_THRESHOLDS["genre_min_activation"])) if new_top else None,
        }
    return out


def write_summary(path, report):
    lines = [f"# 评估摘要：{report['dataset']}", "",
             f"- 曲目数：{report['n_tracks']}；录音条件：{', '.join(report['conditions'])}",
             f"- 时间上限：{report['time_limit_minutes']:g} 分钟（到时停止开始新曲目，只用已完成的曲目计算）"
             if report.get("time_limit_minutes") else "- 时间上限：无",
             f"- 截取：{report.get('excerpt', '整首')}；窗口级置信区间按曲目聚类重采样",
             f"- 噪声来源：{json.dumps(report['noise_sources'], ensure_ascii=False)}",
             "- 所有数值为点估计 [95% bootstrap 置信区间]；只做前向推理，未进行任何训练。", ""]

    def fmt(v):
        return "—" if not v else (f"{v[0]:.3f}" if v[1] is None else f"{v[0]:.3f} [{v[1]:.3f}, {v[2]:.3f}]")

    if "genre" in report:
        lines += ["## 流派", "", "| 条件 | 层级 | 新模型·开放集 准确率 | 新模型·闭集 平衡准确率 | 新模型·闭集 宏F1 | 旧模型(可比类别) 准确率 | 新模型(可比类别) 准确率 |",
                  "|---|---|---|---|---|---|---|"]
        for cond, r in report["genre"].items():
            for level in ["window", "track"]:
                e = r[level]
                lines.append(f"| {cond} | {level} | {fmt(e['new_open']['accuracy'])} | "
                             f"{fmt(e['new_closed']['balanced_accuracy'])} | {fmt(e['new_closed']['macro_f1'])} | "
                             f"{fmt(e.get('legacy_on_comparable_classes', {}).get('accuracy'))} | "
                             f"{fmt(e.get('new_open_on_comparable_classes', {}).get('accuracy'))} |")
        lines += ["", "窗口间标签跳变率（越低越稳定）：", ""]
        for cond, r in report["genre"].items():
            lines.append(f"- {cond}: {json.dumps(r['flicker_rate'])}")
    if "nonmusic" in report:
        lines += ["", "## 非音乐输入", "", "| 输入 | 旧模型平均最高流派置信度 | 新模型平均最高流派激活 | 新模型超过流派阈值的窗口比例 |", "|---|---|---|---|"]
        for kind, r in report["nonmusic"].items():
            f = lambda v: "—" if v is None else f"{v:.3f}"  # noqa: E731
            lines.append(f"| {kind} | {f(r['legacy_mean_top1_confidence'])} | {f(r['new_mean_top_genre_activation'])} | "
                         f"{f(r['new_fraction_windows_above_genre_threshold'])} |")
    if "emotion" in report:
        lines += ["", "## 情绪（Emotify GEMS 相关性检验）", ""]
        for cond, r in report["emotion"].items():
            lines.append(f"### {cond}（{r['n_tracks']} 首）")
            for chk in r["expected_direction_checks"]:
                within = "; ".join(f"{g}: {fmt(v)}" for g, v in chk["spearman_within_genre"].items())
                lines.append(f"- {chk['model_output']} ~ {chk['gems']}（预期{'正' if chk['expected_sign'] > 0 else '负'}相关）："
                             f"总体 ρ={fmt(chk['spearman_overall'])}；组内 {within or '—'}")
            if "legacy_on_its_validation_split" in r:
                lg = r["legacy_on_its_validation_split"]
                lines.append(f"- 旧情感模型（其验证集 {lg['top1_vs_argmax_gems']['n']} 首）：top-1 准确率 "
                             f"{fmt(lg['top1_vs_argmax_gems']['accuracy'])}，平衡准确率 {fmt(lg['top1_vs_argmax_gems']['balanced_accuracy'])}；"
                             f"“总是预测训练集均值”基线准确率 {fmt(lg['baseline_always_predict_training_mean']['accuracy'])}")
    if "jamendo" in report:
        lines += ["", "## MTG-Jamendo（弱标签：上传者标签缺失不代表否定）", ""]
        for cond, r in report["jamendo"].items():
            acc = r["genre_open_set_accuracy"]
            lines.append(f"### {cond}")
            lines.append(f"- 显示的顶层流派落在曲目标签允许范围内：窗口 {fmt(acc.get('window'))}，整段 {fmt(acc.get('track'))}")
            lines.append("- 各流派 ROC-AUC：" + "; ".join(f"{p}: {fmt(v)}" for p, v in r["genre_parent_roc_auc"].items() if v))
            for k, v in r["mood_tag_roc_auc"].items():
                lines.append(f"- {k}：AUC {fmt(v['auc'])}（正例 {v['n_pos']}/{v['n']}）")
            if "moodtheme_head_macro_roc_auc_test_split" in r:
                m = r["moodtheme_head_macro_roc_auc_test_split"]
                lines.append(f"- mood/theme 头（测试集 {m['n_tracks']} 首，{m['n_tags_evaluated']} 个标签）宏平均 ROC-AUC："
                             + ("—" if m["value"] is None else f"{m['value']:.3f}") + f"（{m['note']}）")
    if "pmemo" in report:
        lines += ["", "## PMEmo 效价/唤醒度", "", "| 条件 | 维度 | Pearson | Spearman | CCC (换算后) | 高于中位数 AUC | 预测范围 (1–9) |",
                  "|---|---|---|---|---|---|---|"]
        for cond, r in report["pmemo"].items():
            for dim, e in r.items():
                lines.append(f"| {cond} | {dim} | {fmt(e['pearson'])} | {fmt(e['spearman'])} | {fmt(e['ccc_scaled'])} | "
                             f"{fmt(e['above_median_roc_auc'])} | {e['prediction_range'][0]:.2f}–{e['prediction_range'][1]:.2f} |")
    path.write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="emotify_local", choices=list(datasets.LOADERS))
    ap.add_argument("--conditions", default="core", help="预设 all/core/noise，或逗号分隔的条件名")
    ap.add_argument("--max-per-class", type=int, default=0, help="每个类别最多取多少首（0 = 全部）")
    ap.add_argument("--reuse-cache", action="store_true")
    ap.add_argument("--max-seconds", type=float, default=60, help="每首最多分析多少秒（取正中间）；0 = 整首")
    ap.add_argument("--max-minutes", type=float, default=0, help="整个脚本的硬性时间上限（分钟）；0 = 不限")
    args = ap.parse_args()
    deadline = START + args.max_minutes * 60 - 150 if args.max_minutes else None  # 预留 2.5 分钟给非音乐测试与指标计算

    tracks = datasets.LOADERS[args.dataset]()
    if args.max_per_class:
        by = defaultdict(list)
        for t in tracks:
            by[t.label].append(t)
        rng = np.random.default_rng(0)
        tracks = [t for lab in sorted(by) for t in
                  [by[lab][i] for i in sorted(rng.choice(len(by[lab]), min(args.max_per_class, len(by[lab])), replace=False))]]
    wanted = augment.PRESETS.get(args.conditions, args.conditions.split(","))
    unknown = set(wanted) - {c.name for c in augment.CONDITIONS}
    if unknown:
        sys.exit(f"未知条件: {sorted(unknown)}；可选预设 {list(augment.PRESETS)} 或条件名 {[c.name for c in augment.CONDITIONS]}")
    conditions = [c for c in augment.CONDITIONS if c.name in wanted]
    out_dir = RESULTS / "eval" / args.dataset
    out_dir.mkdir(parents=True, exist_ok=True)
    is_emotify = args.dataset.startswith("emotify")
    val_ids = legacy_validation_ids() if is_emotify else set()
    tracks = balanced_order(tracks, priority=(lambda t: t.meta.get("track_id") in val_ids) if is_emotify else None)
    print(f"数据集 {args.dataset}：{len(tracks)} 首 × {len(conditions)} 种条件" +
          (f"，时间上限 {args.max_minutes:g} 分钟" if args.max_minutes else ""), flush=True)
    print("加载噪声与房间混响素材…", flush=True)
    pools, sources = load_noise_pools()
    print(f"  完成（{mmss(time.time() - START)}）：" + "；".join(f"{k}: {v}" for k, v in sources.items()), flush=True)

    cache_file = out_dir / "cache.npz"
    if args.reuse_cache and cache_file.exists():
        raw = np.load(cache_file, allow_pickle=True)
        cache = raw["cache"].item()
        nonmusic = raw["nonmusic"].item()
        if "track_paths" in raw:  # 缓存可能只覆盖了部分曲目（时间上限），按缓存中的顺序恢复
            by_path = {str(t.path): t for t in tracks}
            tracks = [by_path[p] for p in raw["track_paths"]]
    else:
        t = time.time()
        style_names_live = json.loads((COREML_OUT / "labels.json").read_text())["styles"]
        cache, done = predict(tracks, conditions, pools,
                              legacy_emotion_for=(lambda t: t.meta.get("track_id") in val_ids) if is_emotify else None,
                              max_seconds=args.max_seconds, deadline=deadline, dataset=args.dataset,
                              style_names=style_names_live)
        tracks = tracks[:done]
        print("非音乐输入测试（语音 / 环境噪声 / 静音）…", flush=True)
        nonmusic = predict_nonmusic(conditions, pools)
        np.savez_compressed(cache_file, cache=dict(cache), nonmusic=dict(nonmusic),
                            track_paths=np.array([str(t.path) for t in tracks]))
        print(f"推理完成，用时 {mmss(time.time() - t)}；计算指标…", flush=True)

    new_labels = CoreMLMusicModel().labels
    style_names = new_labels["styles"]
    legacy_classes = LegacyGenre().classes
    report = {"dataset": args.dataset, "n_tracks": len(tracks), "conditions": [c.name for c in conditions],
              "time_limit_minutes": args.max_minutes or None,
              "condition_descriptions": {c.name: c.description for c in conditions}, "noise_sources": sources,
              "window_seconds_new": new_labels["window_seconds"], "window_seconds_legacy": 5.5,
              "excerpt": f"超过 {args.max_seconds:g} 秒的曲目取正中间 {args.max_seconds:g} 秒" if args.max_seconds else "整首"}
    maps = datasets.genre_maps()
    gmap = maps.get("emotify" if is_emotify else args.dataset)
    if gmap:
        report["genre"] = evaluate_genre(tracks, cache, conditions, gmap, style_names, legacy_classes)
    if is_emotify:
        report["emotion"] = evaluate_emotify_emotion(tracks, cache, conditions, legacy_classes)
    if args.dataset == "pmemo":
        report["pmemo"] = evaluate_pmemo(tracks, cache, conditions)
    if args.dataset == "mtg_jamendo":
        report["jamendo"] = evaluate_jamendo(tracks, cache, conditions, style_names, new_labels["moodtheme"])
    report["nonmusic"] = evaluate_nonmusic(nonmusic, style_names, legacy_classes)
    (out_dir / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))
    write_summary(out_dir / "summary.md", report)
    print((out_dir / "summary.md").read_text())


if __name__ == "__main__":
    main()
