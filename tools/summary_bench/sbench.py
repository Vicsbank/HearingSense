"""Summary benchmark runner. One model per process, one request at a time.
  sbench.py run --model qwen35-4b --set dev --limit 10 --tasks neutral,prod --phase pilot
  sbench.py run --model qwen35-4b --set final --tasks neutral,prod,continue,latency --phase final
Models never download (HF_HUB_OFFLINE=1)."""
from __future__ import annotations

import argparse, json, os, sys, time
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(ROOT / "tools" / "model_bench"))
from mb.backends import MLXBackend, AppleBackend      # reused, read-only
from mb import sysmon                                   # reused, read-only
from sb import prompts as P, common as C, post as PP

MODELS = {
    "apple": {"kind": "apple", "name": "Apple AFM 3 Core"},
    "qwen35-4b": {"kind": "mlx", "repo": "mlx-community/Qwen3.5-4B-MLX-4bit", "rev": "32f3e8ecf65426fc3306969496342d504bfa13f3", "name": "Qwen3.5-4B"},
    "lfm25-2.6b": {"kind": "mlx", "repo": "LiquidAI/LFM2.5-2.6B-MLX-4bit", "rev": "04efa23776ce61ec34ec95ec34c859854c89542b", "name": "LFM2.5-2.6B"},
}
DATA = {"dev": HERE / "data" / "dev.jsonl", "final": HERE / "data" / "final.jsonl", "continue": HERE / "data" / "continue.jsonl",
        "continue_dev": HERE / "data" / "continue_dev.jsonl"}
LIMIT = 500


class ThinkClosedMLX(MLXBackend):
    """LFM2.5-2.6B: the chat template ends the generation prompt with an open "<think>" and has no switch.
    Non-thinking is forced by closing the block at once (empty thinking). Not a native mode of the model."""
    def tokens(self, instructions, prompt):
        toks = super().tokens(instructions, prompt)
        if self.tokenizer.decode(toks[-3:]).rstrip().endswith("<think>"):
            toks = toks + list(self.tokenizer.encode("</think>", add_special_tokens=False))
        return toks


def backend(tag: str):
    m = MODELS[tag]
    if m["kind"] == "apple":
        return AppleBackend(HERE / "apple_bridge" / ".build" / "release" / "apple-bridge", mode="guided")
    from huggingface_hub import snapshot_download
    path = snapshot_download(m["repo"], revision=m["rev"], local_files_only=True)
    return ThinkClosedMLX(path) if tag == "lfm25-2.6b" else MLXBackend(path)


def ask(be, tag, instructions, prompt, fields=None, limit=LIMIT):
    """fields: structured answer (prod). Apple: constrained schema. Open models: JSON described in the instructions."""
    if fields is None:
        r = be.generate(instructions, prompt, limit, None)
        text = C.strip_think(r.text)
        return r, {"summary": text}, "text"
    if tag == "apple":
        r = be.generate(instructions, prompt, limit, {"fields": fields})
        obj, st = C.parse_json(r.text)
        return r, obj, st
    r = be.generate(instructions + P.json_suffix(fields), prompt, limit, None)
    obj, st = C.parse_json(C.strip_think(r.text))
    return r, obj, st


def rec(r):
    d = r.as_dict(); d.pop("text", None); return d


def task_neutral(be, tag, item):
    text, _ = C.transcript(item)
    r, obj, st = ask(be, tag, P.NEUTRAL_RECAP, "Transcript:\n" + text)
    out = (obj or {}).get("summary", "") if st == "text" else r.text
    return {"id": item["id"], "language": item["language"], "task": "neutral", "output": out, "reply": rec(r), "len": C.length_stats(out)}


def task_prod(be, tag, item):
    text, notes = C.transcript(item)
    prompt = "Transcript:\n" + text + (("\n\nKnown limits of this transcript: " + " ".join(notes)) if notes else "")
    r, obj, st = ask(be, tag, P.PRODUCTION_RECAP, prompt, P.RECAP_FIELDS)
    obj = obj if isinstance(obj, dict) else {}
    summary = obj.get("summary") if isinstance(obj.get("summary"), str) else ""
    if st == "failed" and r.text.strip():
        summary = C.strip_think(r.text)               # not JSON: the text is the draft (recorded as parse failure)
    kp = [k for k in (obj.get("keyPoints") or []) if isinstance(k, str)] if isinstance(obj.get("keyPoints"), list) else []
    title = obj.get("title") if isinstance(obj.get("title"), str) else ""
    # production: tidy, validate, restate up to 3 copied sentences (one short request each), validate again
    draft_s = " ".join(PP.tidied(s) for s in PP.sentences(summary)); draft_k = [PP.tidied(k) for k in kp]
    v = PP.Validator(text)
    first = v.validate(draft_s, draft_k, title)
    restatements, restate_seconds = {}, 0.0
    for st_ in first["copied"][:PP.MAX_RESTATEMENTS]:
        rr, o2, s2 = ask(be, tag, P.PRODUCTION_RESTATE, "Sentence:\n" + st_, P.RESTATE_FIELDS, limit=80)
        restate_seconds += rr.seconds
        sent = (o2 or {}).get("sentence") if isinstance(o2, dict) else None
        if isinstance(sent, str):
            tidy = PP.tidied(sent)
            if not PP.words(tidy) or tuple(PP.words(tidy)) not in {tuple(PP.words(st_)[i:i+len(PP.words(tidy))]) for i in range(len(PP.words(st_)))}:
                restatements[st_] = tidy
            elif len(PP.words(st_)) > 0:
                restatements[st_] = sent
    return {"id": item["id"], "language": item["language"], "task": "prod", "title": title, "draft_summary": summary, "draft_keyPoints": kp,
            "parse": st, "restatements": restatements, "restate_seconds": restate_seconds, "reply": rec(r), "len": C.length_stats(summary + " " + " ".join(kp))}


def task_continue(be, tag, item):
    out = {"id": item["id"], "language": item["language"], "task": "continue"}
    text, notes = C.transcript(item)
    r0, o0, _ = ask(be, tag, P.NEUTRAL_RECAP, "Transcript:\n" + text)
    initial = o0["summary"]
    out["initial_summary"], out["initial_reply"] = initial, rec(r0)
    new = "\n".join(l["text"].strip() for l in item["more_lines"])
    # (a) production style: only the addition is written and appended
    prompt = "Earlier recap (context only, do not repeat it):\n" + initial + "\n\nSaid since then:\n" + new
    r1, o1, st1 = ask(be, tag, P.PRODUCTION_UPDATE, prompt, P.ADDITION_FIELDS, limit=250)
    o1 = o1 if isinstance(o1, dict) else {}
    added = (o1.get("summary") if isinstance(o1.get("summary"), str) else "") or (C.strip_think(r1.text) if st1 == "failed" else "")
    out["addition"] = {"added": added, "keyPoints": o1.get("keyPoints") if isinstance(o1.get("keyPoints"), list) else [], "parse": st1,
                       "final": (initial + " " + added).strip(), "reply": rec(r1), "len": C.length_stats(added)}
    # (b) neutral rewrite: the complete updated recap
    r2, o2, _ = ask(be, tag, P.NEUTRAL_REWRITE, "Earlier recap:\n" + initial + "\n\nTranscript of what was said since:\n" + new)
    out["rewrite"] = {"final": o2["summary"], "reply": rec(r2), "len": C.length_stats(o2["summary"])}
    return out


def wait_quiet(max_wait=600):
    """Latency groups start when the machine is quiet (Window 8 builds / other model runs would distort them)."""
    start = time.time()
    while time.time() - start < max_wait:
        busy = sysmon.other_runs()
        ps = os.popen("ps -axo command=").read()
        builds = [l for l in ps.splitlines() if any(k in l for k in ("xcodebuild", "swift-build", "swift-test", "swift-frontend", "mlx_lm", "hs-semantic-eval")) and "summary_bench" not in l and "apple-bridge" not in l]
        if not busy and not builds and os.getloadavg()[0] < 3.5:
            return {"waited": round(time.time() - start), "quiet": True, "load": os.getloadavg()[0]}
        time.sleep(15)
    return {"waited": round(time.time() - start), "quiet": False, "load": os.getloadavg()[0]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["run"]); ap.add_argument("--model", required=True, choices=list(MODELS))
    ap.add_argument("--set", default="dev"); ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--tasks", default="neutral,prod"); ap.add_argument("--phase", default="pilot")
    ap.add_argument("--stride", type=int, default=1); ap.add_argument("--repeats", type=int, default=3); ap.add_argument("--latency-n", type=int, default=12)
    a = ap.parse_args()
    out_dir = ROOT / "results" / "summary_model_bench" / a.phase; out_dir.mkdir(parents=True, exist_ok=True)
    tag = a.model
    be = backend(tag)
    pre = {"sysmon": sysmon.snapshot(), "load": os.getloadavg()}
    info = be.load()
    if tag != "apple":
        info["revision"] = MODELS[tag]["rev"]
    meta = {"model": tag, "name": MODELS[tag]["name"], "info": info, "set": a.set, "pre": pre, "started": time.strftime("%F %T"), "groups": {}}
    # warm-up (not scored); the first request after loading is timed separately
    warm = C.load(DATA["dev"])[0]
    t = time.perf_counter(); task_neutral(be, tag, warm); meta["first_request_seconds"] = time.perf_counter() - t
    task_prod(be, tag, warm)
    items = C.load(DATA[a.set])[:: a.stride]; items = items[: a.limit] if a.limit else items
    tasks = a.tasks.split(",")

    def group(name, fn, data):
        path = out_dir / f"{tag}__{a.set}__{name}.jsonl"
        t0 = time.time(); n = 0
        with open(path, "w", encoding="utf-8") as f:
            for it in data:
                res = fn(be, tag, it); res["model"] = tag; res["mem"] = be.memory() if tag != "apple" else None
                f.write(json.dumps(res, ensure_ascii=False) + "\n"); f.flush(); n += 1
        meta["groups"][name] = {"n": n, "wall_seconds": time.time() - t0, "mem_after": be.memory(), "sysmon": sysmon.snapshot(), "load": os.getloadavg()}
        print(f"{tag} {a.set} {name}: n={n} wall={time.time()-t0:.0f}s", flush=True)

    for name in ("neutral", "prod"):
        if name in tasks: group(name, task_neutral if name == "neutral" else task_prod, items)
    if "continue" in tasks:
        cont = C.load(DATA["continue"] if a.set == "final" else DATA["continue_dev"])
        group("continue", task_continue, cont[: a.limit] if a.limit else cont)
    if "latency" in tasks:
        meta["latency_quiet"] = wait_quiet()
        sample = items[: a.latency_n]
        path = out_dir / f"{tag}__{a.set}__latency.jsonl"
        with open(path, "w", encoding="utf-8") as f:
            for rep in range(a.repeats):
                for it in sample:
                    res = task_neutral(be, tag, it); f.write(json.dumps({"id": it["id"], "language": it["language"], "rep": rep, "reply": res["reply"], "len": res["len"]}, ensure_ascii=False) + "\n"); f.flush()
        meta["groups"]["latency"] = {"n": len(sample) * a.repeats, "mem_after": be.memory(), "sysmon": sysmon.snapshot(), "load": os.getloadavg()}
    meta["finished"] = time.strftime("%F %T")
    (out_dir / f"{tag}__{a.set}.meta.json").write_text(json.dumps(meta, indent=1, default=str))
    be.close()


if __name__ == "__main__":
    main()
