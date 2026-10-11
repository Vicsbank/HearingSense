# Window 5 — Test Results (Dynamic Island and Live Activity)

Date: 2026-10-10. Branch `feature/window5-dynamic-island`.

**Evidence levels.** Mac = package tests and the replay tool. Simulator = iPhone 18 Pro Simulator,
iOS 27.0, on the Mac. Physical iPhone = §5 (D1–D4, run later the same day). Every input was
scripted and synthetic (`synthetic.replay`); the microphone was never used. §1–§3 were written
before the device session; the test counts in §1 are from then (the package now has 49 tests in
`IslandPresentationTests`). Numbers below
describe the presentation rules, not recognition accuracy and not what iOS does with the updates.

## 1. Automated tests

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | macOS 27.2, Swift 6.4 | **303 tests: 302 passed, 1 skipped** (opt-in real-model test); 47 new + 256 earlier |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27.0 Simulator, iPhone 18 Pro | **308 tests: 304 passed, 4 skipped** (3 recognizer tests, 1 opt-in) |
| App + widget extension, Debug | iOS 27.0 Simulator | **Build succeeded**, 0 Swift warnings |
| App + widget extension, Release, unsigned | generic iOS device | **Build succeeded**; `HearingSenseWidgets.appex` embedded; `NSSupportsLiveActivities` = true; background modes unchanged (`audio`, `processing`) |

New tests (`Tests/IslandPresentationTests`, 47):

- `SoundSymbolCatalogTests` (6): all 303 labels resolve; every event kind has a symbol; the tables
  name only labels and kinds that exist; **every symbol name exists on the system running the
  test** (macOS 27.2 and the iOS 27.0 Simulator); fallback order.
- `AmbientIconStreamTests` (12): icon without text; weak evidence; minimum display; rank; linger;
  a returning sound keeps its icon; changes per minute; stale events; exclusion; session end; every
  kind gets an icon; determinism.
- `IslandPipelineTests` (23): one activity per session; pause/resume; activity switched off and on;
  ambient icon; coalescing; keep-alive; **an attention episode cannot be overwritten by ambient
  updates**; resolve/expiry; priority order and minimum hold; uncertainty; speech summary on/off
  (checked on the encoded content); expansion requests (once per episode, on a priority rise, first
  summary, spacing, only for the episode in front); **sounds the attention engine suppresses are
  still icons** (with the real engine); every Window 4 scene in every mode keeps the rules; update
  rate of the generated hour; determinism.
- `AlertGateTests` (6): lock estimate; the signal must have been observed; expansion off by
  default; settings decoding.

## 2. Replay of the Window 4 scenes through engine + pipeline

(Numbers of the first implementation. After the change described in §5, point 1, the update rates
are lower; the current output is in `results/island_eval_window5/`.)

`swift run -c release hs-attention-eval island` — output in `results/island_eval_window5/`.
"Updates" are `Activity.update` calls the app would make (start and end not counted). "Expansion
requests" are counted before the lock-state gate; with the default settings none reaches iOS.

| Input | Mode | Updates / h | Icon changes | Attention episodes | Expansion requests | Rule violations |
|---|---|---|---|---|---|---|
| 18 scenes (5 230 s incl. 60 s tail each) | Quiet | 105 | 89 | 36 | 21 | 0 |
| | Balanced | 123 | 89 | 50 | 28 | 0 |
| | Sensitive | 133 | 89 | 60 | 29 | 0 |
| Generated hour (seed 20261010) | Quiet | 163 | 130 | 22 | 13 | 0 |
| | Balanced | 226 | 130 | 51 | 31 | 0 |
| | Sensitive | 291 | 130 | 86 | 34 | 0 |

Highest rate in one scene: `14-rapid-burst`, Sensitive, 28 updates in 120 s. In the generated hour
(Balanced) the island showed an attention episode for 911 s, an ordinary icon for 2 210 s and the
plain listening glyph for 698 s.

Rules checked on every command of every run: no text outside an attention episode; no expansion
request without an attention episode; no speech text in a request; whenever the engine presents an
episode the activity shows attention content; exactly one start; ended with the session.

These scenes were written for Window 4 and are dense on purpose; the rates are an upper region for
the rules, not a forecast of a real day.

## 3. Simulator checks (synthetic demo scenes, microphone off)

Launch arguments `--hs-island-demo <idle|ambient|knock|siren|speech>`; `--hs-assume-unlocked` only
where noted. Screenshots in `docs/device-tests/window5-simulator/`.

| # | Check | Result |
|---|---|---|
| S1 | Activity starts with the demo; card in the app mirrors it | Works (`01_app_card_ambient_icon.png`) |
| S2 | Ordinary sound (rain) in the compact island | Ear left, mint rain icon right, no text (`02_…`) |
| S3 | Attention episode in the compact island (dog, Balanced; speech) | Coloured icon left, priority mark right (`03_…`, `05_…`) |
| S4 | Knock with `--hs-assume-unlocked` | iOS expanded the island: "Door or knock", mark, time (`04_…`); log: "expansion requested" |
| S5 | Speech summary with `--hs-assume-unlocked` | Expanded: “Biology Test Tomorrow” / Nearby Speech, rain as secondary icon (`06_…`) |
| S6 | Lock Screen with an attention episode | Icon, "Hearing Sense · Listening", mark, timer; no title (`07_…`). iOS adds its one-time "Allow Live Activities?" prompt |
| S7 | **Locked Simulator, first implementation of the gate** | **Failed the requirement:** estimate "unlocked" (passcode reported, protected data available) and an expansion request was sent while locked. Led to §4.1 of the report |
| S8 | Locked Simulator, final implementation, default settings | Estimate `unknown`; log: "silent update … (disabled_in_settings)"; 0 requests sent |
| S9 | Updates while the app is in the background | Delivered (3 updates in the heartbeat export; SpringBoard log shows them applied) |
| S10 | Leftover activity of a terminated launch | Ended at the next launch ("ended a leftover activity"); never two |

Not checked in the Simulator: whether the screen actually lit up in S7 (the Simulator's display
does not show that reliably); the in-app settings and preview screens were built and compiled but
not screenshot (the Simulator display stayed dimmed after the lock tests).

Tooling note: `xcrun simctl io … screenshot` often omits the Dynamic Island layer; the screenshots
here were taken through the Simulator's own capture.

## 4. Apple documentation checked (2026-10-10)

"Displaying live data with Live Activities" and `AlertConfiguration`: active up to 8 hours, then on
the Lock Screen up to 4 more; static + dynamic data ≤ 4 KB; start in the foreground, update and
end from the background; an alert shows the expanded island on iPhone (banner without an island)
and uses title and body on Apple Watch; **nothing about the effect of an alert on a locked iPhone;
no update budget for app-made updates is stated.**

## 5. Physical iPhone: D1–D4 (2026-10-10, synthetic events, microphone off)

iPhone 18 Pro, iOS 27.2 (24B5099f), USB, Developer Mode on, charging. Debug build with the widget
extension, signed with the Personal Team (the profile for `org.hearingsense.HearingSense.Widgets`
was created automatically by `xcodebuild -allowProvisioningUpdates`). Authorized by the student for
this session; the phone was driven with `devicectl` and iphone-use; locking, unlocking and watching
the screen were done by the student, one step per message. Every event was scripted
(`--hs-island-demo`); the microphone was never started.

Two kinds of evidence, kept apart:

- **Captured**: screenshots of the top strip of the screen only (status bar and Dynamic Island) with
  Settings in front, in `docs/device-tests/2026-10-10-window5/`; full screenshots were deleted at
  once. Metadata-only diagnostics exports in `results/device_window5/`.
- **Student-observed**: what the student saw, heard and felt, reported in chat. One observation
  each unless stated.

| # | Check | Captured / logged | Student-observed |
|---|---|---|---|
| D1 | Install and run with the extension | Installed and launched; activity started; "ended a leftover activity of an earlier launch" at every relaunch, never two | — |
| D1 | Compact island, ordinary sound | Ear left, mint sound icon right (rain, bird); no text (`d1_compact_ambient_*.png`) | — |
| D1 | Compact island, attention episode | Icon in the priority colour, mark, tinted outline: dog = yellow paw + dot, knock = orange door + "!" (`d1_compact_attention_*.png`) | — |
| D1 | Icon changes over a 50 s scene (one frame every 0.55–1 s) | 3 changes (rain → dog episode → bird), one cross-fade frame, no alternation (`d1_ambient_scene_timeline.png`) | — |
| D1 | Expanded island (touch and hold) | "Door or knock" with mark, timer, secondary rain icon; “Biology Test Tomorrow” / Nearby Speech (`d1_expanded_*.png`) | — |
| D1 | Privacy of logs | 0 occurrences of the summary text in every export; update log shows `<speech summary>` | — |
| D1 | Spotify playing | Island split in two: Hearing Sense on the left with both compact icons, Spotify's Now Playing on the right, its level animation running (`d1_spotify_split_island.png`, album art pixelated). The minimal presentation was not shown | Whether the music was audibly unaffected: not asked yet |
| D2 | Lock by hand; rain 1.1 s and knock 10.1 s after locking; default settings | Both updates sent while locked; "silent update … (disabled_in_settings)" | **Screen did not wake, no sound, no vibration.** Lock Screen entry after waking: door icon, "Hearing Sense", "Listening", no event title |
| D2 | Same after an automatic lock (3 minutes) | Both updates sent while locked | Nobody was watching |
| D3 | Always-On display | — | Always-On is enabled; the display did not brighten. Whether the icon visibly changed on the dimmed screen was not reported |
| D4 | "Expand for important events" on, unlocked, Home Screen | "expansion requested"; expanded frame captured (`d4a_auto_expanded_knock.png`) | **Expanded by itself for about 4 s, readable, no sound, no vibration** (silent sound file) |
| D4 | Same, knock 2.2 s after locking | Estimate still "unlocked": **the expansion request was sent to iOS** | **Screen did not light up, no sound, no vibration** |
| D4 | Same, knock 20 s after locking | "silent update … (device_locked)": request held back | No wake, no sound, no vibration |
| D4 | Forced request 20 s after locking (`--hs-assume-unlocked`, worst case) | Request sent while the estimate was "locked" | **Nothing: no wake, no sound, no vibration** |

Measured on the device:

- **Data-protection lag.** Protected data was reported unavailable between 7–12 s, 3.6–8.8 s,
  4.9–10.2 s and 4.3–9.7 s after the lock (four runs; heartbeat every 5 s, hence the ranges).
- **Early lock notice.** `protectedDataWillBecomeUnavailableNotification` arrived at the moment of
  locking while the data was still available: 1.4 s before the app entered the background in the
  one run with a timestamp, and before the first heartbeat after the lock in another. Based on it
  the estimate now treats a pending notice as `locked` (unit-tested; **not yet exercised in a
  device run**).
- **Update calls.** `Activity.update` returned in 1.8–120 ms (most under 10 ms).
- **Suspension.** Without a listening session iOS suspended the app 26–27 s after it left the
  screen ("background time is over" in the log). The island then stays on its last content: in the
  first long capture the bird icon was still shown 20 s after the scene would have removed it. With
  a listening session the audio background mode keeps the app running; an app that crashes or is
  terminated leaves its last icon until the stale date (15 minutes).

Screenshot caveat: in the capture series of the automatic expansion the island was expanded in one
frame and compact again 0.6 s later, while the student saw about 4 s without captures running. The
student's observation is the result; the capture probably disturbs the presentation.

Found and changed during the device session:

1. Updates that only changed a secondary detail of an attention episode (the small ambient icon,
   "+N more") were 26–35 % of all updates in the replay. They are no longer sent by themselves
   (§2 shows the numbers before; after: 73 / 82 / 88 per hour for the 18 scenes and
   127 / 168 / 188 for the generated hour, Quiet / Balanced / Sensitive).
2. The demo injection delivered a sound to the icon channel before the attention engine, the
   reverse of real events, which produced two updates 8 ms apart on the device. The order now
   matches production.
3. Demo scenes can be timed from the moment the app leaves the screen
   (`--hs-demo-after-background`, `--hs-demo-key-at <s>`), because a locked-screen check cannot be
   timed from a chat message.
4. Per-update log in the diagnostics export (time, redacted content, call duration).
5. Lock estimate: pending lock notice counts as locked (above).

The real update frequency during listening is still unknown: these runs sent two to four scripted
updates each. It needs the microphone (D6).

## 6. Physical iPhone: D5–D6 with the real microphone (2026-10-10)

Authorized by the student for D5 and D6 only (D7 battery and D8 transcription are postponed).
Sound classification only: "Transcribe nearby speech" was checked to be off before the first run.
Test clips (ESC-50, 5 s each) were played from the Mac's speakers at 75 % with the student's
approval. The student has no AirPods, so in D5b Spotify played through the iPhone's own speaker.
The room was in normal use: the classifier heard people (speech, laughter, coughing, glasses).
Objective data only is reported as a result; exports in `results/device_window5/d5*`, `d6*`.

| Run | Conditions | Logged / captured |
|---|---|---|
| D5a | Unlocked, Settings in front, 8 clips in 2 minutes | 163 classifier windows, 0 failures. Island (strip captures, `d5a_real_sounds_timeline.png`): dog icon → Dog episode → Nearby Speech → Door or knock (orange "!") → Siren (red "!!") → Horn → ordinary icons; about 10 visible changes in 110 s, no alternation. 14 updates in 114 s; 43 secondary-only changes not sent; 3 high-priority episodes, all silent updates. iOS's own orange microphone indicator sits beside the island |
| D5b | Same, Spotify playing on the iPhone speaker, 3 clips | Island split: Hearing Sense left, Spotify right, its level animation running throughout (`d5b_spotify_real_timeline.png`, album art pixelated). Music recognized (note icon); siren recognized; **dog and knock not recognized** — the music from the phone's own speaker covered them; a "Shouting" episode from the song's vocals. Student: the music did not stop or change volume when listening started |
| D6 | Locked, 8 clips at about 68 s intervals; the session ran 34.9 minutes in all because it was stopped by the student later | **2 793 classifier windows, 0 failures** over 34.9 minutes locked. First 10 minutes: 44 updates (258 per hour), 131 secondary-only changes not sent, 16 episodes, 9 high-priority episodes all sent as silent updates, CPU 4–5.5 % of one core, 44 MB, thermal nominal, on USB power. Whole session: 150 updates in 2 093.6 s (**256 per hour**), `Activity.update` 9.1 ms mean, 27 ms max; lock notice at the moment of locking again |

**Not verified in D6** (the student did not watch): what the Lock Screen entry showed, and whether
the screen lit up, or the phone made a sound or vibrated, at any time in those 35 minutes. These
are not counted as passed. (The same checks were student-observed for the short runs in §5.)

Recognition of the played clips (one clip per class, through a loudspeaker; a classifier matter,
not a presentation one), without music: dog 2 of 3, knock 3 of 3, siren 2 of 2, birds 2 of 2, car
horn 1 of 2, rain 0 of 2 as rain (heard as water, once also as train), footsteps 0 of 1 (heard as
handling objects), glass breaking 0 of 1 (heard as door / glass clink). With Spotify on the phone
speaker: siren 1 of 1, dog 0 of 1, knock 0 of 1.

### 6.1 What the real session showed, and what was changed

**False alerts.** In the first 10 minutes of D6 the engine raised 9 high-priority episodes; 3 were
played clips (two knocks, a siren). The other 6 were room sounds: 5 "Door or knock" from the label
`door` and one "Screaming" from a single window at 0.90 among laughter. Over all microphone runs
the label `door` was confirmed 12 times and none was a knock (one coincided with the glass-breaking
clip), while the label `knock` was confirmed 3 times, each a played knock.

- The kind `door` ("Door or knock") now holds `knock`, `door_bell`, `tap`. The labels `door` and
  `door_sliding` (and, after the retest of §7, `door_slam`) are a new kind `door_movement`
  ("Door"): an ordinary sound with an icon, never an alert in Quiet or Balanced, and confirmed by
  two windows only (4 of the 12 came from one window). 51 kinds now.
- `screaming` needs two windows or one window at 0.95, like the other warning signals.
- Not changed: "Nearby Speech" episodes (12 in the last 17 minutes of D6, real speech in the room,
  transcription off) — see the icon rules below; and the misrecognitions listed above.

These rules rest on one room and one evening. They could not be replayed on the recorded audio
(none is kept); the effect on the recorded sessions follows from the labels and window counts in
the log: all 12 `door` events and the one `screaming` event would no longer be alerts.

**Icons too few and too slow** (the student's observation during D6: a strong sneeze did not
appear). Cause: the first rules let the highest-ranked sound that was still going on — speech,
almost always — keep the icon, and "Nearby Speech" episodes held the island as attention content.

- The icon channel now shows the **newest** confirmed sound for 5 s whatever its rank, then goes
  back to the highest-ranked sound still going on. Minimum display 2 s (was 4).
- A sound that has ended does not get the icon late; the plain glyph waits 5 s, so a sound that
  follows replaces the previous icon directly.
- Only a high-priority episode or one showing a speech summary is protected from ordinary sounds
  (the wording of the student's brief). A lower-priority episode gives way to a newer sound.
- A resolved episode does not return to the front after another one.

Replay of the recorded events through the icon channel (`hs-attention-eval island-device-trace`,
output in `results/device_window5/icon_channel_trace_replay.txt`; confirmation and end times from
the export, the rest rebuilt, attention engine not included):

| Recording | Rules | Icon changes per hour | Confirmed sounds that became the icon | Delay, 90th percentile |
|---|---|---|---|---|
| D6, first 10 min (73 events) | first | 295 | 44 of 73 | 5.8 s |
| | current | 477 | 68 of 73 | 1.8 s |
| D6, last 22 min (104 events) | first | 200 | 72 of 104 | 4.2 s |
| | current | 319 | 104 of 104 | 0.5 s |

The model reproduces the device: 50 icon changes for the first 10 minutes against 52 counted on
the iPhone. **The price of the faster icons is more updates** — in a room this lively roughly
300–480 icon changes per hour, bounded by 12 per minute. The new rules are unit-tested and
replayed. They ran on the iPhone in the retest R1 (§7), after the student's decisions were added.

## 7. Retest R1 on the iPhone (2026-10-11 UTC, 5 minutes, real microphone)

Authorized by the student for five minutes with the microphone and the Mac's speakers; no
transcription (D8) and no battery test (D7). Build: commit `1d06721` plus the rules of §6.1 with
the student's three decisions (speech without a summary is an icon in every mode; newest sound
first, with same-kind de-duplication and a switch cooldown; no raw audio kept).

Safeguards as run: transcription was forced off for this launch by a launch argument
(`-speech.transcriptionEnabled NO`; the stored switch had been found on) and checked in the export
before the first clip ("Transcription switch: off", 0 utterances, 0.0 s transcribed at the end). The
app was started with `--hs-autostop-after 300`. The Mac script relaunched the app with the
microphone off 5 min 5 s after the start. **Whether the app's own 300 s stop fired is not
confirmed**: the last export was written 0.7 s before it was due.

Phone unlocked, Settings in front, 17 clips, the room in normal use (speech, laughter). The
student's setting "Expand for important events" was on. 398 classifier windows, 0 failures.

**Kept apart: what the device did, and what a replay says.**

### 7.1 Measured on the device in R1

| Question | Result |
|---|---|
| New sound → icon | Confirmation to update handed to ActivityKit: **median 0.02 s** (17 matched updates; D6 with the first rules: 2.22 s). Examples: laughter 11 ms, cough 17 ms, knock 26 ms, dog 0.85 s (it waited for the minimum display of the icon before it) |
| Sound → confirmation (classifier, unchanged) | median 2.25 s, 90th percentile 3.0 s on the audio clock, n = 37. This is now nearly all of the delay the user sees |
| Flicker in a burst (5 overlapping clips in 17 s) | 2 updates: laughter icon for 5 s, back to speech. No alternation |
| Same kind repeated (3 dog clips in 20 s) | 1 dog icon; the third clip did not show it again |
| Updates | 24 in 293 s (282 per hour), shortest gap 1.0 s; 43 secondary-only changes not sent; `Activity.update` 9.6 ms median, 26.5 ms maximum |
| "Nearby Speech" without a summary | The engine presented it 3 times; the island showed the speech icon only, 0 episodes, 0 expansion requests |
| Door sounds | `door` confirmed 3 times as the new kind "Door": icon only, no alert |
| Knock | Recognized (0.72, two windows); episode and expansion request 26 ms after confirmation; the island expanded (strip captures, `r1_retest_timeline.png`) |

Problems found in R1 (real device):

1. **A false "Door or knock" with an expansion request**: the label `door_slam` (0.78) from the
   room. → `door_slam` moved to the kind "Door" (icon only).
2. **A sneeze at 0.99 was not shown**: a cough had used the same icon 18 s earlier and the
   same-kind cooldown (30 s) held it back. → cooldown 15 s, and a peak of 0.9 or more ignores it.
3. **A door episode held the island for 48 s** (the room's speech had joined it) and hid a dog
   and footsteps. → a high-priority episode or a summary is protected for 20 s after the engine
   last changed it; an urgent one throughout.
4. **Two icons within 2 s for one rain clip** (water, then tap) and **an icon replaced after
   1.0 s** when an episode left. → minimum display 3.5 s, also enforced in the pipeline.
5. Recognition (classifier, not presentation): the siren clip was **not** recognized in this run
   (3 of 3 before), nor the first sneeze, the second knock clip, clapping, coughing and breaking
   glass in the burst; the door creak was heard as burp, crying and cow. The room was louder than
   in the earlier runs; no scores are kept, so the cause is not known.

### 7.2 Replay of the recorded events with the final rules (simulation, not a device run)

`hs-attention-eval island-device-trace` on the exports (`results/device_window5/
icon_channel_trace_replay.txt`). Icon channel only; confirmation and end times are from the
device, everything between is rebuilt; the attention engine is not included. For R1 the replay of
the rules that ran gives 29 icon changes, the number counted on the iPhone.

| Recording | Rules | Icon changes per hour | Confirmed sounds that became the icon | Same kind back within 30 s |
|---|---|---|---|---|
| D6, first 10 min (73 events) | first version | 295 | 44 | 16 |
| | newest first, no cooldowns | 477 | 68 | 36 |
| | final | 359 | 58 | 25 |
| D6, last 22 min (104 events) | first version | 200 | 72 | 29 |
| | newest first, no cooldowns | 319 | 104 | 61 |
| | final | 247 | 90 | 41 |
| R1 (37 events) | first version | 134 | 10 | 4 |
| | newest first, no cooldowns | 474 | 29 | 19 |
| | final | 340 | 23 | 12 |

Scripted Window 4 scenes with the final rules: 77 / 81 / 84 updates per hour (18 scenes) and
177 / 194 / 206 (generated hour); 0 rule violations in 57 runs; 314 package tests pass.

**The final rules (the four fixes of §7.1) have not run on the iPhone.** The build is installed;
verifying them needs another microphone authorization.

## 8. Not verified

- The four fixes made after R1, on the device.
- The app's own stop after `--hs-autostop-after` (the Mac-side stop worked).
- D6's subjective checks: Lock Screen content, screen wake, sound, vibration during 35 minutes.
- An expansion request with "Play the alert sound" on (all runs used the silent file).
- More than one observation of each locked-screen case; the phone was on USB power throughout.
- iOS's "Allow Live Activities?" prompt: not confirmed whether it appeared.
- The minimal presentation on the device; VoiceOver on the activity.
- Update throttling by iOS (no sign of it in about 200 updates, but nothing measures it
  directly), the 8-hour end and the restart.
- Battery and thermal cost off the charger (D7) and speech text with real speech (D8): postponed
  by the student.

## 9. Remaining device steps (each needs microphone authorization)

| # | Step | Looks for |
|---|---|---|
| R2 | 5 minutes as R1 with the final build | No alert from a slammed door; a strong sneeze shows although a cough was shown shortly before; an icon after a knock episode within about 20 s; no icon shorter than 3.5 s; siren recognized or not (repeat) |
| R3 | The same locked, with the student watching the screen | No wake, no sound, no vibration (D6's unverified items) |
| D7 | 30–60 minutes off the charger with the activity on, then off | Battery and thermal difference (postponed) |
| D8 | Real knock / speech with transcription on | Episode text; summary only in the expanded island (postponed) |
