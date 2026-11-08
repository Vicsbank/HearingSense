#!/usr/bin/env python3
"""Hearing Sense local model benchmark (Mac). One model per process, one request at a time.

  bench.py check                                  memory, swap, other benchmark runs
  bench.py show   --model M --task hs --set S     the exact text one request sends to the model
  bench.py run    --model M --task hs|general --set S [--limit N] [--phase pilot]
  bench.py stream --model M --set S --pattern 3s|1.5s|1s|burst [--queue 4] [--expire 10]
  bench.py score  --phase pilot                   tables from the stored raw answers

Raw answers and timings go to results/local_model_comparison/<phase>/. Nothing is downloaded:
the Hugging Face hub is used offline, so a checkpoint that is not on disk fails to load.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import statistics
import sys
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
RESULTS = ROOT / "results" / "local_model_comparison"
sys.path.insert(0, str(HERE))

from mb import common, sysmon  # noqa: E402
from mb.backends import AppleBackend, MLXBackend  # noqa: E402

MODELS = json.loads((HERE / "models.json").read_text())


def backend_for(tag: str):
    spec = MODELS[tag]
    if spec["kind"] == "apple":
        return AppleBackend(HERE / "apple_bridge" / ".build" / "release" / "apple-bridge", mode=spec["mode"],
                            prewarm=spec.get("prewarm", True))
    return MLXBackend(spec["repo"], prefix_cache=spec.get("prefix_cache", True), thinking=spec.get("thinking", False))


def guard(args) -> dict:
    """Refuses to run a model while another window's benchmark is running."""
    state = sysmon.snapshot()
    if state["other_runs"] and not args.allow_concurrent:
        print("Another benchmark is running; not starting:\n  " + "\n  ".join(state["other_runs"]))
        sys.exit(3)
    return state


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, round(q * (len(ordered) - 1))))]


def timing(rows: list[dict]) -> dict:
    good = [r for r in rows if not r.get("error")]
    seconds = [r["seconds"] for r in good]
    first = [r["first_seconds"] for r in good if r.get("first_seconds") is not None]
    out = [r["output_tokens"] for r in good if r.get("output_tokens") is not None]
    inp = [r["input_tokens"] for r in good if r.get("input_tokens") is not None]
    decode = [r["decode_tps"] for r in good if r.get("decode_tps")]
    prefill = [r["prefill_tps"] for r in good if r.get("prefill_tps")]
    return {
        "requests": len(rows), "errors": len(rows) - len(good),
        "seconds_p50": percentile(seconds, 0.5), "seconds_p95": percentile(seconds, 0.95),
        "seconds_p99": percentile(seconds, 0.99), "seconds_mean": statistics.fmean(seconds) if seconds else None,
        "first_seconds_p50": percentile(first, 0.5),
        "output_tokens_mean": statistics.fmean(out) if out else None,
        "input_tokens_mean": statistics.fmean(inp) if inp else None,
        "decode_tps_median": percentile(decode, 0.5), "prefill_tps_median": percentile(prefill, 0.5),
        "decisions_per_minute_back_to_back": 60 / statistics.fmean(seconds) if seconds else None,
    }


def requests_for(args):
    """Yields (id, instructions, prompt, limit, schema) and returns what is needed to score."""
    if args.task == "hs":
        dataset = common.load_hs(args.set)
        items = list(dataset.items)
        make = lambda i: (i.id, common.HS_INSTRUCTIONS, common.hs_prompt(dataset.profiles[i.profile], i), 40,
                          common.hs_schema(dataset.profiles[i.profile]))
        return dataset, items, make
    items = common.load_general(args.set)
    make = lambda i: (i.id, common.GENERAL_INSTRUCTIONS, common.general_prompt(i), common.GENERAL_LIMIT[i.kind], None)
    return items, list(items), make


def command_check(args) -> None:
    print(json.dumps(sysmon.snapshot(), indent=1))


def command_show(args) -> None:
    _, items, make = requests_for(args)
    backend = backend_for(args.model)
    if backend.kind == "mlx":
        backend.load()
    _, instructions, prompt, limit, schema = make(items[args.index])
    print(backend.rendered(instructions, prompt))
    print(f"\n[limit {limit} tokens] [schema {json.dumps(schema)}]")


def command_run(args) -> None:
    before = guard(args)
    data, items, make = requests_for(args)
    if args.limit:
        # A spread over the whole file, not its first lines.
        step = max(1, len(items) // args.limit)
        items = items[::step][: args.limit]
    random.Random(args.seed).shuffle(items)
    out = RESULTS / args.phase
    out.mkdir(parents=True, exist_ok=True)
    stem = f"{args.model}__{args.task}_{args.set}"
    backend = backend_for(args.model)
    info = backend.load()
    after_load = sysmon.snapshot()
    # Warm-up requests are not scored and not timed: the first request after a load is not typical.
    warm = []
    for item in items[: args.warmup]:
        _, instructions, prompt, limit, schema = make(item)
        warm.append(backend.generate(instructions, prompt, limit, schema).seconds)
    rows = []
    started = time.time()
    with open(out / f"{stem}.jsonl", "w") as handle:
        for item in items:
            ident, instructions, prompt, limit, schema = make(item)
            reply = backend.generate(instructions, prompt, limit, schema)
            row = {"id": ident, "at": time.time(), **reply.as_dict()}
            if args.task == "hs":
                row["status"], row["answer"] = common.parse_hs(reply.text)
            rows.append(row)
            handle.write(json.dumps(row) + "\n")
            handle.flush()
            if sysmon.other_runs() and not args.allow_concurrent and len(rows) % 5 == 0:
                print("Another benchmark started; stopping this run.")
                break
    wall = time.time() - started
    memory = backend.memory()
    backend.close()
    if args.task == "hs":
        subset = common.HSDataset(data.name, data.profiles, [i for i in data.items if i.id in {r["id"] for r in rows}])
        score = common.score_hs(subset, rows)
    else:
        score = common.score_general([i for i in data if i.id in {r["id"] for r in rows}], rows)
    meta = {"model": args.model, "spec": MODELS[args.model], "task": args.task, "set": args.set, "phase": args.phase,
            "seed": args.seed, "warmup_requests": args.warmup, "first_request_seconds_after_load": warm[:1],
            "info": info, "memory": memory, "timing": timing(rows), "score": score, "wall_seconds": wall,
            "system_before": before, "system_after_load": after_load, "system_after": sysmon.snapshot()}
    (out / f"{stem}.meta.json").write_text(json.dumps(meta, indent=1))
    print(summary_line(meta))


def summary_line(meta: dict) -> str:
    t, s = meta["timing"], meta["score"]
    f = lambda v, d=2: "-" if v is None else f"{v:.{d}f}"
    text = f"{meta['model']} {meta['task']}/{meta['set']} n={s['n']}"
    if meta["task"] == "hs":
        text += (f" P={f(s['precision'])} R={f(s['recall'])} F1={f(s['f1'])} fp={s['fp']} fn={s['fn']}"
                 f" json_ok={s['status']['ok']}/{s['n']} repaired={s['status']['repaired']} failed={s['status']['failed']}"
                 f" errors={s['status']['error']}")
    else:
        text += f" right={s['right']}/{s['n']} format={f(s['format_followed'])}"
    text += (f" | p50={f(t['seconds_p50'], 3)}s p95={f(t['seconds_p95'], 3)}s first={f(t['first_seconds_p50'], 3)}s"
             f" out_tok={f(t['output_tokens_mean'], 1)} decode={f(t['decode_tps_median'], 0)}tok/s")
    return text


PATTERNS = {"3s": 3.0, "1.5s": 1.5, "1s": 1.0}


def arrivals(pattern: str, count: int, seed: int) -> list[float]:
    if pattern in PATTERNS:
        return [i * PATTERNS[pattern] for i in range(count)]
    # burst: groups of 3-6 sentences 0.4-0.9 s apart, then 4-9 s of quiet
    rng, times, now = random.Random(seed), [], 0.0
    while len(times) < count:
        for _ in range(rng.randint(3, 6)):
            times.append(now)
            now += rng.uniform(0.4, 0.9)
        now += rng.uniform(4.0, 9.0)
    return times[:count]


def command_stream(args) -> None:
    """Sentences arrive on a clock; one request runs at a time; waiting sentences sit in a bounded
    queue (oldest dropped when full) and expire when they waited too long. Everything is recorded."""
    before = guard(args)
    dataset = common.load_hs(args.set)
    items = list(dataset.items)
    random.Random(args.seed).shuffle(items)
    items = items[: args.count]
    times = arrivals(args.pattern, len(items), args.seed)
    backend = backend_for(args.model)
    info = backend.load()
    profile0 = dataset.profiles[items[0].profile]
    backend.generate(common.HS_INSTRUCTIONS, common.hs_prompt(profile0, items[0]), 40, common.hs_schema(profile0))
    queue: list[int] = []
    rows: dict[int, dict] = {}
    nxt, zero = 0, time.perf_counter()
    while nxt < len(items) or queue:
        now = time.perf_counter() - zero
        while nxt < len(items) and times[nxt] <= now:
            queue.append(nxt)
            rows[nxt] = {"id": items[nxt].id, "arrival": times[nxt], "outcome": "waiting"}
            if len(queue) > args.queue:
                rows[queue.pop(0)]["outcome"] = "dropped_queue_full"
            nxt += 1
        if not queue:
            time.sleep(max(0.0, min(0.01, times[nxt] - now)) if nxt < len(items) else 0)
            continue
        index = queue.pop(0)
        waited = now - times[index]
        if waited > args.expire:
            rows[index]["outcome"] = "expired"
            continue
        item = items[index]
        profile = dataset.profiles[item.profile]
        reply = backend.generate(common.HS_INSTRUCTIONS, common.hs_prompt(profile, item), 40, common.hs_schema(profile))
        status, answer = common.parse_hs(reply.text)
        done = time.perf_counter() - zero
        rows[index].update({"outcome": "error" if reply.error else "answered", "waited": waited, "done": done,
                            "arrival_to_decision": done - times[index], "status": status, "answer": answer, **reply.as_dict()})
    end = time.perf_counter() - zero
    memory = backend.memory()
    backend.close()
    ordered = [rows[i] for i in sorted(rows)]
    answered = [r for r in ordered if r["outcome"] == "answered"]
    lost = [r for r in ordered if r["outcome"] in ("dropped_queue_full", "expired")]
    expected = {i.id: i for i in items}
    delays = [r["arrival_to_decision"] for r in answered]
    summary = {
        "model": args.model, "set": args.set, "pattern": args.pattern, "queue": args.queue, "expire_seconds": args.expire,
        "sentences": len(items), "answered": len(answered), "dropped_queue_full": sum(r["outcome"] == "dropped_queue_full" for r in ordered),
        "expired": sum(r["outcome"] == "expired" for r in ordered), "errors": sum(r["outcome"] == "error" for r in ordered),
        "relevant_lost": sum(expected[r["id"]].expected for r in lost),
        "important_lost": sum("important" in expected[r["id"]].flags for r in lost),
        "arrival_to_decision_p50": percentile(delays, 0.5), "arrival_to_decision_p95": percentile(delays, 0.95),
        "arrival_to_decision_max": max(delays) if delays else None,
        "wait_p95": percentile([r["waited"] for r in answered], 0.95),
        "input_span_seconds": times[-1], "all_done_seconds": end, "drain_after_last_arrival_seconds": end - times[-1],
        "answered_per_minute": 60 * len(answered) / end if end else None,
        "info": info, "memory": memory, "system_before": before, "system_after": sysmon.snapshot(),
    }
    out = RESULTS / args.phase
    out.mkdir(parents=True, exist_ok=True)
    stem = f"{args.model}__stream_{args.set}_{args.pattern}_q{args.queue}"
    (out / f"{stem}.jsonl").write_text("\n".join(json.dumps(r) for r in ordered) + "\n")
    (out / f"{stem}.meta.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps({k: v for k, v in summary.items() if k not in ("info", "memory", "system_before", "system_after")}))


def command_score(args) -> None:
    for path in sorted((RESULTS / args.phase).glob("*.meta.json")):
        meta = json.loads(path.read_text())
        if "timing" in meta:
            print(summary_line(meta))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("check", "show", "run", "stream", "score"):
        p = sub.add_parser(name)
        p.add_argument("--model", choices=sorted(MODELS))
        p.add_argument("--task", choices=["hs", "general"], default="hs")
        p.add_argument("--set", default="hs_dev")
        p.add_argument("--phase", default="pilot")
        p.add_argument("--limit", type=int, default=0)
        p.add_argument("--seed", type=int, default=7)
        p.add_argument("--warmup", type=int, default=2)
        p.add_argument("--index", type=int, default=0)
        p.add_argument("--pattern", choices=["3s", "1.5s", "1s", "burst"], default="3s")
        p.add_argument("--count", type=int, default=60)
        p.add_argument("--queue", type=int, default=4)
        p.add_argument("--expire", type=float, default=10.0)
        p.add_argument("--allow-concurrent", action="store_true")
    args = parser.parse_args()
    globals()["command_" + args.command](args)


if __name__ == "__main__":
    main()
