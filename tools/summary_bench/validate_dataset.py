"""Validate a summary-benchmark dataset JSONL file against DATASET_SPEC.md."""
import json
import sys

KINDS = {"date_time", "number", "name", "place", "decision", "task", "change", "relation", "uncertainty", "other"}


def check(path: str) -> int:
    problems, ids = [], set()
    count = 0
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        if not raw.strip():
            continue
        count += 1
        try:
            d = json.loads(raw)
        except Exception as e:
            problems.append(f"line {n}: bad JSON {e}")
            continue
        p = lambda m: problems.append(f"line {n} ({d.get('id')}): {m}")
        if d.get("id") in ids:
            p("duplicate id")
        ids.add(d.get("id"))
        if d.get("language") not in ("en", "zh", "mixed"):
            p("language")
        if not d.get("scenarios") or not set(d["scenarios"]) <= set("ABCDEFG"):
            p("scenarios")
        lines = d.get("lines") or []
        ts = [l.get("t") for l in lines]
        if not lines or any(not isinstance(t, (int, float)) for t in ts) or ts != sorted(ts) or ts[0] < 0 or ts[-1] > 125:
            p("lines/t")
        if any(not str(l.get("text", "")).strip() for l in lines):
            p("empty text")
        text = " ".join(l["text"] for l in lines)
        size = len(text) if d.get("language") == "zh" else len(text.split())
        low, high = (200, 900) if d.get("language") == "zh" else (150, 450)
        if "G" not in d.get("scenarios", []) and not low <= size <= high:
            p(f"size {size}")
        facts = d.get("facts") or []
        if not 2 <= len(facts) <= 16:
            p(f"facts {len(facts)}")
        for f in facts:
            if f.get("kind") not in KINDS or not f.get("text") or not isinstance(f.get("critical"), bool):
                p(f"bad fact {f.get('id')}")
        for key in ("must_not", "uncertain"):
            if not isinstance(d.get(key), list):
                p(key)
        if not isinstance(d.get("missing", []), list):
            p("missing")
    print(f"{path}: {count} conversations, {len(problems)} problems")
    for q in problems[:40]:
        print("  ", q)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(max(check(a) for a in sys.argv[1:]))
