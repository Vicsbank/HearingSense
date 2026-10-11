# Window 6.1 — Semantic Intelligence: Accuracy and Latency Optimization

Date: 2026-10-10/11. Branch `feature/window6-semantic-optimization`, worktree
`.claude/worktrees/window6-opt`, from the Window 6 baseline `ead23f3`. Not merged, not pushed,
not rebased onto Window 5. Numbers, methods and commands:
`docs/testing/SEMANTIC_OPTIMIZATION_BENCHMARK.md`.

**Evidence level.** Mac (M1 Max) with the real on-device language model, synthetic text; package
tests and app builds for the iOS Simulator. No microphone, no physical iPhone, no model training,
no download, no change of model (Apple Foundation Models throughout).

## 1. Result in one table

Sealed set, 220 synthetic utterances written before any change, run once per configuration.

| | Window 6 | Window 6.1 | Target |
|---|---|---|---|
| Recall | 73.3 % (77/105) | **98.1 % (103/105)** | ≥ 95 % — met |
| Implicit relevance recall | 76.2 % (32/42) | **97.6 % (41/42)** | ≥ 95 % — met |
| Precision | 90.6 % (77/85) | **86.6 % (103/119)** | ≥ 95 % — **not met, and lower than before** |
| False-positive rate | 8.3 % (8/96) | 16.7 % (16/96) | |
| Important events found | 11/16 | **16/16** | |
| Short urgent instructions found | 8/12 | **12/12** | |
| Utterances lost to a model failure | 3 | 0 | |
| One judgement (Mac, prepared session) | 2.74 s | **1.2–1.4 s** | |
| End to end at one sentence every 3 s, p50 / p95 / p99 | 3.86 / 8.89 / 9.69 s | **1.47 / 2.21 / 2.92 s** | p50 ≤ 1.5 s — met at this rate |
| Sentences dropped at one every 1.5 s | 11 of 37 (3 relevant) | 0 | |
| Model-written text shown to the user | headline, reason | none | |

In short: the engine now finds almost everything it should and decides in about half the time,
and it pays for that with twice as many false alerts. Section 7 says what that means for the
configuration to ship.

## 2. Why Window 6 missed things (error analysis)

On the new development set (171 utterances) Window 6 missed 20 of 82 relevant utterances:

- **10 were stopped by the one-word first pass** before the full judgement saw them — among them
  "Stay away from the window." and three sentences addressed to the listener. The first pass was
  the largest single source of misses, and on the sealed set too (15 of 28).
- **3 were lost because the model request failed**; the engine answered "irrelevant" and the
  utterance was gone ("The baby's got hold of the scissors." was one of them).
- 5 were judged irrelevant (indirect consequences: "The school is closing at noon because of the
  storm." for a goal about picking up children); 2 were demoted as "about someone else".

Its 6 false alerts: past events, sarcasm, an impression of someone talking, another group's
deadline, a repetition introduced by "One more time".

The weakness reported in Window 6 — goals unlike the prompt's examples — showed again: on the
sealed set it found 12 of 25 in the clinic profile and 16 of 24 in the shop profile.

## 3. What was changed

### 3.1 Reasoning (prompt and answer form)

- **The instructions describe what makes a sentence matter instead of listing examples from one
  setting**: something is different, ready, waiting or needed; someone speaks to the listener; a
  danger or an instruction to move. This is what lifted the clinic and shop profiles (24 of 25
  and 23 of 24 on the sealed set).
- **Three fields, all enumerations, no free text**: `kind` (others, past, reported, hypothetical,
  noChange, warning, request, change, other), `goal`, `verdict` (irrelevant, uncertain, relevant,
  urgent). The kind comes first, so the model decides what sort of sentence it is before it
  names a goal: the distinctions the brief asks for (explicit vs implied, negation,
  hypothetical, third person, announcement vs story) are answered as a field, not hoped for.
- **A "not" can be the news** ("will no longer be accepted", "do not use the stairs") is stated
  in the instructions; "nothing changes" is its own kind and is never an alert.
- **A warning belongs to the goal about danger; being addressed belongs to the goal about
  attention.** Before this line, every short command ("Duck!", "Watch out!") was judged
  relevant with no goal and discarded.
- **A second look** at utterances judged relevant (not at warnings): a separate, short question
  without the goals — is this about here and now, or about someone else, the past, a story, a
  wish, "nothing changes"? It can only take an alert back. On the development set it removed 9
  of 15 false alerts and no correct one.
- **No first pass.** With a 1.3 s judgement the 0.6 s first pass no longer pays, and it was the
  main cause of misses.
- **Repetition**: "Again, …", "One more time, …", "Just a reminder, …" are removed before two
  statements are compared ("one" had counted as a changed number).

### 3.2 Evidence and wording

Nothing the model writes is shown any more. The headline is the utterance's own words (cut at
12 words only if no "not", number, day or time would be lost; otherwise there is no headline
and the app shows the sentence). The reason is a fixed phrase plus the user's own goal. "The
exam may be canceled" therefore cannot become "The exam was canceled", and an announcement
cannot become an agreement: there is no generated sentence in which that could happen. Window 6's
verifier had to remove 20 model-written texts on the development set and 21 on the sealed set;
that class of error is gone by construction. What remains possible is a wrong *verdict*.

The deterministic verifier is unchanged in principle (only ever more cautious) and now also
applies the second look. No verification by lexical overlap was added, and no extra model pass
for claim checking beyond the second look: with no generated claims there is nothing to check.

### 3.3 Latency

Measured first, then changed (benchmark §5):

1. **Time is output tokens**: about 40 ms each. 75 tokens → 29–37 tokens.
2. **The system keeps what one session has read, for one session at a time.** A fresh session
   reads about 950 tokens of instructions for 1.2 s; preparing it ahead helps only if there is a
   pause. So one session answers six utterances in a row, and only the new sentence is sent.
3. **A longer session text makes every answer slower**, so the answer's form is sent on the
   first turn only and a session is replaced after six utterances.
4. After the second look (which needs its own session to be worth anything) the judging session
   is made ready again in the pause that follows.

Not adopted, each for a measured reason: sentence-embedding prefilter (relevant and irrelevant
sentences have the same similarity to the goals: no threshold rejects irrelevant ones without
losing relevant ones), group requests (13 relevant sentences waved through), an unconstrained
three-word answer (format not kept), plain `prewarm()` (no effect without the goals as prefix),
a free-text reasoning field (slower, not more accurate), running a judgement beside a recap (no
gain).

### 3.4 Queueing and contention

`ModelInferenceScheduler` (new, in `SemanticAttention`) is the one place that hands out turns
at the language model:

| Class | What | Behaviour |
|---|---|---|
| P0 | Acoustic warnings, the phrase rule ("Watch out!") | never come here: no language model, no waiting |
| `urgentCandidate` | a sentence that may be a warning but is not caught by the phrase rule | first in line; own lane in the engine |
| `userRequest` (P1) | the Action Button recap and its updates | next turn, ahead of goal matching |
| `attention` (P2) | finalized utterances | in order |
| `background` (P3) | early evaluation of partial transcripts | only while nothing finalized waits; served once after 6 s of waiting so it cannot starve |

One request at a time; bounded waiting per class; timeouts; cancellation; counts and waiting
times per class. The recap no longer pauses goal matching: with the pause Window 6 dropped 9 of
20 sentences that arrived around a recap; now none.

In the engine: up to 12 utterances wait; one that is pushed out or has waited 20 s is reported
with stage `dropped` and counted — nothing disappears without a decision. A decision later than
4 s is marked late and still made. Each decision carries its waiting time, model time, total
time and output tokens; the app's diagnostics show the medians (no text).

Warning-like sentences are recognized for *ordering only* by three kinds of cue — a word of
alarm, the form of a short command ("Don't …", "Stay …", an exclamation), a phrase about
something happening to the listener ("about to", "behind you") — 21 of 22 urgent or important
development sentences, 13 of 229 others. Whether it is a warning is the model's judgement, and a
sentence the cue does not flag is judged all the same.

### 3.5 Partial transcripts

`StablePartialDetector` (no clock of its own) offers a partial transcript once it has not
changed for 0.4 s (0.15 s if it ends a sentence), at most twice per utterance, compared by its
words (not its punctuation). The engine evaluates it only while nothing finalized is waiting,
stores the answer under the words, and uses it only if the final transcript has the same words.
A partial transcript never produces a decision, an alert, a saved record or a "said before"
entry. Measured gain: 0.4 s at the median, a worse 95th percentile (benchmark §5.3). The app
feeds it from `SpeechSemanticResult.volatileText`; **how Apple's recognizer revises real speech
was not exercised** (synthetic timestamps only).

## 4. Architectures compared

| | Tried as | Outcome |
|---|---|---|
| A. Single-pass structured reasoning | `compact`, `lean` | `lean` chosen as the first stage |
| B. Fast candidate stage + full reasoning | Window 6 first pass; embedding prefilter | rejected: the candidate stage causes the misses, and no cheap signal separates the classes |
| C. Context-aware incremental reasoning | a session kept for six utterances; the two sentences before as context | chosen for speed; side effect on precision suspected (§6) |
| D. Lightweight retrieval + model verification | sentence embeddings as retrieval | rejected with B |
| E. Selective second-pass verification | second look on relevant verdicts | chosen |
| F. Adaptive inference by uncertainty | warnings skip the second look; partial transcripts only when idle | partly |

## 5. What stayed the same

Sound classification, the 303 icon mappings and drawn glyphs, the Window 4 attention engine and
its phrase rule, the Live Activity pipeline and its no-screen-wake rules, the recap engine and
its checks, history, privacy switches, capture: not edited. Ordinary speech is still an icon
only; no automatic headlines; one microphone path. The app change is confined to
`ConversationIntelligenceController` (optimized reasoner, shared scheduler, partial transcripts,
diagnostics lines). 426 package tests pass on the Mac, the same suites in the Simulator.

## 6. Limitations

- **Precision 86.6 % on the sealed set.** Seven of the 16 false alerts are unrelated sentences
  filed under a goal ("We're having tacos tonight." → hours). On the development set that kind
  of error was rare (1–4 of 22). A likely cause, **not verified**: a kept session has just
  answered several relevant sentences and carries the pattern on; the sealed file has long runs
  of one kind. Testing it needs a new unseen set (the sealed one is spent): the same
  configuration with `sessionTurns: 1` against `6`.
- **"Urgent" is taken at the model's word.** A verdict of `urgent` skips the second look and is
  presented as a possible warning. In the Simulator demo (after the configuration was frozen)
  the model called "Fine, then let's split it, three pages each." urgent for the grades goal: an
  alert that the second look would probably have taken back. The fix that suggests itself —
  count `urgent` only together with kind `warning`, otherwise treat it as `relevant` — was
  **not made**, because it changes the pipeline that the sealed numbers describe; it should be
  made and measured on a new set.
- The app's match list shows the goal twice (once in the fixed-word reason, once on its own line).
- **Run-to-run spread.** The same configuration gave 5 and 8 false alerts on the development
  set: with a kept session a judgement depends on the sentences before it.
- **Dense speech.** About 31–33 sentences per minute on the Mac. Faster than that for long, and
  decisions arrive up to 20 s late before sentences are given up (reported).
- **A recap blocks the model for about 7 s**; a spoken warning outside the phrase rule waits.
- "Nothing changes" and other people's affairs still cause false alerts (6 of the 16).
- A kept session holds the last few utterances in memory until it is replaced, the session ends
  or speech data is cleared (`forget()`); Window 6 held none between requests.
- English only; depends on Apple Intelligence; all labels and sentences are by one author.
- Memory, CPU/GPU, energy and heat of the model process were not measured.

## 7. Recommendation

**Production configuration: the Window 6.1 engine as frozen**, for an awareness aid in which a
missed "everyone out" or "you're next" costs more than an extra entry: recall 73 → 98 %, every
important event and every short urgent instruction found, no utterance lost to a failed request,
no generated wording, half the latency. Its alerts for goal matches are non-interrupting
(Window 4 budget, no expansion, no sound), which bounds what the extra false alerts cost.

The honest alternative, if false alerts turn out to bother more than misses: keep the Window 6.1
engine and set `sessionTurns: 1` (independent judgements; 1.4 s with pauses, 2.6 s without) —
after testing on a new set whether that restores precision. Going back to the Window 6 prompt is
not recommended: its misses are structural (first pass, failed requests).

**Model comparison.** Apple Foundation Models stays. It does not reach 95 % precision and 95 %
recall together on this task in any configuration tried, and its speed is bound to output
tokens and to one cached session. Whether a compact open model would do better is unknown; no
model was downloaded or run. If the student wants that experiment later, it needs a separate
approval with model, licence, size, memory and an evaluation plan (a new sealed set, the same
`hs-semantic-eval` runs); nothing here suggests it is urgent before iPhone timings exist.

## 8. For the iPhone (not done; each step needs the student's authorization)

1. Build and install; with a spoken script, read ten development sentences: time from the end of
   a sentence to the decision, foreground and background (the diagnostics export has the medians
   of waiting and total time, second looks, early evaluations, late decisions).
2. Check that a kept session survives the app going to the background and the screen locking
   (Window 3 saw the model take 6.1 s instead of 0.7 s in the background once).
3. Real partial transcripts: how often the early answer is used and abandoned (two counters).
4. A recap while people keep talking: no dropped sentence, recap time.
5. Twenty minutes of ordinary surroundings with goals on: false alerts per hour, battery, heat.
   This is the measurement that decides between `sessionTurns` 6 and 1.
6. Confirm that goal matches never expand the island, sound or wake the screen (Window 5 rules).

## 9. Verification

| Check | Result |
|---|---|
| `swift test` (Mac) | 426 passed (395 + 31 new) |
| `xcodebuild test`, iOS 27 Simulator, iPhone 18 Pro Max | TEST SUCCEEDED (431 run, recognizer tests skipped there as before) |
| App Debug, Simulator build / Release unsigned, generic device | Succeeded / Succeeded |
| App in the Simulator (iPhone 18 Pro Max), scripted conversation through the new engine, microphone off | Goal matches appear with the utterance's own words as headline and a fixed-word reason (`docs/device-tests/window6-1-simulator/goals.png`, reviewed; `conversation.png` captured). No timing was taken there |
| Physical iPhone | **Not run** |
