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
| `semantic_sealed2.txt` | 265, of which 264 used | 115 / 119 / 8 / 22 | sealed: run once after the freeze | a separate agent |
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

