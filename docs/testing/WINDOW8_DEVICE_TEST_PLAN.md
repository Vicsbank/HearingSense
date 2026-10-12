# Window 8 — Physical Device Test Plan

Written 2026-10-11 for the iPhone 18 Pro, on branch `feature/window8-device-validation`
(baseline `68cb1a8`). **A plan only. No step has been run and none may be run until the
student authorizes its scope.** Findings behind it: `docs/testing/WINDOW8_PREFLIGHT.md`.

## Rules for every step

1. A step runs only inside a scope the student has authorized (P0–P8 below). Authorization
   for one scope says nothing about the next.
2. Manual steps are given one per message; the next one follows the student's report.
3. Every microphone run has an automatic time limit and starts with transcription forced off,
   unless the step is in group D or J. The microphone is never left on while waiting for an answer.
4. No real conversation is recorded or transcribed. Speech is macOS `say` from the Mac's
   speakers, in a room the student confirms is quiet.
5. What the student did not watch (screen wake, sound, vibration) is recorded as
   **Not verified**.
6. Evidence is metadata: the app's diagnostics file, the self-test report, island strip
   screenshots (full image deleted at once). No raw audio is kept. Saved test summaries are
   deleted at the end.
7. Phone automation stays in Hearing Sense and Settings and releases its owner lease after
   every test, also on failure.
8. Results are written to `docs/testing/WINDOW8_DEVICE_RESULTS.md` with three columns that are
   never merged: measured by the app, seen in a screenshot, seen by the student.

## Scopes (permissions)

| | Scope |
|---|---|
| P0 | One Debug-only commit: persisted test mode and three more report sections (preflight F1, F2). No device |
| P1 | iPhone over USB with the microphone off: build, sign, install, launch, read the app's files, terminate |
| P2 | Phone automation in Hearing Sense and Settings |
| P3 | Microphone for sound classification, transcription off, time-limited |
| P4 | Test sounds from the Mac's speakers |
| P5 | Transcription of synthetic speech |
| P6 | Tests the student watches (locked screen, sound, vibration) |
| P7 | AirPods and Spotify |
| P8 | Long runs (30 min locked; 30–60 min on battery; optionally 8 h) |

## Order

A → B → C → F → E → D → G → H → I → J → K. Groups A–C (synthetic part) need no microphone.
The order follows the student's priorities, except that the alert tests (F) come before the
icon tests (E) because the new default makes them the larger risk.

---

## A. Install and microphone-free baseline — P1 (P2 optional)

| | Step | Pass when | Evidence |
|---|---|---|---|
| A1 | Build, sign, install over the Window 5 build | Installed; app data kept | `devicectl` output |
| A2 | Launch with `--hs-synthetic-capture --hs-export-diagnostics`; do nothing | App runs; microphone permission state reported; no session | Diagnostics file |
| A3 | Read the settings audit and the Live Activity settings | "Prominent alerts" on (new default; if it was stored as off, one audit line "set by the app update"); "Also when the iPhone is locked" off; the other switches as before | Diagnostics file; strip of the settings screen |
| A4 | `--hs-w7-selftest` (synthetic capture: **microphone off**) | 28 checks pass on the iPhone, with the iPhone's own language model; summary time recorded | Self-test report |
| A5 | Same with `--hs-w7-persist`, then copy the container and scan it | No test sentence in any file; then the summaries are deleted | Scan output |

A4 calls the intents' code directly: it is not an Action Button test and proves nothing about
touch, background starts or the microphone.

## B. Action Button ON/OFF — P1 + P2, then P3; needs P0 first

One manual step first: the student assigns Settings → Action Button → Shortcut → Hearing
Sense → **Toggle Hearing Sense**. Record whether the shortcut is listed and whether any of
Summarize / Continue / Stop is offered there (expected: not).

**B-syn: test mode with synthetic capture (microphone never starts).** Checks the intent, the
process launch and the Live Activity.

| | Starting state | Student's action | Pass when |
|---|---|---|---|
| B1 | App on screen, off | Press and hold | ON; the state in the app changes; one Live Activity |
| B2 | App on screen, on | Press and hold | OFF; activity gone |
| B3 | Home Screen, app in the background, off | Press and hold | ON without the app opening; island appears; log shows `requested (intent)` |
| B4 | Home Screen, on | Press and hold | OFF; island gone |
| B5 | App terminated, off | Press and hold | Process launched in the background; ON; island appears. If iOS opens the app instead, record that |
| B6 | iPhone locked, off | Press and hold | Record exactly what iOS does (starts, asks to unlock, nothing) |
| B7 | iPhone locked, on | Press and hold | OFF; Lock Screen activity gone |
| B8 | Any | Press twice quickly, three times | Never two sessions; refusals logged; final state matches the number of presses or a press was refused |
| B9 | On, then terminate the app from the switcher, relaunch | — | Starts off; "previous session lost" logged; no microphone |
| B10 | On | While a summary state is shown | The button only switches off; it never summarizes, continues or stops a conversation |

**B-mic: the same with the real microphone** (P3; transcription off; time limit 3 minutes per
run through the persisted test mode). Only B1–B7. This is the part that answers preflight F4:

| | Question | Recorded |
|---|---|---|
| Bm3/Bm5 | Does the audio session activate when the intent runs in the background, with the app not on screen or not running? | `state=`, classifier windows growing, audio-session trace, orange indicator (student) |
| Bm6 | From the locked iPhone? | Same; what the Lock Screen shows |
| Bm4/Bm7 | Does OFF release the microphone at once? | "microphone released" in the log; indicator gone (student) |
| Bm-limit | Does the time limit fire in a process the intent started? | `timeLimit=fired` |

Stop condition: if the microphone stays on after OFF or after the time limit, terminate the
app from the Mac and stop the group.

## C. Dynamic Island interactions — P1 + P2 (+ P3 for the real session)

Session on, another app (Settings) in front. First with synthetic capture, then once with the
real microphone, transcription off.

| | Action | Pass when |
|---|---|---|
| C1 | Look at the compact island | Ear glyph or sound icon; no text |
| C2 | Touch and hold | Expanded view: sound or "Listening", scene line, **Summarize last 2 min**. Nothing starts by the touch alone (summary requests stay 0) |
| C3 | Press Summarize with transcription off | Island says that past speech cannot be recovered; no model call; the notice goes away by itself |
| C4 | Tap the island (not a button) | The app opens |
| C5 | A second Live Activity is running (a timer) | Minimal presentation shows; nothing breaks; record which app gets the leading side |
| C6 | Press a button while the app has been in the background for 2 minutes (real microphone) and for 2 minutes with synthetic capture (the app is then suspended) | The intent reaches the app both times; delay from press to island change recorded |
| C7 | Rotate through light and dark appearance, largest text size | Nothing clipped in the expanded view (strip screenshots) |

Whether automation can touch the island is itself a result (preflight F5). If it cannot, the
student does C2–C6 by hand, one per message.

## F. Alerts for the highest-priority sounds — P3 + P4 + P6

ActivityKit alert updates. These are **not** Critical Alerts: the app has no such entitlement
and schedules no notification. iOS decides what is presented; a pass means "the request was
made and this is what iOS did", never "expansion is guaranteed".

Siren and alarm clips from the Mac's speakers, alert sound off unless stated.

| | State | Expected from the app | Student watches |
|---|---|---|---|
| F1 | Unlocked, Settings in front, defaults | Request sent (`alertsSent` +1) for a verified siren | Does the island expand? For how long? |
| F2 | Same, ordinary sounds (dog, rain, speech-like clip) | No request | No expansion |
| F3 | Same, siren twice within 6 s, then again after a minute | One request, then one more | — |
| F4 | App on screen | Request held back (`app_in_foreground`) | Nothing expands |
| F5 | "Prominent alerts" off | Held back (`disabled_in_settings`); warning icon only | No expansion |
| F6 | Locked, opt-in **off**, siren 15 s after locking | Held back (`device_locked`); silent update | Screen stays dark, no sound, no vibration |
| F7 | Locked, opt-in off, siren **1 s, 3 s and 6 s** after locking (three runs) | What the lock estimate was at that moment; sent or held back | Whether the screen lit. This measures the residual risk of preflight F3 |
| F8 | Locked, opt-in **on** | Request sent | What iOS does: screen, banner, nothing |
| F9 | Locked, opt-in on, alert sound on | Request sent | Sound and vibration (this run makes noise) |
| F10 | Summary ready while locked (after group D) | Never sent | Dark screen |

Decision the results feed: whether "Prominent alerts" can stay on by default as it is, needs a
longer safety margin after the lock notice, or should wait for the first unlock.

## E. Acoustic icons — P3 + P4

Eight ESC-50 clips in two minutes, Settings in front, as in Window 5 D5a, plus the four
post-R1 fixes that never ran on the device.

| | Check | Pass when |
|---|---|---|
| E1 | Each clip | The right icon within a few seconds; the custom glyphs (cough, sneeze, and the others of Window 6) readable at island size (student's judgement) |
| E2 | Scene line in the expanded view | Changes plausibly, does not flicker (count scene changes) |
| E3 | Door slam | No alert (R2) |
| E4 | Strong sneeze shortly after a cough | Shown (R2) |
| E5 | Icon after a knock episode | Within about 20 s (R2) |
| E6 | Any icon | None shown for less than 3.5 s (R2) |
| E7 | Ten quiet minutes in the room | Count of high-priority episodes and of alert requests from room sounds (Window 5: 6 of 9 were room sounds) |
| E8 | Updates per hour | Within what Window 5 measured (256–282 per hour delivered) |

## D. Summarize / Continue / Stop with speech — P3 + P5 (+ P2)

Synthetic speech only. Transcription on for this group, and switched off again at its end.

| | Step | Pass when |
|---|---|---|
| D1 | Session on, transcription on, play the seven first-part sentences; press nothing | No summary, no model call; captions only in the app |
| D2 | Summarize from the island | "Writing the summary…", then "Summary ready"; time from press to ready on the iPhone; island expands if unlocked (iOS decides) |
| D3 | Read the summary in the app | Facts of the sentences present; no sentence word for word; a sentence played more than two minutes earlier absent |
| D4 | Continue; play the three later sentences | Live captions; the summary is extended; "restated" and "refused before storage" counts recorded |
| D5 | Stop from the island | Conversation ends, saved once in History; **listening continues** (classifier windows keep growing) |
| D6 | Summarize twice quickly; Summarize during Continue | One summary at a time; no crash |
| D7 | Action Button during Continue | Everything off; the summary so far is saved, completed |
| D8 | Summarize with 5 s of speech only | "Not enough for a summary"; nothing saved |
| D9 | Language model unavailable (Apple Intelligence off; only if the student wants to switch it) | Explained; nothing saved; no transcript shown in its place |

Recognition errors of loudspeaker speech are expected and are recorded, not fixed here.

## G. Locked screen — P3 + P6 (+ P5 for G3)

| | Check | Pass when |
|---|---|---|
| G1 | Lock Screen activity while listening | Generic state and icon; no controls; "Not updating" never appears while the app runs |
| G2 | Lock with a sound icon showing | Updates silently; screen does not light for ordinary sounds (student) |
| G3 | Lock while a summary is in the island | Summary text is not on the Lock Screen; it is removed from the content while locked |
| G4 | Swipe the activity away on the Lock Screen while listening | Listening continues; opening the app shows the activity again (removed before its time). Record whether iOS stops the recording (preflight F4) |
| G5 | Terminate the app while locked and listening | Activity shows "Not updating" after its stale time; no controls |
| G6 | Unlock | Lock estimate returns to unlocked; next alert is sent again |

## H. AirPods and Spotify — P3 + P7

Audio-session regressions are blocking: any of these failing stops the group.

| | Check | Pass when |
|---|---|---|
| H1 | Spotify playing on the iPhone speaker; ON, OFF | Music never pauses, ducks or stutters at ON or OFF (student) |
| H2 | Spotify on AirPods Pro; ON, OFF | Same; AirPods stay in high-quality playback (no drop to call quality); input route recorded |
| H3 | AirPods taken out and put back while listening | Route change logged; capture recovers; classifier failures 0 |
| H4 | Island with Spotify | Both activities shown; which side each takes; album art pixelated in what is kept |
| H5 | Action Button ON from the Home Screen while Spotify plays on AirPods | As B3, and music uninterrupted |
| H6 | A summary request while music plays (after group D) | Music unaffected; speech-over-music behaviour recorded |
| H7 | Siri or a short call, if the student wants | Session shows "paused", then resumes as the same session |

## I. Background audio stability — P3 + P8 (+ P4)

| | Run | Recorded |
|---|---|---|
| I1 | 30 minutes locked, transcription off, on the charger | Classifier windows and failures, dropped chunks, backlog, Live Activity updates, keep-alives, app state |
| I2 | Same with Spotify on AirPods | Same, plus interruptions |
| I3 | 10 minutes with clips every minute, locked (Window 5 R3) | No wake, sound or vibration for ordinary sounds (student watches) |
| I4 | Optional: until the Live Activity's limit (8 h) | The activity ends; status "ended at the system's limit"; nothing is requested in its place; whether listening and the recording continue (preflight F4) |

Window 5 has one 35-minute run without a classifier failure. I1 is the second.

## J. Privacy — P1 after groups D and G

| | Check | Pass when |
|---|---|---|
| J1 | Copy the app container; scan every file for the test sentences | None found; the History store holds summaries only |
| J2 | Audio files in the container | None |
| J3 | Diagnostics and logs | No caption, no summary text |
| J4 | Live Activity content after Stop and after OFF | No speech text left |
| J5 | Delete all summaries in the app | History empty; the store holds no text of them |
| J6 | "Refused before storage" count | Recorded (0 expected; any other number is examined) |

## K. Battery and memory — P3 + P8

| | Run | Recorded |
|---|---|---|
| K1 | 30 minutes listening, locked, off the charger, transcription off | Battery percent before and after (the app's heartbeat), thermal state, CPU and memory every 5 s; read afterwards over USB |
| K2 | The same amount of time with the app not running | Baseline drain |
| K3 | 30 minutes with transcription on and synthetic speech every few minutes, three summaries | The same, plus memory before and after each summary |
| K4 | Memory over I1 | First and last five minutes compared (a leak shows as a slope) |

One run each is a first number, not a rate. Nothing here supports a statement about a whole day.

---

## What this plan cannot show

- That iOS will expand the island or light the screen in general: only what it did in these runs.
- That any sound is detected reliably: one clip per class through a loudspeaker.
- Anything about real conversations.
- Eight-hour stability, unless I4 is run.
