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

Results are in §5 (accuracy) and §8–§10 (time). SUMMARY-RESULTS-PENDING

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
| Oldest-first line with expiry; newest-first line | simulation, §9 | Oldest-first: seconds late under overload. Newest-first alone: loses sentences after a burst that a pause would have saved |

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
| Waiting line: newest first while behind and speech keeps arriving, oldest first in a pause; given up after 20 s, reported as `expired` | §9 |
| The group request (several sentences in one) was removed from the code | Rejected in Window 6.1; it was dead weight in the engine |

Not changed: the model, the two-minute conversation buffer, live captions (they never wait for
this engine), the recap, Window 4's phrase rule and sound alerts (no language model), the
privacy rules (decisions hold speech-derived text in memory only; logs and statistics hold none).

