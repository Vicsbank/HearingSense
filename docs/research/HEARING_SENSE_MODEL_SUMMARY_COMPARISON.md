# Hearing Sense — on-device summarization: Apple AFM 3 Core vs Qwen3.5-4B vs LFM2.5-2.6B

Date: 2026-10-12. Branch `research/local-model-comparison`, worktree `.claude/worktrees/model-bench`.
Mac only (M1 Max, 32 GB, macOS 27.2). Method, fairness rules and limitations: `docs/testing/SUMMARY_MODEL_BENCHMARK.md`.
Raw outputs and metrics: `results/summary_model_bench/`.

## Verdict (short)

- **Qwen3.5-4B is the only open model worth a follow-up; LFM2.5-2.6B is not.** LFM2.5-2.6B is worse than Apple AFM 3 on recall and critical-information recall (paired bootstrap, 95 % CI excludes zero) and not better on hallucinations.
- **Qwen3.5-4B vs Apple AFM 3 Core, same neutral prompt:** factual precision (+1.1 pp), recall (+1.9 pp) and critical recall (+0.9 pp) are **not distinguishable** (all CIs include 0). The measurable gains are a **lower share of summaries with at least one unsupported claim (61 % vs 76 %, −15.5 pp, CI −26 … −5 pp)**, much better naturalness/readability, no "someone said…" vagueness, correct handling of corrections in the production-prompt setting (88 % vs 75 %) and about 1.7–2× lower Mac latency.
- **That is not yet a "meaningful, repeatable improvement" large enough to justify** ~3 GB of extra storage, an MLX runtime in the app, and unknown iPhone memory/latency. **Recommendation: keep Apple AFM 3 Core as the production model; treat Qwen3.5-4B as a candidate for a device feasibility study** (see section K).
- Strong caveats: judge is a single pass of blinded Claude Sonnet sub-agents (no human check); the model-based grounding step of the production pipeline was **not** reproduced; the synthetic transcripts are shorter than real two-minute speech; Mac numbers do not transfer to iPhone.

## A. Setup actually run

| | Apple AFM 3 Core | Qwen3.5-4B | LFM2.5-2.6B |
|---|---|---|---|
| Checkpoint | system model, `SystemLanguageModel.default`, variant reported by the framework: **AFM 3 Core**, context 4096 | `mlx-community/Qwen3.5-4B-MLX-4bit` @ `32f3e8ec…` | `LiquidAI/LFM2.5-2.6B-MLX-4bit` @ `04efa237…` |
| Params / quant | n/a | 4.54 B (incl. vision tower, unused), 4-bit affine g64 | 2.70 B, 4-bit affine g64 |
| Runtime | FoundationModels (on-device only, no Private Cloud Compute) | mlx-lm 0.32.0, mlx 0.32.3 | same |
| Thinking | n/a | **off**, natively (`enable_thinking=false` in the chat template) | **no native off switch** — template hard-codes an open `<think>`; I close it in the prompt (`<think></think>`). The model still writes reasoning-like text before answering; that text is removed from the scored summary but **counted in latency/tokens**. 11/110 neutral outputs hit the 500-token cap. |
| Decoding | greedy | greedy (temp 0) | greedy (temp 0; LFM's recommended repetition penalty not used) |
| Download | – | 3.06 GB (2.8 GiB on disk) | 1.60 GB (1.5 GiB on disk) |

Data: frozen synthetic held-out set of **110 conversations** (44 English, 44 Mandarin, 22 mixed; SHA-256 `1e309249…`), 24-conversation development set (only 12 used, pilot), 30-item Continue set (SHA-256 `cec4a9bd…`). Authored by independent Claude sub-agents that had no access to prompts, models or results; each conversation has atomic reference facts (with a critical flag), `must_not` inferences and uncertainties. Scoring by separate blinded Claude Sonnet sub-agents (model identity hidden, order shuffled) at claim level.

Two configurations (never mixed):
- **Neutral**: one common prompt for all three models, plain-text recap of 4–8 sentences.
- **Production prompt ("prod")**: the app's actual `FoundationModelRecapSummarizer` instructions copied verbatim from the Window 8 worktree, same title/summary/keyPoints schema (Apple: constrained decoding as in the app; open models: the same schema described in the instructions, no constrained decoding). Reported as **prod_raw** (before post-processing) and **prod_final** (after a Python port of the app's lexical checks; see caveat below).

## B–D. Factual precision, recall, hallucination (110 held-out conversations)

Precision = supported claims / all claims in the summary. Recall = reference facts fully (1) or partly (0.5) present. Critical recall = same, critical facts only. Hallucination rate = share of summaries containing at least one unsupported claim (the judge was strict; absolute rates are high for every model — compare models, not against zero). "vs Apple" = paired difference over conversations, 95 % bootstrap CI.

**Neutral prompt (identical for all)**

| Model | Precision | Recall | Critical recall | Hallucination rate | Unsupported claims / summary | must_not violated | Correction handled correctly |
|---|---|---|---|---|---|---|---|
| Apple AFM 3 Core | 0.916 | 0.825 | 0.861 | 76.4 % | 1.56 | 5.3 % | 85 % (51/60) |
| Qwen3.5-4B | 0.927 | 0.844 | 0.870 | **60.9 %** | 1.16 | 5.0 % | 87 % (52/60) |
| LFM2.5-2.6B | 0.874 | 0.750 | 0.772 | 76.4 % | 2.13 | 9.3 % | 73 % (44/60) |

Qwen − Apple: precision +0.011 [−0.007, +0.028]; recall +0.019 [−0.014, +0.053]; critical recall +0.009 [−0.019, +0.038]; hallucination −0.155 [−0.264, −0.045] (significant).
LFM − Apple: precision −0.042 [−0.061, −0.023]; recall −0.075 [−0.113, −0.038]; critical recall −0.089 [−0.125, −0.051] (all significant); hallucination 0.000 [−0.10, +0.10].

**Production prompt, raw model output (before post-processing)**

| Model | Precision | Recall | Critical recall | Hallucination rate | Unsupported / summary | Correction correct |
|---|---|---|---|---|---|---|
| Apple AFM 3 Core | 0.865 | 0.822 | 0.830 | 95.5 % | 4.19 | 75 % |
| Qwen3.5-4B | 0.931 | 0.806 | 0.817 | **64.5 %** | 1.63 | 88 % |
| LFM2.5-2.6B | 0.864 | 0.654 | 0.676 | 82.7 % | 3.36 | 62 % |

Qwen − Apple: precision +0.066 [+0.040, +0.093]; recall −0.017 [−0.048, +0.016]; hallucination −0.309 [−0.400, −0.218]. LFM − Apple recall −0.169 [−0.207, −0.132].
Apple's raw production output is repetitive (restating every point twice via "Someone said … / Someone agreed …", 3.1 vague units per summary versus 0.27 for Qwen) which inflates its unsupported-claim count. The app's `tidied` step and its model-based grounding check (not reproduced here) target exactly this, so **Apple's real in-app hallucination rate is lower than the 95 % shown**.

**After the app's lexical checks (prod_final) — treat with caution**

The Python port of the app's lexical validator rejected whole summaries in many cases: English 4/44 (Apple), 14/44 (Qwen), 9/44 (LFM) became "no summary"; Chinese and mixed were rejected almost always (42–44 of 44 and 22 of 22). Two causes, neither is model quality alone:
1. The validator is designed for English; Chinese text is not tokenized into words by it.
2. My synthetic transcripts spell numbers as words ("seven forty-five") while Qwen/LFM write digits ("7:45"). The validator's number check then removes correct sentences. Real speech-recognizer output normally contains digits, so this penalises the open models unfairly. English survivors: precision 0.944 / 0.916 / 0.915 and recall 0.737 / 0.418 / 0.463 (Apple / Qwen / LFM). **I do not use prod_final to rank the models.** It does show that the app's English-only checks would need work before any Chinese summary can be shown with the current post-processing, for any model.

## E. English / Chinese / mixed (neutral prompt)

| Language | Model | Precision | Recall | Critical recall | Halluc. rate | Natural (1–5) | Readable (1–5) |
|---|---|---|---|---|---|---|---|
| EN (44) | Apple | 0.921 | 0.830 | 0.854 | 77 % | 3.02 | 3.11 |
| | Qwen | 0.914 | 0.823 | 0.851 | 64 % | 3.68 | 3.57 |
| | LFM | 0.909 | 0.754 | 0.810 | 73 % | 3.45 | 3.43 |
| ZH (44) | Apple | 0.916 | 0.846 | 0.880 | 77 % | 3.05 | 3.11 |
| | Qwen | 0.935 | 0.857 | 0.880 | 57 % | 4.05 | 3.89 |
| | LFM | 0.865 | 0.779 | 0.777 | 75 % | 3.20 | 3.07 |
| Mixed (22) | Apple | 0.904 | 0.773 | 0.837 | 73 % | 2.73 | 2.91 |
| | Qwen | 0.937 | 0.861 | 0.890 | 64 % | 4.09 | 4.05 |
| | LFM | 0.829 | 0.685 | 0.688 | 86 % | 3.05 | 2.86 |

Per-language samples are small (22–44); only the large effects (LFM's weak mixed-language recall and must_not violations of 24 %; Qwen's naturalness) are likely to be stable. For mixed conversations the prompt asked for a Chinese recap; only Qwen reliably complied (median 140 CJK characters); Apple and LFM mostly answered in English. Chinese corrections: Apple 91 %, Qwen 91 %, LFM 77 % (neutral).

## F. Latency (Mac, warm, one request at a time)

Time from submitting the transcript to the complete summary. Median / p95 over the 110 held-out conversations; the 36-request repeat group (12 conversations × 3 repeats, greedy, so identical outputs) is consistent with these (Apple 5.9 / 7.4 s, Qwen 3.8 / 5.8 s, LFM 3.6 / 6.2 s; repeat medians within ±0.2 s).

| Model | Neutral median / p95 | Production prompt median / p95 | First token (median) | Output tokens (neutral/prod) | Tokens/s | Cold load | First request after load |
|---|---|---|---|---|---|---|---|
| Apple AFM 3 Core | 5.9 / 8.3 s | 10.9 / 14.8 s | 1.7 s | 174 / 329 | 29 | not observable (system service) | 7.9 s |
| Qwen3.5-4B | 3.5 / 5.4 s | 5.6 / 7.6 s | 0.7 s | 142 / 272 | 42 | 4.2 s (files cached) | 7.3 s |
| LFM2.5-2.6B | 3.1 / 6.4 s | 3.6 / 5.3 s | 0.5 s | 215 / 255 | 70 | 1.8 s (files cached) | 3.8 s |

Notes: Apple's guided output includes JSON structure and key points; its tokens/s mixes prefill and decode. The production-prompt time covers the draft only (restating adds < 0.1 s median; the model-based grounding request that the app adds afterwards is **not** included for any model). Qwen had a single 23 s neutral outlier (a slow request while the Mac was loaded) that does not appear in the repeat group. The LFM latency group did not get a quiet machine (load average 4.4 after a 10-minute wait; Apple's waited 379 s and ran at load 3.3, Qwen's started at 2.1), so its absolute numbers may be slightly pessimistic.

## G. Memory

| Model | Observable memory | Note |
|---|---|---|
| Apple AFM 3 Core | none — the model lives in a system service | cannot be compared with MLX process memory |
| Qwen3.5-4B | MLX peak 3.43 GB, active 2.7 GB after the whole run; process max RSS 1.6 GB (weights are memory-mapped/Metal buffers, so RSS undercounts) | 2.85 GiB file includes a vision tower that a text-only conversion could drop |
| LFM2.5-2.6B | MLX peak 2.54 GB, active 1.7 GB; max RSS 2.2 GB | |

Swap was already ~11 of 12 GB used before the benchmark started (other apps), so Mac memory pressure was not clean. These are Mac figures; **iPhone memory limits, thermal behaviour and background-execution limits were not tested** and would likely decide feasibility for a 4 B model.

## H. Failure examples (neutral prompt; judge's notes)

- Apple, `fin-en-029`: "…with a correction that the soccer game is at ten at the Riverside field, not six" — no such correction occurred (invented correction).
- Apple, `fin-zh-025`: invented a flight and a garbled price in a number-dense Chinese conversation. `fin-zh-016`: reported a consultation with the manager as already done when it was still future.
- Qwen, `fin-zh-009`: homework due "next Thursday" where the transcript said tomorrow. `fin-zh-035`: invented a "misreported 17" in a statistics sentence. `fin-mix-009`: invented "a decision to go rest".
- LFM, `fin-mix-011`: attributed invented prices to a hotel stay (the 18,000 belonged to another city). `fin-zh-015`: wrong per-night price and a total for three people. `fin-en-004`: said the speaker would ask about the meeting time, when it was the room.
- Production-prompt Apple output: every fact is duplicated ("Someone said … Someone agreed …"), 3.1 vague units per summary; Qwen: 0.27.
- LFM Continue (addition mode): 23/30 JSON answers needed repair and the additions are long (median 360 characters vs 126 for Qwen) and repetitive.

These judgements are from one blinded Claude Sonnet pass; some "unsupported" calls are debatable (e.g. paraphrase of garbled speech). Ambiguous claims were counted separately in the judgments and are not scored as errors.

## I. Continue (30 items: 12 EN, 12 ZH, 6 mixed; 16 contain a correction, 4 are "nothing new")

Two modes: **addition** (the app's `update` prompt: only new text is written and appended to the earlier recap) and **rewrite** (complete updated recap).

| Mode | Model | Earlier facts kept | New facts added | Correction stated correctly | Precision | Unsupported / update | Update latency median (max) |
|---|---|---|---|---|---|---|---|
| addition | Apple | 0.90 | 0.84 | 88 % (14/16) | 0.925 | 1.43 | 3.4 s (4.1) |
| addition | Qwen | 0.92 | 0.87 | **100 %** (16/16) | 0.909 | 1.50 | 2.1 s (3.0) |
| addition | LFM | 0.81 | 0.58 | 81 % | 0.876 | 2.77 | 1.9 s (3.9) |
| rewrite | Apple | 0.88 | 0.65 | 81 % | 0.918 | 1.27 | 3.5 s (5.9) |
| rewrite | Qwen | 0.91 | 0.77 | 100 % | 0.911 | 1.37 | 2.9 s (4.2) |
| rewrite | LFM | 0.74 | 0.49 | 75 % | 0.912 | 1.40 | 1.9 s (6.6) |

n = 30 (16 for corrections): Apple and Qwen are close except for correction handling and naturalness; LFM is clearly weaker. In the "nothing new" items every model still produced about 0.5–2.3 unsupported claims on average (4 items; too few to conclude). In addition mode the earlier recap is kept by construction, so "earlier facts kept" there mostly measures the earlier recap each model wrote itself. Each model used its own first-part recap as the starting point, so the starting points differ.

## J. Installation and licensing

- **Apple AFM 3 Core**: no extra storage, no extra runtime, already integrated.
- **Qwen3.5-4B**: Apache-2.0. 3.06 GB download; needs an MLX-based Swift runtime in the app (support for the `qwen3_5` architecture in the Swift runtime was **not verified** here) and an in-app model download or on-demand resource. Multimodal checkpoint; a text-only conversion would be smaller.
- **LFM2.5-2.6B**: LFM Open License v1.0 — free including commercial use for organisations under USD 10 M annual revenue; above that a commercial licence is required. 1.60 GB download.

## K. Recommendation for Hearing Sense

Using the stated priority order (factual correctness → hallucinations → preserved information → completeness → latency → memory → iPhone feasibility):

1. **Factual correctness / information preserved**: Apple AFM 3 and Qwen3.5-4B are statistically tied on precision, recall and critical recall (neutral prompt); LFM2.5-2.6B is worse.
2. **Hallucinations**: Qwen has a significantly lower share of summaries with an unsupported claim (−15 pp neutral, −31 pp with the production prompt). Apple's raw production output is the weakest, but the app's grounding step (not reproduced) is meant to repair precisely that, so the real gap in the app is smaller and unmeasured.
3. **Latency**: Qwen is 1.7–2× faster on the Mac than Apple for the production prompt; Mac figures say nothing reliable about an iPhone.
4. **Cost**: +3 GB storage, a new runtime, a second model to maintain, and a Chinese post-processing gap that exists for any model.

**Decision: do not replace Apple AFM 3 Core now.** The measured improvement is real on hallucination rate and style but not on recall or critical-information recall, and the deployment cost and iPhone risk are high. If the project wants to pursue it, the next steps (not done here, and each needs its own authorization) are: (a) run the app's real Swift pipeline, including the grounding step, with both models on the same data; (b) repeat the comparison with digits-style transcripts and a Chinese-aware validator; (c) a human spot-check of ~10 % of judge calls, plus a second judge; (d) an iPhone memory/thermal/latency feasibility test for Qwen3.5-4B (a text-only 4-bit conversion) in a separate, approved device session. Drop LFM2.5-2.6B from further consideration for this task.

## Final comparison table

Neutral prompt, 110 held-out conversations (production-prompt hallucination in brackets):

| Model | Factual Precision | Factual Recall | Hallucination Rate | Median Latency | p95 Latency | Memory | Overall Assessment |
|---|---|---|---|---|---|---|---|
| Apple AFM 3 Core | 0.916 | 0.825 | 76 % (95 %) | 5.9 s (prod 10.9 s) | 8.3 s (prod 14.8 s) | not observable; no extra storage | Baseline; accurate but repetitive/stilted; already integrated. **Keep.** |
| Qwen3.5-4B | 0.927 | 0.844 | 61 % (65 %) | 3.5 s (prod 5.6 s) | 5.4 s (prod 7.6 s) | MLX peak 3.4 GB; 3.06 GB download | Same accuracy and recall within noise; fewer hallucinations, much better prose, best on corrections. **Candidate for a device feasibility study, not a replacement yet.** |
| LFM2.5-2.6B | 0.874 | 0.750 | 76 % (83 %) | 3.1 s (prod 3.6 s) | 6.4 s (prod 5.3 s) | MLX peak 2.5 GB; 1.60 GB download | Lower recall and critical recall than Apple, weak on mixed-language and corrections, no native non-thinking mode, license revenue cap. **Not recommended.** |

## Limitations (all of them matter)

- One blinded judge pass by Claude Sonnet sub-agents; the same model family wrote the data. No human check, no second judge, no inter-rater agreement. The judge is strict, so absolute rates are pessimistic for all models; differences are what carry information.
- Synthetic transcripts are shorter than real two-minute speech (English median 174 words, Mandarin 235 characters; some mixed ones were lengthened to pass a length check) and spell numbers out, unlike a real recognizer.
- The model-based grounding check and the real Swift validator were not run; the Python port is approximate.
- LFM was run with a prompt-level workaround for thinking; a native thinking run was not made.
- Greedy decoding, one run per conversation; no seeds/variance across sampling.
- Mac only; iPhone memory, thermal, background and battery behaviour unknown. Apple memory not observable.
- Window 8 and other apps were running; latency was measured after waiting for a quiet machine (LFM's group never got one).
