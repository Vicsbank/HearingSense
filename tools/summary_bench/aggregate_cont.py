import glob, json, random, statistics as st
from pathlib import Path
from score_lib import *
J = ROOT / "results/summary_model_bench/judging/cont"
key = json.load(open(J / "keyvault/KEY_DO_NOT_SHARE.json"))
data = {d["id"]: d for d in C.load(HERE / "data/continue.jsonl")}
res = {m: {r["id"]: r for r in jl(ROOT / f"results/summary_model_bench/final/{m}__final__continue.jsonl")} for m in MODELS}
rows = []
for f in sorted(glob.glob(str(J / "out/*.json"))):
    for conv in json.load(open(f))["results"]:
        cid = conv["conversation"]; d = data[cid]
        sup = {c["supersedes"] for c in d["corrections"]}
        newids = {x["id"] for x in d["new_facts"]}; corrids = {c["id"] for c in d["corrections"]}
        oldkeep = {i for i in d["must_keep"] if i not in sup}
        for s in conv["summaries"]:
            k = key[f"{cid}/{s['sid']}"]
            fs = {x["id"]: {"full": 1, "partial": .5}.get(x["status"], 0) for x in s["facts"]}
            avg = lambda ids: (sum(fs.get(i, 0) for i in ids) / len(ids)) if ids else None
            claims = sum(u["n_claims"] for u in s["units"]); uns = sum(u["n_unsupported"] for u in s["units"])
            cor = [d["corrections"][0]] if d["corrections"] else []
            rows.append({"model": k["model"], "config": k["config"], "id": cid, "lang": d["language"],
                         "keep_earlier": avg(oldkeep & set(fs)), "new": avg(newids), "corr_fact": avg(corrids), "corr": s["correction"],
                         "precision": 1 - uns / claims if claims else None, "unsup": uns, "mn_viol": sum(1 for x in s["must_not"] if x["violated"]), "mn_total": len(s["must_not"]),
                         "rep": s["quality"]["repetition"], "natural": s["quality"]["natural"], "all_recall": sum(fs.values()) / len(fs),
                         "added_chars": len(res[k["model"]][cid]["addition"]["added"]) if k["config"] == "addition" else None,
                         "noop": (len(d["new_facts"]) == 0 and not d["corrections"])})
mean = lambda xs: (sum(xs) / len(xs)) if xs else None
out = {}
for cfg in ("addition", "rewrite"):
    for m in MODELS:
        rs = [r for r in rows if r["config"] == cfg and r["model"] == m]
        cr = [r["corr"] for r in rs if r["corr"] in ("correct", "wrong")]
        out[f"{cfg}|{m}"] = {"n": len(rs), "earlier_facts_kept": mean([r["keep_earlier"] for r in rs if r["keep_earlier"] is not None]),
            "new_facts_added": mean([r["new"] for r in rs if r["new"] is not None]), "correction_fact_present": mean([r["corr_fact"] for r in rs if r["corr_fact"] is not None]),
            "correction_accuracy": cr.count("correct") / len(cr) if cr else None, "n_corr": len(cr),
            "precision": mean([r["precision"] for r in rs if r["precision"] is not None]), "unsupported_per_update": mean([r["unsup"] for r in rs]),
            "must_not_violation_rate": sum(r["mn_viol"] for r in rs) / max(1, sum(r["mn_total"] for r in rs)), "repetition_5best": mean([r["rep"] for r in rs]), "natural": mean([r["natural"] for r in rs]),
            "noop_unsupported_per_update": mean([r["unsup"] for r in rs if r["noop"]]), "n_noop": sum(1 for r in rs if r["noop"]),
            "mean_added_chars": mean([r["added_chars"] for r in rs if r["added_chars"] is not None])}
json.dump({"rows": rows, "metrics": out}, open(ROOT / "results/summary_model_bench/metrics_continue.json", "w"), indent=1)
f = lambda x: "-" if x is None else f"{x:.3f}"
for k, v in out.items(): print(k, {a: f(b) if isinstance(b, float) else b for a, b in v.items()})
# latency of update
for m in MODELS:
    cs = jl(ROOT / f"results/summary_model_bench/final/{m}__final__continue.jsonl")
    a = [c["addition"]["reply"]["seconds"] for c in cs]; r = [c["rewrite"]["reply"]["seconds"] for c in cs]
    print(m, "update latency add med/max", round(st.median(a), 2), round(max(a), 2), "rewrite med/max", round(st.median(r), 2), round(max(r), 2), "add parse", {k: sum(1 for c in cs if c["addition"]["parse"] == k) for k in ("ok", "repaired", "failed")})
