# Hearing Sense — Final Product Architecture (Window 7)

Written 2026-10-11. Branch `feature/window7-product-integration`, worktree
`.claude/worktrees/window7`. Not merged, not pushed. Verified on the Mac and in the iOS
Simulator only; nothing of this window ran on a physical iPhone. Code state: commit `f765725`.

Hearing Sense is an ambient-awareness app for people who wear AirPods. It is an awareness aid,
not a safety or emergency system.

## 1. The product: three features and one switch

| | Feature | Where the user meets it |
|---|---|---|
| A | **Continuous ambient and scene awareness** | The icon of the current sound in the Dynamic Island; the scene ("Traffic nearby") as a secondary line |
| B | **Prominent alerts for the highest-priority acoustic events** | A warning icon with a priority mark; if the user allows it, a request to iOS to expand the island |
| C | **A two-minute conversation summary on request** | "Summarize" in the expanded Dynamic Island or in the app; then optionally Continue and Stop |

The interaction contract:

| Control | Does | Never does |
|---|---|---|
| **Action Button** (long press) | Listening **on** / **off** | Summarize, open a menu, Continue, stop a conversation |
| **Dynamic Island** | Shows the current sound; alerts | — |
| **Touch and hold the island** | Reveals the expanded presentation with its controls | Summarize anything by itself |
| **Summarize** | Summary of what was transcribed in the last 120 seconds | Stop anything; run without being pressed |
| **Continue** | Follows the conversation: live captions, a summary that grows | — |
| **Stop** | Ends following the conversation | Stop listening for sounds |

Not part of the product: continuous personal semantic attention (goals, "about me", relevance
classification of every sentence). See §9.

## 2. Integration baseline

Audit of 2026-10-11 (read-only): the history is linear, `main` → Window 2 → 3 → research →
4 → 5 (`eddc450`) → 6 (`ead23f3`) → 6.1 (`a979cf9`) → 6.2 (`197d0d0`) → 6.3 (`df2a699`). The
main checkout (Window 5 branch) held uncommitted work: 19 modified and 5 new files (the four
fixes after retest R1, the session time limit, the warning near-miss log, the settings audit).

| Candidate | Has | Why not / why |
|---|---|---|
| Window 5 `eddc450` | Island, attention engine | No icons redesign, no recap, no history |
| **Window 6 `ead23f3`** | Everything above + icon redesign, recap, continued understanding, history, and the *first* semantic attention engine | **Chosen.** The last state with all reusable features |
| Window 6.3 `df2a699` | The same + three rounds of semantic research | W6.1–6.3 changed only `SemanticAttention`, its evaluation tools and their wiring in three app files (checked with `git diff ead23f3 df2a699 -- apps packages`): nothing the product keeps, and more to remove |

On top of `ead23f3` the Window 5 session's uncommitted work was applied as a patch
(`git diff` of the main checkout, plus its five new files copied). The main checkout was only
read. One conflict (`ListeningController`, the speech forwarding closure): both sides kept.
Commit `faf8b35`. All earlier branches and worktrees are untouched.

## 3. Components and where they come from

```
microphone tap (W1) ──┬─▶ SoundRecognitionEngine (W2, Apple Sound Analysis) ─▶ confirmed sound events ─┬─▶ AmbientIconStream (W5/W6 icons) ─┐
                      │                                                                               ├─▶ AttentionEngine (W4) ──intents──┤
                      │                                                                               └─▶ AcousticSceneTracker (W7) ──────┤
                      └─▶ speech pipeline (W3, SpeechTranscriber; only if the user turned it on)                                          ▼
                              └─▶ RollingConversationBuffer (W6, 120 s, memory) ── Summarize (W7) ──▶ recap engine (W6, Foundation Models)   IslandPipeline (W5 + W7)
                                                                                         │                      │                            ▼
                                                                                         └── SwiftData History (W6)   state ─────────▶ one Live Activity
```

| Component | Source | Module / file | Change in Window 7 |
|---|---|---|---|
| Audio session, capture, route | W1 | `HearingSenseAudio` | none |
| Sound classifier, taxonomy (303 labels → 51 kinds), detector | W2, W5 fixes | `SoundEventDetection` | none (near-miss log from the W5 session) |
| Speech pipeline | W3 | `SpeechPipeline`, `SpeechIntelligence`, `SemanticSummary` | automatic headline hard-off in release builds |
| Attention engine (priority, fusion, cooldowns) | W4 | `Attention` | none |
| Icon channel, 303-label icon catalog, custom glyphs | W5, W6 | `IslandPresentation`, `IslandViews` | none |
| Live Activity pipeline, alert gate, lock estimate | W5 | `IslandPresentation` | conversation state, scene title, speech never requests, lifetime policy |
| Rolling buffer, recap engine, validator, summarizer | W6 | `ConversationUnderstanding` | explicit Summarize input; no-summary outcome |
| History | W6 | app `Conversation/ConversationHistoryStore` | goal store removed |
| **Listening switch** | **W7** | `HearingSenseAudio/ListeningSessionMachine` | new |
| **Scene layer** | **W7** | `HearingSenseDomain/AcousticScene`, `SoundEventDetection/AcousticSceneTracker` | new |
| **Intents** | **W7** | app `Listening/ListeningIntents`, `apps/ios/Shared/HearingSenseActions` | new |

## 4. Listening session (the switch)

`ListeningSessionMachine` — a value type without a clock; the host carries out its effects.

```
            toggle / start                captureStarted
   off ───────────────────▶ starting ───────────────────▶ on ◀──────────┐
    ▲                          │ captureEnded(startFailed)  │ interrupted │ captureStarted (resume)
    │                          ▼                            ▼             │
    └──────────────────────── off ◀── toggle / stop ── interrupted ───────┘
```

- A request during `starting` is **refused**, not queued. Two presses cannot make two sessions.
- An interruption (a call, Siri) keeps the session; a toggle while interrupted turns it off.
- After every input the record (`isOn`, session id, start time, last end reason) is stored in
  `UserDefaults`. A launch that finds `isOn == true` logs that the previous process ended while
  listening and stays **off**: the microphone starts only when the user asks.
- `ListeningController` is one shared instance (`ListeningController.shared`) so intents reach
  it without a scene. The app's buttons, the intents and the debug arguments all go through
  `start`, `stop`, `toggle`.

**ON** activates the audio session, starts capture, sound recognition, the attention engine,
the scene tracker and the one Live Activity; the speech pipeline transcribes only if
"Transcribe nearby speech" is on, and only then does the two-minute buffer fill.
**OFF** stops capture and recognition, ends a followed conversation (its summary is finalized
and stays saved), deletes the temporary transcript, ends the Live Activity and deactivates the
audio session. The app is not terminated.

Action Button: `ToggleHearingSenseIntent` (`AudioRecordingIntent` + `LiveActivityIntent`).
See `docs/research/DYNAMIC_ISLAND_API_LIMITS.md` §2 for what is and is not verified.

## 5. Dynamic Island

One Live Activity per listening session. Never one per sound, never one per summary.

| Presentation | Shows |
|---|---|
| Compact, leading | The app's ear; a bubble while a summary is written, ready or a conversation is followed; an alert's icon |
| Compact, trailing | The current sound's icon; an alert's priority mark |
| Minimal | The one icon |
| Expanded (touch and hold) | Leading: the icon. Center: the sound's name and "Listening · *scene*", or an alert's title, or the state of a requested summary with its first lines. Trailing: timer. Bottom: the controls |
| Lock Screen | Icon, "Hearing Sense", a generic state, timer. No event text, no speech text, no controls |

Controls by state: Summarize → (writing…) → Continue · Open → Stop · Open. They are
`LiveActivityIntent`s that iOS runs in the app's process; a tap elsewhere opens the app
(`hearingsense://conversation` while a summary exists).

Rules kept from Window 5: ordinary sounds are silent icon changes (at most 12 per minute,
coalesced, newest sound first); the 303-label icon mapping and the nine custom glyphs are
unchanged; speech-derived text is in the content only while "Show speech summaries" is on and
the iPhone is not judged locked; logs and exports never contain it.

## 6. Summarize / Continue / Stop

`ConversationSessionMachine` with the policy `.product`:

```
                 Summarize                  summary written + saved
   idle ───────────────────▶ summarizing ─────────────────────────▶ summaryAvailable ──(90 s, no choice)──▶ idle
     ▲  ▲                         │ no summary (too little said,          │ Continue
     │  │                         │ model unavailable): explained,        ▼
     │  └─────────────────────────┘ nothing saved                     continuing ──(new speech, after a pause)──▶ update saved
     │                                                                    │
     └───────────── Stop · listening OFF · transcription OFF · 30 min ────┘   (summary finalized, temporary text deleted)
```

- **Summarize** is user-initiated only. The machine has no input that starts a summary from
  speech (test: ten minutes of utterances and ticks produce no effect).
- It uses `RollingConversationBuffer` with the standard policy: look-back **120 s**, retention
  135 s, at most 80 utterances and 6 000 characters, in memory. The buffer fills only while
  "Transcribe nearby speech" is on.
- Transcription off when Summarize is pressed: the app says that summaries need it and that
  speech from before it is turned on cannot be recovered. Nothing is invented.
- The summary is written by Apple Foundation Models on the device
  (`FoundationModelRecapSummarizer`) and checked by `RecapValidator` (Window 6): numbers, days,
  times and names must come from the transcript, and each statement must be supported by it.
  Window 7 added one check: a statement that is, word for word, a whole spoken sentence is
  removed, so that a saved summary cannot turn into a saved transcript. If the model is
  unavailable or the text fails the checks, there is no summary and nothing is saved.
- An update during Continue is written as an **addition**: the model summarizes only what was
  said since, and the earlier text is kept unchanged in front of it.
- **Continue**: live captions in the app (large adjustable text, final and tentative told
  apart), incremental updates only when something new was said and the speakers paused (or
  the text is about to expire), a bubble in the compact island, "Following the conversation"
  in the expanded one.
- **Stop** ends the conversation only: the saved summary is marked completed, the temporary
  captions are deleted, and listening for sounds goes on. The Action Button is not involved.
- Turning listening **off** during a followed conversation finalizes the summary and ends
  everything.

Language-model use in the whole app: one call per Summarize, one per update of a followed
conversation. The Window 3 per-utterance headline is off in release builds.

## 7. Scene awareness

`AcousticSceneTracker` (value type, deterministic, no clock):

1. Each confirmed sound event is evidence for one scene, or for none
   (`AcousticScenePolicy.scene(for:)`): speech, laughter, crowd → conversation; vehicles,
   horns, sirens, reversing beeps → traffic; wind, rain, water, birds, insects → nature;
   music → music; household and device sounds → indoor; dogs, footsteps, coughs, bangs → none.
2. Evidence = seconds of the event inside a rolling **60 s** window × a weight for its quality
   (weak 0.5, moderate 0.8, strong 1). A short sound counts as at least 2 s.
3. Candidate: under 4 s of evidence in total (after 20 s of listening) → **quiet**; a leader
   with ≥ 10 s and ≥ 55 % of the evidence → that scene (≥ 40 % is enough to *stay*); several
   kinds with no leader → **mixed**; otherwise the current scene stays.
4. The candidate replaces the current scene only after leading for **10 s** without a break,
   and never before the current scene has lasted **20 s**.

Scenes: quiet, indoor, conversation, traffic, nature, music, mixed. The titles describe sounds
("Traffic nearby"), never a place. No language model, no location, no audio. The tracker is
looked at every 5 s while evidence is in the window and needs no timer once a quiet scene has
settled. The scene is secondary: a line in the app and in the expanded island; a scene change
alone never causes a Live Activity update.

All thresholds are first values chosen on scripted events. None has been tuned on real sound.

## 8. Alerts for the highest-priority acoustic events

Separate layers, each with its own rule:

| Layer | Rule | Where |
|---|---|---|
| Confidence | Per-kind score thresholds | `DetectionPolicy.standard` (W2) |
| Multi-window confirmation | k-of-n windows per kind; e.g. `screaming` needs two | `SoundEventDetector` (W2, W5) |
| Priority | Policy table per sound kind and mode; urgent: sirens, alarms; high: horns, knocks, glass | `AttentionConfiguration.standard` (W4) |
| Deduplication, cooldown, fusion | One episode per event; repeats update it | `AttentionEngine` (W4) |
| One request per episode; rate limit | 6 s between requests, urgent exempt | `IslandPipeline` (W5) |
| Acoustic only | A speech episode never requests | `IslandPolicy.speechMayRequestExpansion = false` (W7) |
| User preference | "Expand for important events", **off by default** | `IslandSettings` |
| Lock gate | Sent only when the iPhone is judged unlocked | `AlertGate` (W5) |
| Expiry and recovery | An episode leaves at its expiry; a later one can request again | `IslandPipeline` |

With the preference off, a high-priority sound still changes the island to its warning icon
with a priority mark — silently. With it on, the app additionally asks iOS for an expansion
through `AlertConfiguration`; iOS decides. The settings screen states what that can cause
(a lit screen in the seconds after locking; a sound if the alert sound is on). No notification
is ever scheduled; no Critical Alerts entitlement is used. Reliability on real sound is not
established: in Window 5's device session 6 of 9 high-priority episodes in ten minutes were
room sounds, and one siren clip was missed in a loud room.

## 9. What was switched off

Removed from the app (the code stays in the `SemanticAttention` package module, with its tests
and tools, and on the branches of Windows 6–6.3):

- attention goals and their screen; the "about me" line (it existed only on the W6.3 branch);
- `SemanticAttentionEngine`, the relevance reasoner, the evidence verifier, the inference queue;
- goal matches as attention episodes (the engine's `.semantic` input still exists in the
  package; the app never sends it);
- the "Recap Conversation" shortcut for the Action Button;
- the separate "Keep recent speech for recaps" switch and the look-back picker (the buffer is
  two minutes and follows "Transcribe nearby speech").

The app target does not link `SemanticAttention`. `ProductionAuditTests` fails if an app source
file mentions it, if the project file links it, or if the app opens a language-model session of its own.

## 10. Privacy

| Data | Where | How long |
|---|---|---|
| Microphone audio | Memory (analysis buffers, 5 s pre-roll for the recognizer) | Seconds; never written, never uploaded |
| Sound events, scene | Memory | The session |
| Transcribed sentences | Memory, only while "Transcribe nearby speech" is on | 120 s (135 s at most); deleted at once on Stop, OFF, or when transcription is switched off |
| Summaries the user asked for | SwiftData file in Application Support, excluded from backups, data protection until first unlock | Until the user deletes them |
| Live Activity content | Held by iOS for the widget extension | The session; summary text only while unlocked and allowed |
| Session record | `UserDefaults`: on/off, id, times, end reason | Overwritten |
| Diagnostics, logs | Counts, states, timings | No audio, no sentence, no summary |

Everything is processed on the iPhone. `PrivateCloudComputeLanguageModel` is not used.

## 11. Audio

Unchanged: `playAndRecord`, mode `default`, options `mixWithOthers`, `allowBluetoothA2DP`,
`defaultToSpeaker`; built-in microphone preferred; no HFP, no ducking; background modes `audio`
and `processing`. Window 7 changed no file of the audio session, the capture or the Info.plist
(`git diff faf8b35 -- packages/HearingSenseKit/Sources/HearingSenseAudio apps/ios/Config`
shows one new file, the switch). The only new audio-related behaviour is that the session can
be started by an intent while the app is not on screen, which is untested on a device.

## 12. Limits that are known

See `docs/testing/WINDOW7_ACCEPTANCE_REPORT.md` §6 and `docs/PROJECT_HANDOFF.md` §8.
