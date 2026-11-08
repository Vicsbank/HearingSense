import json, statistics as st, sys
from score_lib import *
rd = ROOT / "results" / "summary_model_bench" / "final"
def pct(xs, p):
    xs = sorted(xs); 
    if not xs: return None
    k = (len(xs) - 1) * p; f = int(k); c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)
def stats(rs):
    s = [r["reply"]["seconds"] for r in rs]; ft = [r["reply"]["first_seconds"] for r in rs if r["reply"].get("first_seconds") is not None]
    ot = [r["reply"]["output_tokens"] for r in rs if r["reply"].get("output_tokens")]
    tps = [r["reply"]["output_tokens"] / r["reply"]["seconds"] for r in rs if r["reply"].get("output_tokens") and r["reply"]["seconds"] > 0]
    return {"n": len(s), "median_s": st.median(s), "p95_s": pct(s, .95), "max_s": max(s), "ttft_median_s": st.median(ft) if ft else None,
            "out_tokens_median": st.median(ot) if ot else None, "tok_per_s_median": st.median(tps) if tps else None}
out = {}
for m in MODELS:
    meta = json.load(open(rd / f"{m}__final.meta.json"))
    o = {"load_seconds": meta["info"].get("load_seconds"), "bridge_start": meta["info"].get("bridge_start_seconds"), "first_request_after_load_s": meta.get("first_request_seconds"),
         "latency_quiet": meta.get("latency_quiet"), "info": {k: v for k, v in meta["info"].items() if k in ("repo", "revision", "runtime", "variant", "context_size", "os", "mlx_active_gb_after_load", "rss_gb_after_load", "thinking", "template_has_thinking_switch")}}
    for t in ("neutral", "prod", "latency"):
        rs = jl(rd / f"{m}__final__{t}.jsonl")
        o[t] = stats(rs)
        if t == "latency":
            by = {}
            for r in rs: by.setdefault(r["rep"], []).append(r["reply"]["seconds"])
            o["repeat_medians_s"] = {k: round(st.median(v), 3) for k, v in sorted(by.items())}
        if t in ("neutral", "prod"):
            for lang in ("en", "zh", "mixed"):
                o[f"{t}_{lang}"] = stats([r for r in rs if r["language"] == lang])
    o["prod_with_restate"] = None
    pr = jl(rd / f"{m}__final__prod.jsonl")
    tot = [r["reply"]["seconds"] + r.get("restate_seconds", 0) for r in pr]
    o["prod_with_restate"] = {"median_s": st.median(tot), "p95_s": pct(tot, .95)}
    o["prod_parse"] = {k: sum(1 for r in pr if r["parse"] == k) for k in ("ok", "repaired", "failed")}
    o["truncated_neutral"] = sum(1 for r in jl(rd / f"{m}__final__neutral.jsonl") if r["reply"].get("finish") == "length")
    o["mem_after_groups"] = {g: v.get("mem_after") for g, v in meta["groups"].items()}
    o["load_avg_after_groups"] = {g: v.get("load") for g, v in meta["groups"].items()}
    c = jl(rd / f"{m}__final__continue.jsonl")
    o["continue_update_addition_s"] = stats([{"reply": r["addition"]["reply"]} for r in c]); o["continue_rewrite_s"] = stats([{"reply": r["rewrite"]["reply"]} for r in c])
    out[m] = o
json.dump(out, open(ROOT / "results/summary_model_bench/latency_memory.json", "w"), indent=1, default=str)
for m, o in out.items():
    mem = o["mem_after_groups"].get("latency") or {}
    print(m, "load", o["load_seconds"], "latency med/p95", round(o["latency"]["median_s"], 2), round(o["latency"]["p95_s"], 2), "neutral", round(o["neutral"]["median_s"], 2), "prod", round(o["prod"]["median_s"], 2), "p95", round(o["prod"]["p95_s"], 2), "tok/s", o["neutral"]["tok_per_s_median"] and round(o["neutral"]["tok_per_s_median"]), "mem", {k: round(v, 2) for k, v in mem.items() if isinstance(v, float)}, "quiet", o["latency_quiet"], "trunc", o["truncated_neutral"], "parse", o["prod_parse"], "reps", o["repeat_medians_s"])
