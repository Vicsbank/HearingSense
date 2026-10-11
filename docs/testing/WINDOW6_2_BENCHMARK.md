# Window 6.2 — Benchmark: precision, stability, backpressure

Date: 2026-10-11. Branch `feature/window6-2-precision-backpressure` (worktree
`.claude/worktrees/window6-2`), from Window 6.1 `a979cf9`. Not merged, not pushed.

**Where every number comes from.** Mac (M1 Max, 32 GB, macOS 27.2), Apple Foundation Models
(`SystemLanguageModel.default`), forward-only inference, greedy sampling. Other work was running
on the Mac (load average 3–8), so times vary by a few tenths of a second between runs. All text is
synthetic. **No microphone, no physical iPhone, no training, no download.** Nothing here measures
real conversation or an iPhone. The iOS Simulator was used for package tests, app builds and one
scripted conversation (§10); no timing was taken there.

Raw output: `results/window6_2/`. Explanation: `docs/research/PRECISION_AND_BACKPRESSURE_REPORT.md`.

## 1. Metric definitions

As in Window 6.1. Positive item: expected `relevant`. Negative: expected `irrelevant` or `repeat`
(a repetition must not alert again). `ambiguous` items are reported and not scored. Predicted
positive: the engine *accepted* the utterance (verified, novel, relevant). precision = TP/(TP+FP);
recall = TP/(TP+FN); F1 their harmonic mean; false-positive rate = FP/(FP+TN).

Probe runs (§4) ask the model directly and score the first answer only: an alert is a goal in
range, verdict `relevant` or `urgent`, and a kind that can alert. Repetitions are left out of probe
scores (recognising them is the engine's work).

## 2. Data

| Set | Items | Relevant / irrelevant / repeat / ambiguous | Role | Author |
|---|---|---|---|---|
| `semantic_dev2.txt` | 171 | 82 / 73 / 4 / 12 | development (tuned on in Window 6.1 too) | this project |
| `semantic_dev3.txt` | 223 | 94 / 106 / 8 / 15 | development, new in this window; categories interleaved | this project |
| `semantic_sealed2.txt` | 265, of which 264 used | 115 / 120 / 8 / 21 (the excluded item was ambiguous) | sealed: run once after the freeze | a separate agent |
| `semantic_sealed.txt` | 220 | | Window 6.1's sealed set: read since, regression only | this project |
| `semantic_heldout.txt` | 119 | | Window 6's held-out set: read since, regression only | this project |

**Independence of the second sealed set.** It was written by a separate agent that was given the
task description, the label definitions, the category names and the list of settings already
used, and was told to open no file of the repository. It chose five settings and nineteen goals of
its own and defines them in the file (`@profile` lines), so no code had to name them. It was
committed (`54181f8`, with its SHA-256 in `results/window6_2/sealed2.sha256`) before any change to
the engine, the reasoner or a prompt. Until the frozen run only its format was checked, by
script, with counts as the only output. Limits: the author is a language model of the same family
as the one that wrote this project's other sets and prompts; all text is synthetic; one author per
set; English only.

**One item excluded, by rule, before the run.** A unit test compares every sealed sentence with
every sentence of the sets used for tuning. One everyday sentence (`wd034`) also occurs, word for
word, in the first development set of Window 6 (`d077`). `SemanticDataset.independent()` leaves
such items out and the tool prints them; 264 items remain. No sealed item shares a sentence, a
profile or a goal with a tuning set (`SemanticPromptTests`), and no quoted example of five words
or more in the instructions occurs in any evaluation set.

Development set 3 was extended once (ids 053 and up): four repetitions in other words and five
statements that share words with an earlier one but say something new, to test the repetition
check. Results quoted for 214 items predate that; for 223 items they follow it.

## 3. Commands

```sh
cd packages/HearingSenseKit
swift build -c release --product hs-semantic-eval
BIN=.build/out/Products/Release/hs-semantic-eval

# Raw model answers, one variable at a time (research harness; development sets only)
$BIN probe --set dev3 --variant lean --turns 6 --seed 1            # kept session, shuffled order
$BIN probe --set dev3 --variant lean-spoken --turns 1 --no-schema  # the selected first answer
$BIN probe-check --from <probe json> --check second-look           # a check on its positives
$BIN probe-cost --variant lean          # where the time of a request goes
$BIN probe-lead --variant lean          # how long ahead a session must be prepared
$BIN probe-stream                       # when the parts of a streamed answer arrive
$BIN probe-text                         # which measured variant the production instructions equal

# The engine (gate, first answer, second look, verifier, novelty)
$BIN run --set dev3 --methods model --config window6_2 --reuse 1 --no-steps --errors   # a session per sentence
$BIN run --set dev3 --methods model --config window6_2 --reuse 4 --steps --seed 1      # as while sentences wait
$BIN run --set dev3 --methods model --config window6_1 --errors                        # Window 6.1

# Streams: sentences arriving over time, Window 6.1 against Window 6.2 (one run at a time)
../../tools/run_window6_2_streams.sh
python3 ../../tools/semantic_queue_sim.py --first 1.2 --check 0.9      # no model: serving orders compared

# The sealed set: once, after the freeze (the script refuses a second run)
../../tools/run_window6_2_sealed.sh
```

`--config window6 | window6_1 | window6_2` selects reasoner and engine together
(`EngineSetups.swift`). Full output of every run is kept on disk; the build and test logs are in
`results/window6_2/logs/` (not committed).

## 4. Probe experiments (raw first answers; development data)

Files: `results/window6_2/probe/`. TP/FP/FN/TN over relevant and irrelevant items.

**4.1 Does a kept session change decisions?** Window 6.1 instructions, 214 items.

| Session | Order | TP | FP | FN | TN | Raw answers that differ |
|---|---|---|---|---|---|---|
| New for every sentence | as written | 84 | 14 | 5 | 92 | |
| New for every sentence | shuffled (seed 1) | 84 | 14 | 5 | 92 | 0 of 214 |
| Kept for six | as written | 89 | 17 | 0 | 89 | |
| Kept for six | as written, again | 89 | 17 | 0 | 89 | 0 of 214 |
| Kept for six | shuffled (seed 1) | 86 | 14 | 3 | 92 | |
| Kept for six | shuffled (seed 2) | 88 | 20 | 1 | 86 | 25 items alert in some of the three orders and not in others |
| Kept for six, goals and answer form repeated | shuffled (seed 1) | 87 | 9 | 2 | 97 | 14 items differ from a new session |

False alerts on items that should stay silent, by what the session had answered before (three
kept-session runs): all earlier answers were alerts 7/69 (10 %); some 34/184 (18 %); none 4/17
(24 %). After an alert 31/185; after a silent answer 14/85.

**4.2 Where the time goes** (`e4_cost_lean.txt`, `e10_lead_*.txt`): tables in the report §2.
Streamed answers (`probe-stream`, run while another batch used the model, so only the order of
events is meaningful): of 5 parts per answer the first arrived 0.1 s before the last (kind at
3.47 s of 3.56 s).

**4.3 The form of the answer and the instructions** (new session per sentence; set 3 with 214
items unless marked, set 2 with 171):

| Variant | Set 3 TP/FP/FN | Set 2 TP/FP/FN | Tokens written | Lost answers |
|---|---|---|---|---|
| lean: kind, goal, verdict; answer form sent | 84/14/5 | | 33.6 | 0 |
| kg: kind, goal | 86/18/3 | | 16.0 | 0 |
| lean-tell: kind, goal, true/false | 85/19/4 | | 28.2 | 0 |
| v3: reworded, renamed kinds; kind, goal | 89/29/0 | | 15.0 | 0 |
| v3 without the answer form | 89/23/0 | | 15.4 | 0 |
| v3-verdict | 85/18/4 | | 30.4 | 0 |
| **lean, answer form not sent** (223 items) | 91/11/3 | 80/14/2 | 26.2 | 0 |
| lean in two steps (kind; goal and verdict if needed) (223) | 91/11/3 | | 23.4 | 0 |
| **lean-spoken** (two lines reworded; 223) — selected | 92/9/2 | 78/12/4 | 26.1 | 1 |
| lean-all-shots (order, wording, verdict text, 16 examples; 223) | 86/5/8 | 72/5/10 | 25.5 | 2 |
| spoken-shots3 (18 examples, short answer form; 223) | 93/7/1 | 76/11/6 | 26.7 | 9 |
| spoken-shots3b (17 examples; 223) | 92/10/2 | | 27.2 | 5 |

Hard subsets (the items any variant got wrong plus a random sample; set 3 87 items, set 2 53):
lean 52/25/5; lean-spoken 51/21/6; spoken-shots4 (examples with the answer as JSON) 44/9/13;
lean-shots4 47/12/10; lean-all-shots 39/10/18. Earlier subset of set 3 (101 items):
lean 34/11/3; kinds that can alert first 32/3/5; verdict text 34/11/3; lean-spoken 36/9/1.

`probe-text` confirms that the production instructions equal `lean-spoken`.

**4.4 Checks on the positives of a first answer:**

| Check | On | False alerts before → after | Correct alerts before → after |
|---|---|---|---|
| Window 6.1 second look (goals unknown to it) | lean, set 3 (214) | 14 → 9 | 84 → 84 |
| "role": goals given, told a first reading found it relevant | same | 14 → 12 | 84 → 84 |
| "role" with an off-topic answer | same | 14 → 12 | 84 → 84 |
| "who": goals given, first answer not told | same | 14 → 9 | 84 → 80 |
| "who" without goals | same | 14 → 4 | 84 → 55 |
| Second look with figures of speech named | same | 14 → 9 | 84 → 83 |
| **Second look as shipped** (warnings too; hears earlier alerts) | lean-spoken, set 3 (223) | 9 → 5 | 92 → 91 |
| | lean-spoken, set 2 | 12 → 5 | 78 → 78 |
| | lean, set 3 / set 2 | 11 → 7 / 14 → 6 | 91 → 90 / 80 → 80 |
| | lean-all-shots, set 3 / set 2 | 5 → 2 / 5 → 3 | 86 → 86 / 72 → 72 |
| "Which goal?" asked again | lean-spoken, set 3 / set 2 | 9 → 8 / 12 → 11 | 92 → 90 / 78 → 76 |

Repetition (set 3, 223): of 8 repetitions 7 were called "said before"; of 3 statements that
share words with an earlier alert but say something new, 0; of 6 other sentences that were given
earlier statements, 0. Warnings (set 3): the second look kept 17 of 17 real ones and took back 1
of 2 idioms.

## 5. Engine-level results on the development sets

Files: `results/window6_2/engine/`.

| Run | Set | TP | FP | FN | TN | Precision | Recall | Implicit | Important | Urgent | Repetitions |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Window 6.1 | 3 (223) | 93 | 17 | 1 | 97 | 84.5 % | 98.9 % | 43/43 | 11/11 | 6/6 | 1/8 |
| Window 6.1 | 2 (171) | 80 | 8 | 2 | 69 | 90.9 % | 97.6 % | 36/37 | 16/17 | 11/11 | 4/4 |
| Window 6.2 | 3 | 91 | 7 | 3 | 107 | 92.9 % | 96.8 % | 42/43 | 11/11 | 6/6 | 6/8 |
| Window 6.2 | 3, shuffled | 90 | 7 | 4 | 107 | 92.8 % | 95.7 % | | 11/11 | | |
| Window 6.2 | 2 | 78 | 5 | 4 | 72 | 94.0 % | 95.1 % | 33/37 | 17/17 | 11/11 | 4/4 |
| Window 6.2 while sentences wait | 3 | 92 | 9 | 2 | 105 | 91.1 % | 97.9 % | 43/43 | 11/11 | 6/6 | 6/8 |
| Window 6.2 while sentences wait | 3, shuffled | 91 | 8 | 3 | 106 | 91.9 % | 96.8 % | 43/43 | 11/11 | 6/6 | 6/8 |
| Window 6.2 while sentences wait | 2 | 78 | 5 | 4 | 72 | 94.0 % | 95.1 % | 33/37 | 17/17 | 11/11 | 4/4 |

Earlier in the window, on set 3 with 214 items, Window 6.1 gave TP 89 FP 11 FN 0 TN 99 twice
(`baseline/w61_dev3_run*.txt`); the row above is the extended set, where its false alerts
include 7 of the 8 repetitions.

Decisions that differ: a session per sentence in two orders 1 of 223; a session per sentence
against "while sentences wait" 3 (as written) and 4 (shuffled) of 223, 3 of 171 on set 2; the
two orders of "while sentences wait" 3 of 223.

## 6. Sealed set 2 (run once, after the freeze `80f80b6`)

Files: `results/window6_2/sealed/` (`commit.txt` holds the commit and the file's hash).
265 items in the file, 1 excluded by rule (§2), 264 evaluated by every method; 21 ambiguous items
reported and not scored; 243 scored (115 relevant, 120 irrelevant, 8 repetitions). No item was
skipped, timed out or failed in any model run.

| Method | TP | FP | FN | TN | Precision (95 % CI) | Recall (95 % CI) | F1 | Ambiguous alerted |
|---|---|---|---|---|---|---|---|---|
| Keyword baseline | 81 | 58 | 34 | 70 | 58.3 % (50.0–66.1) | 70.4 % (61.5–78.0) | 0.638 | 7 |
| Sentence embedding (threshold chosen on development data) | 105 | 102 | 10 | 26 | 50.7 % (44.0–57.5) | 91.3 % (84.7–95.2) | 0.652 | 21 |
| Window 6 | 71 | 17 | 44 | 111 | 80.7 % | 61.7 % | 0.699 | 7 |
| Window 6.1 | 114 | 35 | 1 | 93 | 76.5 % | 99.1 % | 0.864 | 17 |
| **Window 6.2** | 114 | 22 | 1 | 106 | **83.8 % (76.7–89.1)** | **99.1 % (95.2–99.8)** | 0.908 | 16 |
| Window 6.2 while sentences wait | 113 | 22 | 2 | 106 | 83.7 % | 98.3 % | 0.904 | 17 |

| Window 6.2, groups | Result |
|---|---|
| Implicit relevance (implicit, causal) | 49/50 (98.0 %; 89.5–99.6) |
| Explicit relevance (obvious, attention) | 28/28 |
| Important events | 19/19 |
| Short urgent instructions | 12/12 |
| Unrelated talk | 35/35 |
| Another person or group | 9/21 (42.9 %) |
| Negation (both directions) | 19/21 |
| Wishes and guesses | 10/10 |
| Past and quotation | 19/20 |
| Figures of speech | 9/10 |
| Recognition errors | 12/12 |
| Needs the sentence before | 10/16 |
| Repetitions | 8/8 |
| Goal named correctly for a correct alert | 92/114 (80.7 %) |
| Verifier corrections | nothing changes 16, said before 9, urgency not confirmed 8, second look 5, no goal 3, hypothetical marker 2 |
| Seconds per item (a new session each, nothing prepared, second look included) | p50 2.64, p95 3.16, p99 3.56 |

Per setting, the 23 errors of Window 6.2 and the comparison by kind of sentence: report §5 and
§7; every wrong item is listed in `sealed/sealed2_window6_2.txt`.

Decisions that differ between normal operation and "while sentences wait": 4 of 264.

## 7. Streams

`tools/run_window6_2_streams.sh`; files `results/window6_2/stream/`. Sentences of one setting of
development set 3 are submitted at the given times; every decision is collected. "Isolated" is
Window 6.2 forced to use a new session for every sentence also under load.

35 sentences (29 everyday or ambiguous, 6 relevant). Seconds.

| Arrival | Engine | Decided | Relevant not evaluated | End to end p50 / p95 / p99 | Relevant p50 / max | Waiting p50 / p95 | Line mean / longest | Empty after | TP/FP/FN | Continued / judged again / alerts found |
|---|---|---|---|---|---|---|---|---|---|---|
| every 3 s | 6.1 | 35/35 | 0 | 1.43 / 2.53 / 3.00 | 2.08 / 2.21 | 0.00 / 0.00 | 0.00 / 1 | 2.6 | 6/4/0 | |
| | 6.2 isolated | 35/35 | 0 | 1.34 / 2.21 / 2.82 | 2.03 / 2.82 | 0.00 / 0.00 | 0.01 / 1 | 1.7 | 6/1/0 | |
| | 6.2 | 35/35 | 0 | 1.31 / 2.11 / 3.47 | 2.05 / 3.47 | 0.00 / 0.01 | 0.01 / 1 | 2.1 | 6/1/0 | 0/0/0 |
| every 1.5 s | 6.1 | 35/35 | 0 | 8.03 / 11.86 / 12.00 | 9.16 / 11.36 | 5.64 / 9.94 | 2.66 / 7 | 11.1 | 6/4/0 | |
| | 6.2 isolated (20 s limit) | 28/35 | 0 | 3.26 / 15.75 / 18.25 | 3.38 / 5.74 | 0.72 / 13.74 | 3.38 / 7 | 10.2 | 6/1/0 | |
| | 6.2 | 34/35 | 0 | 3.00 / 6.77 / 19.17 | 3.44 / 6.66 | 0.41 / 5.18 | 1.04 / 4 | 6.8 | 6/1/0 | 20/14/0 |
| every 1 s | 6.1 | 31/35 | 1 | 11.99 / 21.16 / 21.40 | 13.00 / 21.40 | 9.77 / 18.55 | 5.92 / 12 | 20.4 | 5/3/1 | |
| | 6.2 isolated | 30/35 | 1 | 6.53 / 31.70 / 31.75 | 30.46 / 31.75 | 2.09 / 29.55 | 8.33 / 18 | 31.4 | 5/1/1 | |
| | 6.2 | 33/35 | 0 | 5.31 / 31.25 / 58.83 | 5.31 / 58.83 | 1.76 / 29.73 | 5.19 / 15 | 21.3 | 6/1/0 | 21/14/1 |
| bursty | 6.1 | 35/35 | 0 | 6.91 / 12.26 / 13.27 | 8.62 / 13.27 | 4.57 / 10.36 | 2.46 / 7 | 9.6 | 6/4/0 | |
| | 6.2 isolated | 35/35 | 0 | 3.82 / 24.95 / 26.16 | 5.99 / 23.26 | 1.41 / 23.02 | 3.02 / 8 | 18.1 | 6/1/0 | |
| | 6.2 | 35/35 | 0 | 3.47 / 16.56 / 32.45 | 4.59 / 16.56 | 1.22 / 15.34 | 1.52 / 5 | 5.2 | 6/1/0 | 23/16/2 |
| silence, then every 0.8 s | 6.1 | 32/35 | 0 | 11.34 / 21.04 / 21.11 | 14.06 / 20.67 | 8.90 / 19.53 | 4.64 / 12 | 15.2 | 6/1/0 | |
| | 6.2 isolated | 28/35 | 2 | 5.52 / 26.65 / 30.95 | 19.08 / 23.95 | 2.18 / 24.66 | 6.21 / 16 | 18.3 | 4/1/2 | |
| | 6.2 | 33/35 | 1 | 5.26 / 24.64 / 33.19 | 14.67 / 33.19 | 1.19 / 23.10 | 3.65 / 12 | 15.5 | 5/1/1 | 20/11/0 |

31 sentences, 2 relevant ("sparse"):

| Arrival | Engine | Decided | End to end p50 / p95 / p99 | Line mean / longest | TP/FP/FN | Continued / judged again / alerts found |
|---|---|---|---|---|---|---|
| every 1 s | 6.1 | 31/31 | 12.14 / 20.90 / 21.90 | 4.97 / 11 | 2/3/0 | |
| | 6.2 | 30/31 | 3.49 / 32.47 / 51.46 | 3.70 / 10 | 2/2/0 | 19/12/1 |
| bursty | 6.1 | 31/31 | 4.09 / 8.65 / 10.05 | 1.40 / 4 | 2/3/0 | |
| | 6.2 | 31/31 | 2.66 / 13.53 / 16.29 | 0.78 / 3 | 2/1/0 | 21/16/1 |

Notes. One run each, on a Mac doing other work. The Window 6.2 rows are the frozen
configuration (30 s limit, second judgement, 24 places for it) except "isolated every 1.5 s",
which was run with the earlier 20 s limit. Sentences without any decision: 0 in every run.
Model failures: 0 in every run. In the sparse runs the relevant sentence that a continued
session called silent alerted on its second judgement, 16.3 s and 51.5 s after it was said, which
is the whole of the p99 there. "Bursty": runs of 3–7 sentences 0.5–1.3 s apart, pauses of
2.5–8 s. Model time per decided sentence at a sentence a second: Window 6.1 54.4 s for 31,
Window 6.2 (before the second judgement was added) 46.8 s for 27: 1.75 s and 1.73 s.

## 8. Recap while sentences arrive

`contention_window6_*.txt`. 18 sentences every 1.5 s (setting "cook", as written, about half
relevant, with warning-like sentences mixed in); recap of a synthetic two-minute conversation
asked after the fourth.

| | Recap alone | Recap, request to text | Waited for its turn | Goal matching p50 / p95 | Sentences submitted during the recap, p50 | Warning-like among them | Not evaluated |
|---|---|---|---|---|---|---|---|
| Window 6.1 | 6.01 s | 10.25 s | 4.48 s | 9.81 / 15.60 s | 14.96 s (6) | 5.02 s (2) | 0 |
| Window 6.2 | 5.97 s | 5.85 s | 0.04 s | 13.97 / 26.49 s | 25.33 s (3) | 7.59 s (1) | 0 |

## 9. Model process

`tools/semantic_model_process_summary.py results/window6_2/stream`. `top` every 2 s on the
system process that runs the model, during each stream run.

| Run | Samples | CPU % of a core, mean / max | Memory (top's MEM), largest | Energy impact, mean |
|---|---|---|---|---|
| 6.1, every 3 s | 49 | 4.4 / 7.5 | 474 MB | 4.4 |
| 6.2, every 3 s | 49 | 4.9 / 10.7 | 467 MB | 4.9 |
| 6.1, every 1 s | 26 | 6.8 / 10.3 | 473 MB | 6.8 |
| 6.2, every 1 s | 38 | 4.9 / 10.6 | 465 MB | 4.9 |
| 6.1, sparse, every 1 s | 25 | 7.2 / 10.0 | 473 MB | 7.2 |
| 6.2, sparse, every 1 s | 34 | 4.8 / 6.9 | 467 MB | 4.8 |
| 6.1, recap | 22 | 6.5 / 10.1 | 479 MB | 6.5 |
| 6.2, recap | 28 | 5.5 / 9.8 | 467 MB | 5.5 |

Smaller values at the start of some runs (12–22 MB) are the process before the model is loaded.
The evaluation tool itself: 15 → 25 MB resident. Not measurable without privileges: the model's
mapped weights, the GPU.

## 10. Regression

| Check | Environment | Result |
|---|---|---|
| `swift test` | Mac | **439 passed** |
| `xcodebuild test -scheme HearingSenseKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max'` | iOS 27 Simulator | **TEST SUCCEEDED** (444 tests) |
| `xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense` Debug, Simulator | iPhone 18 Pro Max | **BUILD SUCCEEDED** |
| The same, Release, `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO` | — | **BUILD SUCCEEDED** |
| Scripted conversation in the app, `--hs-conversation-demo --hs-screen goals` | iOS 27 Simulator, microphone off | Matches listed; screenshot `docs/device-tests/window6-2-simulator/goals.png` |
| Window 6.1's sealed set (220), Window 6.2 engine | Mac | TP 100 FP 8 FN 5 TN 88: precision 92.6 %, recall 95.2 % (`regression/sealed_window6_2.txt`). Not independent: the set has been read |
| Window 6's held-out set (119), Window 6.2 engine | Mac | TP 52 FP 8 FN 6 TN 39: precision 86.7 %, recall 89.7 % (`regression/heldout_window6_2.txt`). Not independent |

New tests (17): `SemanticBackpressureTests` (7: newest first while behind, oldest first in a
pause, the Window 6.1 order, expiry reported as such, a full line reported as dropped, the
second judgement of a sentence silenced by a continued session, no second judgement otherwise);
`SemanticPromptTests` (4: no example of the instructions in an evaluation set, independence of
the sealed set, the answer's fields described in the instructions, repeatable arrival patterns);
in `SemanticOptimizationTests`: urgent only with the second look's agreement, not urgent when the
second look fails, the Window 6.1 configuration unchanged, repetition in other words needs both
keys, no question about statements with other numbers or other words, repetition candidates.
Removed: the 3 tests of the group request and the one that asserted that a warning skips the
second look.

Not run: anything on a physical iPhone; the microphone; real speech; real partial transcripts;
background or locked-screen behaviour of the reworked engine.
