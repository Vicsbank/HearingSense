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

{{DEV_TABLE}}

Context and load, development set 4 (decisions that differ from "each sentence by itself"):

{{DEV_CONTEXT}}

## 6. Sealed set 3 (run once, after the freeze `1e269b8`)

Accounting: 315 sentences in the file; 0 excluded as duplicates of tuning sets; 315 evaluated in
every run; 8 ambiguous, not scored; 307 scored. In every run 2 sentences got no answer from the model
after one retry (stage `fallback`) and count as silent. No timeouts. Runs of record, and an account
of an accidental second invocation that was stopped: `results/window6_3/sealed/README.md`.

{{SEALED_TABLE}}

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

{{STREAM_SECTION}}

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

{{RESOURCES}}

## 10. Regression

{{REGRESSION}}
