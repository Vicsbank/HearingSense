# Summary model benchmark — how it was run

Results and recommendation: `docs/research/HEARING_SENSE_MODEL_SUMMARY_COMPARISON.md`.
Research only. Nothing in the app, the Window 8 worktree or the iPhone was changed. Mac only, no microphone,
no real conversations, no training. No git push/merge.

## Layout

```
tools/summary_bench/
  DATASET_SPEC.md         authoring contract for the dataset sub-agents
  validate_dataset.py     schema/size checks
  data/dev.jsonl          24 development conversations (pilot used 12)
  data/final.jsonl        110 held-out conversations (frozen, data/final.sha256)
  data/continue.jsonl     30 Continue items (frozen, data/continue.sha256); continue_dev = first 3 (format check only)
  data/raw/               files as delivered by the authors
  sb/prompts.py           production prompts (verbatim copy) and the neutral prompts
  sb/common.py            transcript construction, JSON parsing, <think> handling
  sb/post.py              Python port of the app's lexical post-processing (approximate)
  sbench.py               runner: one model per process, one request at a time
  run_final.sh            Stage B driver (apple → qwen35-4b → lfm25-2.6b, never concurrent)
  apple_bridge/           Swift bridge to SystemLanguageModel.default (schema fields incl. arrays)
  judge_prompt.txt, judge_pack.py, cont_pack.py   blinded judging batches
  aggregate.py, aggregate_cont.py, bootstrap.py, latency_report.py
results/summary_model_bench/
  final/ pilot/           raw model outputs (.jsonl), run records (.meta.json)
  judging/{main,cont}/    in/ (blinded batches), out/ (judgments), keyvault/ (id key, not shown to judges)
  metrics_main.json, metrics_continue.json, bootstrap_paired.json, latency_memory.json
  production_snapshot.json   hashes of the Window 8 summarizer sources that were read
```

## Pipeline

1. **Preflight** (read-only): caches, disk (412 GB free), memory (32 GB), mlx-lm 0.32.0 already installed in the existing
   `tools/model_bench/.venv`, no model processes running. Downloads (user-approved, pinned to revisions): Qwen3.5-4B 3.06 GB,
   LFM2.5-2.6B 1.60 GB. Existing `tools/model_bench` files were reused read-only (backends, sysmon); nothing there was modified.
2. **Dataset**: 7 independent sub-agents wrote conversations + atomic facts (critical flag), `must_not` inferences and
   `uncertain` items. They saw only `DATASET_SPEC.md`. The held-out set was merged and hashed before any benchmark inference;
   prompts were never tuned (no prompt iteration happened after the smoke tests; only runtime fixes).
3. **Pilot (Stage A)**: 12 development conversations × 3 models (+3 Continue items for format checks): loading, text-only
   inference, valid output, lengths, latency, memory. Findings carried into the run: LFM2.5-2.6B has no non-thinking switch
   (fixed with a closed think block; reasoning-like text before `</think>` is stripped from the scored answer but counted
   in latency); the app's lexical validator removes most Chinese summaries.
4. **Full run (Stage B)**: all models on the same frozen set, in two tasks per conversation — neutral recap and the
   production prompt (with restatement requests for copied sentences, as the app does) — then Continue (initial recap,
   production-style addition, neutral rewrite) and a repeat-latency group (12 conversations × 3 repeats, run after waiting for
   a quiet machine: no xcodebuild/swift/other model runs and load average < 3.5, up to 10 minutes).
5. **Judging**: 65 batches of 2–3 conversations; each judge sees transcript, reference facts, `must_not`, `uncertain`
   and 6 anonymous summaries (3 models × 2 configurations, shuffled), split into numbered units. Output per summary: claims
   and unsupported/ambiguous claims per unit, fact coverage (full/partial/none with the covering units), must_not
   violations, uncertainty handling, correction handling, quality ratings (natural, readable, repetition 5 = none),
   vague-agent count. The id key was kept in a different directory and the judges were told not to open it. The batch
   generators put model identity nowhere in the batch. 660 main + 180 Continue summaries were judged; completeness was verified
   (2 of 660 summaries had a unit/fact id mismatch, kept).
6. **Metrics**: precision, recall (full = 1, partial = 0.5), critical recall, hallucination rate (share of summaries with ≥ 1
   unsupported claim), must_not violation rate, correction accuracy, uncertainty overstated, ratings; **prod_final** derives
   from the unit-level judgments by dropping the units the ported validator removes (and counting a summary the engine would
   reject as "no summary", recall 0). Paired bootstrap over conversations (4000 resamples) for model differences.

## Fairness measures

- Same transcript text, same neutral instruction text, same token cap (500; Continue additions 250), greedy decoding.
- Each open model used its own chat template via `tokenizer.apply_chat_template`; Qwen with `enable_thinking=false`.
- Output length is reported (neutral English median 149 / 138 / 128 words for Apple / Qwen / LFM; Chinese 183 / 181 / 158 CJK
  characters); no model was allowed a longer budget.
- The judge is not a candidate model. No candidate graded any output.
- Raw output, post-processed output and parse status are all stored; nothing was discarded. LFM Continue additions: 23/30
  JSON answers needed repair, 2 failed (their text was used as the addition).
- Neutral and production configurations are never mixed in one table.

## Known gaps relative to the app

- Model-based grounding (`evidence`) request and the real Swift `RecapValidator` are not run; `sb/post.py` is a port.
- Production instructions are English only; Chinese recaps depend on the model choosing the language.
- Apple's guided decoding vs. prompt-described JSON for open models is how the app works today, but it is an asymmetry.
- Apple memory unobservable; open-model memory is MLX peak/active and process RSS.
- Timing: Apple time = bridge request → complete stream; MLX time = request → final token (after the shared instruction prefix is cached).

## Reproduce

```
cd tools/summary_bench
../model_bench/.venv/bin/python sbench.py run --model qwen35-4b --set dev --stride 2 --limit 12 --tasks neutral,prod,continue --phase pilot
./run_final.sh
python3 judge_pack.py final final ../../results/summary_model_bench/judging/main 2   # then judge, then:
python3 aggregate.py final final ../../results/summary_model_bench/judging/main ../../results/summary_model_bench/metrics_main.json
python3 aggregate_cont.py; python3 bootstrap.py; python3 latency_report.py
```
(`aggregate.py` expects `KEY_DO_NOT_SHARE.json` in the judging directory root; it is copied there from `keyvault/` after judging.)
