#!/usr/bin/env python3
"""Window 6.2: discrete-event simulation of the semantic engine's waiting line.

No model is used. Service times are parameters (measured separately on the Mac); the
simulation compares policies for the order in which waiting sentences are served and for what
happens to sentences that have waited too long, on the same arrival patterns as the real stream
benchmark (tools/run_window6_2_streams.sh).

    python3 tools/semantic_queue_sim.py --first 0.85 --check 0.60 [--relevant 0.3] [--json out.json]

Policies:
  fifo        oldest first; a sentence older than --max-wait when its turn comes is expired
  lifo        newest first; the same expiry
  fresh       oldest first while the oldest has waited less than --behind seconds, newest first
              while it has waited longer (the line is "behind"); the same expiry
"""
import argparse
import json
import random
import statistics


def patterns(seed=7):
    rng = random.Random(seed)
    out = {}
    for name, gap in (("every 3.0 s", 3.0), ("every 1.5 s", 1.5), ("every 1.0 s", 1.0)):
        out[name] = [i * gap for i in range(60)]
    # Bursty conversation: runs of 3-7 sentences 0.5-1.3 s apart, pauses of 2.5-8 s between runs.
    t, bursty = 0.0, []
    while len(bursty) < 60:
        for _ in range(rng.randint(3, 7)):
            bursty.append(t)
            t += rng.uniform(0.5, 1.3)
        t += rng.uniform(2.5, 8.0)
    out["bursty"] = bursty[:60]
    # Silence, then dense speech, twice.
    dense, t = [], 20.0
    for _ in range(25):
        dense.append(t)
        t += 0.8
    t += 15.0
    for _ in range(20):
        dense.append(t)
        t += 0.8
    out["silence then dense"] = dense
    # A recap takes the model for 7 s in the middle of sentences every 1.5 s.
    out["every 1.5 s with a recap"] = [i * 1.5 for i in range(40)]
    return out


def simulate(arrivals, relevant, first, check, policy, max_wait, behind, capacity, recap_at=None, recap=7.0, jitter=0.15,
             seed=11):
    rng = random.Random(seed)
    n = len(arrivals)
    waiting, done, expired = [], {}, []
    clock, i = 0.0, 0
    depth_area, last, max_depth = 0.0, 0.0, 0
    recap_pending = recap_at is not None
    recap_done = None

    def advance(to):
        nonlocal depth_area, last
        depth_area += len(waiting) * (to - last)
        last = to

    def admit(until):
        nonlocal i, max_depth
        while i < n and arrivals[i] <= until:
            advance(arrivals[i])
            waiting.append(i)
            if len(waiting) > capacity:
                expired.append((waiting.pop(0), arrivals[i]))
            max_depth = max(max_depth, len(waiting))
            i += 1

    while i < n or waiting or recap_pending:
        admit(clock)
        if recap_pending and clock >= recap_at:
            clock += recap
            recap_pending = False
            recap_done = clock - recap_at
            continue
        if not waiting:
            nxt = arrivals[i] if i < n else None
            if recap_pending and (nxt is None or recap_at <= nxt):
                clock = max(clock, recap_at)
            elif nxt is not None:
                clock = max(clock, nxt)
            continue
        # Expire what has waited too long.
        for k in [k for k in waiting if clock - arrivals[k] > max_wait]:
            waiting.remove(k)
            expired.append((k, clock))
        if not waiting:
            continue
        oldest_wait = clock - arrivals[waiting[0]]
        take_newest = policy == "lifo" or (policy == "fresh" and oldest_wait > behind)
        k = waiting.pop(-1 if take_newest else 0)
        advance(clock)
        service = first * rng.uniform(1 - jitter, 1 + jitter)
        if relevant[k]:
            service += check * rng.uniform(1 - jitter, 1 + jitter)
        start = clock
        clock += service
        done[k] = (start - arrivals[k], clock - arrivals[k])
    advance(clock)
    latencies = sorted(v[1] for v in done.values())
    waits = sorted(v[0] for v in done.values())

    def q(values, p):
        return values[min(len(values) - 1, int(len(values) * p))] if values else None

    return {
        "sentences": n, "evaluated": len(done), "expired": len(expired),
        "expired_relevant": sum(1 for k, _ in expired if relevant[k]),
        "p50": q(latencies, 0.5), "p95": q(latencies, 0.95), "p99": q(latencies, 0.99), "max": latencies[-1] if latencies else None,
        "wait_p50": q(waits, 0.5), "wait_p95": q(waits, 0.95),
        "relevant_p95": q(sorted(done[k][1] for k in done if relevant[k]), 0.95),
        "mean_depth": depth_area / clock if clock else 0, "max_depth": max_depth,
        "recovery": clock - arrivals[-1], "recap_seconds": recap_done,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--first", type=float, required=True, help="seconds for a first judgement")
    parser.add_argument("--check", type=float, required=True, help="extra seconds for a sentence judged relevant")
    parser.add_argument("--relevant", type=float, default=0.3, help="share of sentences judged relevant")
    parser.add_argument("--max-wait", type=float, default=12.0)
    parser.add_argument("--behind", type=float, default=4.0)
    parser.add_argument("--capacity", type=int, default=24)
    parser.add_argument("--json")
    args = parser.parse_args()
    results = {}
    print(f"first {args.first} s, check +{args.check} s on {args.relevant:.0%} of the sentences; "
          f"expiry after {args.max_wait} s; 'behind' from {args.behind} s")
    print(f"{'pattern':26} {'policy':6} eval  exp(rel)  p50   p95   p99   max   rel95  depth mean/max  recovery")
    for name, arrivals in patterns().items():
        rng = random.Random(3)
        relevant = [rng.random() < args.relevant for _ in arrivals]
        for policy in ("fifo", "lifo", "fresh"):
            r = simulate(arrivals, relevant, args.first, args.check, policy, args.max_wait, args.behind, args.capacity,
                         recap_at=arrivals[len(arrivals) // 3] + 0.2 if "recap" in name else None)
            results[f"{name}|{policy}"] = r

            def s(v):
                return "  –  " if v is None else f"{v:5.2f}"

            print(f"{name:26} {policy:6} {r['evaluated']:3}/{r['sentences']:<3} {r['expired']:2}({r['expired_relevant']})   "
                  f"{s(r['p50'])} {s(r['p95'])} {s(r['p99'])} {s(r['max'])} {s(r['relevant_p95'])}  "
                  f"{r['mean_depth']:4.1f}/{r['max_depth']:<3}     {s(r['recovery'])}")
    if args.json:
        with open(args.json, "w") as handle:
            json.dump({"parameters": vars(args), "results": results}, handle, indent=1)


if __name__ == "__main__":
    main()
