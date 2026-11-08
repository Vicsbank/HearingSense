"""Blinded judge batches for the Continue benchmark. usage: cont_pack.py <phase> <set> <out_dir> [per_batch=3] [limit]
Judged text = the updated recap as the user would read it: (a) production style: earlier recap + appended addition,
(b) neutral rewrite. Reference facts = first-part facts not superseded + new facts + corrections (final values)."""
import json, random, sys
from pathlib import Path
from score_lib import *

phase, setname, out_dir = sys.argv[1], sys.argv[2], Path(sys.argv[3])
per_batch = int(sys.argv[4]) if len(sys.argv) > 4 else 3
limit = int(sys.argv[5]) if len(sys.argv) > 5 else 0
data = {d["id"]: d for d in C.load(HERE / "data" / ("continue.jsonl"))}
rd = ROOT / "results" / "summary_model_bench" / phase
res = {m: {r["id"]: r for r in jl(rd / f"{m}__{setname}__continue.jsonl")} for m in MODELS}
ids = [i for i in data if all(i in res[m] for m in MODELS)]
ids = ids[:limit] if limit else ids
out_dir.mkdir(parents=True, exist_ok=True)
rng, key = random.Random(20261013), {}
batches = [ids[i:i + per_batch] for i in range(0, len(ids), per_batch)]
for bi, group in enumerate(batches):
    convs = []
    for cid in group:
        d = data[cid]
        sup = {c["supersedes"] for c in d.get("corrections", [])}
        facts = [f for f in d["facts"] if f["id"] not in sup] + [dict(f, critical=f.get("critical", True)) for f in d.get("new_facts", [])] \
              + [{"id": c["id"], "text": c["text"], "critical": True, "kind": "change"} for c in d.get("corrections", [])]
        sums = []
        for m in MODELS:
            sums.append((m, "addition", res[m][cid]["addition"]["final"]))
            sums.append((m, "rewrite", res[m][cid]["rewrite"]["final"]))
        rng.shuffle(sums)
        entries = []
        for n, (m, cfg, text) in enumerate(sums, 1):
            sid = f"S{n}"; key[f"{cid}/{sid}"] = {"model": m, "config": cfg}
            entries.append({"sid": sid, "units": neutral_units(text)})
        convs.append({"conversation": cid, "language": d["language"],
                      "transcript": [f"{i+1}. {l['text'].strip()}" for i, l in enumerate(d["lines"] + d["more_lines"])],
                      "facts": facts, "must_not": d["must_not"] + d.get("must_not_after", []), "uncertain": d["uncertain"], "summaries": entries})
    (out_dir / f"batch_{bi:03d}.json").write_text(json.dumps({"batch": f"batch_{bi:03d}", "conversations": convs}, ensure_ascii=False, indent=1))
(out_dir / "KEY_DO_NOT_SHARE.json").write_text(json.dumps(key, indent=1))
print(len(batches), "batches")
