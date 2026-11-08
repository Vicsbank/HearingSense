"""Aggregate blinded judgments into metrics. usage: aggregate.py <phase> <set> <judging_dir> <out.json>"""
import glob, json, statistics as st, sys, collections
from pathlib import Path
from score_lib import *

phase, setname, jdir, outp = sys.argv[1], sys.argv[2], Path(sys.argv[3]), sys.argv[4]
data = {d["id"]: d for d in C.load(HERE / "data" / f"{setname}.jsonl")}
rd = ROOT / "results" / "summary_model_bench" / phase
key = json.load(open(jdir / "KEY_DO_NOT_SHARE.json"))
prod = {m: {r["id"]: r for r in jl(rd / f"{m}__{setname}__prod.jsonl")} for m in MODELS}
fin = {(m, cid): finalize_prod(data[cid], r) for m in MODELS for cid, r in prod[m].items()}

rows = []   # one row per (model, config, conversation)
for f in sorted(glob.glob(str(jdir / "out" / "*.json"))):
    for conv in json.load(open(f))["results"]:
        cid = conv["conversation"]; d = data[cid]
        crit = {x["id"]: x["critical"] for x in d["facts"]}
        for s in conv["summaries"]:
            k = key[f"{cid}/{s['sid']}"]; m, cfg = k["model"], k["config"]
            variants = [(cfg if cfg == "neutral" else "prod_raw", None)]
            if cfg == "prod": variants.append(("prod_final", fin[(m, cid)]))
            for name, fz in variants:
                keep = None
                if fz is not None:
                    keep = {u["u"] for u in fz["units"] if u["kept"]} if fz["accepted"] else set()
                units = [u for u in s["units"] if keep is None or u["u"] in keep]
                claims = sum(u["n_claims"] for u in units); uns = sum(u["n_unsupported"] for u in units); amb = sum(u["n_ambiguous"] for u in units)
                fs = {}
                for fa in s["facts"]:
                    st_ = fa["status"]
                    if keep is not None and not (set(fa.get("by", [])) & keep): st_ = "none"
                    fs[fa["id"]] = {"full": 1.0, "partial": 0.5}.get(st_, 0.0)
                nm = fz is not None and not fz["accepted"]
                rows.append({"model": m, "config": name, "id": cid, "lang": d["language"], "no_summary": nm, "claims": claims, "unsup": uns, "amb": amb,
                             "recall": sum(fs.values()) / len(fs) if fs else None, "recall_strict": sum(v == 1 for v in fs.values()) / len(fs) if fs else None,
                             "crit_recall": (sum(v for i, v in fs.items() if crit.get(i)) / max(1, sum(1 for i in fs if crit.get(i)))) if any(crit.get(i) for i in fs) else None,
                             "mn_total": len(s["must_not"]), "mn_viol": sum(1 for x in s["must_not"] if x["violated"]),
                             "corr": s["correction"], "unc": [x["status"] for x in s["uncertain"]], "q": s["quality"], "verbatim": s.get("verbatim", False),
                             "chars": sum(len(u.get("text", "")) for u in units) or None})

def agg(rs):
    ok = [r for r in rs if not r["no_summary"]]
    cl = sum(r["claims"] for r in ok); un = sum(r["unsup"] for r in ok)
    mean = lambda xs: (sum(xs) / len(xs)) if xs else None
    cor = [r["corr"] for r in rs if r["corr"] in ("correct", "wrong")]
    unc = [u for r in ok for u in r["unc"]]
    return {"n": len(rs), "no_summary": len(rs) - len(ok),
            "precision": 1 - un / cl if cl else None, "ambiguous_claims_share": sum(r["amb"] for r in ok) / cl if cl else None,
            "recall": mean([r["recall"] for r in rs if r["recall"] is not None]), "recall_strict": mean([r["recall_strict"] for r in rs if r["recall_strict"] is not None]),
            "critical_recall": mean([r["crit_recall"] for r in rs if r["crit_recall"] is not None]),
            "hallucination_rate": mean([1.0 if r["unsup"] > 0 else 0.0 for r in ok]), "unsupported_per_summary": mean([r["unsup"] for r in ok]),
            "must_not_violation_rate": sum(r["mn_viol"] for r in ok) / max(1, sum(r["mn_total"] for r in ok)),
            "correction_accuracy": (cor.count("correct") / len(cor)) if cor else None, "n_corrections": len(cor),
            "uncertainty_overstated_share": (unc.count("overstated") / max(1, unc.count("overstated") + unc.count("preserved"))) if unc else None,
            "natural": mean([r["q"]["natural"] for r in ok]), "readable": mean([r["q"]["readable"] for r in ok]), "repetition": mean([r["q"]["repetition"] for r in ok]),
            "vague_units": mean([r["q"].get("vague", 0) for r in ok]), "verbatim_share_of_summaries": mean([1.0 if r["verbatim"] else 0.0 for r in ok]), "mean_chars": mean([r["chars"] for r in ok if r["chars"]])}

out = {}
for cfg in ("neutral", "prod_raw", "prod_final"):
    for m in MODELS:
        for lang in ("all", "en", "zh", "mixed"):
            rs = [r for r in rows if r["config"] == cfg and r["model"] == m and (lang == "all" or r["lang"] == lang)]
            if rs: out[f"{cfg}|{m}|{lang}"] = agg(rs)
json.dump({"rows": rows, "metrics": out}, open(outp, "w"), indent=1)
print(len(rows), "rows ->", outp)
