"""Shared helpers: load run outputs, finalize production recaps, build blinded judge batches, aggregate."""
from __future__ import annotations
import json, random, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from sb import post as PP, common as C

MODELS = ["apple", "qwen35-4b", "lfm25-2.6b"]


def jl(path):
    return [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()] if Path(path).exists() else []


def finalize_prod(item, rec):
    """Production post-processing of one recorded draft. Returns dict with units (raw) and the final recap."""
    text, _ = C.transcript(item)
    v = PP.Validator(text)
    summary = " ".join(PP.tidied(s) for s in PP.sentences(rec["draft_summary"]))
    kp = [PP.tidied(k) for k in rec["draft_keyPoints"]]
    res = v.validate(summary, kp, rec.get("title", ""), rec.get("restatements") or {})
    ok, why = PP.accept(res)
    units, ai, ki = [], 0, 0
    for kind, orig, kept, reason in res["items"]:
        if kind == "summary": ai += 1; uid = f"a{ai}"
        else: ki += 1; uid = f"k{ki}"
        units.append({"u": uid, "text": orig, "kept": kept is not None, "kept_text": kept, "reason": reason})
    return {"units": units, "accepted": ok, "reject_reason": why, "final_summary": res["summary"] if ok else "",
            "final_keyPoints": res["keyPoints"] if ok else [], "verbatim_share": res["verbatim_share"], "removed": res["removed"],
            "statements": res["statements"], "restated": res["restated"], "copied": len(res["copied"])}


def neutral_units(text):
    return [{"u": f"a{i+1}", "text": s} for i, s in enumerate(PP.sentences(text))]
