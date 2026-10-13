#!/usr/bin/env python3
"""Builds data/summary_regression/en_judged_v1.json from the model-bench worktree's blinded judging.

Regression corpus only (Window 9): every item was already seen during the benchmark and is
NOT an independent held-out set. English conversations only. Synthetic transcripts.
Usage: build_corpus.py <model-bench worktree> <output file>
"""
import json, sys, glob, os, re

bench, out = sys.argv[1], sys.argv[2]
judge = bench + "/results/summary_model_bench/judging/main"
key = json.load(open(judge + "/KEY_DO_NOT_SHARE.json"))
inputs, results = {}, {}
for f in sorted(glob.glob(judge + "/in/*.json")):
    for c in json.load(open(f))["conversations"]:
        inputs[c["conversation"]] = c
for f in sorted(glob.glob(judge + "/out/*.json")):
    for r in json.load(open(f))["results"]:
        results[r["conversation"]] = r
corpus = []
for cid, c in sorted(inputs.items()):
    if c.get("language") != "en" or cid not in results:
        continue
    item = {"id": cid, "transcript": [re.sub(r"^\d+\.\s*", "", t) for t in c["transcript"]], "facts": c["facts"], "summaries": []}
    in_sums = {s["sid"]: s for s in c.get("summaries", [])}
    for s in results[cid]["summaries"]:
        k = key.get(f"{cid}/{s['sid']}", {})
        texts = {u["u"]: u.get("text", "") for u in in_sums.get(s["sid"], {}).get("units", [])}
        item["summaries"].append({
            "model": k.get("model"), "config": k.get("config"),
            "units": [{"u": u["u"], "text": texts.get(u["u"], ""), "claims": u["n_claims"], "unsupported": u["n_unsupported"],
                       "note": u.get("note", "")} for u in s["units"]],
            "facts": s["facts"],
        })
    corpus.append(item)
json.dump(corpus, open(out, "w"), indent=1, ensure_ascii=False)
print(len(corpus), "conversations;", sum(len(i["summaries"]) for i in corpus), "judged summaries;",
      sum(1 for i in corpus for s in i["summaries"] for u in s["units"] if not u["text"]), "units without text")
