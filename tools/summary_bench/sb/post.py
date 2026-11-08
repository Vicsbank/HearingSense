"""Python port of the lexical production post-processing (Window 8 ConversationRecapEngine.swift:
RecapText.tidied, RecapValidator.validate / restatementProblem / verbatimShare, Policy thresholds).
NOT ported: the model-based grounding check (`evidence`), which the app runs after these checks.
Approximation: Swift's NLTokenizer sentence splitting is replaced by a regex splitter."""
from __future__ import annotations

import re

STOP = set("""a an the is are was were be been being am has have had will would do does did to of in on at for and or but
it its it's this that these those there here i you he she we they me him her us them my your our their his so as by with
from about if then than can could should may might what who when where why how which not no also because after before
into over up out one someone speaker speakers person people conversation said says say mentioned mentions discussed
discuss talked asked explained noted added another other they're there's that's group plan plans""".split())
NUMBER_WORDS = {"zero":0,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,"eight":8,"nine":9,"ten":10,"eleven":11,
 "twelve":12,"thirteen":13,"fourteen":14,"fifteen":15,"sixteen":16,"seventeen":17,"eighteen":18,"nineteen":19,"twenty":20,
 "thirty":30,"forty":40,"fifty":50,"sixty":60,"seventy":70,"eighty":80,"ninety":90,"hundred":100,"thousand":1000}
QUANT_WORDS = set("""monday tuesday wednesday thursday friday saturday sunday today tonight tomorrow yesterday noon midnight half
twice double january february march april june july august september october november december""".split())
NEG = {"not","no","never","cannot","nobody","nothing","none","neither","nor","without"}
TITLES = {"mr.","mrs.","ms.","dr.","prof.","st.","mt.","vs.","jr.","sr."}
OPENERS = {"somebody","everyone","everybody","anyone","nobody","apparently","reportedly"}
KEPT_DOUBLES = {"that","very","really","much","many","long","more","knock","bye"}
NARRATION = re.compile(r"^(someone|somebody|a person|one person|a speaker|one speaker|the speakers?|one of the speakers)\s+(also\s+)?"
                       r"(said|says|mentioned|mentions|stated|states|noted|added|explained)\s+(that\s+)?", re.I)

# policy
MIN_SUPPORT, COPIED_MIN_WORDS, VERBATIM_RUN, PROXIMITY = 0.5, 5, 6, 80
RESTATE_EXTRA, RESTATE_KEEPS, MAX_REMOVED_SHARE, MAX_VERBATIM, MAX_RESTATEMENTS = 10, 0.75, 0.5, 0.65, 3


def words(text: str) -> list[str]:
    t = text.lower().replace("’", "'")
    out = []
    for w in re.split(r"[^\w']|_", t):
        w = w.strip("'")
        if w:
            out.append(w)
    return out


def content_words(t): return [w for w in words(t) if w not in STOP]


def stem(w: str) -> str:
    s = w
    for suf in ("ing", "ed", "es", "s"):
        if len(s) > len(suf) + 2 and s.endswith(suf):
            s = s[: -len(suf)]
            break
    if len(s) > 3 and s.endswith("e"):
        s = s[:-1]
    return s


def sentences(text: str) -> list[str]:
    parts = re.split(r"(?<=[.!?。！？])\s+|(?<=[。！？])|\n+", text)
    out: list[str] = []
    for p in parts:
        p = p.strip()
        if not p:
            continue
        if out and out[-1].split() and out[-1].split()[-1].lower() in TITLES:
            out[-1] += " " + p
        else:
            out.append(p)
    return out


def tidied(statement: str) -> str:
    text = statement.strip()
    m = NARRATION.match(text)
    if m:
        rest = text[m.end():]
        if len(rest.split(" ")) >= 3 and rest:
            text = (rest[0].upper() + rest[1:]).replace(" and that ", " and ")
    for _ in range(4):
        changed = False
        for pattern, minimum, flags in ((r"\b([A-Za-z']+),\s+\1\b", 2, re.I), (r"\b([a-z']+)\s+\1\b", 4, 0)):
            for mt in reversed(list(re.finditer(pattern, text, flags))):
                w = mt.group(1)
                lw = w.lower()
                if len(w) < minimum or lw in NUMBER_WORDS or lw == "one" or lw in KEPT_DOUBLES:
                    continue
                text = text[: mt.start()] + w + text[mt.end():]
                changed = True
        if not changed:
            break
    return text


def quantities(text: str) -> set[str]:
    out = set()
    for w in words(text):
        if w in NUMBER_WORDS:
            out.add(str(NUMBER_WORDS[w]))
        elif any(c.isdigit() for c in w):
            out.add("".join(c for c in w if c.isdigit() or c == "."))
        elif w in QUANT_WORDS:
            out.add(w)
    return out


def names(text: str) -> set[str]:
    out = set()
    for s in sentences(text):
        toks = [t for t in re.split(r"[^A-Za-z']+", s) if t]
        for i, t in enumerate(toks):
            if i == 0 or not t[0].isupper() or len(t) < 2:
                continue
            lw = t.lower()
            if lw in STOP or lw in QUANT_WORDS or lw == "i" or lw.startswith("i'"):
                continue
            out.add(lw)
    return out


def negations(text: str) -> int:
    return sum(1 for w in words(text) if w in NEG or w.endswith("n't"))


def capitalized(text: str) -> list[str]:
    return [t.lower() for t in re.split(r"[^A-Za-z']+", text) if t and t[0].isupper() and len(t) > 1]


def verbatim_share(text: str, transcript: str) -> float:
    run = max(VERBATIM_RUN, 2)
    spoken = set()
    for line in transcript.splitlines():
        w = words(line)
        for i in range(0, len(w) - run + 1):
            spoken.add(tuple(w[i:i + run]))
    total = covered = 0
    for line in text.splitlines():
        for st in sentences(line):
            w = words(st)
            total += len(w)
            if len(w) < run:
                continue
            cov = [False] * len(w)
            for i in range(0, len(w) - run + 1):
                if tuple(w[i:i + run]) in spoken:
                    for j in range(i, i + run):
                        cov[j] = True
            covered += sum(cov)
    return covered / total if total else 0.0


def restatement_problem(restated: str, original: str) -> str | None:
    w, ow = words(restated), words(original)
    if not w or w == ow: return "restatement_unchanged"
    if len(sentences(restated)) > 1: return "restatement_not_one_sentence"
    if len(w) > len(ow) + RESTATE_EXTRA: return "restatement_too_long"
    if quantities(restated) != quantities(original): return "restatement_changed_number_or_time"
    if negations(restated) != negations(original): return "restatement_changed_negation"
    known = set(ow)
    for c in capitalized(restated):
        if c not in known and c not in STOP and c not in OPENERS: return "restatement_added_name"
    content = {stem(x) for x in content_words(original)}
    if content:
        kept = {stem(x) for x in words(restated)}
        if sum(1 for c in content if c in kept) / len(content) < RESTATE_KEEPS: return "restatement_lost_content"
    return None


class Validator:
    def __init__(self, transcript: str, earlier: str = ""):
        self.transcript = transcript
        src = transcript + " " + earlier
        self.src_stems = {stem(w) for w in words(src)}
        self.src_q = quantities(src)
        self.src_names = names(src)
        self.spoken = set()
        for line in transcript.splitlines():
            self.spoken.add(tuple(words(line)))
            for s in sentences(line):
                self.spoken.add(tuple(words(s)))
        st = [stem(w) for w in words(src)]
        self.stretches: list[set[str]] = []
        if PROXIMITY > 0 and len(st) > PROXIMITY:
            step, i = max(PROXIMITY // 4, 1), 0
            while i < len(st):
                self.stretches.append(set(st[i:i + PROXIMITY]))
                if i + PROXIMITY >= len(st): break
                i += step

    def is_copy(self, s: str) -> bool:
        w = words(s)
        return len(w) >= COPIED_MIN_WORDS and tuple(w) in self.spoken

    def problem(self, s: str) -> str | None:
        if self.is_copy(s): return "copied_from_transcript"
        if not quantities(s) <= self.src_q: return "unsupported_number_or_time"
        if not names(s) <= self.src_names: return "unsupported_name"
        c = [stem(w) for w in content_words(s)]
        if len(c) >= 3:
            if sum(1 for x in c if x in self.src_stems) / len(c) < MIN_SUPPORT: return "unsupported_statement"
            if self.stretches:
                best = max(sum(1 for x in c if x in r) for r in self.stretches)
                if best / len(c) < MIN_SUPPORT: return "unsupported_combination"
        return None

    def validate(self, summary: str, key_points: list[str], title: str, restatements: dict[str, str] | None = None) -> dict:
        restatements = restatements or {}
        corrections, statements, removed, copied, restated = [], 0, 0, [], 0
        items = []     # (kind, original, kept or None, reason)

        def resolve(st: str):
            nonlocal statements, removed, restated
            statements += 1
            if self.is_copy(st):
                if st not in copied: copied.append(st)
                cand = (restatements.get(st) or "").strip()
                if cand and restatement_problem(cand, st) is None and self.problem(cand) is None:
                    restated += 1; corrections.append("restated_copy")
                    return cand, "restated_copy"
            issue = self.problem(st)
            if issue:
                removed += 1; corrections.append(issue)
                return None, issue
            return st, None

        kept, points = [], []
        for s in sentences(summary):
            k, why = resolve(s); items.append(("summary", s, k, why))
            if k: kept.append(k)
        for p in [x.strip() for x in key_points if x.strip()]:
            k, why = resolve(p); items.append(("key", p, k, why))
            if k and k not in points: points.append(k)
        share = verbatim_share("\n".join(kept + points), self.transcript)
        return {"summary": " ".join(kept), "keyPoints": points, "statements": statements, "removed": removed,
                "copied": copied, "restated": restated, "verbatim_share": share, "corrections": corrections, "items": items}


def accept(result: dict) -> tuple[bool, str]:
    """ConversationRecapEngine.checked(...)"""
    if result["verbatim_share"] > MAX_VERBATIM: return False, "too_much_verbatim"
    if not result["summary"]: return False, "empty_summary"
    if result["statements"] and result["removed"] / result["statements"] > MAX_REMOVED_SHARE: return False, "too_many_removed"
    return True, "ok"
