# Attention Priority Engine — Architecture (Window 4)

Date: 2026-10-10. Branch `feature/window4-attention-priority`.
Code: `packages/HearingSenseKit/Sources/{HearingSenseDomain/Attention.swift, Attention/, AttentionReplay/,
AttentionReplayTool/}`, `apps/ios/HearingSense/{Attention/, Views/AttentionViews.swift}`.
Results: `docs/testing/WINDOW4_TEST_RESULTS.md`. Summary: `docs/WINDOW4_ATTENTION_PRIORITY_REPORT.md`.

The engine decides which confirmed sounds and speech events deserve the user's attention. It is a
deterministic rule engine. It calls no language model, reads no audio, and presents nothing: its
output is a stream of decisions and presentation intents for Window 5.

What it does not know and never claims: where a sound comes from, how far away it is, who is
speaking, whether speech is addressed to the user, or whether a sound means danger. A priority is a
policy decision about what may deserve a glance.

---

## 1. Pipeline

```
SoundRecognitionEngine ─ AcousticEventUpdate ─┐   (Window 2, unchanged)
                                              ├─▶ AttentionController (app, main actor)
SpeechIntelligenceEngine ─ SpeechSemanticResult┘   (Window 3, unchanged)
                                                      │  AttentionInput (each carries its time)
                                                      ▼
                                             AttentionEngine (value type, package `Attention`)
   advance time ─▶ attach to an episode ─▶ assess priority ─▶ schedule ─▶ AttentionDecision
   stale sources     existing / rejoined     reason codes      SHOW UPDATE SUPPRESS      │
   expirations       fused / new                               DEFER RESOLVE EXPIRE      ▼
   deferred shows                                                  AttentionEvent + AttentionPresentationIntent
                                                                                         │
                                                                    AttentionController.onIntent ─▶ Window 5
```

- No second microphone session, classifier or transcriber: the engine consumes what Windows 2 and 3
  already publish. `RecognitionController` and `SpeechIntelligenceController` forward their
  engines' outputs (each engine's stream has one consumer).
- No Foundation Models call. Speech meaning comes from the summary, category and rule-based
  details that Window 3 already attached to the result.

## 2. Modules

| Module | Contents | Depends on |
|---|---|---|
| `HearingSenseDomain/Attention.swift` | Output contract: `AttentionEventID`, `AttentionPriority`, `AttentionCategory`, `AttentionReason`, `AttentionLifecycle`, `AttentionSourceRecord`, `AttentionPrivateContent`, `AttentionEvent`, `AttentionPresentationIntent` | Foundation |
| `Attention` | `AttentionEngine`, `AttentionInput`, `AttentionDecision`, `AttentionAction`, `AttentionSnapshot`, `AttentionMode`, `AttentionPreferences`, `AttentionConfiguration` (policy as data), speech rules | Domain only |
| `AttentionReplay` | Synthetic event builders, scenario scripts with ground-truth labels, the replay harness and metrics, playback of a scene into a running engine | Attention, Domain, SoundEventDetection (kind names from the real taxonomy) |
| `hs-attention-eval` | Command-line replay and report (macOS) | AttentionReplay |
| App: `AttentionController`, `AttentionViews` | Wiring, preference storage, the one deadline timer, card, settings and debug screens | all |

`Attention` imports no Apple ML, UI or ActivityKit framework. `AttentionPresentationIntent` is the
brief's "PresentationIntent"; the prefix avoids a clash with Foundation's `PresentationIntent`
(attributed strings).

## 3. Episodes

The engine's unit is an *episode* (`AttentionEvent`, stable `AttentionEventID`): one sound, one
stretch of speech, or a few events close in time. Ids are assigned in order, so a replay yields the
same ids.

```
active ─▶ updated ─▶ resolved ─▶ expired
   │         ▲  │        └─▶ updated    the same source resumes shortly after it ended
   └─────────┴──┴──────────▶ expired    presentation timed out, or never presented
```

An input is attached, in this order, to: the episode that already holds its source; an episode of
the same kind that is still alive (**rejoin**); a presented episode it closely follows (**fusion**);
otherwise a new episode. An episode whose presentation is over but whose source is still active
stays as a *tracker* so that the same ongoing sound cannot alert again under that id.

## 4. Priority assessment

Five ordinal priorities: `ambient` (never presented), `low`, `normal`, `high`, `urgent`. Each
assessment produces reason codes (`AttentionReason`, stable raw values such as
`safety_relevant`, `new_event`, `music_context`).

### 4.1 Sound policy table (`AttentionConfiguration.standard`)

Every one of the taxonomy's 50 event kinds (and `unmapped`) is assigned a profile and a user-facing
category; a test fails if a kind is missing. Base priority per mode:

| Profile | Kinds | Quiet | Balanced | Sensitive | Cooldown (Balanced) | Notes |
|---|---|---|---|---|---|---|
| emergency_siren | siren | urgent | urgent | urgent | none | warning signal |
| alarm | alarm | high | high | high | none | → urgent after 20 s |
| vehicle_horn | vehicle_horn | high | high | high | none | warning signal |
| vehicle_signal | reverse_beeps | normal | high | high | none | warning signal |
| bicycle_bell | bicycle_bell | normal | normal | high | none | warning signal |
| danger_impact | glass_breaking, bang | high | high | high | none | |
| scream | screaming | high | high | high | none | |
| door_knock | door | normal | high | high | none | 3 occurrences in 60 s → +1 (at most high) |
| phone | phone | normal | normal | high | 30 s | → high after 15 s |
| crying | crying | low | low*cond.* | normal | 120 s | → +1 after 30 s |
| shouting | shouting | low | low*cond.* | normal | 90 s | |
| dog | dog | ambient | low*cond.* | normal | 120 s | |
| beep, thunder, fire | beep, thunder, fire | ambient | low*cond.* | normal | 60–300 s | |
| thud | impact | ambient | low | normal | 60 s | |
| animal, chime | cat, bird, farm_animal, wild_animal, bell | ambient | ambient | low | 180 s | |
| weather | rain, wind, water_body | ambient | ambient | low | 600 s | |
| transport, household, crowd, human_activity | vehicles, appliances, kitchen, footsteps, laughter, … | ambient | ambient | low | 180–300 s | |
| music | music | ambient | ambient | ambient | — | `music_context`, `low_relevance` |
| minor | small_objects, typing_writing, body_sounds, clock, insect, mic_wind_noise, whoosh, unmapped | ambient | ambient | ambient | — | Window 2 saw these fire on clean speech |

These are the brief's defaults, extended to the remaining kinds by the project. They are choices,
not measurements.

### 4.2 Modifiers

| Input | Rule | Reason codes |
|---|---|---|
| User preference | `muted` → ambient; `low`/`normal`/`high` replace the base in every mode | `user_muted`, `user_priority_override` |
| Evidence quality (Window 2's ordinal `EventQuality`) | Only gates: `urgent` needs at least moderate evidence (weak → `high`, and rises when the evidence does); a weak event is marked uncertain. A higher score never raises priority | `weak_evidence`, `strong_evidence` |
| Conditional (*cond.*) | `low` → `normal` once the sound has at least moderate quality and 3 supporting windows; until then the episode is deferred | `condition_pending`, `condition_met`, `persistent_sound` |
| Duration | Profile rule, e.g. alarm for 20 s → `urgent` | `persistent_sound`, `escalated` |
| Repetition | Profile rule, e.g. third knock within 60 s in Quiet → `high` | `repeated_event`, `escalated` |
| Novelty | First occurrence → `new_event`; a recurrence within the rejoin window joins the episode | `new_event`, `continuation_of_recent`, `recently_seen` |

Classifier scores are never read by the engine. "Confidence is not importance" is a property of the
structure: strongly classified rain is ambient, a weakly classified horn is still `high`.

### 4.3 The three modes (`ModeTuning`)

| | Quiet | Balanced (default) | Sensitive |
|---|---|---|---|
| Presented from priority | normal | normal | low |
| Cooldown scale | × 2 | × 1 | × 0.5 |
| Presentations below `high` per 60 s | 2 | 4 | 8 |
| Minimum time between content updates | 15 s | 8 s | 4 s |
| Ordinary speech | not presented | presented once sustained (2.5 s or one finished sentence), 90 s cooldown | presented, 45 s cooldown |
| Informative speech (validated summary of a question, request, reminder, announcement) | low (not presented) | normal | normal |
| Possible spoken warning | high | high | high |

A mode change applies at once to the episodes that exist (rain already falling appears when the
user switches to Sensitive and is taken down when they switch back).

## 5. Speech (`SpeechAssessment`)

From each `SpeechSemanticResult` the engine keeps a reduced record (`SpeechFacts`: state, level,
category, relevance, quality, flags, the validated headline) and discards the transcript after one
pass of the phrase rule.

| Tier | Condition | Priority |
|---|---|---|
| irrelevant | `possiblyMusic`, or speech attention off / speech muted | ambient — lyrics never alert, whatever the words |
| ordinary | anything else without a relevant summary, including "Nearby Speech" without text | by mode (table above) |
| informative | validated summary and category question / request / reminder / announcement | by mode |
| important | category `warning`, or an urgent phrase in a finished utterance ("watch out", "look out", "call 911", …; single words such as "stop" or "help" only in utterances of at most 3 words) | high; normal if the recognition quality is poor, if the statement is negated and only a keyword matched, or if it was spoken over music |

- **Transcription** is never switched on by the engine. Without it the engine sees detection-level
  results and presents the generic "Nearby Speech" (`transcription_off`).
- **Titles never contain spoken words.** "Nearby Speech" or "Possible Spoken Warning" is the
  lock-screen-safe title; the validated headline travels separately as `privateContent` /
  `privateDetail` (§8).
- **Uncertainty and negation are kept.** The headline is passed on unchanged; `isUncertain` is set
  for speech over music, unclear or poorly recognized speech, a summary with warnings and a
  keyword-only warning; `negated_statement` and `question` are reason codes.
- **Music ambiguity.** While a confirmed music event is active, voice-like sound whose relevance is
  not known yet is not presented as speech (`music_context`, `music_ambiguity`) until Window 3 says
  it is speech.
- **A warning is sticky within its conversation**: later ordinary sentences do not lower it.
- **Unavailable models.** Detection-level results carry `model_unavailable`; without the language
  model the phrase rule still works on the transcript; the classifier's own `speech` event alone
  produces a generic speech episode.

### Summary revisions

A new headline is compared with the one that is shown by `SemanticSignature` (content words,
polarity, numbers and time words):

| Change | Example | Decision |
|---|---|---|
| cosmetic — same content words (Jaccard ≥ 0.8), same polarity, same numbers | "Package Has Not Arrived" → "The Package Hasn't Arrived" | SUPPRESS `cosmetic_revision`; the shown text stays |
| critical — polarity, number or time changed | "Has Not Arrived" → "Has Now Arrived"; "at three" → "at four" | UPDATE at once, with an interruption (`negation_changed` / `detail_changed`) |
| refined — other content words | "Package Has Now Arrived" → "Package Arrived At Front Door" | quiet UPDATE, at most one per update interval (otherwise DEFER, then applied) |
| first summary on a shown episode | late summary | quiet UPDATE `summary_added`, same id |

The comparison cannot recognize synonyms; what it cannot match is treated as different. Two
statements with different polarity are never merged.

## 6. Temporal fusion

A speech event joins a presented episode when (a) the pair is in `fusionAffinities` (default: a
door/knock or a phone/beep followed by speech), (b) the speech was first reported at most 8 s after
the anchor was last observed, and (c) not more than 1 s before the anchor began. Speech that was
already going on is therefore not attributed to a later knock. If the speech was reported just
before the sound was confirmed (the detector needs about two windows), the speech episode is merged
into the new one.

- The first event is never delayed: it is decided the moment it arrives, and later events attach.
- Sources keep their own timestamps (`AttentionEvent.sources`).
- Wording states order in time only: "Door or knock" + "Nearby speech afterwards". The reason code
  is `temporal_fusion`. Nothing says the two are related.
- The fused episode's priority is the higher of its parts; a late summary is added quietly; a
  warning in the speech re-alerts.

## 7. Deduplication, cooldowns and scheduling

| Mechanism | Behaviour |
|---|---|
| Stable identity | One episode per acoustic event id / speech event id; updates of a known source never create an episode |
| Persistent sounds | Updates of a shown sound are `SUPPRESS ongoing_event`; the presentation ends after a lifetime (low 20 s, normal 30 s, high 45 s, urgent 60 s) while the tracker keeps following the source |
| Rejoin | The same kind again within its rejoin window (8–60 s) continues the episode: quiet UPDATE "Repeated n times" |
| Cooldown | Per kind, scaled by mode. A sound that began during its cooldown stays suppressed even after the cooldown ends, unless its priority rises |
| Warning signals | Profiles marked safety-relevant, anything `urgent` and possible spoken warnings ignore cooldowns and the presentation budget |
| Presentation budget | Presentations below `high` per 60 s (2 / 4 / 8). Excess is DEFERred and shown when the budget frees, or dropped after 15 s (or 3 s after its source ended) |
| Update interval | Non-critical content updates of one episode are coalesced |
| Stale sources | A sound without an update for 20 s, or speech for 30 s, is treated as ended (`source_stale`) — covers a classifier that stops in the background and an interrupted session |
| Bounds | 48 episodes (least important, oldest, unpresented evicted first), 8 sources per episode, 8 remembered occurrences, one memory entry per kind |

Decisions: `SHOW` (present), `UPDATE` (update), `SUPPRESS` (no intent, or dismiss if it was shown),
`DEFER` (none), `RESOLVE` (dismiss after a linger of 4–20 s, during which the episode can resume),
`EXPIRE` (dismiss now). Simultaneous events are decided in arrival order; several high-priority
episodes are all presented; `AttentionSnapshot.presented` orders them by priority, then recency.

Time: every input carries its date; the engine keeps a monotonic clock and exposes `nextDeadline`.
The host sends one `.tick` at that time. Nothing polls.

## 8. Interface for Window 5

`AttentionController.onIntent: ((AttentionPresentationIntent) -> Void)?` (main actor), plus
`AttentionController.presented` for the full current list.

```swift
public struct AttentionPresentationIntent: Identifiable, Hashable, Sendable, Codable {
    public var id: AttentionEventID          // stable for the episode
    public var revision: Int                 // increases with every published change
    public var action: PresentationAction    // present / update / dismiss
    public var interruption: PresentationInterruption  // none / passive / active / timeSensitive
    public var priority: AttentionPriority   // ambient < low < normal < high < urgent
    public var category: AttentionCategory   // 15 user-facing categories
    public var title: String                 // generic, lock-screen safe ("Horn", "Nearby Speech")
    public var subtitle: String?             // generic, lock-screen safe ("Nearby speech afterwards")
    public var symbolName: String            // SF Symbol
    public var timestamp: Date
    public var expiresAt: Date?              // dismiss: when to remove; otherwise latest end of presentation
    public var isUncertain: Bool             // do not word it as a fact
    public var reasons: [AttentionReason]
    public var hasPrivateDetail: Bool
    public var privateDetail: String?        // validated speech headline; not encoded
}
```

Rules for the consumer:

- `present` starts an episode, `update` replaces its content, `dismiss` removes it at `expiresAt`.
  After a dismiss with a future `expiresAt` (RESOLVE) an `update` for the same id may still arrive;
  after a dismiss at `timestamp` the id is final.
- `interruption` is a suggestion; map it to what the platform allows. Most updates are `none`.
- `title` and `subtitle` may go on the lock screen. `privateDetail` is speech-derived: show it in
  the app, and elsewhere only with the user's opt-in. `AttentionEvent` and the intent leave it out
  of their `Codable` form, so it cannot be persisted or exported by accident.
- No Live Activity, Dynamic Island, haptic or notification is produced in Window 4.

## 9. App integration

- `ListeningController` owns `AttentionController` (not a view). Session start and end, sound
  updates, speech results and "speech data cleared" are forwarded on the main actor; pipeline
  outputs that arrive after Stop are dropped.
- One `Task` sleeps until `nextDeadline`; it is replaced when an input changes the deadline.
- Preferences: `AttentionPreferences` as JSON in `UserDefaults` (`attention.preferences.v1`); a
  missing or unknown value falls back to its default. Mode, speech attention, one setting per
  category (automatic / muted / low / normal / high), restore defaults.
- Screens: Attention card (mode switch, presented episodes), Attention settings, Attention
  decisions (state, budget, active and tracked episodes, fusion results, cooldowns, decisions with
  reason codes, share report) with **synthetic event injection** (single sounds, speech variants,
  any of the 18 scenes in real time) that uses no microphone.
- Privacy: the decision log (200 entries) and the shared report hold metadata only; speech-derived
  text is removed before a decision is logged. Switching transcription off removes speech sources
  and their text from the engine at once. Nothing is stored except preferences.
- Concurrency: Swift 6. The engine is a `Sendable` value type mutated on the main actor only. No
  work on the audio thread.

## 10. Known limitations

See `docs/WINDOW4_ATTENTION_PRIORITY_REPORT.md` §7.
