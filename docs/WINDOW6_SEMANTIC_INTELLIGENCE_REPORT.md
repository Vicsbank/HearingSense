# Window 6 — Semantic Intelligence, Accessible Conversation and Acoustic Icon Redesign

Date: 2026-10-10. Branch `feature/window6-semantic-intelligence`, from the last committed
Window 5 state (`eddc450`). Not merged, not pushed.

**Evidence level.** Mac (package tests, evaluation tools) and iOS Simulator (app build, UI,
a scripted conversation through the real language model). **Nothing in this window ran on the
iPhone**, at the student's instruction. All speech text is synthetic. Numbers and methods:
`docs/testing/WINDOW6_EVALUATION_RESULTS.md`.

## 1. What the student asked for

A coherent system: environmental sounds as icons that are understood at a glance; attention
goals written in ordinary language and matched by meaning, not keywords; ordinary speech as an
icon only; a detailed recap of the last two minutes on the Action Button, with the choice to
keep following (live captions, a summary that grows) and a second press to stop; summaries
saved locally; privacy, the no-screen-wake rule, Spotify coexistence and the Apple classifier
untouched.

## 2. What exists now

| Capability | State |
|---|---|
| A. Environment as icons | Apple Sound Analysis unchanged. Icon mapping revised: 303/303 labels, 9 glyphs drawn by the app, speech as a bubble, debug gallery (`docs/research/ACOUSTIC_ICON_COVERAGE.md`) |
| B. Semantic attention | `SemanticAttentionEngine`: goals in the user's words, staged model reasoning, deterministic verification, novelty; accepted matches go through the Window 4 engine |
| C. Conversation | Ordinary speech: icon only, no automatic headline. Action Button shortcut → recap → Continue Understanding → live captions and incremental summaries → next press stops |
| D. Memory | Saved summaries in SwiftData on the device: list, detail, search, copy, edit, delete |

### 2.1 Modules

```
packages/HearingSenseKit/Sources/
  SemanticAttention/            goals, engine, Foundation Models reasoner, verifier, baselines
  ConversationUnderstanding/    RollingConversationBuffer, ConversationRecapEngine (+ checks),
                                ConversationSessionMachine, ConversationRecord
  SemanticEvaluation/           labelled synthetic utterances and conversations, metrics
  SemanticEvaluationTool/       hs-semantic-eval (macOS)
  IslandPresentation/CustomSoundGlyph.swift, IslandViews/SoundSymbolImage.swift
apps/ios/HearingSense/
  Conversation/                 ConversationIntelligenceController, ConversationHistoryStore
                                (SwiftData + goal file), ConversationIntents (App Intents)
  Views/ConversationViews.swift card, live conversation, history, goals, privacy
  Views/SoundIconGalleryView.swift (Debug)
```

### 2.2 Data flow

```
MicrophoneCapture (one tap, as before)
 ├─ SoundRecognitionEngine (Apple Sound Analysis) ─► AttentionEngine ─► Live Activity
 │                                              └─► AmbientIconStream (icons)
 └─ SpeechIntelligenceEngine (SpeechTranscriber, only if "Transcribe nearby speech" is on)
       │  SpeechSemanticResult, now with each finalized utterance on its own
       ├─► AttentionEngine            fast path: "Watch out!" phrase rule, unchanged, no model
       └─► ConversationIntelligenceController
             ├─ opt-in "Semantic attention"
             │    SemanticAttentionEngine: gate → first pass → judgement → verifier → novelty
             │    accepted ─► AttentionEngine (.semantic) ─► Live Activity ("Matches Your Goal")
             └─ opt-in "Keep recent speech for recaps"
                  RollingConversationBuffer (memory only, two minutes)
                  Action Button ─► ConversationSessionMachine ─► ConversationRecapEngine
                       ─► saved ConversationRecord ─► history; states ─► Live Activity
```

No second microphone path, no second recognizer, no new acoustic model.

## 3. Acoustic icons

Summary; details and the table of shared fallbacks are in `ACOUSTIC_ICON_COVERAGE.md`.

- A symbol name starting with `hs.` is one of nine drawings (cough, sneeze, snore, laugh, cry,
  scream, whistle, knock, broken glass). `SoundSymbolImage` draws either an SF Symbol or a
  glyph, so `IslandContent` and the pipeline did not change.
- Speech is a speech bubble; shouting, chatter and whispering are in the same family.
- VoiceOver says the name of what the icon shows.
- Reviewed as renderings at island sizes; **not seen on a physical Dynamic Island.**

## 4. Semantic attention

### 4.1 Stages

1. **Gate** (no model): utterances made only of fillers ("yeah, okay") stop here.
2. **Cache**: an utterance decided a moment ago is not decided again.
3. **Goal selection**: all goals if there are at most six, otherwise the six closest by sentence
   embedding.
4. **First pass** (model, one word): "could this matter at all?" — generous; stops everyday
   talk in 0.6 s. Utterances with a word of alarm skip it.
5. **Judgement** (model, guided generation, greedy): about other people only? what kind of
   statement? what would change for the listener? which goal? verdict, headline, urgency.
6. **Verifier** (deterministic): only ever more cautious. See the comparison document §3.
7. **Novelty**: the same statement accepted in the last five minutes is not accepted again,
   whichever goal the model names; a changed day or number is a new statement.

One evaluation at a time; four utterances may wait; the oldest is dropped when a fifth arrives;
an utterance that waited 12 s is dropped; a judgement is abandoned after 8 s. A recap pauses
goal matching. If the model is unavailable or fails there is **no** semantic alert; the engine
does not fall back to keywords.

### 4.2 The structured decision

`SemanticAttentionDecision`: matched goal id; relevant / irrelevant / uncertain; reason;
evidence (the utterance, or a cited span verified against it); headline; urgency; novelty;
statement kind; subject; whether the personal relevance is uncertain; suggested presentation
(none, list only, notify, alert); stage; the verifier's corrections; latency.

Only `relevant`, novel decisions go to Window 4, as `SemanticAttentionSignal`. Window 4 decides
whether it is presented: speech attention off or muted suppresses it; a statement presented in
the last five minutes is not presented again; below high priority it counts against the
presentation budget; it expires like any episode. Its title is generic ("Matches Your Goal");
the headline is private content, handled exactly like a speech summary.

Uncertain decisions (a wish, a quotation, someone else's situation, poor recognition) appear in
the app's "Recent matches" list and nowhere else.

### 4.3 The fast warning path

Unchanged from Window 4: "watch out", "look out", "fire", "stop" and the like are recognized by
a phrase rule inside the attention engine the moment a transcript arrives. It does not wait for
this module. Acoustic warnings (sirens, alarms, horns) never involved speech.

### 4.4 Results

Held-out synthetic set (119 utterances, three profiles, two with goals never seen in tuning):

| | Keyword | Embedding | Foundation Models pipeline |
|---|---|---|---|
| Precision / recall | 62 % / 40 % | 56 % / 93 % | **91 % / 86 %** |
| False alerts on irrelevant speech | 28 % | 88 % | **12 %** |
| Implicit relevance, 28 items | 10 | 26 | **24** |
| Important events missed, 7 items | 6 | 0 | **0** |

Median time on the Mac: 0.6 s when the first pass stops an utterance, 3.6 s to a verdict.

### 4.5 Limits

- 2.7 s per full judgement on the Mac; unknown on the iPhone; lively conversation outruns it.
- Goals unlike the prompt's examples are matched worse (shop-worker profile: 8 of 14).
- "Nothing changes" statements and other people's affairs still cause false alerts (5 of 43).
- English only. Depends on Apple Intelligence being available.
- The reason and the headline are model text; they are checked for numbers, negation and added
  words, not for truth.

## 5. Conversation recap and continued understanding

### 5.1 Ordinary speech

`SummaryPolicy.writesHeadlines` is off in the app: Window 3's pipeline still transcribes (when
the user has turned transcription on) and still produces the rule-based category and details
that the warning rule uses, but it no longer asks the language model for a 2–3 word headline per
stretch of speech. Speech without a summary is an icon in the island (Window 5's rule). Launch
with `-speech.automaticHeadlines YES` to compare with the earlier behaviour.

### 5.2 The buffer

`RollingConversationBuffer`: finalized utterances with their times, only while "Keep recent
speech for recaps" **and** "Transcribe nearby speech" are on and the app is listening. Memory
only. Text older than the look-back time plus 15 s is deleted (also by a timer, when nobody
speaks); at most 80 utterances and 6 000 characters. Cleared when the permission is withdrawn,
when listening stops, when "Clear speech data" is used and when a continued session ends.
Look-back: 1, 2 (default), 3 or 5 minutes.

An excerpt is the conversation going on now: walking back from the newest utterance it stops at
the first pause of 25 s or more. It records where speech was detected but not transcribed, and
whether listening began in the middle of the conversation.

### 5.3 The recap

`ConversationRecapEngine` gives the excerpt to the language model (one utterance per line, no
speaker labels) and asks for a title, a summary of four to eight sentences and up to six key
points, with instructions to copy numbers, times and names, keep negations and not say who
spoke. `RecapValidator` then removes any sentence that names a number, day, time or name that
was not said, or that is mostly made of words that were not said. If more than half is removed,
or the model is unavailable, the app says that no summary could be written — it does **not**
save the transcript in its place. Fewer than eight words: "not enough for a summary", without a
model call. Caveats (missing speech, a missing beginning, poor recognition) are attached
deterministically.

Held-out conversations: 26 of 26 facts, 4 of 4 negations, 6.8 s median. A manual read found
2 unsupported sentences in 56 and one reversed statement in a development scene; see the
evaluation document §3.

### 5.4 The Action Button

`RecapConversationIntent` ("Recap Conversation") is an App Shortcut; the user assigns it in
Settings → Action Button → Shortcut. Public App Intents only. It runs in the app's process
without opening the app and answers with a generic sentence, never with what was said, because
it may run on a locked phone.

`ConversationSessionMachine` (a value type without a clock, like the attention engine):

```
idle ──press──► preparing ──► summarizing ──► summaryAvailable ──Continue──► continuing
  ▲                                              │  (offer ends after 90 s)        │
  └──────────────────────────────────────────────┴──────── press / Stop ◄──────────┘
```

- First press: recap, saved at once, "Continue Understanding" on offer.
- Continue: captions in the app; an incremental summary when something new was said (at least
  six meaningful words) **and** the speakers paused for 6 s, at most every 20 s, and at the
  latest 75 s after the new speech began. Fillers do not count; with nothing new there is no
  update, however long the session lasts. Earlier key points are never dropped.
- Next press (or Stop, or listening stops, or a permission is withdrawn): the record is marked
  completed and the temporary context is deleted. A continued session also ends by itself
  after 30 minutes.

`ContinueUnderstandingIntent` and `OpenConversationIntent` are offered as shortcuts as well.

**Not tested:** invoking the shortcut at all (it compiles and is registered), the Action Button,
a locked or backgrounded phone, and whether the language model answers there in useful time.

## 6. Accessibility

The conversation screen (`ConversationLiveView`): caption text adjustable from 18 to 48 points,
remembered; white on black by default, switchable; final speech in the full colour, tentative
speech lighter, italic **and** labelled "Still listening — may change" (not colour alone);
timestamps on every caption; the summary in its own block above the captions; one large button
for the action that is possible now; VoiceOver labels on captions ("… Said at 8:34:07"), on
tentative text ("Not final yet: …") and on the controls; text can be selected and copied.
Recognition that the recognizer itself rated poor is marked "Hard to recognize".

The Dynamic Island is never the place to read a conversation: it shows an icon and, expanded, a
generic state. Long text is in the app.

Not exercised: VoiceOver and the largest Dynamic Type sizes in a run; a user with hearing loss.

## 7. History

SwiftData (`StoredConversation`) in `Application Support/ConversationIntelligence/`: id, title,
summary, key points, caveats, created and updated dates, status (continuing / completed), an
"edited by the user" flag, the time span of the speech, folded search text. No CloudKit; the
folder is excluded from backups; file protection `completeUntilFirstUserAuthentication` (a
continued session must be able to write while the phone is locked).

List (newest first, swipe to delete), search across title, summary and key points, detail with
copy, edit (the user's wording is never overwritten by a later update; new key points are
added below it) and delete, "Delete All". A record left "continuing" by a terminated app is
completed at the next launch. Only summaries the user asked for are stored; no audio, no
transcript, no goal matches.

## 8. Dynamic Island

Window 5's design and code path are unchanged; Window 6 only adds inputs.

- Ordinary sounds and ordinary speech: icon only (speech is now a bubble).
- Goal match: an attention episode "Matches Your Goal" with a star-bubble icon; the headline is
  private text, shown in the expanded island only where speech summaries are allowed and never
  on the Lock Screen or in a log.
- Recap states (`ConversationStatus`): Preparing Recap, Summarizing, Summary Saved, Summary
  Available, Following Conversation, Stopped Following, Recap Unavailable. They are sent as
  generic attention episodes of normal priority with **no interruption**: no expansion request,
  no sound, nothing that could wake a locked screen. An ordinary sound that comes later takes
  the compact icon back, as with any unprotected episode.
- No new ActivityKit calls; the pipeline's update limits apply.

Not seen on a device or in the Simulator's island (screenshots omit it); tested at pipeline level.

## 9. Privacy

Three switches, each off until the user turns it on, each explained where it is set
(Conversation → Speech data and privacy):

| Switch | What it allows | Kept |
|---|---|---|
| Transcribe nearby speech (Window 3) | speech → text on the device | in memory, bounded, dropped at Stop |
| Keep recent speech for recaps | the two-minute buffer and captions | memory only, expires, cleared on off / stop / end |
| Semantic attention | sentences compared with the goals | nothing; recent matches in memory while listening |

Sound classification needs none of them and implies none of them. Saved: the goals and the
summaries the user asked for. The screen shows what is running, how much is held right now, and
has buttons to clear the recent speech and to delete all summaries. It also says that captions
and recaps put other people's words into text and that the people present should know, and
that Hearing Sense is an awareness aid, not an emergency or safety system and not a replacement
for hearing assistance.

On device only (`SystemLanguageModel.default`; never Private Cloud Compute). Logs and the
diagnostics export hold counts, states and timings; a test checks that a decision's log line
contains no word of the utterance.

## 10. Working beside the Window 5 session

Another session had 24 uncommitted files in the main checkout when this window started and was
still editing them. This window therefore worked in its own worktree
(`.claude/worktrees/window6`, hidden from the main checkout through `.git/info/exclude`) from
the committed `eddc450`, touched nothing in the main checkout and used a second simulator.

Files both sessions changed (expect small merge conflicts; the Window 6 hunks are short):
`ListeningController.swift` (one property, the forwarding block, one report line),
`LiveActivityController.swift` (the symbol check), `SpeechIntelligenceController.swift` (one
configuration line), `HearingSenseDomain/Attention.swift` (two reason codes at the end),
`IslandViews.swift` (two `Image` → `SoundSymbolImage`), `IslandReplayer.swift` (one case),
`IslandPipelineTests.swift` (three icon names), `PROJECT_HANDOFF.md`.

The other session's uncommitted work moves the "speech without a summary" rule into the
attention engine and adds a recalled summary to the island. Both fit Window 6; neither is
included here.

## 11. Remaining device validation

In order, each needing the student's authorization and, for microphone steps, a spoken script:

1. Build and install; open the icon gallery; play the Window 5 clips and look at the icons in
   the real island (cough, sneeze, knock, speech).
2. Goals on, transcription on: read ten sentences from the development set aloud; note the time
   from the end of a sentence to "Matches Your Goal", foreground and background.
3. Assign the shortcut to the Action Button; recap with the app in the foreground, in the
   background, and locked; note whether a recap is written and how long it takes.
4. Continue Understanding for three minutes; check captions, an incremental update, Stop.
5. Twenty minutes with goals on in ordinary surroundings: false alerts, battery, heat.
6. Confirm the island never expands, sounds or wakes the screen for goal matches and recap states.

## 12. Known issues

| Issue | Handling |
|---|---|
| Nothing validated on the iPhone | §11 |
| Full judgement 2.7 s (Mac); queue drops utterances in fast conversation | measure on the iPhone first; options in the comparison document §4 |
| Service-counter goals matched poorly | per-goal examples; a new held-out set before any tuning |
| Recaps can state an announcement as an agreement, and once reversed a statement | shown beside key points; the transcript is visible while it lasts; not fixable by lexical checks |
| A correction in a continued session is added, not reconciled with earlier key points | by design for now; a model pass that marks superseded points would be the next step |
| Topic change without a pause is not a boundary | pause-based segmentation only |
| Recap states give way to ordinary sound icons in the compact island | unprotected episodes, by Window 5's rule |
| Headlines are often withheld (negation check) and the island then shows a generic sentence | cautious on purpose; the app has the sentence itself |
| The held-out set has been looked at | write a new one before the next round of tuning |
| Release build contains the demo sentences' code paths only under `#if DEBUG`; the icon gallery is Debug-only | — |
