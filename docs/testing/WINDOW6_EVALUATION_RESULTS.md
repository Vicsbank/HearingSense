# Window 6 — Evaluation Results

Date: 2026-10-10. Branch `feature/window6-semantic-intelligence`.

**Where every number comes from.** Mac (M1 Max, macOS 27.2) unless a row says Simulator. The
iPhone was not used in this window (the student's instruction: Simulator only). All text is
synthetic and was written for this project; no real conversation was recorded, transcribed or
evaluated. Nothing here measures real-world accuracy, an iPhone's speed, battery or heat.

Reproduce:

```bash
cd packages/HearingSenseKit
swift test                                           # 395 tests (Mac)
tools/run_semantic_eval.sh dev | heldout [no-triage] # ~4–5 min each, forward-only inference
swift run hs-semantic-eval recap --split dev|heldout --texts
swift run hs-attention-eval island-icon-sheets <dir> # icon pictures
tools/window6_sim_screens.sh <sim UDID> <HearingSense.app> <dir>
```

Raw output: `results/semantic_eval_window6/`, `results/conversation_eval_window6/`,
`docs/device-tests/window6-icons/`, `docs/device-tests/window6-simulator/`.

## 1. Build and tests

| Check | Environment | Result |
|---|---|---|
| `swift test` | Mac | **395 tests, every run passed** (the opt-in real-model test of Window 3 is skipped as before; 314 before Window 6; 81 new: 41 semantic attention incl. goal matches in the attention engine and the datasets, 34 conversation, 3 Window 6 presentation, 3 icon catalog) |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27 Simulator, iPhone 18 Pro Max | **TEST SUCCEEDED** (same suites; the recognizer tests are skipped there as before) |
| App + widget extension, Debug | Simulator build | Succeeded, no warnings from the app's sources |
| App, Release, unsigned | generic iOS device | Succeeded |
| Physical iPhone | — | **Not run** |

## 2. Semantic attention

### 2.1 Data

`Sources/SemanticEvaluation/Resources/semantic_dev.txt` (80 utterances, one profile) and
`semantic_heldout.txt` (119 utterances, three profiles). Each line has a category, the expected
outcome and a reason. Labels: *relevant* (an alert is wanted), *irrelevant*, *repeat* (said
before: no second alert), *ambiguous* (either is defensible; reported, not scored).

- The prompt, the verifier's rules and the embedding threshold were developed on the
  **development set only**. The held-out set was written before any tuning and run **once** per
  configuration, after the prompt was frozen. Nothing was changed after looking at it.
- Two of the three held-out profiles (traveler, worker) use goals that do not occur in the
  development set, so the held-out numbers include goals the prompt was never tried on.
- One change was made after the held-out run: the verifier now also removes a model-written
  *reason* that names a number or day that was not said (found in the Simulator demo, not in the
  held-out output). It changes text shown in the app, not a verdict, so the metrics are unaffected.

Categories: obvious, implicit (no shared word), causal, third person, negation, hypothetical,
sarcasm/quotation, recognition errors, incomplete, repeated, ambiguous, unrelated.

### 2.2 Methods

1. **Keyword baseline** — an alert when the utterance shares a (stemmed) content word with a goal.
2. **Sentence-embedding retrieval** — Apple `NLEmbedding.sentenceEmbedding`, cosine similarity to
   the closest goal, threshold chosen for best F1 on the development set (0.60).
3. **Production pipeline** — gate → one-word first pass → full judgement by Apple Foundation
   Models (guided generation, greedy) → deterministic verifier → novelty.
4. Open-source model — **not evaluated** (needs a download and the student's approval; see
   `docs/research/SEMANTIC_MODEL_COMPARISON.md`).

### 2.3 Held-out set (the result to quote)

58 relevant, 43 irrelevant, 4 repeats, 14 ambiguous. 95 % Wilson intervals in brackets.

| | Keyword | Embedding | Foundation Models pipeline |
|---|---|---|---|
| Precision | 62.2 % (23/37) [46–76] | 56.2 % (54/96) [46–66] | **90.9 % (50/55) [80–96]** |
| Recall | 39.7 % (23/58) [28–53] | 93.1 % (54/58) [84–97] | **86.2 % (50/58) [75–93]** |
| F1 | 0.48 | 0.70 | **0.89** |
| False alerts on irrelevant utterances | 27.9 % (12/43) | 88.4 % (38/43) | **11.6 % (5/43) [5–25]** |
| Second alert for a repeated statement | 2/4 | 4/4 | **0/4** |
| Important events missed | 6/7 | 0/7 | **0/7** [0–35] |
| Goal named correctly (of correct alerts) | 20/23 | 25/54 | 48/50 |

Implicit relevance (the category the brief asks about: relevant without a shared word):
keyword 10/28, embedding 26/28, pipeline 24/28. Causal: 2/7, 6/7, 5/7. The embedding's recall is
bought with alerts on almost everything (it alerted on 15 of 18 unrelated utterances); it cannot
tell a goal's topic from a consequence for the listener.

By category, pipeline: obvious 11/13, implicit 24/28, causal 5/7, recognition errors 7/7,
negation 5/7, hypothetical 7/7, sarcasm/quotation 4/4, third person 7/10, repeated 4/4,
unrelated 18/18.

By profile, pipeline: student 30/32 relevant found, 3/30 false alerts; traveler 12/12, 2/9;
**worker 8/14**, 0/8. Four of the six misses in the worker profile belong to one goal ("Notify
me when a customer order is ready or a customer needs help": "Order forty-two is ready at the
counter", "The oat latte for Maya is up", a refund request, a waiting table); the other two are
"Hey, do you work here?" and a request to stay late that the model filed under someone else. The prompt's
examples are about school, emergencies and being addressed; a goal about a service counter was
handled worst. This is the clearest measured weakness.

The 13 errors of the pipeline are listed in `results/semantic_eval_window6/heldout_triage.txt`.
False alerts: two other-people statements ("My dad's work schedule changed…", "Their school had
to evacuate last year…"), another flight's cancellation, and two "nothing changes" statements
("She did not move the deadline, it's still due Friday").

Ambiguous items (14): 8 alerted, 0 kept as uncertain, 6 nothing. The pipeline rarely says
"uncertain" by itself; uncertainty mostly comes from the verifier.

### 2.4 Development set (tuned on; for comparison only)

Pipeline: precision 94.1 % (32/34), recall 100 % (32/32), false alerts 6.1 % (2/33), important
missed 0/5, repeats 0/2. Keyword: recall 18.8 %, false alerts 12.1 %. Embedding: recall 100 %,
false alerts 87.9 %. The gap between this and §2.3 is what tuning on a set is worth.

First version of the prompt on the development set, before tuning: precision 84.6 %, recall
68.8 %, 2 of 5 important events missed. Four defects were fixed on development data: class-wide
announcements judged "about someone else"; "excuse me" not recognized for a goal about being
addressed; repeated announcements filed under another goal and alerted again; 3.4 s per judgement.

### 2.5 False alerts per hour

Not measured: there is no hour of real conversation. **Derived**: the false-alert rate times an
assumed 240 irrelevant utterances per hour (continuous talk, one finished sentence every 15 s):
pipeline 28 per hour on the held-out rate, keyword 67, embedding 212. The held-out irrelevant
items are deliberately hard (other people's exams, other flights, "nothing changes"); on its 18
plainly unrelated utterances the pipeline alerted 0 times. The true rate depends on what people
around the user talk about and is unknown. The attention engine's presentation budget (4 per
window in Balanced) bounds what is shown, whatever the rate.

### 2.6 Latency and cost (Mac)

| | Median | p95 / max |
|---|---|---|
| First pass (one word) | 0.61 s | max 0.91 s |
| Full judgement | 2.73 s | p95 3.00 s |
| Utterance stopped by the first pass (40 of 119 held-out) | 0.61 s | |
| Utterance that reaches a verdict with the first pass on | 3.57 s | max 4.96 s |
| Irrelevant utterance, first pass on / off | 0.81 s / 2.60 s (mean 1.52 s / 2.64 s) | |
| Keyword, embedding | < 0.01 s | |
| Attention engine, per input (Window 4) | microseconds | |

- The first pass removed 34 % of all held-out utterances and changed no outcome: the same 8
  relevant items are missed with it on and off. It costs 0.6 s on everything that passes.
- A prepared session did not shorten a judgement (2.2–2.9 s with and without a 1.5 s warm-up).
- Window 3 measured the same model 2–3× faster on the iPhone 18 Pro than on this Mac for its
  short headline (0.68 s vs ≈ 2 s). **Whether that holds here is not known.**
- In the Simulator demo, sentences arriving every 1.6 s outran the model: decisions came 4–9 s
  after the utterance, and the bounded queue dropped the oldest. In lively conversation the
  pipeline cannot judge every sentence in time; it judges the newest.
- Memory: the tool's own process stayed at 23–35 MB. The language model runs in a system process
  that this measurement does not see. Energy and heat: not measured.
- Failure behaviour (unit tests): model unavailable, failing or slower than 8 s → no alert and no
  guess from keywords; full queue → oldest dropped and counted; reset → nothing remembered.

## 3. Conversation recap

Data: `Resources/conversations.txt`, 8 synthetic conversations (3 development, 5 held-out) with
the facts a recap must contain (51 facts, 7 of them negations), two with missing speech, two
with a "said later" part. A fact counts as recalled when its words occur in the recap (by stem).
The recap prompt was adjusted on the development scenes (key points as full sentences; title
check relaxed) and then run once on the held-out scenes.

| | Development (3) | Held-out (5) |
|---|---|---|
| Summaries written | 3/3 | 5/5 |
| Facts recalled | 13/13 | **26/26** |
| Negations kept | 3/3 | **4/4** |
| Statements removed by the lexical checks | 5/29 | 6/62 (10 %) |
| Continued session: earlier facts kept / later facts added | 4/4, 2/2 | 6/6, 1/1 |
| Missing speech stated (caveat) | 1/1 | 1/1 |
| Model time per recap | median 6.1 s, max 7.2 s | median 6.8 s, max 8.5 s |

**Manual read of the held-out texts (by the assistant, one reader; the texts are in
`results/conversation_eval_window6/recap_heldout.txt`):** of 56 statements that passed the
checks, 2 are not supported by the conversation ("Someone agreed to use the south lot", "The
decision … is final", both in the announcement scene) — about 4 %. No number, day, time or name
was wrong. Recurring weakness: the model frames announcements as agreements ("They agreed…").
In the development scene c01 one sentence reverses a statement ("Saturday at ten won't work"
where the speakers settled on Saturday at ten); the key points beside it are right. **The
lexical checks cannot catch a false sentence made of words that were said.**

Continued session: after "he moved it to Wednesday… so no key needed" the updated recap states
the change, but the earlier key points ("coming on Tuesday", "key with the neighbor") stay
beside it. Earlier details are preserved by design; a correction is added, not reconciled.

Other measures the brief names:

- **Two-minute recall, omissions**: fact recall above. No test with real speech or with
  recognition errors in a long conversation.
- **Number fidelity**: a number, day or time that is not in the transcript cannot appear in a
  shown recap (the sentence is removed; unit-tested). On held-out, 2 of the 6 removed statements
  were removed for that reason.
- **Topic segmentation**: by pauses only (25 s). Unit-tested on scripted timelines (the excerpt
  stops at the last long pause; an older conversation in the same two minutes is left out). A
  change of topic **without** a pause is not detected: scene h04 (octopus documentary, then the
  lake plan) is summarized as one conversation.
- **Caption latency**: not measured in this window. Captions show the recognizer's own partial
  and final results; Window 3 measured the final transcript 0.81 s after the end of speech on
  the iPhone.
- **Missing speech**: unit-tested (too little speech → the app says so and does not call the
  model; no model → no summary is invented and no transcript is saved in its place).

## 4. Icons

- Coverage test: all 303 labels resolve to an icon; 160 through a label entry, 142 through their
  kind, 1 (`silence`, never an event) through its category. Every SF Symbol name exists on the
  installed system (test); the nine custom names are all used and never mistaken for SF Symbols.
- Visual review at island sizes, rendered on the Mac from the widget's own views:
  `docs/device-tests/window6-icons/representative_island_sizes.png` (22 sounds at compact 15 pt,
  minimal 14 pt, expanded 26 pt, light background), `custom_glyphs.png`, `all_labels_1/2.png`.
  Reviewed by the assistant; two rounds of corrections (size, a drawing bug that joined strokes,
  the glass drawing, the crying face's brows).
- Gallery in the app: seen in the Simulator (`docs/device-tests/window6-simulator/06-icons.png`).
- **Not done:** a look at a real Dynamic Island. The pictures are renderings, not photographs;
  `simctl` screenshots leave the island out. Whether the cough and sneeze glyphs read correctly
  at a glance is the student's call (they are a head with an open mouth and marks or droplets).

## 5. Simulator (iPhone 18 Pro Max, iOS 27; microphone off)

`--hs-conversation-demo` plays 11 scripted sentences through the real buffer, semantic engine
and recap engine (the Simulator has the language model; it has no speech recognizer).

| Check | Result |
|---|---|
| Goal matches from the real model | Shown in Attention goals with the sentence, the reason and the checks applied; passed to the attention engine ("Matches Your Goal" on the Attention card) |
| Recap after the scripted Action Button press | Written in 8.6 s, saved, shown; one earlier run ended with "a summary could not be written" while goal matching was using the model at the same time — goal matching now pauses during a recap |
| Continue Understanding | Live captions with times, a marked tentative line, "Stop Following" |
| History | Record with title, summary, key points, note, dates, status |
| Privacy screen, icon gallery, main card | Rendered |
| Recap states in the Dynamic Island | **Not seen** (screenshots omit the island); tested at pipeline level |
| App Intents (`RecapConversationIntent`) | Compile and are registered; **not invoked** from Shortcuts or the Action Button |
| VoiceOver, Dynamic Type at accessibility sizes | **Not exercised** (labels and adjustable sizes are in the code) |

## 6. Regression

All 314 earlier package tests pass. The only edits to them are expected icon names in the
icon-stream, pipeline and catalog tests (speech is `bubble.left.fill`, the door kind `hs.knock`,
laughter `hs.laugh`). Window 3's engine tests pass with the per-utterance output added. The sound
classifier, the capture path and the Live Activity code paths were not changed; **the A2
background behaviour and the Window 5 device results were not re-run.**

## 7. Not validated

- Anything on the iPhone: speed and availability of the language model in the background and
  while locked, the Action Button, the App Intent on a locked phone, battery, heat, memory.
- Real speech: recognition errors in context, several speakers, noise, music.
- The false-alert rate in real surroundings.
- Goals outside the three profiles; languages other than English.
- A user with hearing loss using the conversation screen.
