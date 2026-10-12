# Window 7 Acceptance Report — Product Integration and Stabilization

2026-10-11. Branch `feature/window7-product-integration`, worktree `.claude/worktrees/window7`.

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
| `swift test` (Mac) | **474 test results passed**, 9 skipped (opt-in or recognizer tests without their signals), 0 failed. 413 at the baseline; 61 new |
| `xcodebuild test`, package, iOS Simulator | **475 passed**, 10 skipped, 0 failed |
| App + widget extension, Debug, Simulator | Build succeeded |
| App + widget extension, Release, generic iOS device, unsigned | Build succeeded |
| Self-test in the Simulator, 28 checks over the 18 acceptance tests | **28 passed, 0 failed** (final build, with on-disk history) |
| Summary evaluation, real on-device model, Mac | dev 13/13 facts, 3/3 negations; held-out 25/26 facts, 4/4 negations; 8 of 8 summaries written |
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
| 15 | Eight-hour Live Activity expiration is handled | `ActivityLifetimeTests` (5) | Not exercised (no 7-hour run) | **Not verified** |
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
a fresh measurement.

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
| Prominent alerts are off by default | Feature B is a silent warning icon until the user turns "Expand for important events" on | The student's decision (Window 5 rule: not on by default without device evidence) |
| A possible spoken warning no longer requests an expansion | Speech is never an alert in this product | By the brief; `IslandPolicy.window5` restores it |
| The copy check costs facts | 1 of 26 in the held-out scenes | Accept, or lower the bar only for sentences with a date or number (not done) |
| The summary of a followed conversation only grows | 30 minutes can give a long text | The followed session ends by itself after 30 minutes |
| An update that fails its checks drops that stretch of speech from the summary | Seen as "nothing new" in the log | The captions stay readable for two minutes |
| No controls on the Lock Screen | Summarize needs the unlocked island or the app | By design (no speech text on the Lock Screen) |
| Release build still contains debug screens and scripted scenes | App size and surface (since Window 4) | Gate before a release |
| `--hs-w7-selftest` calls `perform()` directly | The system's intent routing is not exercised | Device steps |
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
| W7-10 | A siren clip with "Expand for important events" off, then on; watch the locked screen | on |
| W7-11 | Swipe the activity away while listening; open the app again | on |
| W7-12 | Scene line during five minutes each of music, a street recording, quiet | on |
| W7-13 | Thirty minutes locked with Spotify: classifier failures, updates per hour, battery percent before and after | on |
| W7-14 | Eight hours (or as long as allowed): what happens at the activity's limit | on |
