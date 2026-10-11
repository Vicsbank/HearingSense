# Window 6.3 research log (working notes; the report is docs/research/WINDOW6_3_PERSONAL_RELEVANCE.md)

Branch `feature/window6-3-personal-relevance`, worktree `.claude/worktrees/window6-3`, base `197d0d0` (W6.2).
Mac only (M1 Max), Apple Foundation Models, synthetic text. No microphone, no iPhone, no training, no download.

## Data
- `semantic_dev4.txt` (225 items, 4 profiles: library, gym, tour, maker): written by me, used for tuning. Two
  profiles have an `@about` line, one says who the listener is inside the goals, one says nothing (maker).
- `semantic_sealed3.txt` (315 items, 5 profiles): written by a separate agent that read nothing of the
  repository. Not read by me. sha256 in `sealed3.sha256`. Committed in `98413b7` before any engine change.
- Harness: `hs-semantic-eval probe2` (requests described by JSON, `tools/w63_specs.py`, `tools/w63_variants.py`),
  scored by `tools/w63_score.py`; whole engine: `tools/w63_engine.sh`, errors: `tools/w63_errors.py`.
- Long stalls (one request of 998 s) happened when the Mac idled; every run is wrapped in `caffeinate -i` since.

## E1 — Window 6.2 on development set 4 (first answer only, then with its second look)
| | TP | FP | FN | TN |
|---|---|---|---|---|
| first answer (`base`) | 89 | 43 | 6 | 68 |
| + second look (`look`) | 89 | 35 | 6 | 76 |
Whole engine, Window 6.2: P 68.5 %, R 93.7 % (89 TP, 41 false alerts incl. 3 repetitions).
False alerts after the second look: other_addressee 8/9, other_group 11/15, multi 6/8, incomplete 3/4,
negation 3, idiom 2, sarcasm_quote 2. Misses: attention 4/10 (questions put to the listener are filed under
"nothing changes"), 1 goal 0, 1 "exact change".

## E2 — can the model use what the listener says about themselves? (first answer, dev4)
| variant | TP | FP | FN | note |
|---|---|---|---|---|
| base | 89 | 43 | 6 | |
| about: the about line shown in the request | 92 | 43 | 3 | other_addressee 7/9, other_group 10/15 still alert |
| own: applicability written into the instructions (+ about line) | 89 | 46 | 6 | no better |
| for: a field "for" (me / others / unknown) before the kind | 87 | 43 | 8 | "me" for 15/15 other_group, 7/9 other_addressee |
Showing or explaining is not the problem: the model does not make the comparison.

## E3 — a second request about whom the sentence is for (on the 149 positives of base)
| check | kept TP | kept FP | note |
|---|---|---|---|
| who (bare answer me/all/notMe/unknown; goals + about) | 38 | 17 | near random: "Stop, there's a car coming!" → notMe |
| who-about (about line only) | 65 | 27 | |
| who-schema (answer form in the request) | 83 | 33 | |
| whom (copy the name or group, then listener yes/no/cannotTell) | 89 | 42 | "yes" for all 148; but the copied span is right: "Daniel", "Hannah", "Group A", "Swim team" |
The model can copy whom a sentence names. It cannot compare that with who the listener is.

## E4 — a narrow question the model can answer
`shared` ("a sentence said to one person who is called by name: theirs / everyones"), 21 name-addressed
dev4 sentences: 12 of 12 "their own business" right, 4 of 5 "for everyone" right (the miss: "Mia, the drill
press is free now if you still need it"). 0.65 s, 232 tokens in, 15 out.
→ Architecture: rules find whom the sentence names and compare it with the listener's own words
(`AudienceAnalyzer`); the model is asked only this narrow question.

## E5 — context
`look-joined` (the second look reads a sentence together with the one before it instead of "for context
only"): multi false alerts 6 → 2 of 8, no correct alert lost (89 → 89).

## E6 — more narrow checks, rejected
- `news` / noNews: marks 22 correct alerts as no news. Rejected.
- `literal` (plain / figure of speech): removes 5 false alerts, takes 3 correct ones; with the second look
  already there the gain is 2–3. Rejected.
- `look-cut` (a "cut off" answer in the second look): incomplete still 3/4. A rule is used instead
  (no closing punctuation and a last word that cannot end a sentence).

## E7 — shorter answers (library profile, 56 items; base: TP 22 FP 12 FN 3 TN 16, 26.9 tokens, 1.86 s)
| form | tokens out | s | TP/FP/FN/TN | kinds |
|---|---|---|---|---|
| joined (one enumerated string "kind goal verdict") | 10.6 | 1.70 | 6/2/19/26 | warning 32, noChange 24 |
| text (plain text, three words) | 9 | 1.63 | 22/13/3/15 | change 52, warning 4 |
| short (fields k, g, v) | 32 | 2.02 | 13/9/12/19 | |
Seventeen tokens less buy 0.2 s: writing is not what a request costs. Field names and form change the
answers. Timing over all probes fits  t ≈ 0.14 s + 1.6 ms × tokens read (not held) + 10–15 ms × tokens written.

## E8 — reading what the listener wrote
- Names by rule ("my name is", "I'm X", "call me X", "my name, X"): right for all profiles.
- Labels of the about line by rule (noun phrases with a mark): library, tour right.
- Labels inside goals ("…, that's the one I take"): the model copies them, one goal per request; kept only if
  every word stands in a goal that speaks of the listener. A request with all goals at once was refused as
  "unsafe content" (a goal about danger). The model also copied the examples of its instructions ("team B");
  the check drops them.
- Which goal is about being spoken to: by rule (the model: 12 of 14 with "which number", worse one by one).

## E9 — whole engine, development set 4 (before the context policy and the speaker's-word rules)
| | TP | false alerts | FN | P | R | ambiguous alerted |
|---|---|---|---|---|---|---|
| Window 6.2 | 89 | 41 | 6 | 68.5 % | 93.7 % | 9/11 |
| Window 6.3 | 90 | 21 | 5 | 81.1 % | 94.7 % | 6/11 (3 listed) |
Corrections: another_group 8, said_to_someone_else 8, audience_unknown 4, called_by_name 2, cut_off 3.
Left: other_group 5 (groups the listener never mentioned: staff, swim team, cruise passengers, teachers,
engineering students), multi 4, negation 3, idiom 3, sarcasm_quote 2, repeated 3, incomplete 1.

## Validity gap found
The app gives every sentence the three sentences said before it as context; the evaluations of Windows 6–6.2
gave a context only to the few items written with one. `run --conversation 3` now gives each item the
sentences before it in the file.
