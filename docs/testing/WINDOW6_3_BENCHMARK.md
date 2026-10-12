# Window 6.3 — Benchmark: personal relevance, context stability, throughput

Companion to [`docs/research/WINDOW6_3_PERSONAL_RELEVANCE.md`](../research/WINDOW6_3_PERSONAL_RELEVANCE.md).
Everything here was measured on one Mac (M1 Max, macOS 27) with Apple's on-device language model and
synthetic text: no microphone, no iPhone, no real conversation. The iOS Simulator was used for
package tests, app builds and one scripted conversation. Nothing here describes an iPhone.

Raw output: `results/window6_3/` (`probe/`, `engine/`, `sealed/`, `stream/`, `regression/`,
`specs/`; working notes in `RESEARCH_LOG.md`).

## 1. Metric definitions

As in Window 6.2 (`WINDOW6_2_BENCHMARK.md` §1): a **true alert** is an alert on a sentence labelled
relevant, a **false alert** an alert on one labelled irrelevant or a second alert on a repetition, a
**miss** a relevant sentence without an alert. Precision = true / (true + false alerts); recall =
true / (true + misses). Sentences labelled ambiguous are not scored; what happened to them is
reported. New in this window:

- **Listed**: the decision is "uncertain": the sentence is kept in the app's list as a possible match
  with a reason and never notifies. A listed sentence is not an alert: on a relevant sentence it
  counts as a miss, on an irrelevant one as correct silence. The number of listed sentences is
  reported beside every result so that nothing hides there.
- **Decisions that differ**: the number of sentences that alert in one run and not in another run of
  the same engine on the same sentences, when only the context, the order or the load differs.
- **As frozen / as shipped**: see §6.

## 2. Data

| set | sentences | listeners | author | role |
|---|---|---|---|---|
| `semantic_dev4.txt` | 225 (95 relevant, 111 irrelevant, 8 repetitions, 11 ambiguous) | library, gym, tour, maker | the implementer | tuning |
| `semantic_sealed3.txt` | 315 (152 / 145 / 10 / 8) | film set, car ferry, food bank, hostel, festival camp | a separate agent that read nothing of the repository | run once after the freeze |
| `semantic_dev3.txt`, `semantic_dev2.txt` | 223, 171 | Windows 6.2 and 6.1 | the implementer | regression (tuned on earlier) |
| `semantic_sealed2.txt`, `semantic_sealed.txt`, `semantic_heldout.txt` | 265, 220, 110 | earlier windows | – | read in earlier windows; used for failure analysis only, not run again |

New categories in both new sets, beside those of Window 6.2: `group_all` (an announcement to
everyone), `my_group` (to the listener's own group or by their name), `other_affects` (said to or
about someone else, but it changes something for the listener too), `other_addressee` (said to
another named person about their own business), `other_group` (to or about another group in the same
place), `audience_unknown` (a named person or group when nothing is known about the listener;
labelled ambiguous), `incomplete` (cut off). A profile may carry one `@about` line: what the listener
wrote about themselves.

The sealed set was committed with its checksum (`results/window6_3/sealed3.sha256`) in `98413b7`,
before any change to the engine. A unit test checks that it shares no sentence, no profile and no goal
with any set used for tuning, and that no example in the model's instructions occurs in it.

## 3. Commands

```sh
cd packages/HearingSenseKit
swift build -c release --product hs-semantic-eval

# One request per sentence, described by a JSON file (research harness; development sets only)
python3 ../../tools/w63_specs.py                     # writes results/window6_3/specs/*.json
tools/w63_probe.sh dev4 base about own               # run descriptions one after another
tools/w63_score.py --set dev4 results/window6_3/probe/base_dev4.json \
    --check results/window6_3/probe/look_base_dev4.json --keep "c['about']=='hereAndNow'" --list

# What is read from a listener's own words; the audience cue of every sentence (rules only)
hs-semantic-eval identity [--set dev4 | --goals "a|b" --about "..."]
hs-semantic-eval audience --set dev4 --list [--no-tagger]

# The whole engine
hs-semantic-eval run --set dev4 --methods model --config window6_3 --reuse 1 --no-steps   # a session per sentence
hs-semantic-eval run --set dev4 --methods model --config window6_3 --conversation 3        # with the 3 sentences before
hs-semantic-eval run --set dev4 --methods model --config window6_3                         # as while sentences wait
#   --config window6_2 | window6_3 (the app) | window6_3_frozen (as evaluated on the sealed set)
#   switches: --no-audience --no-name --no-cutoff --no-word --no-joined --context-always --hold-other-groups
hs-semantic-eval decide --goals "a|b" --about "..." "<sentence>" ...                        # a few sentences by hand

# Streams (one run at a time), the sealed set (ran once; refuses a second run), tables
tools/run_window6_3_streams.sh
tools/run_window6_3_sealed.sh
tools/w63_tables.py "label"=<engine json> ...        # counts only
tools/w63_recount.py sealed3 <6.3 json> <6.2 json>   # the frozen run with the rule for another group off
```

Every model run is wrapped in `caffeinate -i`: early in the window one request took 998 s because the
Mac idled.

## 4. Probe experiments (raw answers; development set 4 unless said otherwise)

True alerts / false alerts / misses of the first answer; 95 relevant and 111 irrelevant sentences.

### 4.1 Can the model use what the listener says about themselves?

| request | TP / FP / FN | sentences to another person that alert (of 9) | … to another group (of 15) |
|---|---|---|---|
| Window 6.2 (`base`) | 89 / 43 / 6 | 8 | 11 |
| + the about line in the request (`about`) | 92 / 43 / 3 | 7 | 10 |
| + applicability written into the instructions (`own`) | 89 / 46 / 6 | 6 | 11 |
| + a field "for": me / others / unknown (`for`) | 87 / 43 / 8 | answered "me" for 7 | "me" for 15 |

### 4.2 A second request about whom the sentence is for (on the 149 positives of `base`: 89 true, 43 false, 17 not scored)

| check | true alerts kept | false alerts kept |
|---|---|---|
| Window 6.2's second look (`look`) | 89 | 35 |
| `who`: me / all / notMe / unknown, one bare word | 38 | 17 |
| `who-about` (the about line only) | 65 | 27 |
| `who-schema` (answer form in the request) | 83 | 33 |
| `whom`: copy the name or group, then "is the listener that person?" | 89 | 42 (it answered "yes" 148 times) |
| `news` / noNews | 68 | 31 |
| `literal`: plain / figure of speech | 85 | 38 |
| `look-joined`: the second look reads a leaning sentence with the one before | 89 | 31 (leaning sentences: 6 → 2 of 8) |
| `look-cut`: the second look can say "cut off" | 89 | 33 (cut-off: 3 of 4 still alert) |
| `look-group`: "someone else" also covers another group here | 89 | 30; on set 3: 92 / 8 against 92 / 7 |

### 4.3 The narrow question (`shared`): 21 sentences that call a person by name

| labelled | answered "theirs" | answered "everyones" |
|---|---|---|
| that person's own business (9 irrelevant, 3 undecidable) | 12 | 0 |
| said to them, holds for everyone (5 relevant) | 1 | 4 |
| calls the listener (4) | 3 | 1 (not asked in the engine: the name is the listener's) |

0.65 s per request, 232 tokens in, 15 out.

### 4.4 Wording, and reading the listener's own words

- "A person who has earphones in and cannot hear what is said around them" for "A person who cannot
  hear": 86 / 43 / 9.
- Names by rule: right for all 14 development profiles and three earlier ones. Labels of the about
  line by rule: right for both profiles that have one. Labels in goals, copied by the model: "six
  o'clock spin class" (gym), "Otters", "table six" (earlier profiles) found; "alto" in "I sing alto" not kept (one
  common word is not a label); the model's own examples ("team B") and things the listener merely wants to hear about
  ("work shift", "class schedule", "group photos") were dropped by the check.
- The goal about being spoken to: by rule right for 14 of 14; the model 12 of 14 ("which number") and
  3 of 14 (asked goal by goal: it said yes to the first goal).

## 5. The whole engine on the development sets

Tuned on; not independent. A session per sentence, each sentence by itself.

| | Window 6.2, set 4 | **Window 6.3 as frozen, set 4** | 6.3 as shipped, set 4 (recount) | 6.3, set 3 | 6.3, set 2 |
|---|---|---|---|---|---|
| true alerts / false alerts / misses | 89 / 38 / 6 | **90 / 14 / 5** | 90 / 22 / 5 | 91 / 7 / 3 | 78 / 4 / 4 |
| precision | 70.1 % | **86.5 %** | 80.4 % | 92.9 % | 95.1 % |
| recall | 93.7 % | **94.7 %** | 94.7 % | 96.8 % | 95.1 % |
| F1 | 0.802 | 0.905 | 0.870 | 0.948 | 0.951 |
| implicit relevance | 29/30 | 29/30 | 29/30 | 42/43 | 33/37 |
| important events / short urgent instructions | 25/26, 10/10 | 25/26, 10/10 | – | 11/11, 6/6 | 17/17, 11/11 |
| a sentence said to another person stays silent | 1/9 | 9/9 | 9/9 | – | – |
| a sentence to or about another group stays silent | 4/15 | 12/15 | 4/15 | – | – |
| said to others, concerns all | 8/8 | 7/8 | 7/8 | – | – |
| announcement to all or own group | 13/14 | 13/14 | 13/14 | – | – |
| negation | 9/12 | 11/12 | – | 18/18 | 16/16 |
| context (leaning sentences) | 10/16 | 13/16 | – | 8/8 | 9/10 |
| repetitions not alerted again | 6/8 | 7/8 | – | 6/8 | 4/4 |
| cut-off sentences stay silent | 1/4 | 3/4 | – | – | – |
| unrelated talk stays silent | 28/28 | 28/28 | – | 31/32 | 21/22 |

Sets 3 and 2 have no sentence with a group cue and no about line, so "as frozen" and "as shipped" are
the same engine there. Window 6.2 on them (its own report): 91 / 7 / 3 and 78 / 5 / 4. On set 4, which I
wrote, the rule for another group removed 8 false alerts and lost nothing; on the sealed set it did the
opposite (§6).

Context and load, development set 4 (decisions that differ from "each sentence by itself"):

| Window 6.3 as frozen, set 4 | each sentence by itself | with the three before it | as while sentences wait |
|---|---|---|---|
| true alerts / false alerts / misses | 90 / 14 / 5 | 90 / 15 / 5 | 89 / 16 / 6 |
| precision / recall | 86.5 % / 94.7 % | 85.7 % / 94.7 % | 84.8 % / 93.7 % |
| unrelated talk stays silent | 28/28 | 28/28 | 28/28 |
| decisions that differ | – | 3 of 225 | 9 of 225 |

Before the context policy (the same engine, context given to every sentence): 91 / 24 / 4, unrelated talk
24/28, 17 of 225 decisions differ. Window 6.2 as its app handed sentences in: 92 / 45 / 3, unrelated talk
24/28, 20 of 225 differ from each sentence by itself (89 / 41 / 6 in that earlier run of Window 6.2 with its
session continued).

## 6. Sealed set 3 (run once, after the freeze `1e269b8`)

Accounting: 315 sentences in the file; 0 excluded as duplicates of tuning sets; 315 evaluated in
every run; 8 ambiguous, not scored; 307 scored. In every run 2 sentences got no answer from the model
after one retry (stage `fallback`) and count as silent. No timeouts. Runs of record, and an account
of an accidental second invocation that was stopped: `results/window6_3/sealed/README.md`.

| | 6.3 as frozen, each sentence by itself | 6.3 as frozen, with the three before it | 6.3 as frozen, while sentences wait | 6.2, each sentence by itself | 6.2, with the three before it (as its app ran) |
|---|---|---|---|---|---|
| true alerts / false alerts / misses / silent | 140 / 41 / 12 / 114 | 140 / 44 / 12 / 111 | 134 / 40 / 18 / 115 | 148 / 67 / 4 / 88 | 150 / 74 / 2 / 81 |
| precision | 77.3 % (140/181) | 76.1 % (140/184) | 77.0 % (134/174) | 68.8 % (148/215) | 67.0 % (150/224) |
| recall | 92.1 % (140/152) | 92.1 % (140/152) | 88.2 % (134/152) | 97.4 % (148/152) | 98.7 % (150/152) |
| F1 | 0.841 | 0.833 | 0.822 | 0.807 | 0.798 |
| false-positive rate | 26.5 % (41/155) | 28.4 % (44/155) | 25.8 % (40/155) | 43.2 % (67/155) | 47.7 % (74/155) |
| false-negative rate | 7.9 % (12/152) | 7.9 % (12/152) | 11.8 % (18/152) | 2.6 % (4/152) | 1.3 % (2/152) |
| ambiguous (not scored): alerted / listed / nothing | 6 / 1 / 1 | 6 / 1 / 1 | 6 / 1 / 1 | 7 / 0 / 1 | 6 / 1 / 1 |
| goal named correctly | 67.1 % (94/140) | 66.4 % (93/140) | 73.1 % (98/134) | 67.6 % (100/148) | 54.0 % (81/150) |
| implicit relevance recall | 91.1 % (41/45) | 91.1 % (41/45) | 84.4 % (38/45) | 95.6 % (43/45) | 97.8 % (44/45) |
| explicit relevance recall | 96.7 % (29/30) | 96.7 % (29/30) | 93.3 % (28/30) | 100.0 % (30/30) | 100.0 % (30/30) |
| important-event recall | 93.3 % (28/30) | 93.3 % (28/30) | 93.3 % (28/30) | 96.7 % (29/30) | 100.0 % (30/30) |
| short urgent instruction recall | 100.0 % (10/10) | 100.0 % (10/10) | 100.0 % (10/10) | 100.0 % (10/10) | 100.0 % (10/10) |
| announcement to all or own group | 96.3 % (26/27) | 96.3 % (26/27) | 96.3 % (26/27) | 96.3 % (26/27) | 100.0 % (27/27) |
| said to others, concerns all | 73.3 % (11/15) | 73.3 % (11/15) | 60.0 % (9/15) | 100.0 % (15/15) | 100.0 % (15/15) |
| another person addressed | 80.0 % (16/20) | 80.0 % (16/20) | 80.0 % (16/20) | 0.0 % (0/20) | 0.0 % (0/20) |
| another group addressed | 25.0 % (5/20) | 25.0 % (5/20) | 35.0 % (7/20) | 5.0 % (1/20) | 5.0 % (1/20) |
| personal relevance accuracy | 100.0 % (10/10) | 100.0 % (10/10) | 100.0 % (10/10) | 100.0 % (10/10) | 100.0 % (10/10) |
| negation accuracy | 93.3 % (14/15) | 93.3 % (14/15) | 93.3 % (14/15) | 93.3 % (14/15) | 93.3 % (14/15) |
| hypothetical accuracy | 90.0 % (9/10) | 90.0 % (9/10) | 90.0 % (9/10) | 90.0 % (9/10) | 70.0 % (7/10) |
| past and quotation accuracy | 90.0 % (18/20) | 80.0 % (16/20) | 85.0 % (17/20) | 90.0 % (18/20) | 90.0 % (18/20) |
| idiom accuracy | 60.0 % (6/10) | 50.0 % (5/10) | 60.0 % (6/10) | 60.0 % (6/10) | 50.0 % (5/10) |
| recognition-error accuracy | 80.0 % (8/10) | 80.0 % (8/10) | 80.0 % (8/10) | 90.0 % (9/10) | 100.0 % (10/10) |
| context (several sentences) accuracy | 70.0 % (14/20) | 70.0 % (14/20) | 70.0 % (14/20) | 60.0 % (12/20) | 50.0 % (10/20) |
| unrelated talk accuracy | 96.7 % (29/30) | 96.7 % (29/30) | 96.7 % (29/30) | 96.7 % (29/30) | 83.3 % (25/30) |
| repetition accuracy | 40.0 % (4/10) | 40.0 % (4/10) | 40.0 % (4/10) | 40.0 % (4/10) | 50.0 % (5/10) |
| cut-off sentence accuracy | 80.0 % (4/5) | 80.0 % (4/5) | 80.0 % (4/5) | 0.0 % (0/5) | 0.0 % (0/5) |
| profile car_ferry | P 80.0 % (28/35), R 90.3 % (28/31) | P 80.0 % (28/35), R 90.3 % (28/31) | P 80.6 % (25/31), R 80.6 % (25/31) | P 71.4 % (30/42), R 96.8 % (30/31) | P 64.6 % (31/48), R 100.0 % (31/31) |
| profile festival_camp | P 73.0 % (27/37), R 96.4 % (27/28) | P 71.1 % (27/38), R 96.4 % (27/28) | P 71.1 % (27/38), R 96.4 % (27/28) | P 62.8 % (27/43), R 96.4 % (27/28) | P 61.9 % (26/42), R 92.9 % (26/28) |
| profile film_set | P 78.4 % (29/37), R 93.5 % (29/31) | P 78.4 % (29/37), R 93.5 % (29/31) | P 79.4 % (27/34), R 87.1 % (27/31) | P 68.2 % (30/44), R 96.8 % (30/31) | P 68.9 % (31/45), R 100.0 % (31/31) |
| profile food_bank | P 76.3 % (29/38), R 93.5 % (29/31) | P 76.3 % (29/38), R 93.5 % (29/31) | P 76.3 % (29/38), R 93.5 % (29/31) | P 71.4 % (30/42), R 96.8 % (30/31) | P 72.1 % (31/43), R 100.0 % (31/31) |
| profile hostel | P 79.4 % (27/34), R 87.1 % (27/31) | P 75.0 % (27/36), R 87.1 % (27/31) | P 78.8 % (26/33), R 83.9 % (26/31) | P 70.5 % (31/44), R 100.0 % (31/31) | P 67.4 % (31/46), R 100.0 % (31/31) |
| decisions that differ from the first column | 0 of 315 | 3 of 315 | 11 of 315 | 37 of 315 | 57 of 315 |
| decisions that differ, Window 6.2 by itself against Window 6.2 with the three before | | | | – | 22 of 315 |

Corrections applied by Window 6.3 as frozen (each sentence by itself): another_group 11, audience_unknown 10,
said_to_someone_else 8, cut_off 4, second_look 10, nothing_changes 6, hypothetical_marker 4, said_before 4,
urgency_unconfirmed 31. Seconds per sentence (one request after another, nothing prepared): median 2.73,
p95 3.52 (Window 6.2: 2.76, 3.01).

Baselines on the same sentences: keyword 95 / 88 / 57 (precision 51.9 %, recall 62.5 %);
sentence-embedding retrieval 146 / 141 / 6 (50.9 %, 96.1 %).

False alerts of Window 6.3 as frozen, by category (Window 6.2 in brackets): another group 15 (19),
repetition 6 (6), leaning sentence 6 (8), another person 4 (20), idiom 4 (4), sarcasm or quotation 2
(2), cut off 1 (5), negation 1 (1), hypothetical 1 (1), unrelated 1 (1). Misses: said to others but
concerns all 4 (0), implicit 3 (2), recognition error 2 (1), causal 1 (0), own group 1 (1; the model
gave no answer), spoken to 1 (0).

Audience cues found on the 315 sentences: listener's group 29, another person 13, a person while the
listener's name is unknown 12, another group 11, listener's name 7, none 243.

**As frozen and as shipped.** The frozen configuration let the rule for another group decide by
itself. On this set that rule removed 4 false alerts and lost 7 correct ones. It was switched off
afterwards (`Configuration.holdsBackOtherGroups = false`). A recount of the runs above for that
setting — the 11 sentences the rule held back take Window 6.2's decision, everything else stays:

```
as frozen:                              TP 140 FP 41 FN 12 TN 114   precision 77.3 %  recall 92.1 %  F1 0.841
rule for another group off (recount):   TP 147 FP 45 FN  5 TN 110   precision 76.6 %  recall 96.7 %  F1 0.855
  categories that change: asr_error 8/10 → 9/10, causal 9/10 → 10/10, implicit 32/35 → 33/35,
                          other_affects 11/15 → 15/15, other_group 5/20 → 1/20
with the three sentences before: as frozen 140 / 44 / 12; recount 147 / 48 / 5
```

The recount is not an independent measurement: the setting was chosen after the result was seen.

## 7. Streams

Sentences arriving over time, Window 6.2 against Window 6.3 (as frozen), one run after the other on
the same sentences; 35 sentences of development set 3 (16 % relevant, the mix of the Window 6.2
report), 34 of set 4 (a listener who says who they are), and a sparse mix (2 relevant in 31). **New
in this benchmark: every sentence is handed in with the three before it, as the app does.** Window
6.2 therefore runs here as its app ran, not as its own report measured it (there no context was
given, and it decided up to 35 sentences a minute). Single runs on a Mac that was otherwise idle; a
second run of the same configuration differs by a sentence or two and by seconds in the tail.

| run | engine | sentences | evaluated | not evaluated (relevant) | end to end p50 / p95 / p99 s | relevant sentences p50 / p95 s | wait for a turn p50 / p95 s | line: mean / longest | empty after s | model requests per minute | second looks | judged again (late alerts) | sentences decided per minute | true / false alerts / misses |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| set 3, 16 % relevant, 1.0 | 6.2 | 35 | 25 | 10 (2) | 6.90 / 32.97 / 33.07 | 5.32 / 30.69 | 1.22 / 29.48 | 8.7 / 21 | 29.7 | 27 | 14 | 4 (0) | 23.5 | 3 / 3 / 3 |
| set 3, 16 % relevant, 1.0 | 6.3 | 35 | 27 | 8 (0) | 5.91 / 33.31 / 62.89 | 26.01 / 62.89 | 0.67 / 29.83 | 6.4 / 17 | 25.1 | 37 | 13 | 9 (1) | 27.4 | 6 / 2 / 0 |
| set 3, 16 % relevant, 1.5 | 6.2 | 35 | 30 | 5 (0) | 4.21 / 26.81 / 28.79 | 4.21 / 7.62 | 1.11 / 25.76 | 4.2 / 12 | 19.5 | 30 | 16 | 5 (0) | 25.5 | 6 / 2 / 0 |
| set 3, 16 % relevant, 1.5 | 6.3 | 35 | 30 | 5 (0) | 3.88 / 21.36 / 28.05 | 7.51 / 11.05 | 0.89 / 20.51 | 3.4 / 8 | 13.3 | 36 | 11 | 9 (0) | 28.0 | 6 / 1 / 0 |
| set 3, 16 % relevant, 3.0 | 6.2 | 35 | 35 | 0 (0) | 2.20 / 4.16 / 4.27 | 2.30 / 3.60 | 0.00 / 0.72 | 0.0 / 1 | 4.2 | 20 | 19 | 0 (0) | 19.8 | 6 / 5 / 0 |
| set 3, 16 % relevant, 3.0 | 6.3 | 35 | 35 | 0 (0) | 1.33 / 3.64 / 4.19 | 2.08 / 3.64 | 0.00 / 0.00 | 0.0 / 1 | 4.2 | 20 | 12 | 0 (0) | 19.8 | 6 / 2 / 0 |
| set 3, 16 % relevant, bursty | 6.2 | 35 | 33 | 2 (1) | 16.64 / 29.55 / 30.65 | 24.44 / 28.20 | 13.03 / 28.61 | 5.0 / 15 | 26.9 | 30 | 18 | 9 (1) | 23.7 | 5 / 4 / 1 |
| set 3, 16 % relevant, bursty | 6.3 | 35 | 35 | 0 (0) | 8.24 / 28.02 / 28.47 | 6.32 / 17.40 | 6.13 / 26.84 | 3.4 / 10 | 18.2 | 38 | 12 | 12 (2) | 28.0 | 6 / 2 / 0 |
| set 3, 16 % relevant, dense | 6.2 | 35 | 28 | 7 (1) | 18.42 / 27.13 / 27.76 | 21.49 / 26.24 | 14.93 / 24.70 | 5.9 / 15 | 25.4 | 21 | 13 | 3 (0) | 19.2 | 5 / 2 / 1 |
| set 3, 16 % relevant, dense | 6.3 | 35 | 27 | 8 (1) | 6.77 / 24.56 / 26.21 | 6.23 / 23.52 | 1.82 / 22.98 | 5.4 / 17 | 15.2 | 29 | 11 | 10 (0) | 20.9 | 5 / 2 / 1 |
| set 4 (listener says who they are), 1.0 | 6.2 | 34 | 23 | 11 (1) | 7.03 / 33.20 / 33.72 | 7.03 / 33.72 | 2.11 / 29.82 | 9.7 / 21 | 30.0 | 24 | 13 | 2 (0) | 21.9 | 5 / 7 / 1 |
| set 4 (listener says who they are), 1.0 | 6.3 | 34 | 27 | 7 (0) | 7.66 / 32.34 / 33.04 | 7.66 / 32.34 | 1.86 / 29.65 | 9.2 / 20 | 32.4 | 25 | 11 | 0 (0) | 24.8 | 5 / 4 / 1 |
| set 4 (listener says who they are), 1.5 | 6.2 | 34 | 25 | 9 (0) | 8.09 / 32.33 / 32.37 | 6.44 / 29.81 | 1.22 / 28.91 | 7.1 / 16 | 28.0 | 19 | 18 | 0 (0) | 19.4 | 6 / 9 / 0 |
| set 4 (listener says who they are), 1.5 | 6.3 | 34 | 33 | 1 (0) | 4.66 / 29.36 / 30.64 | 4.75 / 25.48 | 1.18 / 24.46 | 3.4 / 10 | 22.4 | 32 | 10 | 5 (0) | 27.6 | 5 / 5 / 1 |
| set 3, 2 relevant in 35, 1.0 | 6.2 | 31 | 26 | 5 (0) | 28.38 / 45.91 / 62.57 | 62.57 / 62.57 | 25.12 / 42.36 | 6.2 / 16 | 28.4 | 35 | 13 | 8 (2) | 26.7 | 2 / 5 / 0 |
| set 3, 2 relevant in 35, 1.0 | 6.3 | 31 | 27 | 4 (0) | 5.45 / 34.72 / 56.17 | 56.17 / 56.17 | 0.73 / 29.69 | 4.9 / 13 | 22.3 | 45 | 8 | 12 (1) | 30.9 | 2 / 2 / 0 |
| set 3, 2 relevant in 35, bursty | 6.2 | 31 | 29 | 2 (0) | 4.97 / 28.63 / 43.96 | 4.02 / 4.02 | 1.59 / 26.92 | 2.9 / 9 | 17.9 | 35 | 14 | 10 (1) | 25.9 | 1 / 5 / 1 |
| set 3, 2 relevant in 35, bursty | 6.3 | 31 | 31 | 0 (0) | 2.97 / 18.11 / 19.89 | 15.73 / 15.73 | 1.37 / 13.30 | 1.0 / 4 | 9.4 | 48 | 7 | 16 (2) | 31.6 | 2 / 2 / 0 |

"Sentences decided per minute" is the throughput under overload (rows at 1.5 s and faster, bursty,
dense): Window 6.2 19–27, Window 6.3 21–32. In every pair Window 6.3 decides as many or more
sentences (0 to +8.2 a minute), leaves fewer without an evaluation (33 sentences against 51 over the
nine pairs; relevant ones 1 against 5), and its median delay is lower in eight of nine pairs.
**This is not a faster model request.** It comes from requests that are no longer made: Window 6.3
takes the second look at 7–13 sentences per run where Window 6.2 takes it at 13–19, because a sentence
that stands by itself is no longer judged together with the three before it (which made unrelated
talk look relevant), and it reads fewer tokens per request for the same reason. The tail did not
improve: p95 and p99 are set by sentences that waited for a pause or were given up after 30 s, as
designed in Window 6.2. At one sentence a second the relevant sentences were decided late in Window
6.3's run (median 26 s, one after 63 s: second judgements after the backlog), where Window 6.2 decided
fewer of them, sooner (median 5 s; 2 never evaluated, 3 missed). That is the price of deciding the
newest sentence first and repairing later; it is Window 6.2's policy and was not changed.

### Recap while sentences arrive (16 sentences, one every 1.5 s, recap asked after the fourth)

| | recap alone | recap, waited for its turn | goal matching p50 / p95 (18 sentences) | submitted during the recap, p50 | warning-like sentence | dropped |
|---|---|---|---|---|---|---|
| Window 6.2 | 5.95 s | 6.34 s, 0.47 s | 18.8 / 29.7 s | 27.6 s | 8.4 s | 0 |
| Window 6.3 | 5.95 s | 6.07 s, 0.24 s | 18.0 / 26.9 s | 25.7 s | 8.0 s | 0 |

Unchanged: the recap goes first and takes about six seconds; goal matching waits for it.

## 8. What a request costs (Mac; 24 sentences of one profile per cell; seconds per request)

| request | tokens in / out | unprepared | prepared 1 s ahead | session continued: turns 2, 3, 4 (… 8) |
|---|---|---|---|---|
| `base`: kind, goal, verdict (the engine's first answer) | 836 / 26.8 | 1.94 | 1.26 | 1.12, 1.14, 1.27 (… 1.53) |
| `gv2`: short instructions; goal, verdict | 540 / 17.8 | 1.31 | 1.04 | 0.89, 0.88, 0.92 (… 1.24) |
| `text`: three plain words | 865 / 9 | 1.83 | 0.93 | 0.76, 0.84, 0.92 |
| `num`: one plain number | 886 / 3 | 1.52 | 0.73 | 0.74, 0.82, 0.81 |
| `num-short`: short instructions, one number | 450 / 3 | 0.75 | 0.63 | 0.52, 0.56, 0.61 |
| narrow second requests (`shared`, `news`, `literal`) | 205–255 / 13–15 | 0.60–0.65 | – | – |

Accuracy of the cheaper first requests (first answer only):

| request | set 4: TP / FP / FN | set 3 | |
|---|---|---|---|
| `base` | 89 / 43 / 6 | 92 / 9 / 2 | |
| `gv` (short instructions; goal, verdict) | 83 / 36 / 12 | – | sentences spoken to the listener: 7 of 10 lost |
| `gv2` (with the line about being spoken to) | 85 / 34 / 10 | – | |
| `gv-schema` | 79 / 35 / 16 | – | |
| `num` | 90 / 63 / 5 | 92 / 21 / 2 | recall kept; half as many false candidates again |
| `num-short` | 86 / 66 / 9 | 87 / 26 / 7 | |
| one profile (56 sentences): `base` 22 / 12 / 3; `joined` (one enumerated string) 6 / 2 / 19; `short` (fields k, g, v) 13 / 9 / 12; `text` 22 / 13 / 3 | | | |

A cheap score for serving likely sentences first (sentence embedding against the goals), AUC of
relevant against irrelevant sentences: 0.53 (set 1), 0.46 (set 2), 0.61 (set 3), 0.52 (set 4);
5–6 ms per sentence.

## 9. Model process

The model runs in a system process (`TGOnDeviceInferenceProviderService`), sampled with `top` every
2 s during the stream runs: 162–763 MB (most runs 183–475 MB; the larger figures in runs that followed
a recap benchmark), 5.0–6.5 % of one core on average, peaks of 8–21 %. No growth within a run. The
evaluation tool itself: 14–32 MB. The model's weights and the GPU are not visible to these tools. The
new rules cost a few milliseconds per sentence (a tagger pass and string comparisons); reading the
listener's own words costs one model request per goal that speaks of the listener, once, when goals
or the about line change. Nothing of this was measured on an iPhone.

## 10. Regression

| check | environment | result |
|---|---|---|
| `swift test` | Mac | **473 passed** (439 before; 34 new, 3 runs in a row) |
| `xcodebuild test -scheme HearingSenseKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max'` | iOS 27 Simulator | **TEST SUCCEEDED**, 478 tests |
| `xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense` Debug | Simulator | **BUILD SUCCEEDED** |
| … Release, `generic/platform=iOS`, unsigned | — | **BUILD SUCCEEDED** |
| Scripted conversation in the app, `--hs-conversation-demo --hs-screen goals` | iOS 27 Simulator, microphone off | "About me" shows what was understood ("Name: Alex · Yours: study group B"); "Alex, can you bring the charger tomorrow?" is the newest match; screenshots in `docs/device-tests/window6-3-simulator/` (the lower part of the list could not be scrolled into view: no access to the simulator panel in this session) |
| Development sets 3 and 2 (tuned on in earlier windows) | Mac | 91 / 7 / 3 and 78 / 4 / 4; Window 6.2: 91 / 7 / 3 and 78 / 5 / 4 |
| Earlier sealed sets | — | not run again: all three have been read |

The first simulator run failed, and that was a finding, not a flake: the system's name tagger returns
no names in the Simulator (no linguistic data), so a sentence said to another person was not
recognised there. A form-based fallback was added (commit `56358da`; no change where the tagger
works). Two timing tests of Window 6.2 failed once each while the simulator shared the Mac with the
language model; their margins were widened. Untouched and covered by the existing tests: Apple Sound
Analysis and its 303 label mappings, the acoustic icons, the Window 4 priority engine and its phrase
rule, the Live Activity and Dynamic Island code, the two-minute conversation buffer, the recap and
continued understanding, the conversation history, the privacy controls. No second audio pipeline; no
automatic summaries of ordinary speech.
