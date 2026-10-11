# Semantic Model Comparison (Window 6)

Question: which model should decide whether something said nearby matters for one of the
user's goals, and is a model other than Apple's justified?

Short answer: **Apple Foundation Models stays.** On held-out synthetic text it is far better
than keywords or sentence embeddings (F1 0.89 against 0.48 and 0.70) and it missed none of the
seven important events. Its measured weaknesses are speed (2.7 s per full judgement on the Mac)
and goals unlike its prompt's examples (8 of 14 found for a shop worker's goals). Neither has
been measured on the iPhone, and no open-source model has been run, so replacing it is **not
justified by any evidence yet**. What would justify a test is described in §4.

All numbers: `docs/testing/WINDOW6_EVALUATION_RESULTS.md`. Mac only, synthetic text only.

## 1. What was compared

| | Keyword overlap | `NLEmbedding` sentence similarity | Foundation Models + verifier |
|---|---|---|---|
| Runs | everywhere | on device, CPU | on device, system model |
| Download | none | none | none (part of Apple Intelligence) |
| Held-out precision / recall | 62 % / 40 % | 56 % / 93 % | **91 % / 86 %** |
| False alerts on irrelevant speech | 28 % | 88 % | **12 %** |
| Implicit relevance (28 items) | 10 | 26 | 24 |
| Negation, hypothesis, quotation, other people (28 items) | 14 | 5 | 23 |
| Time per utterance (Mac) | < 10 ms | < 10 ms | 0.6 s (stopped by the first pass) to 3.6 s |

Reading:

- **Keywords** find what names the goal and nothing else. "The exam has been postponed until
  Friday" shares no word with "anything that could affect my grades". They also alert on a
  friend's grade and on "what if they made us work on New Year's Day".
- **Sentence embeddings** measure closeness of topic. With the threshold that is best on the
  development set they alert on almost everything, including "I spilled coffee all over my
  keyboard". A higher threshold loses the implicit cases first. They cannot represent "this
  changes something for the listener", negation, or who is affected. In the engine they are used
  only to pick the closest goals when there are more than six.
- **Foundation Models** is the only method that does the task. Guided generation makes it fill
  a small structure in a fixed order: is it about other people only → what kind of statement →
  what would change for the listener → goal → verdict → headline → urgency.

## 2. Foundation Models: what was measured

Strengths (held-out): recognition errors 7/7 ("the final has been moved up to next choose
day"), hypotheticals 7/7, sarcasm and quotations 4/4, unrelated talk 18/18, important events
7/7, goals it had never been tuned on for a traveler 12/12.

Limitations:

1. **Speed.** 2.7 s per full judgement on the M1 Max, 0.6 s for the one-word first pass. The
   input is short; most of the time is the instructions and the schema, processed again for
   every utterance (a fresh session per utterance is deliberate: nothing overheard is carried
   over). Preparing a session in advance did not help. Sentences that arrive faster than this
   are judged late or dropped (bounded queue, newest first).
2. **Goals unlike the examples.** The prompt explains by example (grades, emergencies, being
   addressed). A goal about customer orders was handled poorly (4 of its positives missed).
   Examples generalize unevenly; a longer prompt costs time on every utterance.
3. **"Nothing changes" and other people.** 2 of 7 negation items and 3 of 10 third-person items
   alerted wrongly ("She did not move the deadline, it's still due Friday").
4. **It rarely says "uncertain".** Of 14 ambiguous items none came back as uncertain; the
   verifier produces most of the uncertainty.
5. **Its free text needs checking.** Headlines dropped a negation often enough that the verifier
   withheld 9 of them on held-out; a reason named a day nobody said (Simulator demo).
6. **One model, several users.** Goal matching, recaps and (if switched back on) Window 3's
   headlines share it. A recap failed once while goal matching was running; goal matching now
   pauses for a recap.
7. **Availability.** It needs Apple Intelligence to be on and the model to be ready, and English
   prompts were used. Background and locked-screen behaviour on the iPhone: one Window 3
   observation (it ran, 6.1 s instead of 0.7 s), nothing from this window.
8. **Not measured:** memory of the system process, energy, heat, context-window limits with long
   goals, behaviour after hours of use.

## 3. What the deterministic layer adds

The model's answer is treated as untrusted. `EvidenceVerifier` can only make a decision more
cautious: a hypothesis, a quotation or an unclear fragment becomes "uncertain" (listed in the
app, never an alert); "nothing changes" becomes irrelevant; a statement about other people only
becomes uncertain; a headline that adds words, loses a negation or changes a number is withheld;
poor recognition quality caps the result at uncertain. On held-out it applied 17 corrections. The
novelty rule removed all four repeated announcements. Without the model there is no semantic
alert at all: the engine never falls back to keywords.

## 4. Open-source alternatives

**None was downloaded or run** (the project's rule: large downloads need the student's approval
with sizes and times; no training or fine-tuning). What follows is a plan, not a result.

When a test would be justified: after an iPhone measurement, if (a) a full judgement takes more
than about 1.5 s there, or (b) the model is not available in the background, or (c) recall on
goals outside the prompt's examples stays where the worker profile is.

What to look for: a small instruction-following model (roughly 1–4 billion parameters, 4-bit
quantized) with reliable JSON or grammar-constrained output, a licence that allows this use, and
an iPhone runtime (MLX Swift or a Core ML conversion; llama.cpp only as a comparison). Candidate
families to check at the time, not endorsed here: Qwen, Phi, Gemma, Llama and SmolLM in their
small instruct variants. Their current versions, licences and sizes must be read from the
sources when the test is prepared; none was verified for this document.

Costs to state in the approval request (typical orders of magnitude, to be replaced by the
actual figures of the chosen file): download 1–3 GB per model; the same again on the iPhone;
1.5–4 GB of memory while loaded, on top of the app's audio and the system's own models; on the
Mac a few minutes for the held-out set per model. A model inside the app would also have to
run in the background, where this project has already seen Apple's own classifier fail under
one configuration (the cause was suspected to be background GPU work and was never confirmed).
That risk is specific to this app and can only be settled on the iPhone.

How it would be judged: the same `hs-semantic-eval` sets (a new held-out set should be written
first, since this one has now been seen), the same verifier, and three numbers side by side with
Foundation Models: held-out F1, important events missed, median time per utterance **on the
iPhone**. A desktop result would not count as evidence for the phone. A smaller, faster model
with equal F1 would be preferred to a larger, slightly better one.

Cheaper things to try first, all without a new model: per-goal examples written by the user
("for instance…") appended to a goal; a shorter prompt with the examples chosen per goal; one
session per conversation instead of per utterance, if a privacy rule for clearing it can be
kept; running the first pass only when the embedding score is below a calibrated floor.

## 5. Decision

- Production reasoning model: Apple Foundation Models (`SystemLanguageModel.default`, on device;
  never Private Cloud Compute), behind `SemanticRelevanceReasoning`, so another model can be put
  in its place without touching the engine, the verifier or the evaluation.
- Sentence embeddings: goal selection only. Keywords: baseline only.
- Open-source model: not justified now; revisit with iPhone measurements.
