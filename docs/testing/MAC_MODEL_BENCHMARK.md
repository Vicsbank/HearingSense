# Mac local model benchmark — how it is run

Branch `research/local-model-comparison` (worktree `.claude/worktrees/model-bench`, based on `197d0d0`).
Research only: nothing here changes the app or the production model. Mac only (M1 Max, 32 GB,
macOS 27.2); no iPhone, no microphone, no training, no server-side model.

## What is compared

| Tag | Model | Checkpoint | Runtime | Licence |
|---|---|---|---|---|
| `apple-guided` | Apple AFM 3 Core, answer constrained to a schema | system model | FoundationModels, `SystemLanguageModel.default` | system |
| `apple-text` | Apple AFM 3 Core, plain text answer | system model | same | system |
| `lfm25-1.2b` | LFM2.5-1.2B-Instruct (1.17 B) | `lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit`, 0.66 GB | mlx-lm 0.32.0 | LFM Open License v1.0 |
| `qwen35-2b` | Qwen3.5-2B (2.27 B, multimodal; text only here) | `mlx-community/Qwen3.5-2B-MLX-4bit`, 1.74 GB | mlx-lm 0.32.0 | Apache-2.0 |
| `lfm25-2.6b` | LFM2.5-2.6B | `LiquidAI/LFM2.5-2.6B-MLX-4bit` — not downloaded | mlx-lm | LFM Open License v1.0 |
| `qwen35-4b` | Qwen3.5-4B | `mlx-community/Qwen3.5-4B-MLX-4bit` — not downloaded | mlx-lm | Apache-2.0 |
| `gemma4-e2b` | Gemma 4 E2B-it | `mlx-community/gemma-4-e2b-it-4bit` — not downloaded | mlx-lm | Apache-2.0 (Google's card) |
| `gemma4-e4b` | Gemma 4 E4B-it | `mlx-community/gemma-4-e4b-it-4bit` — not downloaded | mlx-lm | Apache-2.0 (Google's card) |

Licences as read on 2026-10-11. LFM Open License v1.0: free use, including commercial use, for
organisations under 10 million US dollars of annual revenue; above that, commercial use is not
licensed. Gemma 4: Google's model card says Apache 2.0; the `mlx-community` conversions carry the
older tag `gemma`, which is a labelling difference in the conversion, not a second licence text
that was read. Qwen3.5: Apache 2.0 licence file in the repository.

## Layout

```
tools/model_bench/
  bench.py            command line: check, show, run, stream, score
  models.json         the model tags above
  mb/common.py        datasets, request text, answer parsing, scoring
  mb/backends.py      MLXBackend (in process) and AppleBackend (through the bridge)
  mb/sysmon.py        memory, swap, thermal state, other benchmark runs
  apple_bridge/       Swift program: one JSON request per line -> SystemLanguageModel.default
  data/hs_dev.txt, general_dev.txt        development sets (pilot, format checks)
  data/hs_final.txt, general_final.txt    held-out sets — not to be tuned on
results/local_model_comparison/<phase>/   raw answers (.jsonl) and run records (.meta.json)
results/local_model_comparison/logs/      install, download and build logs
```

Setup: `python3 -m venv tools/model_bench/.venv`, `pip install mlx-lm mlx-vlm psutil`, and
`swift build -c release` in `tools/model_bench/apple_bridge`. `bench.py` sets `HF_HUB_OFFLINE=1`:
it never downloads; a checkpoint that is not on disk fails to load.

## The two tasks

**Hearing Sense relevance (primary).** One request per sentence. The model gets the same
instructions for every profile, then facts about the listener, the listener's goals, earlier lines
if any, and the new sentence. It answers with one JSON object:
`{"relevant": true|false, "goal": "<key or none>", "urgent": true|false}`, at most 40 tokens.
`hs_final.txt`: 288 sentences, 8 profiles, 19 categories, 117 relevant. The categories cover plain
and implicit relevance, news about other people that does or does not matter, speech addressed to
others, announcements to groups the listener is or is not in, relevance that depends on earlier
lines, small talk, "nothing changes" against "the not is the news", wishes, the past, idioms and
sarcasm, danger and danger words without danger, repetitions and updates.

**General abilities (secondary).** `general_final.txt`: 120 short items, twelve in each of logic,
instruction following, meaning, cause, negation, hypotheticals, context, ambiguity, structured
output, one-sentence summaries. Graded by exact answer (a right answer wrapped in extra words is
wrong: the format is part of the task), by JSON equality, or — summaries — by required and
forbidden words and a length limit. No single score is reported across categories.

Both sets were written for this benchmark, by one author, in English, before any model ran on
them. They are not public benchmarks: the numbers compare the models tested here with each other.
About 40 % of the relevance sentences are relevant, far more than in real surroundings, so
precision in daily use would be lower than measured here.

## Fairness

- Same sentences, same labels, same instruction text and same token limit for every model.
- Each open-weight model gets the text through its own documented chat template (system + user
  turn). Models with a thinking switch run with thinking off; a thinking run, if made, is a
  separate tag and its timings are never mixed with the normal ones.
- Greedy decoding everywhere (temperature 0 in MLX, `.greedy` in FoundationModels).
- Parsing is reported apart from meaning: `ok` (the reply is exactly one valid JSON object),
  `repaired` (the decision could be read from a reply that was not), `failed` (no decision; counted
  as "not told"), `error` (the runtime refused or failed). Nothing is discarded.
- A longer answer earns nothing: only the three fields are read.
- The request text may be adjusted on the development sets only. It is frozen, together with every
  setting, before the first run on a final set; a configuration changed afterwards is a new
  configuration and its final-set result is no longer untouched.

## What is not measured the same way

| | Open-weight models (MLX) | Apple AFM 3 Core |
|---|---|---|
| Structured answer | free text; JSON asked for in the instructions | `apple-guided`: decoding constrained to the schema by the framework; `apple-text`: free text like the others |
| Load time | `mlx_lm.load` plus evaluation of the weights, in this process (file cache state noted) | not observable: the model lives in a system service that may already be loaded |
| Memory | MLX peak and active memory, process RSS | not observable from the benchmark process |
| Shared instructions | keys and values computed once, each request continues from a copy | a prepared session per request (`prewarm()`), cached tokens as reported by the framework |
| Token counts | from the tokenizer | from `Response.usage` |
| Time to first token | first streamed piece | first streamed snapshot (for a guided answer this is the first partial object) |

## Running

```
cd tools/model_bench
.venv/bin/python bench.py check
.venv/bin/python bench.py show --model qwen35-2b --task hs --set hs_dev
.venv/bin/python bench.py run --model qwen35-2b --task hs --set hs_dev --limit 20 --phase pilot
.venv/bin/python bench.py run --model qwen35-2b --task general --set general_dev --phase pilot
.venv/bin/python bench.py stream --model qwen35-2b --set hs_dev --pattern 1.5s --phase pilot
.venv/bin/python bench.py score --phase pilot
```

One model per process, one request at a time, models one after another. `run` and `stream`
refuse to start while a benchmark of another development window is running (`hs-semantic-eval`,
`w63_probe`), and record memory pressure, swap and thermal state before and after. Two warm-up
requests after each load are neither scored nor timed; the time of the very first one is kept
separately as the first request after a load.

`stream` replays sentences on a clock (every 3 s, 1.5 s, 1 s, or irregular bursts) into a bounded
queue with one request at a time. A sentence that finds the queue full pushes out the oldest one;
a sentence that waited longer than the expiry time is not asked. Dropped and expired sentences are
written out and counted, with how many of them were relevant.
