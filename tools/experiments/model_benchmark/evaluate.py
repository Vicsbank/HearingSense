"""Metrics for the cross-model benchmark. Reads the raw label scores written by score_models.py
(third-party models) and hs-model-bench (Apple), maps every model's labels to the common
Hearing Sense kinds (taxonomy.py) and reports, per model and context length:

  classification  top-1 kind (argmax over the 49 kinds that can become events; "silence" is not
                  an event kind in the app and is left out) → accuracy, macro F1, per-kind
                  precision and recall, confusion matrix. No thresholds involved.
  detection       one threshold per kind, chosen on the development split only (maximum F1),
                  then applied once to the test split → precision, recall, false-positive rate,
                  micro / macro F1, false alerts per hour of non-target audio.
  events          on the 10 s streams (3 s silence, 5 s of the clip, 2 s silence) with each
                  model's streaming window: event recall, detection delay after the energy onset,
                  false alerts per hour. Thresholds again from the development split.

Scores are model outputs, not probabilities: thresholds are per model and per kind, and scores
are never compared across models. 95 % intervals: bootstrap over test clips (2 000 resamples).

Usage: .venv/bin/python -I tools/experiments/model_benchmark/evaluate.py
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import audio_io  # noqa: E402
import taxonomy  # noqa: E402

SCORES = audio_io.OUT / "scores"
CONTEXTS = ["1", "2", "5", "10"]
RNG = np.random.default_rng(20261010)


# ------------------------------------------------------------------------------- loading

def kind_matrix(label_scores, labels, label_to_kind, kinds):
    """[..., labels] → [..., kinds]: a kind's score is the highest score among its labels."""
    out = np.zeros(label_scores.shape[:-1] + (len(kinds),), np.float32)
    for index, kind in enumerate(kinds):
        columns = [i for i, label in enumerate(labels) if label_to_kind.get(label) == kind]
        if columns:
            out[..., index] = label_scores[..., columns].max(axis=-1)
    return out


def load_third_party(name, kinds, ids):
    data = np.load(SCORES / f"scores_{name}.npz", allow_pickle=False)
    assert list(data["ids"]) == ids, f"{name}: scores do not match the manifest"
    labels = [str(label) for label in data["labels"]]
    mapping = {label: kind for label, (kind, _) in taxonomy.audioset_label_to_kind(labels)[0].items()}
    systems = {}
    aggregations = ["mean", "max"] if name == "yamnet" else ["mean"]
    for aggregation in aggregations:
        title = f"{name}[{aggregation}]" if name == "yamnet" else name
        systems[title] = {
            "contexts": {key: kind_matrix(data[f"context_{key}_{aggregation}"], labels, mapping, kinds) for key in CONTEXTS},
            "streams": {}}
    for key in [k[len("stream_"):] for k in data.files if k.startswith("stream_") and not k.endswith("_window_hop")]:
        window, hop = data[f"stream_{key}_window_hop"]
        scores = kind_matrix(data[f"stream_{key}"].astype(np.float32), labels, mapping, kinds)
        ends = np.arange(scores.shape[1]) * hop + window
        for title in systems:
            systems[title]["streams"][f"{float(window):g} s / hop {float(hop):g} s"] = (scores, ends)
    return systems


def load_variants(name, kinds, ids):
    """EfficientAT with a short context presented inside a 10 s input (score_models.py --variants)."""
    path = SCORES / f"scores_{name}_variants.npz"
    if not path.exists():
        return {}
    data = np.load(path, allow_pickle=False)
    assert list(data["ids"]) == ids
    labels = [str(label) for label in data["labels"]]
    mapping = {label: kind for label, (kind, _) in taxonomy.audioset_label_to_kind(labels)[0].items()}
    plain = np.load(SCORES / f"scores_{name}.npz", allow_pickle=False)
    systems = {}
    for mode in ("pad10", "tile10"):
        if f"context_5_{mode}" not in data.files:
            continue
        contexts = {key: kind_matrix(data[f"context_{key}_{mode}"], labels, mapping, kinds) for key in ("1", "2", "5")}
        contexts["10"] = kind_matrix(plain["context_10_mean"], labels, mapping, kinds)  # already 10 s
        systems[f"{name}+{mode}"] = {"contexts": contexts, "streams": {}}
    for key in ("1", "2"):
        if f"stream_{key}" in data.files and f"{name}+tile10" in systems:
            window, hop = data[f"stream_{key}_window_hop"]
            scores = kind_matrix(data[f"stream_{key}"].astype(np.float32), labels, mapping, kinds)
            ends = np.arange(scores.shape[1]) * hop + window
            systems[f"{name}+tile10"]["streams"][f"{float(window):g} s / hop {float(hop):g} s"] = (scores, ends)
    return systems


def load_apple(kinds, ids):
    files = sorted(SCORES.glob("apple_scores_apple_v1*.jsonl"))
    if not files:
        return {}
    mapping = taxonomy.apple_label_to_kind()
    labels = sorted(mapping)
    column = {label: i for i, label in enumerate(labels)}
    rows = {}
    for file in files:
        for line in open(file):
            row = json.loads(line)
            rows[row["id"]] = row
    missing = [i for i in ids if i not in rows]
    assert not missing, f"Apple scores missing for {len(missing)} clips"

    def vector(scores):
        out = np.zeros(len(labels), np.float32)
        for label, score in scores.items():
            out[column[label]] = score
        return out

    contexts, absent = {}, 0
    for key in CONTEXTS:
        matrix = np.zeros((len(ids), len(labels)), np.float32)
        for n, clip in enumerate(ids):
            if key in rows[clip]["contexts"]:
                matrix[n] = vector(rows[clip]["contexts"][key])
            else:
                absent += 1
        contexts[key] = kind_matrix(matrix, labels, mapping, kinds)
    streams = {}
    for key in rows[ids[0]]["streams"]:
        count = min(len(rows[clip]["streams"][key]) for clip in ids)
        tensor = np.zeros((len(ids), count, len(labels)), np.float32)
        for n, clip in enumerate(ids):
            for w, window in enumerate(rows[clip]["streams"][key][:count]):
                tensor[n, w] = vector(window["scores"])
        first = rows[ids[0]]["streams"][key]
        ends = np.array([w["start"] + w["duration"] for w in first[:count]])
        hop = first[1]["start"] - first[0]["start"]
        streams[f"{first[0]['duration']:g} s / hop {hop:g} s"] = (kind_matrix(tensor, labels, mapping, kinds), ends)
    return {"apple_v1": {"contexts": contexts, "streams": streams, "contexts_without_result": absent}}


# ------------------------------------------------------------------------------- metrics

def f1(precision, recall):
    return 2 * precision * recall / (precision + recall) if precision + recall > 0 else 0.0


def classification(scores, truth, eval_kinds, all_kinds):
    """Top-1 over all event kinds; predictions outside the evaluated kinds count as wrong ('other')."""
    scores = scores.copy()
    scores[:, all_kinds.index("silence")] = -1.0  # never an event (SoundKindDefinition.producesEvents == false)
    predicted = np.array(all_kinds)[scores.argmax(axis=1)]
    predicted[scores.max(axis=1) <= 0] = "none"
    per_kind = {}
    for kind in eval_kinds:
        tp = int(((predicted == kind) & (truth == kind)).sum())
        fp = int(((predicted == kind) & (truth != kind)).sum())
        fn = int(((predicted != kind) & (truth == kind)).sum())
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        per_kind[kind] = {"precision": precision, "recall": recall, "f1": f1(precision, recall), "support": tp + fn}
    return predicted, per_kind


def macro_f1_from(predicted, truth, eval_kinds):
    values = []
    for kind in eval_kinds:
        tp = ((predicted == kind) & (truth == kind)).sum()
        fp = ((predicted == kind) & (truth != kind)).sum()
        fn = ((predicted != kind) & (truth == kind)).sum()
        values.append(2 * tp / (2 * tp + fp + fn) if 2 * tp + fp + fn else 0.0)
    return float(np.mean(values))


def bootstrap(predicted, truth, eval_kinds, rounds=2000):
    n = len(truth)
    accuracy, macro = [], []
    for _ in range(rounds):
        sample = RNG.integers(0, n, n)
        accuracy.append(float((predicted[sample] == truth[sample]).mean()))
        macro.append(macro_f1_from(predicted[sample], truth[sample], eval_kinds))
    return [float(np.percentile(accuracy, 2.5)), float(np.percentile(accuracy, 97.5))], \
           [float(np.percentile(macro, 2.5)), float(np.percentile(macro, 97.5))]


def best_threshold(scores, positive):
    """Threshold with the highest F1 on these (development) clips; ties → the higher threshold."""
    candidates = np.unique(np.concatenate([scores[positive], [0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9]]))
    best, best_value = 0.5, -1.0
    for threshold in candidates:
        if threshold <= 0:
            continue
        fired = scores >= threshold
        tp, fp, fn = (fired & positive).sum(), (fired & ~positive).sum(), (~fired & positive).sum()
        value = 2 * tp / (2 * tp + fp + fn) if 2 * tp + fp + fn else 0.0
        if value >= best_value:
            best, best_value = float(threshold), float(value)
    return best


def detection(dev_scores, dev_truth, test_scores, test_truth, eval_kinds, all_kinds, seconds):
    per_kind, totals = {}, np.zeros(3)
    for kind in eval_kinds:
        column = all_kinds.index(kind)
        threshold = best_threshold(dev_scores[:, column], dev_truth == kind)
        fired, positive = test_scores[:, column] >= threshold, test_truth == kind
        tp, fp, fn = int((fired & positive).sum()), int((fired & ~positive).sum()), int((~fired & positive).sum())
        negatives = int((~positive).sum())
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        per_kind[kind] = {"threshold": threshold, "precision": precision, "recall": recall, "f1": f1(precision, recall),
                          "false_positive_rate": fp / negatives if negatives else 0.0,
                          "false_alerts_per_hour_of_non_target_audio": fp / (negatives * seconds / 3600) if negatives else 0.0,
                          "true_positives": tp, "false_positives": fp, "false_negatives": fn}
        totals += (tp, fp, fn)
    micro_p = totals[0] / (totals[0] + totals[1]) if totals[0] + totals[1] else 0.0
    micro_r = totals[0] / (totals[0] + totals[2]) if totals[0] + totals[2] else 0.0
    return {"micro_f1": f1(micro_p, micro_r), "micro_precision": micro_p, "micro_recall": micro_r,
            "macro_f1": float(np.mean([v["f1"] for v in per_kind.values()])), "per_kind": per_kind}


def events(scores, ends, onsets, truth, dev, test, eval_kinds, all_kinds, stream_seconds):
    """Event-level detection on the streams. A kind fires in a clip when any window that ends
    after the event onset reaches the kind's threshold; the delay is that window's end minus the
    onset (audio time; inference time is not included)."""
    after = ends[None, :] > onsets[:, None]  # [clips, windows]
    per_kind = {}
    for kind in eval_kinds:
        column = all_kinds.index(kind)
        s = np.where(after, scores[:, :, column], 0.0)
        peak = s.max(axis=1)
        threshold = best_threshold(peak[dev], truth[dev] == kind)
        fired = peak >= threshold
        positive = truth == kind
        hit = fired & positive & test
        first = np.argmax(s >= threshold, axis=1)
        delays = (ends[first] - onsets)[hit]
        negatives = int((~positive & test).sum())
        fp = int((fired & ~positive & test).sum())
        support = int((positive & test).sum())
        per_kind[kind] = {
            "threshold": threshold, "event_recall": float(hit.sum() / support) if support else 0.0, "support": support,
            "delay_median_s": float(np.median(delays)) if len(delays) else None,
            "delay_p90_s": float(np.percentile(delays, 90)) if len(delays) else None,
            "false_alerts": fp, "false_alerts_per_hour": fp / (negatives * stream_seconds / 3600) if negatives else 0.0}
    return per_kind


# ---------------------------------------------------------------------------------- main

def main():
    rows = audio_io.manifest()
    ids = [row["id"] for row in rows]
    truth = np.array([row["kind"] for row in rows])
    dev = np.array([row["split"] == "dev" for row in rows])
    test = ~dev
    all_kinds = taxonomy.kinds()
    eval_kinds = sorted(set(truth))
    onsets = np.array([audio_io.STREAM_LEAD + min(max(row["onset"] - row["contexts"][audio_io.STREAM_CONTEXT]["start_sample"]
                                                      / row["sample_rate"], 0.0), 5.0) for row in rows])
    stream_seconds = audio_io.STREAM_LEAD + 5.0 + audio_io.STREAM_TAIL

    systems = {}
    systems.update(load_apple(all_kinds, ids))
    for name in ("yamnet", "mn10_as", "dymn04_as"):
        if (SCORES / f"scores_{name}.npz").exists():
            systems.update(load_third_party(name, all_kinds, ids))
            systems.update(load_variants(name, all_kinds, ids))

    # YAMNet's patch aggregation (mean, as in the reference, or max) is chosen on the development split.
    choice = {}
    if "yamnet[mean]" in systems:
        for key in CONTEXTS:
            values = {a: macro_f1_from(classification(systems[f"yamnet[{a}]"]["contexts"][key][dev], truth[dev],
                                                      eval_kinds, all_kinds)[0], truth[dev], eval_kinds)
                      for a in ("mean", "max")}
            choice[key] = max(values, key=values.get)
        systems["yamnet"] = {"contexts": {key: systems[f"yamnet[{choice[key]}]"]["contexts"][key] for key in CONTEXTS},
                             "streams": systems["yamnet[mean]"]["streams"]}
        del systems["yamnet[mean]"], systems["yamnet[max]"]

    summary = {"clips": {"dev": int(dev.sum()), "test": int(test.sum())}, "evaluated_kinds": eval_kinds,
               "yamnet_patch_aggregation_chosen_on_dev": choice, "priority_kinds": taxonomy.PRIORITY_KINDS,
               "alert_kinds": taxonomy.ALERT_KINDS, "systems": {}}
    confusion = {}
    for name, system in systems.items():
        entry = {"contexts": {}, "streams": {}}
        if "contexts_without_result" in system:
            entry["contexts_without_result"] = system["contexts_without_result"]
        for key in CONTEXTS:
            scores = system["contexts"][key]
            predicted, per_kind = classification(scores[test], truth[test], eval_kinds, all_kinds)
            accuracy_ci, macro_ci = bootstrap(predicted, truth[test], eval_kinds)
            detect = detection(scores[dev], truth[dev], scores[test], truth[test], eval_kinds, all_kinds, float(key))
            priority = [k for k in taxonomy.PRIORITY_KINDS if k in eval_kinds]
            alerts = [k for k in taxonomy.ALERT_KINDS if k in eval_kinds]
            entry["contexts"][key] = {
                "top1_accuracy": float((predicted == truth[test]).mean()), "top1_accuracy_ci95": accuracy_ci,
                "top1_macro_f1": float(np.mean([v["f1"] for v in per_kind.values()])), "top1_macro_f1_ci95": macro_ci,
                "top1_priority_recall_mean": float(np.mean([per_kind[k]["recall"] for k in priority])),
                "top1_per_kind": per_kind, "detection": detect,
                "detection_priority_recall_mean": float(np.mean([detect["per_kind"][k]["recall"] for k in priority])),
                "detection_alert_false_alerts_per_hour_mean": float(np.mean(
                    [detect["per_kind"][k]["false_alerts_per_hour_of_non_target_audio"] for k in alerts]))}
            table = {}
            for t, p in zip(truth[test], predicted):
                column = p if p in eval_kinds else "other"
                table.setdefault(t, {}).setdefault(column, 0)
                table[t][column] += 1
            confusion.setdefault(name, {})[key] = table
        for key, (scores, ends) in system["streams"].items():
            per_kind = events(scores, ends, onsets, truth, dev, test, eval_kinds, all_kinds, stream_seconds)
            alerts = [k for k in taxonomy.ALERT_KINDS if k in eval_kinds]
            priority = [k for k in taxonomy.PRIORITY_KINDS if k in eval_kinds]
            delays = [per_kind[k]["delay_median_s"] for k in alerts if per_kind[k]["delay_median_s"] is not None]
            entry["streams"][key] = {
                "alert_event_recall_mean": float(np.mean([per_kind[k]["event_recall"] for k in alerts])),
                "priority_event_recall_mean": float(np.mean([per_kind[k]["event_recall"] for k in priority])),
                "all_kinds_event_recall_mean": float(np.mean([v["event_recall"] for v in per_kind.values()])),
                "alert_delay_median_s_mean": float(np.mean(delays)) if delays else None,
                "alert_false_alerts_per_hour_mean": float(np.mean([per_kind[k]["false_alerts_per_hour"] for k in alerts])),
                "per_kind": per_kind}
        summary["systems"][name] = entry

    out = audio_io.OUT
    (out / "benchmark_summary.json").write_text(json.dumps(summary, indent=1))
    (out / "confusion_matrices.json").write_text(json.dumps(confusion, indent=1))

    def pct(value):
        return f"{100 * value:.1f}"

    print(f"test clips {int(test.sum())}, dev clips {int(dev.sum())}, kinds {len(eval_kinds)}; YAMNet aggregation {choice}")
    print("\n| model | context | top-1 acc [95% CI] | top-1 macro F1 [95% CI] | det. micro F1 | det. macro F1 | priority recall (det.) | alert false alerts/h |")
    print("|---|---|---|---|---|---|---|---|")
    for name, entry in summary["systems"].items():
        for key in CONTEXTS:
            c = entry["contexts"][key]
            print(f"| {name} | {key} s | {pct(c['top1_accuracy'])} [{pct(c['top1_accuracy_ci95'][0])}, {pct(c['top1_accuracy_ci95'][1])}] "
                  f"| {pct(c['top1_macro_f1'])} [{pct(c['top1_macro_f1_ci95'][0])}, {pct(c['top1_macro_f1_ci95'][1])}] "
                  f"| {pct(c['detection']['micro_f1'])} | {pct(c['detection']['macro_f1'])} "
                  f"| {pct(c['detection_priority_recall_mean'])} | {c['detection_alert_false_alerts_per_hour_mean']:.0f} |")
    print("\n| model | stream window | alert event recall | priority event recall | all-kind event recall | alert delay median (s) | alert false alerts/h |")
    print("|---|---|---|---|---|---|---|")
    for name, entry in summary["systems"].items():
        for key, s in entry["streams"].items():
            delay = "–" if s["alert_delay_median_s_mean"] is None else f"{s['alert_delay_median_s_mean']:.2f}"
            print(f"| {name} | {key} | {pct(s['alert_event_recall_mean'])} | {pct(s['priority_event_recall_mean'])} "
                  f"| {pct(s['all_kinds_event_recall_mean'])} | {delay} | {s['alert_false_alerts_per_hour_mean']:.0f} |")


if __name__ == "__main__":
    main()
