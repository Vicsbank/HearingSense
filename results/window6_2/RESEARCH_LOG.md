# Window 6.2 research log (working notes; the report is docs/research/PRECISION_AND_BACKPRESSURE_REPORT.md)

Branch `feature/window6-2-precision-backpressure`, worktree `.claude/worktrees/window6-2`, base `a979cf9` (W6.1).
Mac only (M1 Max), Apple Foundation Models, synthetic text. No microphone, no iPhone, no training, no download.

## Data
- `semantic_dev3.txt` (214 items, 4 new profiles, categories interleaved): written by me, used for tuning.
- `semantic_sealed2.txt` (265 items, 5 profiles): written by a separate agent that read nothing of the repository.
  Not read by me. sha256 in `sealed2.sha256`. Committed in `54181f8` before any engine change.
- Probe harness: `hs-semantic-eval probe | probe-check | probe-cost` (raw model answers, one variable at a time).

## E1 — does a kept session change decisions? (dev3, first pass only, W6.1 `lean` prompt)
| run | TP | FP | FN | TN |
|---|---|---|---|---|
| fresh session per sentence, file order | 84 | 14 | 5 | 92 |
| fresh, shuffled (seed 1) | identical raw answers for all 214 items |
| kept 6, file order | 89 | 17 | 0 | 89 |
| kept 6, file order again | identical to the first |
| kept 6, seed 1 | 86 | 14 | 3 | 92 |
| kept 6, seed 2 | 88 | 20 | 1 | 86 |
- Fresh session: the answer is a function of the sentence alone (0/214 differ between orders).
- Kept session: 25/214 items alert or not depending on the order alone; 33/214 differ somewhere among the four runs.
- Not imitation: false-alert rate after "all earlier answers were alerts" 10 %, after "none" 23 %.
- What flips towards an alert in later turns: unrelated talk (9), sentences spoken to the listener (10, correct),
  negation (4). Later requests carry only the sentence (no goals, no answer form): looser criteria.
- Kept 6 with goals and form repeated in every request (seed 1): 87/9/2/97; differs from fresh on 14 items;
  1.46 s (turn 2) → 2.02 s (turn 6): the repeated text is read each time.

## E4 — where the time goes (`probe-cost`, lean, tenant goals, ~968 input tokens, 37 output tokens)
- New session, nothing prepared: 2.1 s (0 tokens held).
- New session prepared ≥1.5 s ahead (`prewarm(promptPrefix:)`): 1.35–1.49 s (783 held).
- New session prepared and asked at once: 2.83 s (0 held): worse than not preparing.
- Kept session: 1.16 s at request 2, 1.50 s at request 12 (+0.03 s per request).
- Kept session right after another session's request (the second look): 3.45 s (0 held, 1665 tokens read again).
  After `prewarm()` and 2 s: 1.64 s. After `prewarm()` and asked at once: 3.37 s.
- Two new sessions asked at the same moment: 3.38 s for both (no real parallelism).
- Reading ≈ 1 ms per token not held; writing ≈ 28–30 ms per output token.
- W6.1 backlog, 16 %-relevant benchmark mix: 1.2 s first answer (of which ≈1.1 s is writing 37 tokens)
  + second look 0.83 s and ≈2.2 s eviction penalty on relevant sentences + a new session every 6 sentences
  ≈ 1.85 s per sentence ≈ 32 per minute (measured in W6.1: 31–33).

## E2/E3/E5… — answer form and checks (dev3, fresh sessions)
| variant | TP | FP | FN | TN | tokens out | s (unprepared) |
|---|---|---|---|---|---|---|
| lean (kind, goal, verdict) | 84 | 14 | 5 | 92 | 33.6 | 2.06 |
| kg (kind, goal) | 86 | 18 | 3 | 88 | 16.0 | 1.69 |
| v3 (renamed kinds + "address", kind, goal) | 89 | 29 | 0 | 77 | 15.0 | 1.71 |
| v3 without the form in the request | 89 | 23 | 0 | 83 | 15.4 | 1.55 |
- Without a last field the model has no place to say no: it writes "change, goal 1" for unrelated news.
- Checks on the 98 positives of lean-fresh (84 TP, 14 FP):
  - `confirm` (W6.1, does not know the goals): FP 14 → 9, TP 84 → 84.
  - `role`, `role-topic` (goals given, told "a first reading says it matters"): FP 14 → 12. Anchored: agrees.

## Queue policy (simulation, `tools/semantic_queue_sim.py`)
- With a 0.6 s service time nothing waits at any tested pattern; the policy only matters when service ≥ arrival gap.
- Oldest-first decides the most sentences after a burst but seconds late (median 7–10 s under lasting overload).
- Newest-first-while-behind keeps the median near 2 s but lets old sentences expire.
- Chosen: newest first while behind and speech keeps arriving; oldest first in a pause; explicit expiry.

## Later experiments (dev3 extended to 223 items: 94 relevant, 106 irrelevant, 8 repeat, 15 ambiguous)
- W6.1 engine on dev3 (214), twice, same order: TP 89 FP 11 FN 0 TN 99 both times (P 89.0 %, R 100 %);
  repetitions caught 2/4; other-group sentences 14/20.
- lean, fresh session, no answer form in the request: TP 91 FP 11 FN 3 (223 items); 26.2 tokens out
  (33.6 with the form), 802 tokens in (964), 1.81 s unprepared (2.06).
- "lean-tell" (true/false instead of the verdict): FP 19; 28 tokens. Rejected.
- "v3-verdict" (renamed kinds, new wording, verdict): 85/18/4. Rejected: the rewording is worse.
- Streamed answers: all parts arrive in the last 0.1 s of a request; abandoning after the first field saves
  nothing. Rejected.
- Two-step answer (kind; then goal and verdict in the same session if the kind can alert): kind identical for
  223/223; same score (91/11/3). Kind-only request 1.50 s / 14.9 tokens, two requests 2.33 s / 30 tokens,
  one-step 1.78 s / 26.2 tokens (all unprepared). Gain only when most sentences stop at the kind.
- Second look that hears earlier accepted statements sharing words (`SemanticRepetition.candidates`):
  7 of 8 repetitions called saidBefore; 3 of 3 controls (same words, new fact) not; no other sentence called so.
  On the 102 positives of lean-no-schema: FP 11 → 8, TP 91 → 90.
- "who" checks: with goals, not told the first answer: removes 5 false alerts, takes back 4 correct ones;
  without goals: takes back 32 correct ones. Rejected.

## Prompt selection (fresh session, no answer form in the request; first answer only)
| instructions | dev3 (223) TP/FP/FN | dev2 (171) TP/FP/FN | lost answers |
|---|---|---|---|
| lean (W6.1 text) | 91/11/3 | 80/14/2 | 0 |
| lean-spoken (two lines changed) | 92/9/2 | 78/12/4 | 1 |
| lean-all-shots (order, wording, verdict text, 16 examples) | 86/5/8 | 72/5/10 | 2 |
| spoken-shots3 (18 examples, short answer form) | 93/7/1 | 76/11/6 | 9 |
Hard subsets of both sets (140 items): lean 52/25/5, lean-spoken 51/21/6, spoken-shots4 (examples with the
answer written as JSON) 44/9/13 with no lost answer, lean-shots4 47/12/10, lean-all-shots 39/10/18.
- Worked examples are a dial, not a gain: fewer false alerts, more misses, on both sets.
- Examples in the short form made 5 of 223 answers run to the token limit (lost); in JSON form none.
- With the production second look (warnings and repetitions included), first answer + second look:
  lean 90/7/4 and 80/6/2; lean-spoken 91/5/3 and 78/5/4 (both sets: P 94.4 %, R 96.0 %);
  lean-all-shots 86/2/8 and 72/3/10 (P 96.9 %, R 89.8 %).
- Chosen: lean-spoken. The strict variant is documented as the alternative operating point.

## Preparation lead time (lean, 783 tokens of instructions and goals)
not prepared 2.0 s; prepared 0.1 s ahead 1.8 s; 0.3 s 1.6 s; 0.5 s 1.4 s; ≥0.7 s 1.25 s.
Kind-only request: not prepared 1.5 s; prepared ≥0.7 s ahead 0.87 s.

## Engine level (first answer, second look, verifier, novelty), Window 6.2, a session per sentence
- dev3 (223): TP 91 FP 7 FN 3 TN 107 (P 92.9 %, R 96.8 %); implicit 42/43; important 11/11; urgent 6/6; repetitions 6/8.
- dev2 (171): TP 78 FP 5 FN 4 TN 72 (P 94.0 %, R 95.1 %); implicit 33/37; important 17/17; urgent 11/11; repetitions 4/4.
- A bug found on the way: the second look sent without its answer form answered "someone else" for nearly
  everything (TP 12 of 94). The first answer works without the form because its instructions name the
  fields; the second look's do not. The form is sent with the second look.
- "Which goal?" asked again on its own for every alert (not told the first answer): removes 1 false alert per
  set, takes back 2 correct ones per set. Rejected: the model repeats its own mistakes.
