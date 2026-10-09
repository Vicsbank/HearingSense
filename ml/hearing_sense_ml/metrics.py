"""评估指标。所有指标都附带按曲目重采样的 bootstrap 95% 置信区间，
因为本地评估集很小，单个数字容易给人错误的精确感。"""
import warnings

import numpy as np
from scipy import stats
from sklearn.metrics import precision_recall_fscore_support


def bootstrap_ci(fn, n_items, n_boot=1000, seed=0):
    """fn(indices) -> float；返回 (点估计, 2.5%, 97.5%)"""
    rng = np.random.default_rng(seed)
    point = fn(np.arange(n_items))
    vals = []
    # 重采样偶尔只抽到一个类别，sklearn 会警告并返回 nan；这些样本被丢弃，警告无需显示
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        for _ in range(n_boot):
            idx = rng.integers(0, n_items, n_items)
            try:
                v = fn(idx)
            except ValueError:
                continue
            if np.isfinite(v):
                vals.append(v)
    if not vals:
        return [float(point), None, None]
    return [float(point), float(np.percentile(vals, 2.5)), float(np.percentile(vals, 97.5))]


def _cm_metrics(cm, present_idx):
    """从混淆矩阵（行=真实，列=预测，含所有出现过的标签）计算指标，与 sklearn 在 labels=present、
    zero_division=0 时的定义一致"""
    total = cm.sum()
    diag = np.diag(cm)[present_idx]
    rows = cm.sum(1)[present_idx]
    cols = cm.sum(0)[present_idx]
    recall = np.divide(diag, rows, out=np.zeros(len(diag)), where=rows > 0)
    precision = np.divide(diag, cols, out=np.zeros(len(diag)), where=cols > 0)
    denom = precision + recall
    f1 = np.divide(2 * precision * recall, denom, out=np.zeros(len(diag)), where=denom > 0)
    have = rows > 0
    return (np.diag(cm).sum() / total if total else np.nan,
            recall[have].mean() if have.any() else np.nan,
            f1[have].mean() if have.any() else np.nan)


def classification_report(y_true, y_pred, labels, groups=None, n_boot=1000, seed=0):
    """groups: 每个样本所属的曲目编号。同一首歌的多个窗口高度相关，
    置信区间必须按曲目整体重采样（聚类 bootstrap），否则会偏窄。"""
    y_true, y_pred = np.asarray(y_true), np.asarray(y_pred)
    labels = list(labels) + sorted(set(y_pred) - set(labels))
    index = {l: i for i, l in enumerate(labels)}
    t = np.array([index[x] for x in y_true], int)
    p = np.array([index[x] for x in y_pred], int)
    k = len(labels)
    present = [l for l in labels if l in set(y_true)]
    present_idx = np.array([index[l] for l in present], int)
    n = len(y_true)
    groups = np.arange(n) if groups is None else np.asarray(groups)
    uniq, g_inv = np.unique(groups, return_inverse=True)
    # 每个曲目的混淆矩阵贡献，重采样时直接按曲目求和
    per_group = np.zeros((len(uniq), k * k), np.int64)
    np.add.at(per_group, (g_inv, t * k + p), 1)
    full = per_group.sum(0).reshape(k, k)
    point = _cm_metrics(full, present_idx)
    rng = np.random.default_rng(seed)
    boots = []
    for _ in range(n_boot):
        w = np.bincount(rng.integers(0, len(uniq), len(uniq)), minlength=len(uniq))
        boots.append(_cm_metrics((w @ per_group).reshape(k, k), present_idx))
    boots = np.array(boots)

    def ci(j):
        v = boots[:, j][np.isfinite(boots[:, j])]
        return [float(point[j]), float(np.percentile(v, 2.5)), float(np.percentile(v, 97.5))] if len(v) else \
            [float(point[j]), None, None]

    pr, rc, f1, sup = precision_recall_fscore_support(y_true, y_pred, labels=present, zero_division=0)
    multi = len(present) > 1
    return {
        "n": int(n),
        "n_tracks": int(len(uniq)),
        "accuracy": ci(0),
        "balanced_accuracy": ci(1) if multi else None,
        "macro_f1": ci(2) if multi else None,
        "per_class": {l: {"precision": float(a), "recall": float(b), "f1": float(c), "support": int(d)}
                      for l, a, b, c, d in zip(present, pr, rc, f1, sup)},
        "labels": labels,
        "confusion_matrix": full.tolist(),
        "chance_balanced_accuracy": 1 / max(len(present), 1),
    }


def correlation(x, y):
    """Spearman ρ 及 bootstrap 置信区间"""
    x, y = np.asarray(x, float), np.asarray(y, float)
    return bootstrap_ci(lambda i: stats.spearmanr(x[i], y[i]).statistic, len(x))


def regression_report(pred, target):
    pred, target = np.asarray(pred, float), np.asarray(target, float)
    n = len(pred)

    def ccc(i):
        a, b = pred[i], target[i]
        return 2 * np.cov(a, b)[0, 1] / (a.var(ddof=1) + b.var(ddof=1) + (a.mean() - b.mean()) ** 2)

    return {
        "n": n,
        "mae": bootstrap_ci(lambda i: float(np.mean(np.abs(pred[i] - target[i]))), n),
        "pearson": bootstrap_ci(lambda i: stats.pearsonr(pred[i], target[i]).statistic, n),
        "ccc": bootstrap_ci(ccc, n),
    }


def flicker_rate(window_labels):
    """相邻窗口间 top-1 标签变化的比例（越低越稳定）"""
    if len(window_labels) < 2:
        return None
    return float(np.mean([a != b for a, b in zip(window_labels[:-1], window_labels[1:])]))
