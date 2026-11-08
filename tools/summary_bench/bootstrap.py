import json, random
from score_lib import *
rows = json.load(open(ROOT / "results/summary_model_bench/metrics_main.json"))["rows"]
random.seed(7)
def paired(cfg, a, b, metric, lang="all", B=4000):
    ra = {r["id"]: r for r in rows if r["config"] == cfg and r["model"] == a and (lang == "all" or r["lang"] == lang)}
    rb = {r["id"]: r for r in rows if r["config"] == cfg and r["model"] == b and (lang == "all" or r["lang"] == lang)}
    ids = [i for i in ra if i in rb and (metric in ('precision','halluc') or (ra[i][metric] is not None and rb[i][metric] is not None))]
    def val(r):
        if metric == "halluc": return 1.0 if r["unsup"] > 0 else 0.0
        return r[metric]
    def agg(sample):
        if metric == "precision":
            return (1 - sum(ra[i]["unsup"] for i in sample) / max(1, sum(ra[i]["claims"] for i in sample))) - (1 - sum(rb[i]["unsup"] for i in sample) / max(1, sum(rb[i]["claims"] for i in sample)))
        return sum(val(ra[i]) - val(rb[i]) for i in sample) / len(sample)
    d = agg(ids); bs = sorted(agg([random.choice(ids) for _ in ids]) for _ in range(B))
    return d, bs[int(.025 * B)], bs[int(.975 * B)]
out = {}
for cfg in ("neutral", "prod_raw"):
    for a, b in (("qwen35-4b", "apple"), ("lfm25-2.6b", "apple"), ("qwen35-4b", "lfm25-2.6b")):
        for metric in ("precision", "recall", "crit_recall", "halluc"):
            for lang in ("all", "en", "zh", "mixed"):
                d, lo, hi = paired(cfg, a, b, metric, lang)
                out[f"{cfg}|{a}-{b}|{metric}|{lang}"] = [d, lo, hi]
json.dump(out, open(ROOT / "results/summary_model_bench/bootstrap_paired.json", "w"), indent=1)
for k, v in out.items():
    if k.endswith("|all"): print(k, [round(x, 3) for x in v], "SIG" if v[1] > 0 or v[2] < 0 else "")
