# Window 6.3 — Personal Relevance and Real-Time Performance

Branch `feature/window6-3-personal-relevance` (worktree `.claude/worktrees/window6-3`), based on
Window 6.2 (`197d0d0`). Mac only (M1 Max, macOS 27), Apple Foundation Models on device, synthetic
text. No microphone, no iPhone, no training, no download, nothing uploaded, nothing merged or pushed.
Numbers measured on the Mac say nothing about an iPhone.

Companion: [`docs/testing/WINDOW6_3_BENCHMARK.md`](../testing/WINDOW6_3_BENCHMARK.md) (data, commands,
all tables). Working notes in order of the experiments: `results/window6_3/RESEARCH_LOG.md`.

The product, as the brief for this window states it: Hearing Sense is for ordinary people who have
earphones in — music on, noise cancelling on, working, studying — and want to stay aware of what
around them matters to them. It is not primarily an aid for people who cannot hear. The question of
this window is therefore not "what was said" and not "who was addressed" but:
**does this sentence bring something new that applies to this listener?**

{{SUMMARY}}

## 1. Root causes of the false alerts

Window 6.2 left 22 false alerts on its sealed set; 12 of them were sentences said to another person
or group in the same place. A new development set (`semantic_dev4.txt`, 225 sentences, 4 listeners)
was written around that question: sentences said to another named person, to another group, to
everyone, to the listener's own group, to a named person but about something all share, and to a
named person when nothing is known about the listener. Window 6.2 on it: precision 68.5 %, recall
93.7 % (41 false alerts). What they were, and why:

1. **The model matches topic and change, not applicability.** "Blue bus, you're leaving at four"
   alerts a listener who wrote that they are on the red bus; "Hannah, your booking got cancelled"
   alerts Priya. 19 of the 35 false alerts that the second look left (8 of 9 sentences said to
   another person, 11 of 15 to or about another group).
2. **It was not missing information; the model does not make the comparison.** Five ways of asking
   were measured (§3): showing the listener's own line in the request, writing the rule into the
   instructions, a field of its own for whom the sentence is for, a second request about whom it is
   for, and a second request that first copies the name or group and then says whether the listener
   is that person. None helped; in the last one the model copied "Daniel" correctly and answered
   that the listener, Priya, is that person — for all 148 sentences.
3. **Context was given in a way that the model sets aside, and the evaluations did not see it.**
   A sentence that leans on the one before ("They finally moved it to next Tuesday", after "My
   sister's been waiting on her visa interview date") was sent with the earlier sentence marked "for
   context only": 6 of 8 such sentences alerted. Worse, the app sends every sentence with the three
   before it, whatever they were about, while the evaluations of Windows 6 to 6.2 gave a context only
   to the few items written with one. Run the way the app runs, 20 of 225 decisions of Window 6.2
   changed only because of what had been said before, and 4 of 28 sentences of unrelated talk
   alerted (§8).
4. **A sentence that stops in the middle** ("So the new deadline for the chassis is going to be") is
   called a change: 3 of 4.
5. **Things the speaker says in so many words are overruled by the model:** "the same as this
   morning", "that was just a rumor" (3 of 4 such negations alerted), and reminders that begin with
   "Reminder", "Don't forget" (5 of 8 repetitions alerted again).
6. **What remains** after this window (§11): groups the listener never mentioned (the staff, the
   swim team), figures of speech and sarcasm, a story whose sentence does not look like a
   continuation.

Misses were few and of one kind: a question put to the listener ("Is this your water bottle?",
"Priya, did you bring the lab notebook?") filed by the model under "nothing changes" (4 of 10).

## 2. What changed: personal relevance

The five things the brief asks to keep apart, and where each is decided now:

| | question | decided by |
|---|---|---|
| A | Does it touch a goal? | the language model's first answer (unchanged since Window 6.2) |
| B | Does it plausibly apply to the listener? | rules compare the sentence with the listener's own words; one narrow question to the model |
| C | Is it new or something to act on? | the model's kind and the second look; the speaker's own word ("as usual", "reminder") |
| D | Is there enough evidence? | the verifier: a cut-off sentence, a failed check, poor recognition → listed, not alerted |
| E | Is the audience the listener, someone else, or unknown? | `AudienceAnalyzer`: one of six cues, with "unknown" as an answer of its own |

### 2.1 Who the listener says they are (`ListenerIdentity`, `ListenerProfile`)

- **An optional "about me" line** in the app, beside the goals: "I'm Nora, on the red bus with group
  B". Typed by the user, stored beside the goals on the device, never uploaded, shown back as what was
  understood ("Name: Nora · Yours: red bus, group B"). Leave it empty and nothing is assumed.
- **Names** are read by rule ("my name is …", "I'm Nora", "people call me …", "says my name, Marion"),
  from the line and from the goals.
- **Labels** — the things that tell the listener's group from its neighbours — are the noun phrases
  of the about line that carry a mark ("red bus", "group B", "study room 3"). By rule.
- A label said in passing inside a goal ("… the six o'clock spin class, that's the one I take") is
  copied by the model, one goal per request, and kept only if every word of it stands in a goal that
  speaks of the listener in the first person. The model's copy can be dropped, never added to. (It
  did copy the examples of its own instructions, "team B"; the check drops them. A request with all
  goals at once was refused by the system as "unsafe content" because one goal was about danger.)
- **The goal about being spoken to** is found by its words ("talking to me", "my attention", "says my
  name", "looking for me"). By rule: the model named the wrong goal for 2 of 14 listeners.

Nothing is derived from speech, and nothing identifies a speaker.

### 2.2 Whom the sentence names (`AudienceAnalyzer`)

Rules, a few milliseconds per sentence, on the sentence's own words:

| cue | example (listener: Nora, red bus, group B) | effect |
|---|---|---|
| `listenerNamed` | "Nora, is this seat free?" | alerts under the goal about being spoken to, whatever the model said; no second look |
| `listenerGroup` | "Group B, have your wristbands out" · "the red one" | nothing held back |
| `otherGroup` | "Blue bus, you're leaving at four" · "The school group over there has to …" | listed, not alerted; no further request |
| `otherPerson` | "Paolo, your group is waiting for you" | the model is asked one narrow question (below) |
| `unknownPerson` | "Mia, your mom's outside" when the listener's name is not known | the same question; never taken for the listener, never ruled out: listed as "said to someone by name" |
| none | "The library is closing an hour early" | as before |

A group is compared by its head and its marks: "bus" with "red"; "room" with "3"; "class" with "six
o'clock" and "spin". The same head with another mark, at the start of the sentence, is another
group; a different number is ("seven thirty spinners"); someone else's is ("my roommate's study
group"); "the bus", "both buses", "the bus driver" and a group mentioned further on ("I told Paolo's
group that everyone …") say nothing. A name is a short segment set off by commas that a name tagger
or the listener's own name recognises ("Jordon" is Jordan).

A sentence that looks like a warning (`UtteranceGate.isLikelyUrgent`) is never held back by any of
this: "Peter, watch out, the boom is swinging!" alerts whoever is near.

### 2.3 The one question the model is asked (`concern`)

"A sentence was said to one person, who is called by name in it. Other people were near and heard
it. theirs: it concerns that person only … everyones: it tells that person something that holds for
everybody who is there." On the 21 name-addressed development sentences: 12 of 12 "their own
business" right, 4 of 5 "for everyone" right; 0.65 s. "Hannah, your booking for tomorrow got
cancelled" → theirs; "Hannah, the desk says nobody can stay in the study rooms past ten" →
everyones. If the request fails, the sentence stays silent (it was said to someone else, and nothing
says it is for all).

This is the finding of the window in one line: **the model cannot compare a name with the
listener's, but it can say whether a sentence is one person's business; so the comparison is done in
code, and the model is asked only what it can answer.**

### 2.4 Context

- A sentence is given the one before it only when it cannot be understood without it — it begins
  with "it", "they", "that", "no", "and", "then" … (`SemanticText.leansOnContext`) — and then only
  that one sentence. A sentence that stands by itself is judged by itself.
- The second look reads a leaning sentence and the one before it as one passage instead of "for
  context only": false alerts among such sentences 6 → 2 of 8, no correct alert lost.

### 2.5 The speaker's own word

- A sentence that stops before it has said anything — no closing punctuation, and a last word that
  cannot end a sentence ("… is going to be", "… you all need to") — is listed, not alerted.
- A statement that says in so many words that nothing is different ("the same as", "as usual", "just
  a rumour", …; not when negated) is no news.
- A sentence that begins as a reminder ("Reminder", "Don't forget", "Again", …) and shares its words
  and its numbers with an alert of a moment ago is not alerted again, without asking the model.

All three can only make a decision more cautious, and none applies to a sentence that looks like a
warning.

### 2.6 Three outcomes, not two

Every decision is one of: **alert** (relevant, verified), **listed** (kept in the app's list as a
possible match with the reason — "Seems to be for someone else", "Said to someone by name", "The
sentence was cut off" — and never a notification), **nothing**. The benchmark counts an alert on a
sentence labelled irrelevant as a false alert whatever the list holds, and reports the listed ones
separately (§5): nothing is hidden in the middle category.

## 3. Architectures investigated and rejected

All on development data; numbers are true alerts / false alerts / misses of the first answer on
development set 4 unless said otherwise (Window 6.2's first answer: 89 / 43 / 6).

| tried | result | why not |
|---|---|---|
| The about line shown in the request | 92 / 43 / 3 | sentences for others alert as before (7 of 9, 10 of 15) |
| Applicability written into the instructions (three places) | 89 / 46 / 6 | no better; the instructions are 800 tokens already |
| A field "for" (me / others / unknown) before the kind | 87 / 43 / 8 | "me" for 15 of 15 sentences to another group |
| Second request "who is it for" (four answers), on the 149 positives | keeps 38 of 89 correct alerts | near random: "Stop, there's a car coming!" → not me |
| … with the answer's form in the request | keeps 83, removes 10 of 43 false | loses 6 correct alerts for 10 false ones |
| Second request: copy whom it names, then "is the listener that person?" | "yes" for 148 of 148 | the copy is right, the comparison never |
| Second look that can also say "cut off" | 3 of 4 cut-off sentences still alert | a rule does it |
| Second look whose "someone else" covers another group in the same place | ±1 decision on two sets | no gain |
| Narrow check "news / no news" on every positive | marks 22 correct alerts as no news | |
| Narrow check "plain / figure of speech" on every positive | removes 5 false alerts, takes 3 correct | the second look already catches most |
| "A person who has earphones in …" instead of "A person who cannot hear" in the instructions | 86 / 43 / 9 | three correct alerts fewer; the text is internal and stays |
| One enumerated string as the answer ("kind goal verdict", 10 tokens) | 6 / 2 / 19 on one profile | the answers fall apart |
| Short field names (k, g, v) | 13 / 9 / 12 on one profile | the same |
| Plain three-word answer (9 tokens) | 22 / 13 / 3 against 22 / 12 / 3 | accuracy holds, but 0.2 s saved of 1.9 s |
| Short instructions, goal and verdict only (`gv`, `gv2`) | 83 / 36 / 12, 85 / 34 / 10 | a third faster, 4 to 6 correct alerts fewer |
| One plain number, full instructions (`num`) | 90 / 63 / 5 | recall kept, half as many false candidates again; see §7 |
| One plain number, short instructions (`num-short`) | 86 / 66 / 9 | 2.6 times faster, 3 correct alerts fewer and 23 more false candidates |
| A cheap score to serve likely sentences first (sentence embedding) | AUC 0.46–0.61 | no better than chance on these sets |
| An alert for every sentence that names an unknown group ("Swim team, …") held back | not built | "Attention members, …" is the same form and must alert; the model cannot tell them apart (row 5) |

## 4. The selected architecture

```
sentence ─ gate ─ cache ─ first answer (kind, goal, verdict; Window 6.2, unchanged) ─┐
                                                                                      │ not an alert, but the
                                                                                      │ listener's name is called and
                                                                                      │ a goal asks for that → alert
            would alert ───────────────────────────────────────────────────────────────┤
              │ cut off, not a warning ───────────────────────────────→ listed         │
              │ another group (rule) ─────────────────────────────────→ listed         │
              │ another person, or a person by name while the listener's is unknown    │
              │      └ narrow question: theirs → listed · everyones → on               │
              │ a reminder of an alert of a moment ago (rule) ───────→ not again       │
              └ second look (leaning sentences read with the one before) ─ verifier ─ novelty ─ alert
```

- One more request only for a sentence that calls a person by name and would otherwise alert (8 of 225
  development sentences); three kinds of sentence need one request fewer than in Window 6.2 (another
  group, cut off, marked reminder: no second look).
- Everything new can be switched off (`SemanticAttentionEngine.Configuration.window6_2`), and is
  compared with Window 6.2 on the same sentences in every table.
- Scheduler, queue, serving order, expiry, the two-minute conversation buffer, live captions, the
  recap and the acoustic warning paths are untouched.
