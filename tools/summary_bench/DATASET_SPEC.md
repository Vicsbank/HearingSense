# Summary benchmark dataset spec (authoring contract)

Task being benchmarked: a phone app buffers the last ~120 s of speech-recognizer output near a
hard-of-hearing user; the user asks "what was just said?" and a language model writes a detailed
recap. You author SYNTHETIC test conversations plus a ground-truth fact list. You do not know
which models will be tested or what prompts they get; do not look at any benchmark code or results.

## Output: one JSON object per line (JSONL), UTF-8

```
{
 "id": "<prefix>-001",
 "language": "en" | "zh" | "mixed",
 "scenarios": ["A","D","E"],          // from the list below; 1-3 tags
 "lines": [                             // utterances as a speech recognizer outputs them
   {"t": 0.0, "text": "..."}, ...       // t = start second (0-120, increasing, realistic gaps/pauses)
 ],
 "missing": [[start_s, end_s]],         // optional: spans the recognizer could not transcribe (>=3 s), else []
 "facts": [                              // atomic facts a good recap should preserve
   {"id":"f1","text":"Meeting moved from Monday to Wednesday.","critical":true,"kind":"change"}
 ],
 "must_not": [                           // plausible-but-unsupported inferences a recap must NOT state
   {"id":"n1","text":"Maya is Tom's sister (never stated)."}
 ],
 "uncertain": [                          // things the speakers themselves left uncertain / unconfirmed
   {"id":"u1","text":"Whether the dentist can see Priya on Friday is not confirmed."}
 ]
}
```

`kind` in: date_time, number, name, place, decision, task, change (correction/update), relation, uncertainty, other.
`critical` = true for dates, times, numbers, names, assignments, corrections/changes.

## Rules
- Realism: ~2 minutes of speech = roughly 220-380 English words, or 330-650 Chinese characters,
  as 12-45 utterances. Utterances are recognizer segments, not neat sentences.
- NO speaker labels in `lines` (the app doesn't know who spoke). Speaker changes must be inferable
  only from content, as with a real recognizer. Facts must be defensible from the lines alone.
- Facts: 6-14 per conversation (low-information ones: 2-5). Each fact is ONE atomic claim, stated
  in English for en/mixed and in Chinese for zh, self-contained, no pronouns.
- When a time/date/number is corrected, the fact states the FINAL value and a separate `change`
  fact states the correction. Add a `must_not` for the superseded value being presented as current.
- 2-6 `must_not` per conversation (0-2 for low-information ones): inferences that sound natural
  but are not stated (relationships, confirmed status of tentative plans, reasons, feelings).
- Preserve uncertainty: tentative/unclear things go in `uncertain`, NOT in `facts`.
- Fully synthetic: invented names, schools, companies. No real people, no real private data.
- Vary names, places, topics; avoid repeating the same template. Do not make every conversation
  contain a correction; do make ~35% contain one.
- Scenario tags: A school (homework, exam changes, teacher announcements, discussion, deadlines);
  B everyday (casual, plans, appointments, family, errands); C meeting (multiple topics, decisions,
  assigned tasks, follow-ups); D complex (multiple speakers, pronouns, corrections, contradictions,
  repetition, ambiguous references); E transcription imperfections (missing punctuation, fragments,
  misrecognized words, repeated phrases, unlabeled speaker turns, irrelevant background speech);
  F information-dense (many names/dates/times/numbers/places/schedule changes); G low-information
  (small talk, unclear speech, no decisions, uncertainty).
- Language: en = English; zh = Mandarin (Simplified), natural spoken register, recognizer-style
  punctuation (often missing); mixed = Chinese speech with English words/names/terms embedded
  (code-switching), or alternating sentences. Facts for mixed are written in English.
- Include `missing` spans in about 10% of conversations; mention nothing about them in `facts`
  except an `other` fact "Part of the speech could not be transcribed" when relevant.
- Misrecognized words (E): put the misrecognition in `lines`; the fact states what a careful reader
  can safely conclude (or goes in `uncertain` if it cannot be resolved).

Validate your file with: python3 -I tools/summary_bench/validate_dataset.py <file>
