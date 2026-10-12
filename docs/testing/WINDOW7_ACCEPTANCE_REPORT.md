# Window 7 Acceptance Report — Product Integration and Stabilization

2026-10-11. Branch `feature/window7-product-integration`, worktree `.claude/worktrees/window7`.
Code state: commit `f765725` (baseline `faf8b35`, M1 `f6d9849`, M2 `4bd6701`, M3 + M4 `15859d2`, M5 `262eed4`).

**Where things ran.** The Mac (macOS 27.2, M1 Max) and the iOS 27.0 Simulator (iPhone 18 Pro
Max). **Nothing ran on a physical iPhone**, and no microphone was used anywhere: sound events
came from scripted scenes and "speech" was text written for this project, entering where
transcribed utterances would. Each result below carries one of these labels:

| Label | Meaning |
|---|---|
| **Unit** | Deterministic test of the logic on the Mac (`swift test`) |
| **Sim** | Seen in the running app in the Simulator, microphone off (`--hs-w7-selftest`) |
| **Build** | Checked on the built product or the sources |
| **Not verified** | Needs the physical iPhone |

"Sim" shows that the app's parts work together. It does not show that iOS behaves the same on
a device, and it says nothing about recognition quality, the background, battery or touch.

## 1. Summary

| | Result |
|---|---|
| `swift test` (Mac) | **488 test results passed**, 9 skipped (opt-in or recognizer tests without their signals), 0 failed. 413 at the baseline; 75 new (474 before the final decisions, §8) |
| `xcodebuild test`, package, iOS Simulator | **475 passed**, 10 skipped, 0 failed (before the final decisions; not repeated after them, §8) |
| App + widget extension, Debug, Simulator | Build succeeded |
| App + widget extension, Release, generic iOS device, unsigned | Build succeeded |
| Self-test in the Simulator, 28 checks over the 18 acceptance tests | **28 passed, 0 failed** (final build, with on-disk history) |
| Summary evaluation, real on-device model, Mac | dev 13/13 facts, 3/3 negations; held-out **26/26** facts, 4/4 negations (25/26 before §8); 8 of 8 summaries written |
| Physical iPhone | **Nothing run** |

One privacy defect of the inherited code was found by the storage check and fixed (§4.1).

## 2. The 18 acceptance tests

| # | Requirement | Unit | Sim | Device |
|---|---|---|---|---|
| 1 | OFF → ON using the App Intent | `ListeningSessionMachineTests.aToggleTurnsItOnAndTheNextOneOff` | `ToggleHearingSenseIntent.perform()` → session on, state Listening, one Live Activity running | **Not verified**: Action Button, background launch, locked iPhone, real microphone |
| 2 | ON → OFF using the App Intent | same | session off, state Not listening, 0 activities | **Not verified** |
| 3 | Repeated toggles create no duplicate session | `requestsDuringAStartAreRefusedNotQueued`, `manyTogglesAlternateAndEveryStartIsANewSession` | 9 toggles (two of them issued together): started 5, ended 4, exactly 1 activity alive | **Not verified**: a toggle during the permission prompt or a slow audio-session start |
| 4 | Ordinary sounds update the icons | `ordinarySoundsChangeTheIconSilentlyInTheOneActivity` | scripted rain / dog / bird: icon changes, content `ambient` | Window 5 device runs (D5, D6, R1) for the icon channel; not rerun |
| 5 | Speech does not auto-summarize | `speechAloneNeverStartsASummary` (10 minutes of utterances, no effect) | 7 sentences: phase idle, 0 summaries, History unchanged | **Not verified** with real speech |
| 6 | Expanded island gives access to Summarize | `aRequestedSummaryIsShownAtOnceAndAsksForOneExpansionWhenReady` (content drives the controls) | Content without a conversation state → `IslandControls` shows Summarize; `SummarizeConversationIntent.perform()` starts the summary; preview screenshots | **Not verified**: touch and hold, a real press of the button |
| 7 | Summarize uses only the authorized previous 120 s | `Window7BufferTests` (4) | A sentence dated 200 s earlier is neither buffered nor in the summary; nothing is buffered while transcription is off | **Not verified** |
| 8 | Continue starts continued understanding | `continueFollowsAndStopEndsOnlyTheConversation` | phase continuing, island `following`, 3 new captions, 1 update holding the new facts | **Not verified** |
| 9 | Stop ends understanding, ambient monitoring stays | same | phase idle; state Listening; session on; 1 activity | **Not verified** |
| 10 | Final summary saved to History | `summarizeWritesSavesAndOffersContinue` | 1 record after Summarize, `completed` after Stop (SwiftData, on disk) | **Not verified** |
| 11 | OFF ends the overall session cleanly | `turningListeningOffFinalizesAFollowedConversation`, `aToggleWhileInterruptedTurnsItOff` | OFF while following: phase idle, captions 0, scene none, 0 activities, 2 saved summaries both `completed` | **Not verified**: audio session released, Spotify unaffected |
| 12 | Highest-priority events trigger the presentation request | `aHighestPriorityAcousticEventAsksForAnExpansion`, `inTheScriptedScenesOnlyImportantAcousticEventsAskForAnExpansion` | scripted siren: 1 request, content `attention … urgent "Siren"`; the gate held it back (`disabled_in_settings`: the default) | Window 5 D4 (expansion with the setting on). **Not verified** in this build |
| 13 | Ordinary sounds remain silent | same + `ordinarySoundsChangeTheIconSilentlyInTheOneActivity` | 0 requests, 0 sent to iOS during the ordinary scene | Window 5 D4–D6: silent updates did not wake the locked screen (student-observed). Not rerun |
| 14 | No continuous semantic relevance model calls in production | `ProductionAuditTests` (3): no app source mentions the module, the project does not link it, the app opens no model session | Model calls in the run: 2 summaries + 1 update, all requested | — |
| 15 | Eight-hour Live Activity expiration is handled | `ActivityLifetimeTests` (5): nothing is replaced, nothing is requested after the limit (§8) | Not exercised (no 8-hour run) | **Not verified** |
| 16 | Spotify / AirPods integration not broken by code changes | Existing audio policy tests pass | — | **Not verified.** Evidence is indirect: no file of the audio session, the capture or the Info.plist changed (`git diff faf8b35 -- packages/HearingSenseKit/Sources/HearingSenseAudio apps/ios/Config`: one new file, the switch) |
| 17 | No unauthorized transcript persistence | `Window7VerbatimTests` (3), `itEmptiesItselfWhenNobodySpeaksAndWhenCleared` | App container scanned after a run with on-disk history: none of the 10 spoken sentences and not the old sentence's marker word in any file; files written: the SwiftData store, preferences (session record), the self-test report | **Not verified** |
| 18 | No background summary without an explicit request | `speechAloneNeverStartsASummary`, `summarizeNeverStopsAnything` | Summarize while OFF does nothing; model-call count equals the requests | **Not verified** |

## 3. Builds and regression

| Check | Environment | Result |
|---|---|---|
| `swift test` | Mac | 474 passed, 9 skipped, 0 failed |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27.0 Simulator, iPhone 18 Pro Max | **TEST SUCCEEDED**: 475 passed, 10 skipped (no `SpeechTranscriber` in the Simulator; opt-in tests), 0 failed |
| App Debug | Simulator | Succeeded, 0 warnings from the app's sources |
| App Release, unsigned | generic iOS device | Build succeeded; the extension is embedded; 12 MB |
| Intent metadata of the built app | Build | Toggle / Start: AudioRecording, SessionStarting, ForegroundContinuable; Stop; Summarize / Continue / Stop Understanding not discoverable, present in app and extension |

Seven Window 5/6 tests that expected a *speech* episode to request an expansion now name the
earlier rules explicitly (`IslandPolicy.window5`); one Window 6 recap test used a scripted
summary that was a copy of the transcript and was reworded.

### Self-test (Simulator)

`xcrun simctl launch <UDID> org.hearingsense.HearingSense --hs-w7-selftest [--hs-w7-persist]`,
report in the app's `Documents/hearing-sense-w7-selftest.txt` (states, counts, timings; no
text). The report of the final build is in `results/window7_simulator/selftest_persist_final.txt`.

Real in it: the app's object graph, the listening switch, the intents' `perform()` (called
directly, not through Shortcuts or the Action Button), ActivityKit requests and updates, the
conversation state machine, the on-device language model, SwiftData. Synthetic: the microphone
(off: `--hs-synthetic-capture` skips the audio session and the engine), the sound events, the speech text.

### Summary evaluation (Mac, real on-device model, synthetic conversations)

`swift run hs-semantic-eval recap --split dev|heldout`; results in `results/conversation_eval_window7/`.

| | Window 6 | Window 7 |
|---|---|---|
| dev (3 scenes): summaries / facts / negations | 3 / 13 of 13 / 3 of 3 | 3 / 13 of 13 / 3 of 3 |
| held-out (5 scenes): summaries / facts / negations | 5 / 26 of 26 / 4 of 4 | 5 / **25 of 26** / 4 of 4 |
| continued: earlier facts kept, later facts added | 10 of 10, 3 of 3 | 10 of 10, 3 of 3 |
| statements removed by the checks | 11 of 91 | 16 of 91 (5 of them as copies) |

The one lost fact ("the lot reopens on Friday") was a sentence the model copied word for word;
the new copy check removed it (§4.1). The held-out set has been seen since Window 6 and is not
a fresh measurement. **Superseded by §8.4:** the copy is now restated in memory and the fact is kept (26 of 26).

## 4. Findings of this window

### 4.1 A saved summary could contain the transcript (fixed)

The storage check found two spoken sentences word for word in the SwiftData store. Cause: when
asked to extend a recap during "Continue", the on-device model returned the earlier recap with
the three new utterances appended unchanged. Window 6's checks passed them, because a copy is
fully supported by its source.

Fixes: (1) `RecapValidator` removes any statement of five or more words that is, word for
word, a whole sentence or utterance of the transcript (`copied_from_transcript`); (2) an update
is now written as an *addition* — the model summarizes only what was said since, and the
earlier recap is kept as it is in front of it; (3) an update that adds nothing but copies
changes nothing. After the fix: no spoken sentence in the container, and the update still
holds the new facts (self-test checks 8 and 17).

What this does not guarantee: a summary uses the speakers' words, and a copy that differs by
one word passes. It stops whole sentences from being stored as they were said.

### 4.2 An example in the prompt leaked into a summary (fixed before commit)

A first version of the fix added an example sentence to the model's instructions. The model
repeated the example's day in a summary of a conversation that never mentioned it; the
validator removed the statements and the summary with them, and one request ended without a
summary. The recap instructions are back to the Window 6 wording, and no instruction contains
an example with a day, a time or a number.

### 4.3 Summary time

8–11 s per summary in the Simulator (eight summaries); on the Mac the median was 6–7 s and the longest 8.6 s. On the iPhone the Window 3
measurements suggest the model is slower in the background (6.1 s instead of 0.7 s for a short
call, once). Unmeasured for a two-minute summary.

## 5. Resources

All on Mac hardware. None of this is an iPhone measurement, and in the Simulator runs the
microphone, the sound classifier and the transcriber were not running.

| Measurement | Value |
|---|---|
| Self-test, whole run (about 90 s, includes 3 model calls) | 3.0–5.0 % of one core on average (six runs) |
| 20 s with a session on, scripted events, no speech | 0.6–0.9 % of one core in five runs, 1.7 % in one (a debug screen was open) |
| Memory footprint | 29 MB at launch, 48–51 MB after the model was used |
| Live Activity updates in the run | 21; 5 activities started (one per session), never two alive |
| Scene tracker, per input (debug build, Mac) | 15 µs |
| Island pipeline, per input (debug build, Mac) | 22 µs |
| Language-model calls | 2 summaries + 1 update per run; none without a request |

The scene tracker schedules a look every 5 s while evidence is in its window and none once a
quiet scene has settled. Battery life over a day is **unverified**; the earlier device data is
one 35-minute run on a charger (Window 5).

## 6. Known defects and limits

| | Impact | Handling |
|---|---|---|
| **Nothing of Window 7 ran on an iPhone** | Every device column above | §7 |
| Starting from the Action Button in the background is an assumption about `AudioRecordingIntent` | If iOS refuses, ON works only with the app open | Fallback exists: the intent can continue in the foreground; decide after device step 2 |
| The scene thresholds were chosen on scripted events | Scenes may flicker or lag with real sound | Tune on recorded device events (`island-device-trace` has them) |
| ~~Prominent alerts are off by default~~ | Decided 2026-10-11: on by default, the locked iPhone only by opt-in (§8.1) | Device steps W8 measure what a locked screen does |
| A possible spoken warning no longer requests an expansion | Speech is never an alert in this product | By the brief; `IslandPolicy.window5` restores it |
| ~~The copy check costs facts~~ | Decided 2026-10-11: a copied sentence is restated in memory instead of deleted (§8.4); 26 of 26 | A restatement is mostly "Someone said that …" around the sentence; see §8.4 |
| The summary of a followed conversation only grows | 30 minutes can give a long text | The followed session ends by itself after 30 minutes |
| An update that fails its checks drops that stretch of speech from the summary | Seen as "nothing new" in the log | The captions stay readable for two minutes |
| No controls on the Lock Screen | Summarize needs the unlocked island or the app | By design (no speech text on the Lock Screen) |
| Release build still contains debug screens and scripted scenes | App size and surface (since Window 4) | Gate before a release |
| `--hs-w7-selftest` calls `perform()` directly | The system's intent routing is not exercised | Device steps |
| No touch on the real island, not even in the Simulator | A long press and a press on Summarize were to be tried in the Simulator at the end; the access request for the Simulator control was not answered (the student was away), so it was not done | Can be done in the Simulator with `--hs-synthetic-capture --hs-autostart` (go Home, touch and hold the island, press Summarize: "Transcription is off" should appear), or as device step W7-6 |
| Window 5's four post-R1 fixes are in this branch and still unverified on the device | As before | R2–R3 of the Window 5 protocol |

## 7. Remaining physical-device tests

Each step needs the student's authorization; one manual step per message; no real conversation
is recorded or transcribed without it. Synthetic speech can be played from the Mac.

| Step | What | Microphone |
|---|---|---|
| W7-1 | Install; open the app; Start and Stop with the buttons; Spotify on AirPods keeps playing | on, classification only |
| W7-2 | Shortcuts: "Toggle Hearing Sense" exists; run it from the Shortcuts app with Hearing Sense in the background | on |
| W7-3 | Assign it to the Action Button; long press from the Home Screen with the app **not running**: listening starts, island appears; long press again: it ends | on |
| W7-4 | The same from the locked iPhone | on |
| W7-5 | Press twice quickly; press during a phone call | on |
| W7-6 | Touch and hold the island: expanded view with the sound's name, the scene line and Summarize. Transcription off, press Summarize: "Transcription is off" | on, no transcription |
| W7-7 | Transcription on, synthetic sentences from the Mac's speakers, Summarize: summary in the island and in the app; time it | on, synthetic speech |
| W7-8 | Continue: captions in the app, an update; Stop in the island: listening goes on | on, synthetic speech |
| W7-9 | Action Button OFF while following: everything ends, the summary is in History | on |
| W7-10 | A siren clip with "Prominent alerts" on (default), then with "Also when the iPhone is locked" on; watch the locked screen | on |
| W7-11 | Swipe the activity away while listening; open the app again | on |
| W7-12 | Scene line during five minutes each of music, a street recording, quiet | on |
| W7-13 | Thirty minutes locked with Spotify: classifier failures, updates per hour, battery percent before and after | on |
| W7-14 | Eight hours (or as long as allowed): what happens at the activity's limit | on |

## 8. Final decisions of 2026-10-11 and what changed after the first report

The student accepted Window 7 as the baseline of the next stage and decided five points. This
section records what was changed for them and how it was checked. Sections 1–7 describe the
state before these changes unless a line says otherwise. Everything here ran on the Mac and in
the iOS Simulator; nothing on an iPhone.

| | Mac | Simulator |
|---|---|---|
| `swift test` | **488 passed**, 9 skipped, 0 failed (`results/window7_final/swift_test_mac.log`) | not repeated |
| App, Debug | — | Build succeeded |
| App, Release, unsigned, generic device | Build succeeded | — |
| Self-test, History on disk | — | **28 passed, 0 failed** (`results/window7_final/selftest_persist.txt`); 0 of 11 spoken sentences in any file of the app's container |
| Summary evaluation, real model | dev 13/13; held-out 26/26 (`results/conversation_eval_window7b/`) | — |

### 8.1 Prominent alerts for verified highest-priority acoustic events (decision 1)

- "Prominent alerts for urgent sounds" (`IslandSettings.expandsForImportantEvents`) is **on by
  default**. Settings stored by an earlier build are carried over once and take the new
  default for this one switch (`IslandSettings.migrated(fromVersion1:)`; the change is written
  to the settings audit). The other switches keep the user's values.
- A request is made only for an acoustic episode of priority **high or urgent** that the
  attention engine does **not mark as uncertain** (`IslandPolicy.alertMinimumPriority`,
  `alertsNeedVerifiedEvent`). The same episode may ask later, once it is verified. Ordinary
  sounds, scene changes and every speech episode stay silent.
- While the iPhone is judged locked, or the app cannot tell, the update is silent **unless the
  user opted in** with the new switch "Also when the iPhone is locked"
  (`IslandSettings.alertsWhileLocked`, off by default). A summary is never announced on a
  locked iPhone, opt-in or not.
- Only `Activity.update(_:alertConfiguration:)` is used. The settings text says that iOS
  decides and that nothing is guaranteed.

**Known residual risk, not removed by code:** the lock state is an estimate. Data protection
lags the lock by 4–12 s (measured in Window 5); iOS's earlier "will become unavailable" notice
closed that gap in the two runs that were instrumented. With the default now on, an alert in
the first seconds after locking could reach a locked screen without the opt-in. The settings
screen says so. Window 8 measures it (`docs/testing/WINDOW8_DEVICE_TEST_PLAN.md`, group F).

Tests: `AlertGateTests` (default, lock rule), `Window7PresentationTests`
(`anAlertOnTheLockedIPhoneNeedsTheUsersOptIn`, `settingsStoredBeforeTheDecisionTakeTheNewDefaultOnce`,
`onlyAVerifiedHighPriorityAcousticEventAsksForAProminentPresentation`). In the Simulator the
siren of the self-test produced one request, held back because the app was on screen
(`app_in_foreground`): no alert has been presented by iOS in this window.

### 8.2 Spoken warnings (decision 2)

Nothing was restored. `IslandPolicy.speechMayRequestExpansion` stays false, the app does not
link `SemanticAttention`, and `ProductionAuditTests` still guards both.

### 8.3 Live Activity lifetime (decision 4)

The replacement of an activity older than seven hours was removed: no `renew` job, no
`renewAfter`. In addition, when iOS ends the activity at its limit (it ended at least 7 h 50 min
after it was requested), **no activity is requested in its place for that session**; the status
says so, listening goes on, and the next listening session gets its own activity. What remains
is ordinary lifecycle: content updates, the keep-alive, ending the activity with the session,
ending leftovers of an earlier launch, and showing the activity again when the user opens the
app if it could not be started or was removed *before* its time.

That last case is an interpretation: the decision names replacement "to extend the eight-hour
presentation limit", and an activity the user swiped away after ten minutes is not that. If no
activity should ever be requested again within a session, `ActivityLifetimePolicy.decide` is
the one place to change (return `.stayEnded` for every missing activity).

Tests: `ActivityLifetimeTests` (5). Not exercised: any run long enough to reach the limit.

### 8.4 The lost fact, and summaries that must not become transcripts (decision 5)

**What was lost.** Held-out scene h05, fact "friday". The announcement ends with the utterance
"The lot reopens on Friday." The model put that sentence into the summary and into a key point
exactly as it was said (five words), and the copy check deleted both. A second key point, a
whole 15-word utterance, was deleted the same way. Nothing was wrong with the fact; the
sentence was simply too short to be said differently by a model that was not asked to.

**What changed.**

1. *Restating in memory instead of deleting.* A statement that repeats a spoken sentence is
   given back to the model with a short instruction to rewrite it as one sentence of reported
   speech (`ConversationSummarizing.restate`, at most three per draft, ten seconds together).
   The answer replaces the copy only if it passes `RecapValidator.restatementProblem` — the same
   numbers, days and times; the same negations; no new name; at least three quarters of the
   content words; one sentence; not much longer; not the spoken sentence again — and every
   ordinary check. Otherwise the statement is left out, as before. Nothing is shown or stored
   before these checks.
2. *The rule itself is unchanged.* No statement of five or more words that is, word for word,
   a whole spoken sentence or utterance is kept. An accepted restatement meets exactly the
   checks every model-written statement had to meet before.
3. *New: a limit on the whole text.* `RecapValidator.verbatimShare` measures the share of a
   text's words that lie in runs of six or more consecutive words of one utterance. A text
   above 0.65 is not a summary: it is not shown or saved (`too_much_verbatim`), and an update
   above it is not taken. This catches what the sentence rule cannot — utterances glued
   together with "and". The limit was chosen on the development scenes (0.13, 0.20, 0.44).
4. *New: a last check before storage.* `ConversationIntelligenceController.save` asks
   `ConversationRecapEngine.maySave` with the words still held in memory, whatever path the
   text took; a refused text is not written and the count is in the diagnostics.

**Result (Mac, real on-device model, `results/conversation_eval_window7b/`).**

| | Window 6 | Window 7 first report | Window 7 final |
|---|---|---|---|
| dev: facts / negations | 13 of 13 / 3 of 3 | 13 of 13 / 3 of 3 | 13 of 13 / 3 of 3 |
| held-out: facts / negations | 26 of 26 / 4 of 4 | 25 of 26 / 4 of 4 | **26 of 26** / 4 of 4 |
| copies restated / left out | — | 0 / 5 | 5 / 0 (dev 1, held-out 4) |
| statements removed by the checks | 11 of 91 | 16 of 91 | 11 of 91 |
| word-for-word share, max (first two columns recomputed from the saved texts) | 0.48 | 0.46 | dev 0.44, held-out 0.47 |
| held-out: model time per summary, median / max | 6–7 s | 6.8 s / 8.6 s | 6.8 s / 10.9 s |

**What this result does and does not show.**

- It is not a blind result. Scene h05 is the scene whose failure led to the change, and the
  held-out set has been read since Window 6. Five held-out scenes are a small sample.
- The restatements the on-device model wrote are the spoken sentence in reported speech:
  "Someone said that the lot reopens on Friday.", "Someone said that cars left in the north lot
  after six will be towed at the owner's expense." The fact is kept and no statement equals a
  spoken sentence, but this is a change of form, not of wording. What bounds how much of a
  conversation can end up in storage is the limit on the whole text, not the restatement.
- The 0.65 limit rests on three development scenes. A very short announcement summarized very
  tersely can exceed it and would then give "no summary" (the safe direction; not seen in the
  eight scenes).
- A restatement costs one more model request: up to about 2 s more per summary here.

Tests: `RecapRestatementTests` (6) and `RecapVerbatimShareTests` (5) in
`Tests/ConversationUnderstandingTests/RecapRestatementTests.swift`; the earlier
`Window7VerbatimTests` (3) are unchanged and pass.
