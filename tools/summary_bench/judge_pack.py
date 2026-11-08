"""Build blinded judge batches. usage: judge_pack.py <phase> <set> <out_dir> [per_batch=2] [limit]"""
import json, random, sys
from pathlib import Path
from score_lib import *

phase, setname, out_dir = sys.argv[1], sys.argv[2], Path(sys.argv[3])
per_batch = int(sys.argv[4]) if len(sys.argv) > 4 else 2
limit = int(sys.argv[5]) if len(sys.argv) > 5 else 0
data = {d["id"]: d for d in C.load(HERE / "data" / f"{setname}.jsonl")}
rd = ROOT / "results" / "summary_model_bench" / phase
neutral = {m: {r["id"]: r for r in jl(rd / f"{m}__{setname}__neutral.jsonl")} for m in MODELS}
prod = {m: {r["id"]: r for r in jl(rd / f"{m}__{setname}__prod.jsonl")} for m in MODELS}
ids = [i for i in data if all(i in neutral[m] and i in prod[m] for m in MODELS)]
ids = ids[:limit] if limit else ids
out_dir.mkdir(parents=True, exist_ok=True)
key, rng = {}, random.Random(20261012)
batches = [ids[i:i + per_batch] for i in range(0, len(ids), per_batch)]
for bi, group in enumerate(batches):
    convs = []
    for cid in group:
        d = data[cid]; text, _ = C.transcript(d)
        sums = []
        for m in MODELS:
            sums.append((m, "neutral", neutral[m][cid]["output"], neutral_units(neutral[m][cid]["output"])))
            fin = finalize_prod(d, prod[m][cid])
            sums.append((m, "prod", None, [{"u": u["u"], "text": u["text"]} for u in fin["units"]]))
        rng.shuffle(sums)
        entries = []
        for n, (m, cfg, _, units) in enumerate(sums, 1):
            sid = f"S{n}"; key[f"{cid}/{sid}"] = {"model": m, "config": cfg}
            entries.append({"sid": sid, "units": units})
        convs.append({"conversation": cid, "language": d["language"],
                      "transcript": [f"{i+1}. {l['text'].strip()}" for i, l in enumerate(d["lines"])] + ([f"(speech could not be transcribed at seconds {m[0]}-{m[1]})" for m in d.get("missing", [])]),
                      "facts": d["facts"], "must_not": d["must_not"], "uncertain": d["uncertain"], "summaries": entries})
    (out_dir / f"batch_{bi:03d}.json").write_text(json.dumps({"batch": f"batch_{bi:03d}", "conversations": convs}, ensure_ascii=False, indent=1))
(out_dir / "KEY_DO_NOT_SHARE.json").write_text(json.dumps(key, indent=1))
print(len(batches), "batches", len(ids), "conversations")
