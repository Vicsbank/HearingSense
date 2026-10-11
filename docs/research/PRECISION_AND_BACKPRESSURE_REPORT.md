# Window 6.2 — Precision Recovery and Real-Time Semantic Inference

Date: 2026-10-11. Branch `feature/window6-2-precision-backpressure` (worktree
`.claude/worktrees/window6-2`), from Window 6.1 `a979cf9`. Not merged, not pushed.

**Scope of every number.** Mac (M1 Max, 32 GB, macOS 27.2), Apple Foundation Models
(`SystemLanguageModel.default`), forward-only inference, greedy sampling. All sentences are
synthetic. No microphone, no physical iPhone, no training, no gradient step, no download, no other
model. The production model was not changed. Other work was running on the Mac during the
measurements (load average 3–8), so times vary by a few tenths of a second between runs. Nothing
here measures real conversation or an iPhone.

Raw output: `results/window6_2/` (`probe/` raw model answers, `engine/` engine-level runs on the
development sets, `stream/`, `sealed/`, `RESEARCH_LOG.md` the working notes in order). How to
reproduce: `docs/testing/WINDOW6_2_BENCHMARK.md`.

## Summary

Window 6.1 left two problems: precision 86.6 % on its sealed set, and a queue that fell 20 s
behind at one sentence every 1.5 s. Both were traced to measurable causes, most of them in how
the model was *asked* rather than in what it was asked.

What was found:

1. **A kept session makes decisions depend on the order of the conversation.** With the
   Window 6.1 arrangement (one session answers six sentences, the goals sent only with the
   first), 25 of 214 development sentences alerted or not depending only on what had been said
   before. With a session per sentence, 0 of 214.
2. **Sending the answer's form with the request made the first answer worse and slower.**
   Without it: 14 → 11 false alerts, 5 → 3 misses, 34 → 26 tokens written, 964 → 802 tokens read.
3. **The backlog was mostly not the judgement itself.** A relevant sentence cost a second look
   in another session; the system holds one session's text at a time, so the next sentence then
   took 3.4 s instead of 1.2 s. Add 37 tokens written per answer (about 1.1 s) and a strict
   oldest-first line twelve deep, and one sentence every 1.5 s is enough to fall 20 s behind.
4. **The model's remaining mistakes are stable.** Sentences about another group in the same
   place ("the servers have a meeting"), everyday remarks with a time in them, and figures of
   speech are judged wrongly by every variant of the instructions that keeps recall. Asking again
   in a different way mostly repeats the mistake, and telling the model that a first reading
   found the sentence relevant makes it agree.

What was built (§4): a session per sentence, prepared while nothing waits; the answer's form in
the instructions; one turn of the scheduler per sentence; a second look that also judges warnings
and hears which accepted statements a sentence may repeat; an "urgent" that needs the second
look's agreement; a waiting line that serves the newest sentence while it is behind, the oldest in
a pause, and gives up, visibly, after a time limit; and, only while sentences are waiting, a
session that continues for up to four sentences with the goals said again.

Results, on a fresh sealed set of 264 sentences by another author, with goals that occur nowhere
else, each engine run once after the configuration was frozen:

| | Window 6 | Window 6.1 | **Window 6.2** | Target |
|---|---|---|---|---|
| Precision | 80.7 % | 76.5 % | **83.8 %** | ≥ 95 %: **not met** |
| Recall | 61.7 % | 99.1 % | **99.1 %** | ≥ 95 %: met |
| Implicit relevance recall | 27/50 | 50/50 | **49/50 (98.0 %)** | ≥ 95 %: met |
| False alerts (of 128 sentences that should stay silent) | 17 | 35 | **22** | |
| F1 | 0.699 | 0.864 | **0.908** | |
| Important events / short urgent instructions | 17/19, 11/12 | 19/19, 12/12 | 19/19, 12/12 | |

Precision rose by 7 points over Window 6.1 at the same recall, and is still 11 points short of
the target. More than half of the remaining false alerts (12 of 22) are of one kind: a sentence
said to another person or group in the same place (§14). On the development sets the same
engine reaches 93.4 % precision and 96.0 % recall; they hardly contained that kind of sentence.

Time, the Mac, synthetic streams (§8–§10): while the model keeps up nothing much changes
(median 1.4 s → 1.3 s at a sentence every 3 s). At a sentence every 1.5 s the median falls from
8.0 s to 3.0 s and the p95 from 11.9 s to 6.8 s. At a sentence a second the median falls from
12.0 s to 5.3 s, but the slowest decisions are later (p95 21 s → 31 s), by design: fewer
sentences are given up and the newest are decided first. **The model's capacity, about 35
sentences a minute in these streams, did not change.** Overload is explicit: every sentence
gets a decision that says what happened to it, and the app shows how many were not checked.

## 1. Root causes of the false alerts

Evidence: `results/window6_2/probe/e1_*`, `e2_*`, `e9_*`, `e12_*`; Window 6.1's own sealed log.

| Cause | Evidence | What was done |
|---|---|---|
| Later requests of a kept session carry only the sentence (no goals, no answer form). The model's criteria loosen: unrelated talk and "nothing changes" start to alert. | Kept session, three orders of the same 214 sentences: false alerts 14–20, 25 sentences flip. What flips to an alert: unrelated talk (9 times over three runs), negation (4), and, correctly, sentences spoken to the listener (10). It is not imitation of earlier answers: the false-alert rate after "all earlier answers were alerts" is 10 %, after "none" 23 %. | A session per sentence. While sentences wait, a session may continue, but the goals are said again each time (3–4 of 223 decisions then differ, §11). |
| The answer's form (schema) in the request distracts the model. | Same instructions, same sentences, fresh sessions: with the form TP 84 FP 14 FN 5 (214 items); without it TP 91 FP 11 FN 3 (223 items); second set 80/14/2 without it. | The form is described in the instructions and not sent with the first request. |
| A sentence about another group in the same place is filed as news for the listener. | 6 of Window 6.1's 11 false alerts on development set 3; unchanged by every check that keeps recall (§3). | Not solved. Documented (§14). |
| A repetition in other words is a new statement to a word count. | Window 6.1 caught 2 of 4 on development set 3 and missed one of 4 on its sealed set. | The second look hears the accepted statements that share words with the sentence and may say "said before" (7 of 8 on development set 3; 3 of 3 look-alikes with a new fact kept). |
| The model's "urgent" was taken at its word and skipped the second look. | Window 6.1 Simulator demo; idioms ("Get out, no way …") arrive as warnings. | Warnings get the second look too; without its agreement an alert is not urgent. On development set 3 it kept all 17 real warnings and took back 1 of 2 idioms. |
| The model files a question put to the listener under "nothing changes". | "Sorry, is this seat taken?" → kind `noChange`. 5 of 5 misses of the fresh-session run were sentences spoken to the listener. | Two lines of the instructions reworded (§4). |

Not a cause, although suspected: earlier *answers* biasing later ones (see the first row), and
randomness (the same order twice gives the same 214 answers; so does a fresh session in any
order).

## 2. Root causes of the queue

Evidence: `probe/e4_cost_lean.txt`, `probe/e10_lead_*.txt`, Window 6.1 stream logs,
`tools/semantic_queue_sim.py`.

Where the time of a request goes (Window 6.1 instructions, 4 goals):

| Request | Seconds | Tokens read (already held) | Tokens written |
|---|---|---|---|
| New session, nothing prepared | 2.1 | 968 (0) | 37 |
| New session, prepared ≥ 0.7 s ahead | 1.25–1.5 | 966 (783) | 37 |
| New session, prepared 0.1 / 0.3 / 0.5 s ahead | 1.8 / 1.6 / 1.4 | (783) | |
| New session, prepared and asked in the same instant | 2.8 | 967 (0) | 39 |
| Kept session, 2nd request | 1.16 | 1032 (1006) | 39 |
| Kept session, 12th request | 1.50 | 1599 (1572) | 37 |
| Kept session right after another session's request (the second look) | **3.45** | 1665 (0) | 37 |
| … after it was made ready again and 2 s passed | 1.64 | 1723 (1693) | 37 |
| Two new sessions asked at the same moment | 3.4 for both | | |

Reading costs about 1 ms per token that is not held; writing about 28–30 ms per token; the
system holds what **one** session has read; two requests at once are not served side by side.

From this, the Window 6.1 backlog in its own benchmark (one relevant sentence in six):

| Part | Seconds per sentence, average | Share |
|---|---|---|
| First answer, of which about 1.1 s is writing 37 tokens | 1.2 | 65 % |
| Second look (0.83 s) and the kept session read again afterwards (about 2.2 s), on relevant sentences | 0.48 | 26 % |
| A new session every six sentences | 0.17 | 9 % |
| Total | 1.85 → 32 sentences per minute (measured in Window 6.1: 31–33) | |

A sentence every 1.5 s is 40 per minute: the line can only grow. The second cause is the line
itself: twelve places, oldest first. Under lasting overload every decision is then made about
twelve service times late, including the ones for sentences that were just said (simulation, §9).

What did **not** help, measured: the parts of a streamed answer all arrive in the last 0.1 s of
the request, so a request cannot be abandoned after its first field; a `true`/`false` instead of
the verdict saves little (28 tokens) and loses precision (§3).

## 3. Architectures tested and rejected

All on development data, fresh sessions unless stated. TP/FP/FN are for the first answer only
(no second look) on development set 3 (214 items before, 223 after it was extended) and, where
given, development set 2 (171).

| Tried | Result | Why rejected |
|---|---|---|
| Kept session, six sentences (Window 6.1) | 89/17/0, 86/14/3, 88/20/1 in three orders | 25 of 214 decisions depend on the order |
| Kept session with goals **and** answer form repeated every time | 87/9/2 (one order) | Each request reads 295 more tokens: 1.5 → 2.0 s by the sixth; no faster than a new session |
| Answer without the verdict (kind, goal) | 86/18/3, 16 tokens | Without a last word the model writes "change, goal 1" for unrelated news |
| `true`/`false` instead of the verdict | 85/19/4, 28 tokens | Worse than the verdict, hardly shorter |
| Reworded instructions with renamed kinds and a kind for being spoken to | 89/29/0 without verdict; 85/18/4 with it | More false alerts |
| "What is the sentence about" first, with everyday subjects as answers | not completed | Stopped in favour of the variants below |
| Kinds that can alert listed first | hard subset: 32/3/5 against 34/11/3 | Recall |
| Verdict paragraph that spells out "irrelevant" | hard subset: 34/11/3 against 34/11/3 | No effect |
| Worked examples in the instructions (four variants, 16–18 examples from a setting of their own) | sets 3 and 2: 86/5/8 and 72/5/10; 93/7/1 and 76/11/6; hard subsets 44/9/13, 47/12/10 against 51/21/6 | A dial, not a gain: fewer false alerts, more misses, on both sets. With the short answer form 5 of 223 answers ran to the token limit and were lost |
| Abandoning a streamed answer after its first field | all parts arrive in the last 0.1 s | Saves nothing |
| Two-step answer always (kind; goal and verdict only if the kind can alert) | same score (91/11/3), kind identical for 223 of 223; 1.50 s for one request, 2.33 s for two, against 1.78 s | Slower for every alert. Kept **only** for requests that find no prepared session (§4) |
| Second look that is given the goals and told a first reading found the sentence relevant | keeps 12 of 14 false alerts | The model agrees with what it is told |
| Second look "whom is it about", goals given, first answer not told | removes 5 false alerts, takes back 4 correct alerts | Recall |
| The same without the goals | takes back 32 correct alerts | Recall |
| Second look with figures of speech spelled out | 9 false alerts left, 1 correct alert lost; the Window 6.1 text: 9 and 0 | No gain |
| "Which goal?" asked again on its own for every alert | per set: 1 false alert removed, 2 correct ones taken back | The model repeats its own mistakes |
| Second look without its answer form (as the first answer now is) | "someone else" for nearly every sentence | Its instructions do not name the field. The form is sent |
| Oldest-first line with expiry; newest-first line | simulation, §10 | Oldest-first: seconds late under overload. Newest-first alone: loses sentences after a burst that a pause would have saved |

Window 6.1's own rejections still stand and were not repeated: embedding-only filtering, the
one-word first pass, several sentences in one request (removed from the code in this window),
free-text answers.

## 4. The selected architecture

```
utterance → gate → (warning-like? own lane) → waiting line
          → one turn of the scheduler:
               first answer   kind, goal, verdict     a session of its own, prepared if there was a pause
               second look    what kind of statement  another session; only for an alert; hears earlier alerts it may repeat
          → verifier (can only make the decision more cautious; urgent only with the second look's agreement)
          → novelty (same words, or "said before" from the second look) → decision
```

| Decision | Why (measurement) |
|---|---|
| A session per sentence | An answer depends on the sentence and the goals only: 0 of 214 differ between orders (kept session: 25) |
| The session is prepared when the engine's line is empty, never otherwise | Prepared ≥ 0.7 s ahead: 1.25 s instead of 2.0 s. A request that comes sooner waits for the rest and is still no slower than unprepared. The engine knows when nothing waits; the reasoner does not |
| The answer's form is in the instructions, not in the request | Fewer tokens to read (−160) and to write (−8), and more answers right |
| Instructions: Window 6.1's with two lines changed ("request", "noChange") | Sets 3 and 2 together, first answer: 170/21/6 against 171/25/5; after the second look 169/10/7 against 170/13/6. The smallest change that helped; everything larger traded recall for precision (§3) |
| One turn of the scheduler for the first answer and the second look | Given back in between, an ordinary sentence gets in before the second look of a warning |
| The second look judges warnings too | An idiom arrives as a warning; without the second look it would be an urgent alert |
| "Urgent" needs the second look to say "here and now" | The model's word alone is not evidence. If the second look fails, the alert is shown, not urgent |
| The second look hears accepted statements that share words with the sentence and name no other number, day or time | Two keys: shared words (deterministic) and "the same news" (model). 7 of 8 repetitions, 0 of 3 look-alikes with a new fact, no other sentence |
| While sentences wait: the session continues for up to four sentences, goals said again; the kind is asked first | A new session would read 840 tokens first (0.84 s) and there is no pause to prepare one. 3–4 of 223 decisions differ from a session per sentence (§11). Kind first: a sentence that stops at the kind is half the writing |
| Waiting line: newest first while behind and speech keeps arriving, oldest first in a pause; given up after 30 s, reported as `expired` | §10 |
| The group request (several sentences in one) was removed from the code | Rejected in Window 6.1; it was dead weight in the engine |

Not changed: the model, the two-minute conversation buffer, live captions (they never wait for
this engine), the recap, Window 4's phrase rule and sound alerts (no language model), the
privacy rules (decisions hold speech-derived text in memory only; logs and statistics hold none).

## 5. Old against new: precision, recall, F1

Engine level (gate, first answer, second look, verifier, novelty). "Window 6.2" is the frozen
configuration in its normal operation (a session per sentence). "While sentences wait" is the
same engine as it works under load (the session continues for up to four sentences, the kind is
asked first), measured here without the second judgement that follows in a pause (§11), so it is
the worst case of that mode.

**Sealed set 2** (264 items; another author; five settings and nineteen goals that occur nowhere
else; each configuration run once, after the freeze `80f80b6`):

| | TP | FP | FN | TN | Precision | Recall | F1 | False-positive rate |
|---|---|---|---|---|---|---|---|---|
| Keyword baseline | 81 | 58 | 34 | 70 | 58.3 % | 70.4 % | 0.638 | 45.3 % |
| Sentence-embedding baseline | 105 | 102 | 10 | 26 | 50.7 % | 91.3 % | 0.652 | 79.7 % |
| Window 6 | 71 | 17 | 44 | 111 | 80.7 % | 61.7 % | 0.699 | 13.3 % |
| Window 6.1 | 114 | 35 | 1 | 93 | 76.5 % | 99.1 % | 0.864 | 27.3 % |
| **Window 6.2** | 114 | 22 | 1 | 106 | **83.8 %** | **99.1 %** | 0.908 | 17.2 % |
| Window 6.2 while sentences wait | 113 | 22 | 2 | 106 | 83.7 % | 98.3 % | 0.904 | 17.2 % |

Accounting: 265 items in the file; 1 excluded by rule before the run (its sentence also occurs
in a development set); 264 evaluated; 21 ambiguous items reported and not scored (Window 6.2:
16 alerted, 5 silent); 243 scored = 115 relevant + 120 irrelevant + 8 repetitions; no item
skipped, timed out or failed (all 264 decided by the model).

**The precision target was not met.** 83.8 % on the sealed set, against 93.4 % on the two
development sets below. The difference is one kind of sentence (§14, first item).

**Development sets** (tuned on; not independent evidence):

| | Set 3 (223) TP/FP/FN/TN | Set 2 (171) TP/FP/FN/TN | Both: precision | recall | F1 |
|---|---|---|---|---|---|
| Window 6.1 | 93 / 17 / 1 / 97 | 80 / 8 / 2 / 69 | 87.4 % | 98.3 % | 0.925 |
| Window 6.2 | 91 / 7 / 3 / 107 | 78 / 5 / 4 / 72 | 93.4 % | 96.0 % | 0.947 |
| Window 6.2 while sentences wait | 92 / 9 / 2 / 105 | 78 / 5 / 4 / 72 | 92.4 % | 96.6 % | 0.944 |

**Where the 22 false alerts on the sealed set come from:**

| Kind | False alerts | Examples |
|---|---|---|
| Said to, or about, another person or group in the same place | 12 of 21 such items | "Basses, stay behind for five minutes, I want to fix your entry." (the listener is an alto); "Arthur, your daughter is on the phone for you."; "Table two, your vegetarian meals are coming out first."; "The staff lunch is at two today because of the training." |
| Understandable only with the sentence before, which was unrelated | 6 of 8 | "It got moved to Friday at two."; "Then the guy shouts get out of the water." |
| Says that nothing changes | 2 of 12 | "Rehearsals next month stay on Thursdays, same time, same place." |
| Figure of speech | 1 of 10 | "Get out of here, you never won two hundred quid on a scratch card." |
| Quotation | 1 of 10 | "On the wireless the man said your visitor has arrived, and it turned out to be the murderer." |

The one miss: "Put the Gloria away and get out the folk song with the green cover."

By kind of sentence, the same sealed set, correct decisions:

| | Window 6.1 | Window 6.2 |
|---|---|---|
| Unrelated talk | 32/35 | **35/35** |
| Repetitions | 4/8 | **8/8** |
| "Nothing changes" and "not" as the news | 17/21 | 19/21 |
| Another person or group | 7/21 | 9/21 |
| Needs the sentence before | 9/16 | 10/16 |
| Wishes and guesses | 10/10 | 10/10 |
| The past and quotations | 19/20 | 19/20 |
| Figures of speech | 9/10 | 9/10 |
| Recognition errors | 11/12 | 12/12 |
| False alerts in all | 35 | 22 |

What was fixed shows on unseen material (unrelated talk, repetitions); what was not fixed shows
just as clearly (the addressee, context).

## 6. Implicit relevance

| | Window 6.1 | Window 6.2 |
|---|---|---|
| Sealed set 2, implicit and causal | 50/50 | **49/50 (98.0 %)** |
| Sealed set 2, important events | 19/19 | 19/19 |
| Sealed set 2, short urgent instructions | 12/12 | 12/12 |
| Development set 3, implicit and causal | 43/43 | 42/43 |
| Development set 2, implicit and causal | 36/37 | 33/37 |

Recall was kept, which was the condition for every change. The stricter instructions with
worked examples were rejected for that reason: measured end to end on the development sets they
reach 96.9 % precision at 89.8 % recall (§3).

## 7. Unseen goals

Sealed set 2 is entirely unseen goals: its author chose the five settings and wrote the goals.
Per setting (Window 6.2): camp TP 23 FP 4 FN 0 TN 22; care TP 23 FP 5 FN 0 TN 21; choir TP 22
FP 6 FN 1 TN 19; site TP 23 FP 2 FN 0 TN 24; wedding TP 23 FP 5 FN 0 TN 20. Recall is 95.7–100 % in
every setting; precision between 78.6 % (choir) and 92.0 % (site). The goal that the engine
named for a correct alert was one the author accepts in 92 of 114 cases (80.7 %).

Development set 3 (four settings unseen by Window 6.1) is the nearest thing to an unseen-goal
comparison between the two engines: Window 6.1 precision 84.5 %, Window 6.2 92.9 %.

## 8. Latency and throughput

One sentence at a time, development sentences, the Mac:

| | Window 6.1 | Window 6.2 |
|---|---|---|
| First answer, session ready | 1.16–1.5 s (kept session, grows with every sentence) | 1.25 s (prepared ≥ 0.7 s ahead) |
| First answer, nothing ready | 2.1 s | 1.9 s; kind only 1.5 s |
| First answer right after a second look | 3.45 s (1.64 s if 2 s passed) | as above: the session is new anyway |
| First answer in a continued session (only while sentences wait) | — | kind only 0.75 s; with goal and verdict 1.6 s |
| Second look | 0.83 s | 0.86–0.9 s |
| Tokens written per first answer | 34–37 | 26; 15 for the kind alone |
| Tokens read per first answer, new session | 964 | 837 |

## 9. End-to-end timing: p50, p95, p99

Streams of 35 sentences (29 everyday or ambiguous, 6 relevant; setting "tenant" of development
set 3), end to end from submission to decision, seconds. One run each; Window 6.2 is the frozen
configuration.

| Arrival | Engine | Decided | p50 / p95 / p99 | Relevant sentences: p50 / max | Waiting for a turn: p50 / p95 | Line: mean / longest | Line empty after the last sentence |
|---|---|---|---|---|---|---|---|
| every 3 s | 6.1 | 35/35 | 1.43 / 2.53 / 3.00 | 2.08 / 2.21 | 0.00 / 0.00 | 0.00 / 1 | 2.6 |
| | 6.2 | 35/35 | 1.31 / 2.11 / 3.47 | 2.05 / 3.47 | 0.00 / 0.01 | 0.01 / 1 | 2.1 |
| every 1.5 s | 6.1 | 35/35 | 8.03 / 11.86 / 12.00 | 9.16 / 11.36 | 5.64 / 9.94 | 2.66 / 7 | 11.1 |
| | 6.2 | 34/35 | **3.00 / 6.77** / 19.17 | 3.44 / 6.66 | 0.41 / 5.18 | 1.04 / 4 | 6.8 |
| every 1 s | 6.1 | 31/35 | 11.99 / 21.16 / 21.40 | 13.00 / 21.40 | 9.77 / 18.55 | 5.92 / 12 | 20.4 |
| | 6.2 | 33/35 | **5.31** / 31.25 / 58.83 | 5.31 / 58.83 | 1.76 / 29.73 | 5.19 / 15 | 21.3 |
| bursty | 6.1 | 35/35 | 6.91 / 12.26 / 13.27 | 8.62 / 13.27 | 4.57 / 10.36 | 2.46 / 7 | 9.6 |
| | 6.2 | 35/35 | **3.47** / 16.56 / 32.45 | 4.59 / 16.56 | 1.22 / 15.34 | 1.52 / 5 | 5.2 |
| 20 s silence, then every 0.8 s | 6.1 | 32/35 | 11.34 / 21.04 / 21.11 | 14.06 / 20.67 | 8.90 / 19.53 | 4.64 / 12 | 15.2 |
| | 6.2 | 33/35 | **5.26** / 24.64 / 33.19 | 14.67 / 33.19 | 1.19 / 23.10 | 3.65 / 12 | 15.5 |

Nearer to ordinary conversation (31 sentences, 2 relevant):

| Arrival | Engine | Decided | p50 / p95 / p99 | Line: mean / longest |
|---|---|---|---|---|
| every 1 s | 6.1 | 31/31 | 12.14 / 20.90 / 21.90 | 4.97 / 11 |
| | 6.2 | 30/31 | 3.49 / 32.47 / 51.46 | 3.70 / 10 |
| bursty | 6.1 | 31/31 | 4.09 / 8.65 / 10.05 | 1.40 / 4 |
| | 6.2 | 31/31 | 2.66 / 13.53 / 16.29 | 0.78 / 3 |

Read honestly:

- **While the model keeps up (a sentence every 3 s) little changes**: 1.4 s → 1.3 s.
- **At moderate overload (every 1.5 s) the backlog is largely gone**: median 8.0 s → 3.0 s, p95
  11.9 s → 6.8 s, the line at most 4 deep instead of 7, empty 6.8 s after the last sentence
  instead of 11.1 s.
- **At heavy overload the typical decision is twice as fresh, the slowest ones are later**:
  median 12.0 s → 5.3 s at a sentence a second, but p95 21 s → 31 s. That is the chosen policy and
  not an accident: the newest sentence goes first, and a sentence left behind is decided in the
  next pause, up to 30 s late, instead of being given up at 20 s (Window 6.1 lost 4 of 35 at a
  sentence a second, one of them relevant; Window 6.2 lost 2, none relevant).
- **The model's sustained capacity did not grow.** In these streams both engines decide about
  35 sentences a minute. Under load Window 6.2 answers an everyday sentence in 0.75 s instead
  of 1.2 s, but every alert costs it a new session afterwards. The gain is in what waits and in
  what order, not in how much the model can do.
- A stream that never pauses is not covered by any policy: at a sentence a second for longer
  than half a minute, sentences are given up, and reported.

## 10. Queue loss, expiry and overload

A sentence can leave the engine in exactly these ways, each with a decision that says so and a
counter (`SemanticAttentionEngine.Statistics`): decided (`model`, `cache`, `speculative`);
stopped by the gate; pushed out of a full line (`dropped`; 36 places, not reached in any run);
given up after 30 s (`expired`); model failure after one retry (`fallback`). In every stream run
the number of sentences without any decision was 0. The app shows, under the list of matches,
"Goal matching could not keep up: N sentence(s) were not checked", and the diagnostics report
counts every kind.

Not evaluated in the runs of §9 (of 35): every 3 s 0 and 0 (Window 6.1 and 6.2); every 1.5 s
0 and 1; every 1 s 4 (1 relevant) and 2 (0 relevant); bursty 0 and 0; silence then dense 3
(0 relevant) and 2 (1 relevant).

The order in which waiting sentences are served was chosen by simulation
(`tools/semantic_queue_sim.py`, no model, service times from §2) and then measured:

| Policy | Under lasting overload | After a burst |
|---|---|---|
| Oldest first (Window 6.1) | Every decision late by the depth of the line (median 7–12 s) | Decides the most sentences |
| Newest first | Median near 2 s; old sentences expire | Loses sentences that a pause would have saved |
| **Newest first while behind and speech keeps arriving; oldest first in a pause** (Window 6.2) | As newest first | As many as oldest first, less a few |

With a service time of 0.6 s nothing waits at any tested pattern: the policy only decides who
pays when the model is too slow, it does not make it faster.

## 11. Model-session context stability

| Arrangement | Decisions that differ from a session per sentence |
|---|---|
| A session per sentence, any order (raw answers) | 0 of 214 |
| The same order twice, kept session | 0 of 214 (it is the order, not chance) |
| Kept session, six sentences, goals sent once (Window 6.1), three orders | 17, 20, 24 of 214; 25 sentences flip between the three |
| Window 6.2 engine, a session per sentence, two orders | 1 of 223: the memory of accepted statements (a statement and its near-repetition changed places), which is intended |
| Window 6.2 engine while sentences wait (four sentences, goals said again, kind first), two orders | 3 and 4 of 223; set 2: 3 of 171; sealed set 2: 4 of 264 |

So reuse is not free even with the goals restated, which is why it is confined to the moments
when the alternative is not deciding at all, and why a sentence that a continued session called
silent is judged once more, in a session of its own, when nothing waits
(`rechecksContinuedAnswers`). In the stream runs that second judgement found 5 alerts among
83 sentences judged again (the same relevant sentence in four runs, and one ambiguous sentence);
they arrived 16–59 s after the sentence. An alert that a continued session raised wrongly cannot be taken
back that way.

## 12. Recap contention and priorities

A recap is one request of about 6–7 s (6.0 s alone in these runs). It takes its turn in the same
scheduler, ahead of goal matching; a sentence that looks like a warning goes ahead of the recap
but cannot interrupt one that is being written.

| 18 sentences every 1.5 s, recap asked after the fourth (setting "cook", dense in relevant sentences) | Window 6.1 | Window 6.2 |
|---|---|---|
| Recap, from request to text | 10.25 s (waited 4.48 s for its turn) | 5.85 s (waited 0.04 s) |
| Goal matching, all sentences, p50 / p95 | 9.81 / 15.60 s | 13.97 / 26.49 s |
| Warning-like sentence that arrived during the recap | 5.02 s | 7.59 s |
| Not evaluated | 0 | 0 |

One run each; how long the recap waits depends on whether a judgement had just started. Goal
matching was **not** faster during a recap in Window 6.2: this stream is half relevant sentences,
each of which costs the kind-first engine two requests and a second look. Nothing was lost in
either. The recap itself and the two-minute buffer were not changed. Live captions do not pass
through this engine and never wait for it.

## 13. Memory and resources

The model runs in a system process (`TGOnDeviceInferenceProviderService`), sampled with `top`
every 2 s during each stream run (`results/window6_2/stream/*.top`,
`tools/semantic_model_process_summary.py`):

| | Window 6.1 | Window 6.2 |
|---|---|---|
| Memory of the process as `top` reports it, largest value in a run | 473–479 MB | 465–478 MB |
| CPU share of one core, mean over a run | 4.4–7.2 % | 3.9–5.5 % |
| Energy impact (`top`), mean | 4.4–7.2 | 3.9–5.5 |
| Tokens written for 35 sentences every 3 s | 1237 | 828 |
| Evaluation tool's own memory | 15–25 MB | 15–25 MB |

No growth over a run in either. What cannot be measured without privileges: the memory of the
model weights that the system maps for the process, and the GPU, where the work happens. None of
this is an iPhone measurement.

## 14. Remaining limitations

1. **Speech meant for someone else in the same place is the largest source of false alerts, and
   it is not solved.** "Basses, stay behind" for a listener who sings alto; "Arthur, your
   daughter is on the phone"; "Table two, your meals are coming out first". Each is a real
   announcement, here and now, on the goal's own subject; only the addressee is wrong. The goals
   say who the listener is, and the model does not use that reliably: 9 of 21 right on the sealed
   set. The second look does not know the goals (told them, it agrees with the first answer),
   and a separate "whom is it about" question cost as many correct alerts as it removed false
   ones. The development sets held only a handful of such sentences (all of them also wrong),
   which is why they overstated precision by ten points. This needs its own piece of work:
   most likely the listener's own names and groups taken from the goals once, and compared with
   the name or group a sentence is addressed to, before the model is asked at all. One lead from
   the sealed run: Window 6, whose answer had a field of its own for "names another person or
   group as the one affected", got 17 of these 21 right (and missed 44 relevant sentences
   elsewhere). A separate question for exactly that, asked only about alerts, has not been tried
   in this form.
2. **A sentence that only makes sense with the one before it** alerts too easily when that
   earlier sentence was unrelated (6 of 8 on the sealed set; 10 of 16 right overall).
3. **Precision 83.8 % on the sealed set**: about one alert in six is false, against a target of
   one in twenty.
4. **The model's capacity is unchanged**: about 35 sentences a minute in the test streams.
   Lasting speech faster than that is not kept up with; sentences are then decided late (up to
   30 s) or given up, visibly. A second judgement of a sentence silenced under load can arrive a
   minute late.
5. **Under load decisions depend slightly on what was said before** (3–4 in 223). The second
   judgement repairs missed alerts when a pause comes, not false ones.
6. **The second look is still the weakest part for anything but the classic cases.** On the
   sealed set it took back 5 alerts; 22 false ones remained.
7. **Run-to-run timing varies** with whatever else the Mac is doing; stream numbers are single
   runs. At a sentence a second two runs of the same configuration differed by two sentences
   decided and by which sentence was given up.
8. **Nothing was measured on an iPhone**, on real speech, on real partial transcripts, in the
   background or with the screen locked. The model process's weights and GPU use could not be
   measured on the Mac either. English only. All sentences synthetic, each set by one author;
   the sealed set's author is a language model.
9. The early evaluation of partial transcripts (Window 6.1) is unchanged and was not measured
   again; with a session per sentence it uses the prepared session and a new one is prepared
   afterwards.

## 15. Regression

| Check | Environment | Result |
|---|---|---|
| `swift test` | Mac | **439 passed** (426 in Window 6.1; 4 removed with the group request and the unchecked warning, 17 added) |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27 Simulator, iPhone 18 Pro Max | **TEST SUCCEEDED**, 444 tests |
| App, Debug, Simulator | iPhone 18 Pro Max | Build succeeded |
| App, Release, unsigned, generic device | — | Build succeeded |
| Scripted conversation in the app (`--hs-conversation-demo`, microphone off, real language model) | iOS 27 Simulator | Matches appear with the sentence's own words and the fixed-word reason (`docs/device-tests/window6-2-simulator/goals.png`); no timing taken |
| Window 6.1's sealed set (220; read since, **not independent**) | Mac | Window 6.2: TP 100 FP 8 FN 5 TN 88, precision 92.6 %, recall 95.2 %; unrelated talk 29/29. Window 6.1 had 103/16/2/80 (86.6 %, 98.1 %; unrelated talk 22/29) |
| Window 6's held-out set (119; read since, **not independent**) | Mac | Window 6.2: TP 52 FP 8 FN 6 TN 39, precision 86.7 %, recall 89.7 %. Window 6 had 50/5/8/42 (90.9 %, 86.2 %) |
| Production instructions equal the measured variant | `hs-semantic-eval probe-text` | `staged == lean-spoken: true` |
| No example of the instructions occurs in an evaluation set; the sealed set shares no sentence, setting or goal with a tuning set | unit tests (`SemanticPromptTests`) | Passed (one sealed sentence excluded by rule, §5) |

Not changed and not re-measured beyond the tests above: sound classification and its 303 icon
mappings, the Dynamic Island and Live Activity code, privacy controls, the Action Button recap,
live captions, continued understanding, the conversation history, local-only processing. The
only app files touched are `ConversationIntelligenceController.swift` (the new reasoner, three
diagnostic lines, a count of unchecked sentences) and `ConversationViews.swift` (one line under
the list of matches when sentences were not checked). No second audio capture path was added;
the engine still receives text only.

Nothing ran on a physical iPhone and the microphone was never used.

## 16. Git

Branch `feature/window6-2-precision-backpressure`, worktree `.claude/worktrees/window6-2`,
from `a979cf9` (Window 6.1). Commits: `54181f8` data sets and research harness, before any
change to the engine; `06d36c7` work in progress; `80f80b6` the frozen configuration, before the
sealed run; then the commit that adds the sealed results and these documents (see
`docs/PROJECT_HANDOFF.md`). Not merged, not pushed, not rebased. The Window 5 checkout and the
Window 6 and 6.1 worktrees were not touched.

## Recommendations

- **Ship the Window 6.2 engine in place of Window 6.1's**, with the precision limit stated. On
  the same fresh sentences it raises 22 false alerts where Window 6.1 raises 35, with the same
  recall (114 of 115). Its decisions no longer depend on the order of
  the conversation in normal use, repetitions and unrelated talk are handled, an "urgent" is
  backed by a second reading, and overload is visible instead of silent.
- **Next piece of work: the addressee.** One problem accounts for more than half of the false
  alerts on unseen material (limitation 1). It is specific enough to be attacked directly and
  to be measured on a set written for it.
- **Do not chase the model's capacity on the Mac.** Measure on the iPhone first (the report of
  Window 6.1, §8, lists the steps; each needs authorization). If one judgement there costs
  several seconds, the waiting-line policy of this window matters more than anything else in it.
- **A different small language model was not tried and is not proposed now.** Nothing measured
  here says that the errors come from the model being too small rather than from what it is
  given: the largest one (the addressee) is missing information, not missing capacity. A
  comparison would need a download of 1–4 GB, an iOS runtime for it and iPhone measurements;
  it should wait for the iPhone numbers of this engine and would need separate approval.
