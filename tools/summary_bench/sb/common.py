"""Datasets, transcript construction, JSON answer parsing."""
from __future__ import annotations

import json
import re
from pathlib import Path

MARKER = "[some speech here could not be transcribed]"
MAX_WORDS = 900          # ConversationRecapEngine.Policy.maximumTranscriptWords


def load(path) -> list[dict]:
    return [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]


def transcript(item: dict, lines_key: str = "lines", missing: bool = True) -> tuple[str, list[str]]:
    """Transcript text as ConversationRecapEngine.transcript(of:) builds it, and the caveat notes."""
    rows = [(l["t"], l["text"].strip()) for l in item[lines_key]]
    gaps = [m for m in item.get("missing", []) if m[1] - m[0] >= 3] if missing else []
    rows += [(m[0], MARKER) for m in gaps]
    text = "\n".join(t for _, t in sorted(rows, key=lambda r: r[0]))
    words = text.split(" ")
    if len([w for w in words if w]) > MAX_WORDS:
        text = " ".join([w for w in words if w][-MAX_WORDS:])
    total = sum(m[1] - m[0] for m in item.get("missing", [])) if missing else 0
    notes = [f"About {round(total)} seconds of speech could not be transcribed."] if total >= 6 else []
    return text, notes


def parse_json(text: str) -> tuple[dict | None, str]:
    """Returns (object, status): ok | repaired | failed."""
    t = text.strip()
    try:
        return json.loads(t), "ok"
    except Exception:
        pass
    t2 = re.sub(r"^```(?:json)?\s*|\s*```$", "", t)
    for cand in (t2, t[t.find("{"): t.rfind("}") + 1] if "{" in t else ""):
        try:
            return json.loads(cand), "repaired"
        except Exception:
            continue
    return None, "failed"


def strip_think(text: str) -> str:
    """The answer is what follows the last </think> (LFM writes its reasoning-like text before it even
    when the block was closed in the prompt); a block that never closed is dropped."""
    if "</think>" in text:
        text = text.rsplit("</think>", 1)[1]
    elif "<think>" in text:
        text = text.split("<think>", 1)[0]
    return text.strip()


def length_stats(text: str) -> dict:
    cjk = len(re.findall(r"[一-鿿]", text))
    words = len(re.findall(r"[A-Za-z0-9']+", text))
    return {"chars": len(text), "cjk_chars": cjk, "latin_words": words, "sentences": len(re.findall(r"[.!?。！？]+(?:\s|$)|[。！？]", text)) or (1 if text.strip() else 0)}
