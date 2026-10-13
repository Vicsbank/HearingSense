# Window 9 — recap postprocessing (`SummaryPostprocessing`)

2026-10-13. Module `packages/HearingSenseKit/Sources/SummaryPostprocessing` (Foundation + NaturalLanguage,
no other package module). English only in this phase. Tests: `Tests/SummaryPostprocessingTests`.

## Why

The Window 7/8 `RecapValidator` mixed four jobs in one lexical pass and one global word bag: it rejected
valid summaries whose numbers were written differently ("7:45" for "seven forty five"), treated words said
minutes apart as support (80-word proximity window), required names to be capitalized in a lower-case
transcript, and relied on a model verifier that added latency yet missed unsupported claims. The new module
separates the jobs into components that each have one question to answer and their own tests.

## Components

| | File | Question it answers |
|---|---|---|
| A | `EnglishNormalizer.swift`, `EnglishValueParsing.swift` | What values does a text contain, in every reading, and are two of them the same? Times, dates, weekdays (relative ones stay relative), months, money, percent, ordinals, durations, digit strings, spoken compounds ("one hundred and forty", "two thousand nineteen", "five five five oh one"). Abbreviations and contractions are normalized in the tokens. |
| B | `ClaimGrounder.swift`, `TextAnalysis.swift` | Is each clause of a statement said in one utterance or in up to three adjacent ones (values, names, polarity, content words together)? Verdict `supported` (with line indices), `unsupported` (reason code) or `uncertain`. |
| C | `CorrectionResolver.swift` | Which values did the speech explicitly change ("actually", "no wait", "I mean", "move it to", "instead", "is now", "from X to Y", "X, not Y", a "no" that answers with another value), what is the final value of the slot (chains followed), and does a statement present a superseded value as current? |
| D | `PrivacyCopyFilter.swift` | Does a statement repeat a spoken sentence, may it stay (approved short-copy rule), is a restatement acceptable, and how much of the text is verbatim? |
| E | `SummaryQualityEditor.swift` | Narration openers and stutters out (port of `RecapText.tidied`, plus "They said …"), empty filler and unfinished fragments dropped, near-duplicates detected by stems, relation words and normalized values. |
| F | `SummaryPostprocessor.swift`, `SummaryPostprocessing.swift` | `process` (first recap) and `merge` (update) in this order per statement: cleanup → grounding → duplicate → copy rule. `PostprocessingOutput.applying(verifierVerdicts:)` for an optional model verifier on the uncertain statements only. |

Shared: `Lexicon.swift` (word lists, a deterministic suffix stemmer, a small synonym map), `SummaryText.swift`
(sentence and word splitting identical to Window 8, so the copy limits mean what they meant).

## Invariants (each has tests)

1. **Never invent.** Output statements are input statements (or restatements the caller passed in) with
   words only deleted: narration opener, a doubled word; the first letter may be capitalized.
   Merge may add the fixed presentation label "Superseded:" to an earlier compound statement
   whose correction is known but whose unrelated details cannot safely survive replacement.
   (`everyOutputStatementWasAnInputStatement`, `tidyingNeverAddsAWord`.)
2. **Fail closed only on clear contradictions.** Removed (`unsupported`): a value or name never said
   (`invented_value`, `invented_name`), a value whose own words point to another utterance holding a
   different value of the same type (`value_mismatch`), a value later corrected and presented as current
   (`superseded_value`), a dropped or added "not" against the evidence (`negation_flip`), a "no"-answered
   question asserted (`denied_question`), a hedged value made exact (`certainty_added`), words attributed to
   a person named nowhere within three utterances of the evidence (`attribution_not_in_evidence`).
   Everything else that cannot be decided is **kept** and listed in `uncertainStatements` (weak local
   support, value not local, hedge dropped, settled claim on a "maybe/could/if" utterance, name far from its
   evidence, claims of absence, statements about the recording).
3. **Equivalent forms are equal.** Same type and value, with every reading of an ambiguous form kept
   ("two twelve" = 2:12 or 212; a bare spoken hour 1–12 can be that hour). Cardinal ≠ ordinal, number ≠
   percent, days ≠ hours, "next Friday" ≠ "this Friday".
   Compatible hour/minute spellings remain equivalent when AM/PM is unspecified; claim grounding
   separately flags an added half of the day as `time_qualifier_added` unless local evidence establishes it.
4. **No transcript text in diagnostics.** `StatementReport.reason` and `corrections` are `ReasonCode` raw
   values only; `reasonCounts` is safe to log. `reports[].text`, `copiedNeedingRestatement` and
   `uncertainStatements` are speech-derived: in memory only, never logged or persisted.
5. **Deterministic.** Fixed tables, no model, no system tagger in decisions; ordered arrays for all output;
   ties broken by shortest, then earliest evidence window.

The privacy rule is unchanged: short copies (≤ 12 words) kept, at most 3, never two adjacent; longer copies
restated or removed; verbatim share measured exactly as before (`verbatimShare`, limit 0.65, exposed as
`exceedsVerbatimShare`). A short true sentence is never removed for matching its source.

## What replaced what

| Window 8 `RecapValidator` | Window 9 |
|---|---|
| `quantities` string sets ("3" = "three") | typed values with readings (A) |
| ≥ 50 % of content stems anywhere in the transcript | clause-level local evidence, ≤ 3 adjacent utterances (B); low coverage → `uncertain`, not removal |
| 80-word proximity window | slot check: a value's own words vs. the utterance that holds it (B) |
| names must be capitalized in the transcript | names looked up case-insensitively (as written and normalized) |
| model `evidence` verifier on every statement | optional, only for `uncertainStatements`; unanswered stay `unverifiedStatements` |
| update: earlier text as a word bag | `merge`: earlier recap as supporting lines, duplicates dropped, explicit changes replace the earlier statement in place when nothing else of it is lost, otherwise visibly labeled "Superseded:" and unverified (`earlier_outdated_kept`, `outdated_by_new_speech`) |

## Wiring notes for the engine (main agent)

- Tidy restatements with `SummaryQualityEditor.tidied`; `SummaryText.isRun`/`words` replace `RecapText`.
- Restate step: call `process`, restate `copiedNeedingRestatement` (keys are the tidied statements), call
  `process` again with `restatements`.
- Removed share: `removedCount / statementCount` (duplicates and filler are counted apart:
  `duplicateCount`, `fillerCount`).
- Update: `merge` expects the addition's own sentences. Both runtime paths now return the addition
  through the shared plain JSON draft schema; older summarizers returning `previous.summary + added`
  are handled by the engine's compatibility trimming.
- Behaviour that changes against Window 8 tests: a paraphrase with no word overlap ("The landlord promised to
  renovate the whole bathroom soon.") and words said far apart ("Vic is a student in their family.") are now
  `uncertain` (kept and listed) instead of removed; a key point identical to a summary sentence is dropped
  as a repeat (a shorter key point stays).

## Corpus regression (seen data, not held out)

`CorpusRegressionTests` runs all 264 judged summaries of `data/summary_regression/en_judged_v1.json` and
prints, per model and configuration, the share of supported units removed and of unsupported units removed
or flagged, plus removal reasons and unit ids (no text). It asserts only conservative floors: supported-unit
removal ≤ 8 %, unsupported caught ≥ 20 %. This corpus was read while the module was written; it measures
regressions, not generalization.

## Round 2 (false deletions on the corpus, by root cause)

Each fix is a general rule with a synthetic test in `RootCauseTests.swift`; none names a corpus example.

- **Value readings:** "seven oh five" is also 7:05 and 705; digits joined by hyphens stay one token
  ("1-14", "4-7-1-9", "555-0142"), each part carrying the joined digits; a lone "one" is an hour in a time
  range ("from one to four"); a day after a month and "to/through" keeps the month ("October 21 to 25",
  "October 21-25"); a percent said once covers the bare numbers said with it ("seventy one percent and we
  want eighty"); number words with an ending are numbers ("eighty sixed"). Not values: "this may be later",
  "on the third floor", "the two considered".
- **Derived numbers:** an unsaid number, money, percent or duration in a statement that says it computed
  something ("calculated", "density", "total", "remaining", "12 by 14") is `uncertain` (`derived_value`),
  provided the transcript has at least two numbers; any other unsaid value is still removed.
- **Names:** letters said one by one and two words said apart are known ("K R" → "KR", "k p eye" → "KPI",
  "red wood" → "Redwood"); common abbreviations are no names ("TBD"); a name with the same sound as a word
  said ("Krebs" / "crabs") is `uncertain` (`name_spelling_differs`).
- **Corrections:** a weak cue ("actually", "sorry" before a value, a reply "no", a change verb) changes an
  earlier value only when the two utterances share a content word; a strong repair ("no wait", "I mean",
  "scratch that") may fix the value just said. A reply "no" must be an answer ("no, it's four", "no Sunday …"),
  not the start of a phrase ("no more than"). A repair corrects one value. A correction that names no matter
  takes it from the utterance before. A statement keeps an old value when another utterance about another
  matter holds it and matches the statement better, or when the correcting utterance says it again for
  something else.
- **Negation:** a question denies nothing ("isn't the recital Sunday?"); "not" denies one word (plus a verb
  after "to"), "no"/"without" the words that follow; "I'm not sure", "I don't know" are hedges (they feed
  the settled-claim check, not the negation check); a contracted subject ends the reach ("no, that's the
  other one"). Negative words in a summary count as negation ("unsuitable", "little", "against",
  "eliminating", "off"). A dropped "no" is removed only when the denying utterance is about what the
  statement is about. A "no" to a question about hearing, knowing or watching denies nothing; a statement
  that itself denies part of a "no"-answered question reports the answer.
- **Attribution:** words attributed to a name said elsewhere in the conversation are `uncertain`, never removed.
- **Slot check:** not for values in a list ("5th, 6th and 7th respectively"); a value's own utterance includes
  the next one when that one comments on it ("that's the beta").

## Known limits

- English only. Chinese/mixed text has no value parser and no capitalization; keep the old path or skip
  grounding for it until a Chinese normalizer exists.
- Lexical: a false relation between true words ("Priya will send it today" when "today" was the chase) is
  not detected; overstated decisions are flagged only when the evidence carries "maybe/could/if/I think".
- A sentence-initial name is checked only when the draft uses it as a name elsewhere.
- A spoken pair is never split ("seven forty five" does not match a lone "7"); a bare spoken hour matches
  that hour on the clock (lenient on purpose).
- Corrections need an explicit cue; a proposal accepted with "yes" or a "but" contrast is not a correction.
- Negation scope is heuristic on unpunctuated speech; it stops at a new subject pronoun ("she can't she
  works Thursdays") and treats a leading "no" after a question as an answer unless it repeats what was asked.
- Letting a value's next utterance count as its own (round 2) means a wrong pairing inside that comment is
  not caught ("that's the beta, the full release is the 27th" cannot tell "beta" from "full release" on the
  20th without punctuation).

## Integration repair (Codex, 2026-10-13)

- Explicit "Y instead of X" binds both values before generic "sorry/make that" cues. A rejected value
  in any repair on that line is never treated as an unchanged restatement for another matter.
- "Move it to Y" may refer to the immediately previous utterance despite adding rationale. Named-topic
  evidence is preferred; the implicit fallback requires exactly one adjacent value of that kind.
- Correction chains require a shared evidence line or topic; two independent slots that happen to use
  the same weekday no longer become one chain.
- Merge replacements must name the corrected topic. Before deleting an earlier sentence, all its
  other values and content/relation stems must survive, with the same polarity; otherwise it remains
  marked for the caller's existing rewrite path. This is deliberately conservative and does not claim
  semantic equivalence for arbitrary paraphrases.
- Synthetic tests cover rationale on implicit moves, cue precedence, independent chains, ambiguous
  adjacent slots, dropped nonnumeric tasks and an unrelated replacement with the same weekday.
  Verified: 81 module tests and all 9 scripted Window 9 pipeline tests. The module adds no logging,
  persistence, model calls or changes to the approved short-copy limits.

### Explicit venue and zero-price corrections

The typed normalizer additionally recognizes a bounded set of literal venue heads (auditorium,
cafeteria, library, gym, theater/theatre, house, gate, entrance), with short directional, school or
possessive modifiers. An abbreviated venue phrase may omit its modifiers; conflicting directions
remain different. These words still participate in lexical support and negation, so "no cafeteria"
cannot be turned into an available cafeteria. An explicit move uses the existing slot resolver;
facts about painting the old building do not reinstate it as the current venue.

In price contexts and explicit "for free/it is free/free of charge" forms, "free" is a zero monetary
value with unspecified currency. An explicit correction can therefore supersede an old nonzero
price. A venue and price may both change in one utterance. "No need to bring $20" is handled more
narrowly as a withdrawn payment instruction: it does not establish that tickets themselves cost zero.

Known scope: arbitrary business names and general place noun phrases are not normalized, venue
paraphrases outside the vocabulary remain lexical/uncertain, and an ambiguous bare "free" without
a price context is not treated as zero cost. No new model call or persistence is introduced.

### Full recap consistency and commentary cleanup

Accepted correction statements remain available after insertion into the merged summary. Separate
old key points about that same corrected slot therefore see the replacement and are removed when
their other facts are preserved elsewhere. Simple payment claims may replace their payment predicate
with an explicitly resolved zero price; compound statements still preserve unrelated tasks and polarity.
Retained stale statements are visibly prefixed "Superseded:" in both the summary and key points and
reported as uncertain, rather than presented as current facts. The label is fixed presentation metadata,
not a new model-authored claim; their verbatim counts are still measured.

The quality editor drops bounded, generic transcript commentary (unspecified names, times, details or
tasks "mentioned/provided"; "the plan remains as stated in the transcript"). Real named-person actions,
specific values, substantive absence claims such as "no other flights are available", and missing-speech
caveats are preserved.

Latest focused validation: 35 correction, merge and quality tests plus all 13 scripted pipeline tests,
including polarity retention when earlier speech has expired. No native model rerun was performed by
the module agent; integration builds and evaluation remain with the coordinating agent.

### Qualifier specificity and historical evidence

Adding AM/PM to a compatible bare clock time now produces an uncertain claim, retained and listed as
unverified, rather than a supported claim. Explicit local AM/PM evidence (or an unambiguous normalized
24-hour time) establishes the qualifier. Normalized clock equality remains compatible; genuine numeric
or negation contradictions still fail their existing checks.

Reserved `Superseded:` statements stay visible on later updates but are excluded from current earlier
recap evidence, draft-name support, correction candidates and strong duplicate coverage. They cannot
reestablish an old value after the original correction speech has expired. New speech may still independently
support an unrelated detail that also appears inside a historical statement.

Verified after these repairs: 33 focused grounding, normalization and merge tests plus all 13 pipeline
tests. Explicit spaced speech-recognizer forms "a m"/"p m" establish meridiem like "a.m."/"p.m.".

### Historical digest consistency

When an original summary sentence is retained as visibly superseded in an update, its shorter old
key points also receive that label if they report a corrected slot and their values, content/relation
stems and polarity belong to that original. Unchanged slots (such as the recital's Saturday time)
remain current. Only generic venue-role words (`event`, `location`, `venue`) may be omitted during
this digest comparison; a named unrelated event sharing the auditorium must still match the original
event and is preserved otherwise. A generic venue digest that cannot distinguish two events remains
visible as uncertain history instead of asserting the changed event's old venue as current.

An accepted addition explicitly saying "changed from X to Y" can provide this history/uncertainty
link for a venue even when the original speech expressed the move implicitly. That generated pair
does not independently establish a replacement fact, and receives no fabricated transcript evidence
index. The original containing sentence must already have been marked historical by the merge.
General semantic entailment, arbitrary event aliases and arbitrary venue names remain outside scope.

Verified: all 15 merge regressions and all 13 scripted Window 9 pipeline tests, including the exact
synthetic book-club and recital outputs and an unrelated workshop still using the same auditorium.
No native model run, logging, persistence or additional model call was added by this module change.
