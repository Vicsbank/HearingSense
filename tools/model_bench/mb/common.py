"""Datasets, request texts, answer parsing and scoring shared by every model."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data"

# ---------------------------------------------------------------------------------------------
# Hearing Sense semantic relevance
# ---------------------------------------------------------------------------------------------

HS_INSTRUCTIONS = """You help a person who wears earphones notice nearby speech that matters to them. \
You get facts about the listener, the listener's goals, sometimes a few earlier lines, and one new \
sentence that was just said nearby. Decide whether the listener should be told about the new sentence.

Answer relevant when the new sentence gives news, a request or a warning that matters for one of the \
goals of this listener. It does not have to use the words of the goal. It may be said to a group the \
listener belongs to, or be about another person, as long as it still matters for a goal.

Answer not relevant when the sentence is small talk or about something else; when it concerns only \
other people or a group the listener is not part of; when it says that nothing changes; when it is \
about the past, a wish, a joke, an exaggeration or something only imagined; or when it only repeats \
news that is already in the earlier lines.

A warning of immediate danger to the people nearby is always relevant: use the goal "safety" and \
urgent true. Otherwise urgent is false.

Reply with one JSON object on one line and nothing else:
{"relevant": true or false, "goal": "<key of the goal, or none>", "urgent": true or false}"""


@dataclass
class HSItem:
    id: str
    profile: str
    category: str
    expected: bool
    goals: list[str]
    flags: list[str]
    context: list[str]
    utterance: str
    why: str


@dataclass
class HSProfile:
    name: str
    about: str = ""
    goals: list[tuple[str, str]] = field(default_factory=list)


@dataclass
class HSDataset:
    name: str
    profiles: dict[str, HSProfile]
    items: list[HSItem]


def load_hs(name: str) -> HSDataset:
    profiles: dict[str, HSProfile] = {}
    items: list[HSItem] = []
    for number, raw in enumerate((DATA / f"{name}.txt").read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("@profile"):
            parts = [p.strip() for p in line.split("|")]
            profile = profiles.setdefault(parts[1], HSProfile(parts[1]))
            if parts[2] == "about":
                profile.about = parts[3]
            else:
                profile.goals.append((parts[3], parts[4]))
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 9:
            raise ValueError(f"{name}.txt line {number}: expected 9 fields, found {len(parts)}")
        if parts[3] not in ("relevant", "irrelevant"):
            raise ValueError(f"{name}.txt line {number}: bad label {parts[3]}")
        item = HSItem(parts[0], parts[1], parts[2], parts[3] == "relevant",
                      [g for g in parts[4].split(",") if g], [f for f in parts[5].split(",") if f],
                      [c.strip() for c in parts[6].split("//") if c.strip()], parts[7], parts[8])
        if item.profile not in profiles:
            raise ValueError(f"{name}.txt line {number}: unknown profile {item.profile}")
        keys = {k for k, _ in profiles[item.profile].goals} | {"safety"}
        if item.expected != bool(item.goals) or not set(item.goals) <= keys:
            raise ValueError(f"{name}.txt line {number}: goals do not fit the label")
        items.append(item)
    if len({i.id for i in items}) != len(items):
        raise ValueError(f"{name}.txt: duplicate ids")
    return HSDataset(name, profiles, items)


def quoted(text: str) -> str:
    return '"' + text.replace('"', "'") + '"'


def hs_prompt(profile: HSProfile, item: HSItem) -> str:
    lines = ["Listener: " + profile.about, "Goals:"]
    lines += [f"- {key}: {text}" for key, text in profile.goals]
    if item.context:
        lines.append("Earlier lines:")
        lines += ["- " + quoted(c) for c in item.context]
    lines.append("New sentence: " + quoted(item.utterance))
    return "\n".join(lines)


def hs_schema(profile: HSProfile) -> dict:
    """Fields of the answer, for runtimes that constrain the output to a schema."""
    return {"fields": [
        {"name": "relevant", "type": "bool"},
        {"name": "goal", "type": "enum", "values": [k for k, _ in profile.goals] + ["safety", "none"]},
        {"name": "urgent", "type": "bool"},
    ]}


_OBJECT = re.compile(r"\{[^{}]*\}", re.S)


def parse_hs(text: str) -> tuple[str, dict]:
    """Returns (status, answer). status: ok (one clean JSON object), repaired (the fields could be
    read, but the reply was not exactly one valid object), failed (no decision could be read)."""
    stripped = text.strip()
    try:
        value = json.loads(stripped)
        if isinstance(value, dict) and isinstance(value.get("relevant"), bool):
            return "ok", _normal(value)
    except json.JSONDecodeError:
        pass
    for match in _OBJECT.finditer(stripped):
        try:
            value = json.loads(match.group(0))
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and isinstance(value.get("relevant"), bool):
            return "repaired", _normal(value)
    found = re.search(r'"?relevant"?\s*[:=]\s*"?(true|false)', stripped, re.I)
    if found:
        goal = re.search(r'"?goal"?\s*[:=]\s*"?([A-Za-z_]+)', stripped)
        urgent = re.search(r'"?urgent"?\s*[:=]\s*"?(true|false)', stripped, re.I)
        return "repaired", {"relevant": found.group(1).lower() == "true",
                            "goal": goal.group(1).lower() if goal else "none",
                            "urgent": bool(urgent) and urgent.group(1).lower() == "true"}
    return "failed", {"relevant": False, "goal": "none", "urgent": False}


def _normal(value: dict) -> dict:
    goal = value.get("goal")
    return {"relevant": value["relevant"], "goal": str(goal).strip().lower() if goal else "none",
            "urgent": value.get("urgent") is True}


def score_hs(dataset: HSDataset, rows: list[dict]) -> dict:
    """rows: one per item, with id, status and answer. A failed parse counts as "not told"."""
    by_id = {r["id"]: r for r in rows}
    tp = fp = fn = tn = 0
    goal_right = urgent_tp = urgent_fp = urgent_total = important_missed = important_total = 0
    status = {"ok": 0, "repaired": 0, "failed": 0, "error": 0, "missing": 0}
    categories: dict[str, dict] = {}
    wrong: list[str] = []
    for item in dataset.items:
        row = by_id.get(item.id)
        state = "missing" if row is None else ("error" if row.get("error") else row["status"])
        status[state] += 1
        answer = row["answer"] if row and not row.get("error") else {"relevant": False, "goal": "none", "urgent": False}
        said = bool(answer["relevant"])
        cell = categories.setdefault(item.category, {"n": 0, "right": 0, "tp": 0, "fp": 0, "fn": 0, "tn": 0})
        cell["n"] += 1
        key = ("tp" if said else "fn") if item.expected else ("fp" if said else "tn")
        cell[key] += 1
        cell["right"] += said == item.expected
        if said != item.expected:
            wrong.append(item.id)
        tp += key == "tp"; fp += key == "fp"; fn += key == "fn"; tn += key == "tn"
        if key == "tp":
            goal_right += answer["goal"] in item.goals
        if "urgent" in item.flags:
            urgent_total += 1
            urgent_tp += said and answer["urgent"]
        elif answer["urgent"] and said:
            urgent_fp += 1
        if "important" in item.flags:
            important_total += 1
            important_missed += not said
    precision = tp / (tp + fp) if tp + fp else None
    recall = tp / (tp + fn) if tp + fn else None
    f1 = 2 * precision * recall / (precision + recall) if precision and recall else None
    implicit = categories.get("implicit")
    return {
        "n": len(dataset.items), "tp": tp, "fp": fp, "fn": fn, "tn": tn,
        "precision": precision, "recall": recall, "f1": f1,
        "accuracy": (tp + tn) / len(dataset.items) if dataset.items else None,
        "goal_accuracy_on_tp": goal_right / tp if tp else None,
        "implicit_recall": implicit["tp"] / (implicit["tp"] + implicit["fn"]) if implicit and implicit["tp"] + implicit["fn"] else None,
        "important_total": important_total, "important_missed": important_missed,
        "urgent_total": urgent_total, "urgent_flagged": urgent_tp, "urgent_false_flags": urgent_fp,
        "status": status,
        "structured_ok_rate": status["ok"] / len(dataset.items) if dataset.items else None,
        "categories": categories, "wrong_ids": wrong,
    }


# ---------------------------------------------------------------------------------------------
# General abilities
# ---------------------------------------------------------------------------------------------

GENERAL_INSTRUCTIONS = "You answer short test questions. Follow the answer format exactly. Do not explain."

GENERAL_FORMAT = {
    "mc": "Reply with only the letter of the correct option.",
    "yn": "Reply with only yes or no.",
    "exact": "Reply with only the answer, without a sentence around it.",
    "json": "Reply with only the JSON object on one line.",
    "sum": "",
}
GENERAL_LIMIT = {"mc": 8, "yn": 8, "exact": 16, "json": 80, "sum": 64}


@dataclass
class GeneralItem:
    id: str
    category: str
    kind: str
    answer: str
    prompt: str


def load_general(name: str) -> list[GeneralItem]:
    items = []
    for number, raw in enumerate((DATA / f"{name}.txt").read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|", 4)]
        if len(parts) != 5 or parts[2] not in GENERAL_FORMAT:
            raise ValueError(f"{name}.txt line {number}: bad item")
        items.append(GeneralItem(parts[0], parts[1], parts[2], parts[3], parts[4].replace("\\n", "\n")))
    if len({i.id for i in items}) != len(items):
        raise ValueError(f"{name}.txt: duplicate ids")
    return items


def general_prompt(item: GeneralItem) -> str:
    form = GENERAL_FORMAT[item.kind]
    return item.prompt + ("\n" + form if form else "")


def _plain(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", text.lower().replace("-", " ")).strip()


def grade_general(item: GeneralItem, text: str) -> tuple[bool, bool]:
    """Returns (correct, format followed). A right answer inside extra words is wrong on format, and
    is still counted as incorrect for mc / yn / exact: these items test following the format too."""
    reply = text.strip()
    if item.kind == "mc":
        clean = reply.strip("().*: \n").upper()
        return clean == item.answer.upper(), bool(re.fullmatch(r"[A-D]", clean))
    if item.kind == "yn":
        clean = _plain(reply)
        return clean == item.answer.lower(), clean in ("yes", "no")
    if item.kind == "exact":
        clean = _plain(reply)
        accepted = [_plain(a) for a in item.answer.split(";")]
        return clean in accepted, len(clean.split()) <= max(len(a.split()) for a in accepted) + 1
    if item.kind == "json":
        try:
            value = json.loads(reply)
        except json.JSONDecodeError:
            return False, False
        expected = json.loads(item.answer)
        if not isinstance(value, dict):
            return False, False
        same = set(value) == set(expected) and all(
            (_plain(str(value[k])) == _plain(str(v)) if isinstance(v, str) else value[k] == v) for k, v in expected.items())
        return same, True
    # sum: must=a;b / any=c;d / forbid=e / max=20   (parts separated by " / ")
    rules = dict(part.split("=", 1) for part in item.answer.split(" / "))
    words = reply.split()
    low = reply.lower()
    fits = len(words) <= int(rules.get("max", "40")) and len(words) >= 3
    good = all(m.lower() in low for m in rules.get("must", "").split(";") if m)
    if rules.get("any"):
        good = good and any(a.lower() in low for a in rules["any"].split(";"))
    good = good and not any(f.lower() in low for f in rules.get("forbid", "").split(";") if f)
    return good and fits, fits


def score_general(items: list[GeneralItem], rows: list[dict]) -> dict:
    by_id = {r["id"]: r for r in rows}
    categories: dict[str, dict] = {}
    right = formed = 0
    wrong = []
    for item in items:
        row = by_id.get(item.id)
        correct, form = grade_general(item, row["text"]) if row and not row.get("error") else (False, False)
        cell = categories.setdefault(item.category, {"n": 0, "right": 0, "format": 0})
        cell["n"] += 1; cell["right"] += correct; cell["format"] += form
        right += correct; formed += form
        if not correct:
            wrong.append(item.id)
    return {"n": len(items), "right": right, "accuracy": right / len(items) if items else None,
            "format_followed": formed / len(items) if items else None, "categories": categories, "wrong_ids": wrong}
