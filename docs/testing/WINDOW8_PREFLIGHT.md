# Window 8 — Preflight Audit (Physical Device Validation)

Written 2026-10-11. **Read-only audit.** Nothing in this document was done on the iPhone: no
device query, no install, no launch, no microphone, no phone automation (`devicectl list`,
`phone_status` and the like were not called either). Sources: the repository at
`68cb1a8`, the documents of Windows 3–7, and the tools present on the Mac.

The test plan that follows from it: `docs/testing/WINDOW8_DEVICE_TEST_PLAN.md`.

## 1. Baseline

| | |
|---|---|
| Branch / worktree | `feature/window8-device-validation` in `.claude/worktrees/window8` |
| Based on | `68cb1a8` "Window 7 final decisions" on `feature/window7-product-integration` |
| Merged / pushed | Nothing. There is no remote. `main` is untouched. |
| Other worktrees | Main checkout (`feature/window5-dynamic-island` @ `eddc450`, 24 uncommitted entries: the original Window 5 work, untouched), `window6`, `window6-opt`, `window6-2`, `window6-3`, `model-bench`, `window7`: all as they were |
| Verified so far | Mac: 488 package tests. Simulator: Debug build, 28-check self-test, no spoken sentence in the app container. Release build, unsigned. **Nothing of Windows 6–7 has run on an iPhone.** |

What the iPhone last ran is the final Window 5 build (2026-10-11, per the handoff). The four
fixes made after retest R1 never ran on the device (R2–R3 of
`docs/testing/WINDOW5_TEST_RESULTS.md` §9); they are part of this baseline and are folded into
groups E and I of the plan.

## 2. Build and signing (from the project file; nothing was built for a device)

| | Value | Note |
|---|---|---|
| Bundle ids | `org.hearingsense.HearingSense`, `.Widgets` | Unchanged since Window 5: an install updates the app in place and keeps its data |
| Team / signing | `86G57JQY76` (Personal Team), automatic | Free profiles last about 7 days: the build on the iPhone has probably expired or will; `xcodebuild` must run outside the Bash sandbox to sign |
| Deployment target | iOS 26.0; Xcode 27.0 (27A266a), SDK 27.0 | The iPhone ran iOS 27.2 in Window 5 |
| Background modes | `audio`, `processing` | Exactly the configuration measured in Windows 4–5 |
| Usage descriptions | Microphone, speech recognition | Present |
| Live Activities | `NSSupportsLiveActivities = YES`; widget extension embedded | |
| Entitlements | None (no App Group, no Critical Alerts, no push) | The Live Activity intents run in the app's process; nothing needs a shared container |
| Alert sound | `hs-silence.wav` in the app bundle | Used unless "Play the alert sound" is on |
| App Intents | Toggle / Start / Stop Hearing Sense (discoverable); Summarize / Continue / Stop conversation (not discoverable) | Checked in the Simulator build's intent metadata, not on a device |

Consequences for the first device step:

- Installing replaces the Window 5 build and keeps its settings. On first launch the stored
  settings are migrated: "Prominent alerts" takes the new default (**on**), the change is
  written to the settings audit, and "Also when the iPhone is locked" starts off. This is
  worth checking once (plan A3).
- "Transcribe nearby speech" was found **on** on this iPhone in Window 5. Every microphone run
  that is promised as transcription-free must start with `--hs-transcription-off` and verify
  the label, as before.

## 3. Findings that matter before any device test

### F1. A start through the Action Button has no test safeguards (blocks group B with the microphone)

The debug aids are armed by launch arguments, in a `.task` of the app's window
(`HearingSenseApp.swift`). When iOS launches the app in the background for the Action Button's
intent there is no window and there are no arguments. So for exactly the case Window 8 most
needs to test:

- **the automatic microphone time limit is not armed** (`--hs-autostop-after`). The student's
  rule from the Window 5 session is that a timed microphone test must switch the microphone
  off by itself, whatever happens;
- **nothing is written to the diagnostics file**, which is the only way to see what the app did
  while the iPhone was locked or the app was never on screen;
- `--hs-transcription-off` and `--hs-synthetic-capture` do not apply either.

Proposed fix (Debug builds only, no device needed, about one small commit): a persisted *test
mode* stored once with a launch argument and read by `ListeningController.shared` itself, so
that it also applies to a process started by an intent: time limit, diagnostics export,
transcription forced off, optionally synthetic capture. Cleared with a second argument and
shown in the app's diagnostics screen while active.

Until that exists, Action Button tests with the real microphone should not be run.

### F2. The diagnostics export does not show the Window 7 state

`hearing-sense-diagnostics.txt` has the heartbeat (app state, classifier windows and failures,
CPU, memory, thermal state, battery), the event log and the reports of recognition, speech,
attention and the Live Activity. Session requests are in the event log with their source
(`requested (intent)`), refusals too. Missing: the conversation controller's report (phase,
summary requests, updates, refused before storage), the scene, and the listening session's
counters. Proposed: add the three to the export (metadata only) in the same commit as F1.

### F3. The lock estimate now decides more than before

With "Prominent alerts" on by default, the gate's `unlocked` estimate is what stands between
a siren and a lit locked screen for a user who did not opt in. Data protection lags the lock
by 4–12 s; iOS's earlier notice closed the gap in two instrumented runs. Two runs are not
enough for a default. Group F of the plan measures events 1, 3, 6 and 15 s after locking with
the student watching the screen, with the alert sound off.

Also unknown: whether iOS lights the screen at all for an alert update with a silent sound. In
Window 5 (D4) two alert updates on the locked iPhone lit nothing, as the student saw.

### F4. `AudioRecordingIntent` in the background is an assumption

The intent adopts the API made for starting a recording without opening the app; the build's
metadata is right. Not known: whether iOS lets the audio session activate from that process
state, whether the Live Activity can be requested from there, what happens on the locked
iPhone, and whether iOS stops the recording when the Live Activity ends (after the decision of
2026-10-11 the app no longer requests another one after the eight-hour limit, and the user can
swipe the activity away). Fallback that exists: the intent can continue in the foreground.

### F5. What cannot be automated

| Step | Who |
|---|---|
| Assigning the shortcut: Settings → Action Button → Shortcut → Hearing Sense → Toggle Hearing Sense | The student, once (Settings could be driven by phone automation, but the hardware press cannot, and this page is quick by hand) |
| Pressing and holding the Action Button | The student, every time |
| Locking and unlocking | The student (phone automation cannot, and it dies when the iPhone locks) |
| Watching whether the locked screen lights up, a sound plays, the iPhone vibrates | The student. Unwatched means "Not verified", never "passed" |
| Touch and hold on the island, pressing a button in it | To be tried with phone automation first (coordinates on system UI: may or may not work); otherwise the student |
| Starting Spotify, connecting AirPods | The student (a personal app: not opened or read by automation) |

### F6. Evidence available without touching personal data

- The diagnostics file in the app's container, read over USB (`devicectl device copy from`),
  also while locked. Metadata only.
- The self-test report (`--hs-w7-selftest`): runs with synthetic capture, so **the microphone
  stays off**; on the iPhone it would exercise the real on-device model, the Live Activity and
  the intents' code. It calls the intents directly: it is not an Action Button test.
- Island strip screenshots as in Window 5: Settings in front, only the top 12–17 % of the
  image kept, the full image deleted at once, Spotify's album art pixelated.
- The app container for the privacy check (History store and every other file), copied to the
  Mac, scanned for the test sentences, deleted.

### F7. Test signals

- Sounds: ESC-50 clips under the main checkout's `data/downloads/esc50` (the archive; the
  Window 5 session played 5-second clips from the Mac's speakers at 75 %). One clip per class,
  through a loudspeaker: this measures the presentation, not the classifier's accuracy. In
  Window 5 a siren clip was missed once in a loud room.
- Speech: `tools/make_speech_test_signals.sh` (macOS `say`); the two-part scripted
  conversation of the self-test exists as text and can be spoken the same way. Synthetic
  sentences only. The microphone hears the whole room: the student has to confirm that nobody
  is talking nearby, or the run is not started.

### F8. Things that are already known to be weak (not new, but the plan must not rediscover them)

- False alerts with real room sounds: in Window 5's D6, 6 of 9 high-priority episodes in ten
  minutes were room sounds. With prominent alerts on by default this now means island
  expansions, not only icons. Group E counts them.
- The scene thresholds were chosen on scripted events.
- Summaries take 8–11 s in the Simulator on Mac hardware; unknown on the iPhone.
- No battery measurement exists at all.

## 4. Tools on the Mac (presence only)

| Tool | State |
|---|---|
| `xcrun devicectl` | Present (Xcode 27.0) |
| iphone-use (`~/.local/bin/iphone-use`, MCP tools `phone_*`) | Present; approved by the student on 2026-10-10 with rules (localhost-only daemon, always release the owner, Hearing Sense and Settings only, ask before the microphone). Its runner profile also expires after about 7 days: `iphone-use setup` may be needed, with the iPhone unlocked on USB |
| Simulators | iPhone 18 Pro (another session's, booted, not touched); iPhone 18 Pro Max (this work's, shut down) |

## 5. Permissions needed before testing

Each line is a separate scope. None is implied by another, and none has been given.

| | Scope | Needed for | What it allows, exactly |
|---|---|---|---|
| **P0** | Code, no device | F1, F2 | One Debug-only commit on the Window 8 branch: persisted test mode, three more report sections. Mac tests only |
| **P1** | iPhone over USB, **microphone off** | Group A | Build and sign (outside the sandbox), install over the Window 5 build, launch with debug arguments, read the app's diagnostics and self-test files, terminate the app. Synthetic capture only |
| **P2** | Phone automation, limited | Groups A–C | `phone_*` tools in Hearing Sense and Settings only; strip screenshots; owner released after every test |
| **P3** | Microphone, sound classification only | Groups B (real start), C, E, F, G, H, I, K | Transcription forced off and verified; every run with an automatic time limit; a stated maximum length per run |
| **P4** | Playing test sounds from the Mac's speakers | Groups E, F, I | ESC-50 clips at a stated volume; the Mac is the school computer |
| **P5** | Transcription of **synthetic** speech | Groups D, J | Sentences spoken by macOS `say` from the Mac's speakers; the student confirms a quiet room; temporary captions; the saved summaries are of the test sentences and are deleted afterwards |
| **P6** | Tests the student has to watch | Groups F, G | Locked screen: lit or not, sound or not, vibration or not. One with "Also when the iPhone is locked" on, one with the alert sound on (it will make a sound) |
| **P7** | AirPods and Spotify | Group H | The student connects the AirPods and starts playback; album art is pixelated in anything kept |
| **P8** | Long runs | Groups I, K | 30 minutes locked; 30–60 minutes off the charger for the battery; optionally the eight-hour limit |

Manual steps are given one per message. Every test ends with the microphone off, the owner
lease released, full screenshots deleted, and no raw audio kept anywhere.
