# Window 6.1 — Semantic Optimization Benchmark

Date: 2026-10-10/11. Branch `feature/window6-semantic-optimization` (worktree
`.claude/worktrees/window6-opt`), from Window 6 `ead23f3`. Not merged, not pushed.

**Where every number comes from.** Mac (M1 Max, 32 GB, macOS 27.2), Apple Foundation Models
(`SystemLanguageModel.default`), forward-only inference. The Mac was in use by other work during
the runs (load average 4–8), so times vary by a few tenths of a second between runs. All text is
synthetic and was written for this project. **No microphone, no physical iPhone, no training, no
download.** Nothing here measures real conversations or an iPhone. The iOS Simulator was used for
the package tests and the app build only (§9); no timing was taken there.

Raw output: `results/semantic_optimization/` (`baseline/`, `ablation/`, `latency/`, `stream/`,
`sealed/`). Explanation and recommendations: `docs/research/SEMANTIC_OPTIMIZATION_REPORT.md`.

## 1. Metric definitions (audit of the Window 6 numbers)

- Positive item: expected `relevant`. Negative item: expected `irrelevant` or `repeat` (a
  repetition must not alert again). `ambiguous` items are reported, not scored.
- Predicted positive: the engine *accepted* the utterance (verified, novel, relevant — what is
  handed to the attention engine). An `uncertain` verdict (kept in the app's list, no alert) is a
  negative prediction.
- precision = TP/(TP+FP); recall = TP/(TP+FN); false-positive rate = FP/(FP+TN);
  false-negative rate = FN/(FN+TP); balanced accuracy = (recall + TN/(TN+FP))/2.

Window 6's "false alerts 11.6 %" was FP on `irrelevant` items only, 5 of 43 — a false-positive
rate that left the 4 `repeat` items out of the denominator (5 of 47 = 10.6 % with them). Its
precision 90.9 % is 50 of 55. The two have different denominators; they do not contradict each
other. Reproduced on this branch before any change (`baseline/heldout_triage_repro.*`):

| Window 6 held-out set (119) | TP | FP | FN | TN | Precision | Recall | FPR |
|---|---|---|---|---|---|---|---|
| Reported in Window 6 | 50 | 5 | 8 | 38 + 4 repeats | 90.9 % | 86.2 % | 11.6 % (of 43) |
| Reproduced | 50 | 5 | 8 | 42 | 90.9 % | 86.2 % | 10.6 % (of 47) |

That set has been read and is a historical benchmark only; nothing was tuned or reported on it
after this reproduction.

## 2. Data

| File (`Sources/SemanticEvaluation/Resources/`) | Role | Items | Relevant / irrelevant / repeat / ambiguous |
|---|---|---|---|
| `semantic_dev.txt` | Window 6 development set | 80 | 32 / 33 / 2 / 13 |
| `semantic_heldout.txt` | Window 6 held-out set (read; historical) | 119 | 58 / 43 / 4 / 14 |
| `semantic_dev2.txt` | **development**, Window 6.1 | 171 | 82 / 73 / 4 / 12 |
| `semantic_sealed.txt` | **sealed**, Window 6.1 | 220 | 105 / 92 / 4 / 19 |

- The sealed set was written before the first prompt or rule of this window was changed, with
  four profiles (pupil, commuter, clinic patient, shop worker); three of them use goals that
  occur in no other file. It was run **once per configuration** after the configuration was
  committed (`e455e1c`), and nothing was changed afterwards. Its sentences were written by the
  same author as the development set: it is unseen by the tuning, not independent of the writer.
- Categories: obvious, implicit, causal, third person, negation, hypothetical, past,
  sarcasm/quotation, recognition errors, incomplete, repeated, ambiguous, unrelated (including
  goal words used for something else), someone addressing the listener, short urgent
  instructions (with casual uses of alarm words as negatives), sentences that need the one before.
- Labels are kept out of every model input (the tool passes the utterance, its context and the
  goals only).

## 3. Sealed set — the result to quote

Run once, frozen configuration. `sealed/sealed_window6.*`, `sealed/sealed_optimized.*`,
`sealed/sealed_baselines.*`.

| | Keyword | Embedding | Window 6 pipeline | **Window 6.1** |
|---|---|---|---|---|
| TP / FP / FN / TN | 19 / 21 / 86 / 75 | 97 / 84 / 8 / 12 | 77 / 8 / 28 / 88 | **103 / 16 / 2 / 80** |
| Precision | 47.5 % | 53.6 % | 90.6 % | **86.6 %** |
| Recall | 18.1 % | 92.4 % | 73.3 % | **98.1 %** |
| F1 | 0.262 | 0.678 | 0.811 | **0.920** |
| False-positive rate | 21.9 % | 87.5 % | 8.3 % | **16.7 %** |
| False-negative rate | 81.9 % | 7.6 % | 26.7 % | **1.9 %** |
| Balanced accuracy | 48.1 % | 52.4 % | 82.5 % | **90.7 %** |
| Important events found | 1/16 | 16/16 | 11/16 | **16/16** |
| Short urgent instructions found | 1/12 | 12/12 | 8/12 | **12/12** |

Semantic understanding, Window 6 → Window 6.1 (correct / total):

| Group | Window 6 | Window 6.1 |
|---|---|---|
| Implicit relevance recall (implicit + causal) | 32/42 (76.2 %) | 41/42 (97.6 %) |
| Explicit relevance recall (obvious + addressed) | 12/21 (57.1 %) | 20/21 (95.2 %) |
| Negation accuracy | 17/18 | 16/18 |
| Hypothetical accuracy | 11/11 | 11/11 |
| Personal relevance (third person) accuracy | 15/20 | 16/20 |
| Past and quotation accuracy | 14/15 | 15/15 |
| Recognition-error accuracy | 10/13 | 13/13 |
| Needs the sentence before | 9/9 | 8/9 |
| Unrelated talk accuracy | **29/29** | **22/29** |
| Repetition (no second alert) | 3/4 | 3/4 |
| Ambiguous (not scored): alerted / uncertain / silent | 12 / 1 / 6 | 17 / 0 / 2 |
| Model failures (utterance lost without a judgement) | 3 | 0 |

By profile (TP/FP/FN/TN): Window 6 — clinic 12/2/13/18, commuter 20/2/5/23, pupil 29/4/2/26,
shop 16/0/8/21. Window 6.1 — clinic 24/4/1/16, commuter 25/3/0/22, pupil 31/5/0/25, shop
23/4/1/17.

**Against the targets:** recall ≥ 95 % — met (98.1 %, Wilson 95 % interval 93.3–99.5).
Implicit relevance recall ≥ 95 % — met (97.6 %, 41 of 42; interval 87.7–99.6). **Precision
≥ 95 % — not met: 86.6 % (interval 79.3–91.6), lower than Window 6's 90.6 % (82.5–95.2; the two
intervals overlap).** The false-positive rate doubled
(8 → 16 false alerts on 96 negatives). Seven of the 16 are plain unrelated sentences ("Is it
supposed to rain on Saturday?", "We're having tacos tonight."), which Window 6 never alerted on.

Errors of Window 6.1 on the sealed set (all 18):

| Kind | Items |
|---|---|
| Unrelated talk alerted (7) | sp044, sp047, sp048, sk040, sk041, sw038, sw040; also sw048 (context item "Anything but pizza.") |
| Someone else's affairs (4) | sc013 "northbound has delays, we're fine going south", sc053, sk017, sk018 |
| "Nothing changes" (2) | sp021 "we are not having a quiz tomorrow, same plan", sw020 "Your hours aren't changing" |
| Alarm phrase used casually (1) | sc052 "Get out, you did not just say that." |
| Repetition alerted (1) | sp041 "Remember, the midterm now covers chapters one through nine." |
| Missed (2) | sk042 "Ma'am, we're ready for you now." (judged relevant, no goal named), sw003 "Someone's been standing at the fitting rooms for a while." (filed under someone else) |

The 28 misses of Window 6 on the same set: 15 stopped by its one-word first pass, 3 lost to
model failures, 7 judged irrelevant, 3 demoted to uncertain. 21 of the 28 are in the clinic and
shop profiles; by category 9 are sentences addressed to the listener, 9 implicit, 5 short
urgent or important instructions (`sealed/sealed_window6.txt`).

## 4. Development set 2 — what was tuned on

Same configurations on the 171 development items (tuned on; for comparison and ablation only).

| Configuration (`ablation/`) | TP | FP | FN | TN | Precision | Recall | Time per item (median) |
|---|---|---|---|---|---|---|---|
| Window 6 pipeline (`w6_triage_dev2`) | 62 | 6 | 20 | 71 | 91.2 % | 75.6 % | 3.28 s |
| Five enum fields, first version of the short prompt (`compact_dev2`) | 60 | 15 | 22 | 62 | 80.0 % | 73.2 % | 2.40 s |
| …plus one short free-text field first (`reasoned_dev2`) | 62 | 13 | 20 | 64 | 82.7 % | 75.6 % | 3.03 s |
| Three enum fields, first prompt (`lean_dev2`) | 50 | 1 | 32 | 76 | 98.0 % | 61.0 % | 2.04 s |
| Three enum fields, revised prompt (`lean_v2_dev2`) | 79 | 15 | 3 | 62 | 84.0 % | 96.3 % | 2.64 s |
| …plus second look in its own session, session kept 6 turns (`lean_v2_confirm_turns6_dev2`) | 79 | 5 | 3 | 72 | 94.0 % | 96.3 % | 2.13 s |
| …second look as a follow-up in the same session (`final_candidate_dev2`) | 79 | 12 | 3 | 65 | 86.8 % | 96.3 % | 1.56 s |
| **Frozen configuration** (`final_dev2`) | 80 | 8 | 2 | 69 | 90.9 % | 97.6 % | 2.01 s |

Times in this table come from loops without pauses on a busy machine and include the second look
for about half of the items (half of this set is relevant); §5 has the clean timings.

- The frozen configuration and `lean_v2_confirm_turns6_dev2` differ only in session details
  (§6); their 8 vs 5 false alerts show the run-to-run spread of this design: a kept session makes
  a judgement depend on the few sentences before it.
- Second look with a goal-fit question added (`lean_v2_confirm2_subset`, the 110 items accepted
  or uncertain before): 18 correct alerts lost. Rejected.
- Development gap: precision 90.9–94.0 % on the tuned set, 86.6 % sealed.

Window 6's errors on this set (26; listed in `ablation/w6_triage_dev2.txt`): 20 misses — 10
stopped by the first pass (among them "Stay away from the window." and three sentences
addressed to the listener), 3 model failures, 2 demoted as "about someone else", 5 judged
irrelevant; 6 false alerts — past, sarcasm, an impression, another group's deadline, a repetition.

## 5. Latency

### 5.1 One judgement, by stage (Mac; `latency/stage_breakdown_mac.txt`, `final_latency_mac.txt`)

| Stage | Measured |
|---|---|
| Input preparation and prompt construction | < 1 ms |
| Session creation | < 1 ms (the cost is reading the instructions, below) |
| Reading instructions + goals + answer form (≈ 950 tokens) when the session has not read them | ≈ 1.2 s (2.4–2.7 s per judgement instead of 1.2–1.4 s) |
| Structured generation | ≈ 35–45 ms per output token |
| First part of the answer | arrives with the last: guided generation delivers the first field late, so "first response latency" ≈ total |
| Evidence verification, novelty | < 1 ms (deterministic) |
| Attention arbitration (Window 4) | microseconds (Window 4 measurement; unchanged) |
| Live Activity update submission | not measured in this window (Window 5: 0.02 s median on the iPhone) |

| Answer form | Output tokens | One judgement, session prepared in a pause |
|---|---|---|
| Window 6: 7 fields, 2 free-text | 75–77 | 2.74–2.77 s |
| 5 enum fields + 1 short free-text field | 53 | 2.23 s |
| 5 enum fields | 37 | 1.66 s |
| **3 enum fields (chosen)** | 29–37 | **1.19–1.44 s** |
| One-word first pass of Window 6 | ≈ 6 | 0.61 s (Window 6 measurement) |
| Second look (1 enum field, own session, 427 input tokens) | 17 | 0.87–0.93 s |

What was tried and measured (each on 10–12 development sentences):

| Question | Result |
|---|---|
| Does a session prepared ahead help? | Only with the goals as prompt prefix and only if ≥ 0.6 s pass before the request: 1.44 s vs 2.57 s with no pause. Plain `prewarm()` without the prefix did nothing useful here. |
| Does the system keep what a session has read? | For one session at a time. After a request of any other session the next request reads everything again (cached input tokens 0, +1.2 s). |
| Keep one session for several utterances | 1.29 s without pauses (2.73 s with a fresh session each time). Chosen: 6 utterances per session. |
| Repeat the answer form on later turns? | No: +150 input tokens per turn, and a longer session text makes every later answer slower (1.4 s at 950 tokens → 2.1 s at 2 800). |
| Second look as a follow-up in the kept session | 1.2–2.3 s and much weaker (§4). Rejected. |
| Second look in its own session, then make the kept session ready again (`prewarm()` on it) | 0.9 s; the next judgement is fast again (1.17 s). Chosen. |
| Unconstrained three-word answer instead of guided generation | 0.55 s for 11 tokens, but the model did not keep the format ("kind, 1, relevant") and the answers were poor. Rejected. |

Token counts are the system's own (`LanguageModelSession.Usage`, iOS/macOS 27).

### 5.2 Through the engine's queue (`stream/throughput_*`)

37 development sentences (one relevant in about six — still far denser than conversation),
submitted at a fixed interval through `submit`, decisions read from the stream. Seconds.

| Interval | Engine | End to end p50 / p95 / p99 | Waiting for a turn p50 / p95 / p99 | Model p50 / p95 / p99 | Dropped (relevant) | Later than 4 s | Sentences per minute decided |
|---|---|---|---|---|---|---|---|
| 3.0 s | Window 6 | 3.86 / 8.89 / 9.69 | 0.84 / 5.99 / 6.56 | 2.50 / 2.97 / 3.00 | 0 | 18 | 20.1 |
| 3.0 s | **Window 6.1** | **1.47 / 2.21 / 2.92** | 0 / 0 / 0 | 1.47 / 2.21 / 2.92 | 0 | 0 | 20.3 |
| 1.5 s | Window 6 | 5.93 / 9.57 / 9.60 | 4.44 / 5.95 / 7.03 | 2.37 / 2.94 / 2.99 | 11 (3) | 20 | 26.4 |
| 1.5 s | Window 6.1 | 5.39 / 20.62 / 20.96 | 3.80 / 17.61 / 19.07 | 1.91 / 3.66 / 4.76 | **0** | 24 | 30.8 |
| 1.0 s | Window 6 | 6.42 / 11.11 / 11.11 | 3.33 / 10.11 / 10.11 | 2.61 / 2.97 / 2.97 | 19 (4) | 15 | 23.9 |
| 1.0 s | Window 6.1 | 11.58 / 21.58 / 22.26 | 8.76 / 19.72 / 19.84 | 1.86 / 4.04 / 5.25 | 7 (2) | 22 | 33.2 |

Window 6.1 at 3.0 s, by kind of decision: one model request (24 sentences) p50 1.35, p95 1.78,
p99 1.90 s; with a second look (13 sentences) p50 2.04, p95 2.92 s. Model requests per minute:
20.3 judgements + 7 second looks at 3.0 s; about 31–33 judgements at the faster rates. Output
tokens per judgement: 32.4 (Window 6: 73.1); a second look adds 17.

Reading: at one sentence every 3 s the p50 target (≤ 1.5 s) is met and nothing waits. The
engine decides about 31–33 sentences per minute; when sentences arrive faster than that for a
long time it falls behind. Window 6.1 then keeps up to 12 sentences waiting and reports the ones
it gives up after 20 s (stage `dropped`, counted); Window 6 kept 4 and dropped the oldest. So
Window 6.1 loses fewer sentences under overload but its late decisions are later. Every
submitted sentence got a decision of some kind in every run ("without any decision": 0).

### 5.3 Early evaluation of a stable partial transcript (`stream/speculation.*`)

24 development sentences, one at a time; the final transcript comes 0.8 s after the end of the
speech (the Window 3 iPhone figure, used here as an assumption); every sixth final text differs
from the partial one. Simulated timing, real model.

| | Speech end → decision p50 / p95 | Final text → decision p50 / p95 | Model requests |
|---|---|---|---|
| Final transcript only | 2.67 / 3.79 s | 1.87 / 2.95 s | 24 |
| Partial transcript offered after 0.4 s without change | **2.29 / 4.46 s** | 1.46 / 3.63 s | 24 early + 4 on final text |

Early answers used: 20 of 24; abandoned: 4 (all 4 revised sentences were decided on their final
text). Same outcome as without early evaluation: 23 of 24 (the one difference is the run-to-run
spread of §4, not a provisional text being trusted). Gain: 0.4 s at the median; the 95th
percentile is worse, because an abandoned early request is in the way. It runs only while
nothing finalized is waiting.

### 5.4 Recap beside goal matching (`stream/contention.*`)

20 sentences every 1.5 s; the recap of a development conversation is requested after the fourth.

| Mode | Recap | Sentences dropped | Decided, submitted during the recap (p50) | Warning-like sentence during the recap |
|---|---|---|---|---|
| Recap alone | 7.1 s | – | – | – |
| Window 6: goal matching paused | 6.8 s | **9 of 20** | 7.7 s (1 sentence) | 7.7 s |
| No coordination | 7.2 s | 0 | 10.0 s | 8.2 s |
| **One scheduler, recap first** | 7.0 s after 1.2 s for its turn | 0 | 12.9 s | 7.9 s |
| Scheduler, warning-like sentence allowed beside the recap | 7.2 s | 0 | 11.2 s | 7.6 s |

Running a judgement beside the recap gained nothing (7.6 s vs 7.9 s: the system runs one
request at a time whatever the app asks), so it is off. Consequence: **a spoken warning that is
not caught by the attention engine's phrase rule waits for a running recap, up to about 7 s on
the Mac.** The phrase rule and the acoustic path do not use the language model and do not wait.

### 5.5 Judging waiting sentences together (`stream/together_size3.txt`)

Development set 2 in groups of three, one request per group: of 34 groups that contain a
relevant sentence, 27 were recognized as such and 19 named a relevant sentence; **13 relevant
sentences sat in groups that were waved through.** 2.5 s per group request. Rejected; the
mechanism exists and is off (`batchThreshold = 0`).

## 6. Frozen configuration

`FoundationModelRelevanceReasoner.optimized` + `SemanticAttentionEngine.Configuration.standard`:
answer form `lean` (kind, goal, verdict); no first pass; second look on relevant, non-urgent
verdicts in its own session; session kept for 6 utterances, answer form sent on the first turn
only; queue 12, give up after 20 s, deadline mark at 4 s; no group requests; partial transcripts
evaluated early; warning-like sentences in their own lane; one scheduler shared with the recap.
Commit `e455e1c`. Window 6's behaviour is `Configuration.window6` + style `window6`.

## 7. Evidence and wording

| | Window 6 | Window 6.1 |
|---|---|---|
| Text written by the model and shown | headline, reason | none |
| Model text removed by the verifier, dev set 2 | 20 (10 headline not in the utterance, 7 negation lost, 3 details in the reason) among 86 non-irrelevant decisions | not applicable |
| Model text removed, sealed set | 21 (10 / 8 / 3) among 106 non-irrelevant decisions | not applicable |
| Headline | model, checked | the utterance's own words; cut at 12 words only if no "not", number, day or time is lost, otherwise none (5 of 220 sealed items) |
| Reason | model, checked for numbers | fixed words + the user's goal |

Unsupported inference in shown text is therefore 0 by construction in Window 6.1 (unit-tested);
what can still be wrong is the verdict itself (§3). How many of Window 6's model-written texts
that *passed* its checks were unsupported was not counted here (Window 6 read 56 recap statements
and found 2).

## 8. Resources

- Evaluation process: 14 → 26 MB resident. The language model runs in a system process that this
  does not include; its memory, CPU/GPU use, energy and heat were **not measured** (they need
  privileged tools or a device).
- Runtime: development run 338–420 s (171 items), sealed runs 438 s (Window 6.1) and 494 s
  (Window 6), each throughput run 55–125 s, speculation ≈ 2.5 min, contention ≈ 3 min. No run
  exceeded 9 minutes; runs were sequential, one model request at a time.

## 9. Regression

| Check | Environment | Result |
|---|---|---|
| `swift test` | Mac | **426 tests, all passed** (395 before; 31 new: scheduler 10, engine / second look / headline / partial transcripts / detector 21). Log: `results/semantic_optimization/logs/` (not committed) |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27 Simulator, iPhone 18 Pro Max | **TEST SUCCEEDED** (same suites; recognizer tests skipped there as before) |
| App, Debug | iOS Simulator build | Succeeded |
| App, Release, unsigned | generic iOS device | Succeeded |
| Scripted conversation in the Simulator (iPhone 18 Pro Max, microphone off) | new engine, real language model | Goal matches shown; one of them is a questionable "urgent" (report §6). No timing taken |
| Sound classification, icon mappings, attention engine, island pipeline, recap engine | package tests of Windows 2–6 | unchanged and passing; their sources were not edited |
| Physical iPhone, microphone, real speech | — | **Not run** (not part of this window) |

## 10. Reproduce

```bash
cd packages/HearingSenseKit
swift test --filter SemanticAttentionTests
swift run hs-semantic-eval latency --styles window6,lean --turns 6        # one judgement, by stage
swift run hs-semantic-eval cues                                            # order cue for warnings (no model)
../../tools/run_semantic_ablation.sh ablation my_dev2 dev2 --config optimized     # ≈ 6 min
../../tools/run_semantic_ablation.sh ablation my_w6 dev2 --config window6 --style window6
swift run hs-semantic-eval throughput --config optimized --interval 3.0   # also 1.5, 1.0; --config window6
swift run hs-semantic-eval speculation
swift run hs-semantic-eval contention
swift run hs-semantic-eval together --size 3
../../tools/semantic_confusion_table.py Sources/SemanticEvaluation/Resources/semantic_dev2.txt <run.json>
```

The sealed set (`--set sealed`) has been run for the two configurations above. Do not run it to
compare variants, and do not tune on it; write a new one first.
