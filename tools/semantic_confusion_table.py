#!/usr/bin/env python3
"""Window 6.1: the confusion counts and category groups of one or more hs-semantic-eval JSON files,
computed from the stored per-item outcomes and the labelled set (same definitions as
SemanticConfusion.swift). Reads only; no model.

  tools/semantic_confusion_table.py <set file> <run.json> [<run.json> ...] [--method model]
"""
import json, sys

GROUPS = [("implicit relevance recall", {"implicit", "causal"}, "relevant"),
          ("explicit relevance recall", {"obvious", "attention"}, "relevant"),
          ("negation accuracy", {"negation"}, None), ("hypothetical accuracy", {"hypothetical"}, None),
          ("personal relevance accuracy", {"third_person"}, None),
          ("past and quotation accuracy", {"past", "sarcasm_quote"}, None),
          ("recognition-error accuracy", {"asr_error"}, None), ("context accuracy", {"multi"}, None),
          ("unrelated talk accuracy", {"unrelated"}, None), ("repetition accuracy", {"repeated"}, None)]

def items(path):
    rows = {}
    for line in open(path, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        f = [x.strip() for x in line.rstrip("\n").split("|")]
        flags = f[5].split(",")
        rows[f[0]] = dict(profile=f[1], category=f[2], expected=f[3], important="important" in flags,
                          urgent="urgent" in flags, text=f[6])
    return rows

def table(labels, run, method):
    data = json.load(open(run))
    outcomes = {o["id"]: o for o in data["outcomes"][method]}
    c = dict(TP=0, FP=0, FN=0, TN=0)
    groups, amb, fp, fn, corrections = {}, [0, 0, 0], [], [], {}
    def count(name, ok):
        hit, total = groups.get(name, (0, 0))
        groups[name] = (hit + ok, total + 1)
    for key, item in labels.items():
        o = outcomes.get(key)
        if o is None:
            continue
        for name in o.get("corrections", []):
            corrections[name] = corrections.get(name, 0) + 1
        if item["expected"] == "ambiguous":
            amb[0 if o["alerted"] else 1 if o.get("verdict") == "uncertain" else 2] += 1
            continue
        positive = item["expected"] == "relevant"
        ok = o["alerted"] == positive
        c[("TP" if ok else "FN") if positive else ("TN" if ok else "FP")] += 1
        if not ok:
            (fn if positive else fp).append(key)
        if positive and item["important"]:
            count("important-event recall", ok)
        if positive and item["urgent"]:
            count("short urgent instruction recall", ok)
        for name, categories, expected in GROUPS:
            if item["category"] in categories and (expected is None or expected == item["expected"]):
                count(name, ok)
    p = c["TP"] / max(1, c["TP"] + c["FP"]); r = c["TP"] / max(1, c["TP"] + c["FN"])
    spec = c["TN"] / max(1, c["TN"] + c["FP"])
    print(f"\n{run}\n  TP {c['TP']}  FP {c['FP']}  FN {c['FN']}  TN {c['TN']}   ambiguous: {amb[0]} alerted, {amb[1]} uncertain, {amb[2]} silent")
    print(f"  precision {p:.1%}  recall {r:.1%}  F1 {2*p*r/max(1e-9,p+r):.3f}  FPR {1-spec:.1%}  FNR {1-r:.1%}  balanced accuracy {(r+spec)/2:.1%}")
    for name in ["important-event recall", "short urgent instruction recall"] + [g[0] for g in GROUPS]:
        if name in groups:
            print(f"  {name:<34}{groups[name][0]}/{groups[name][1]}")
    seconds = sorted(o["seconds"] for o in outcomes.values())
    q = lambda v: seconds[min(len(seconds) - 1, int(len(seconds) * v))]
    print(f"  seconds per item p50 {q(.5):.2f} p95 {q(.95):.2f} p99 {q(.99):.2f}   corrections {corrections}")
    print(f"  false alerts: {' '.join(fp)}\n  missed: {' '.join(fn)}")

args = [a for a in sys.argv[1:] if not a.startswith("--")]
method = sys.argv[sys.argv.index("--method") + 1] if "--method" in sys.argv else "model"
labels = items(args[0])
for run in args[1:]:
    table(labels, run, method)
