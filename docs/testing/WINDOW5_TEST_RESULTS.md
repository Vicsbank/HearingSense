# Window 5 — Test Results (Dynamic Island and Live Activity)

Date: 2026-10-10. Branch `feature/window5-dynamic-island`.

**Evidence levels.** Mac = package tests and the replay tool. Simulator = iPhone 18 Pro Simulator,
iOS 27.0, on the Mac. **No physical-iPhone test was run** (the iPhone was not connected). Every
input was scripted and synthetic (`synthetic.replay`); the microphone was never used. Numbers below
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

## 5. Not verified

Everything on the physical iPhone: Lock Screen and Always-On appearance; that silent updates do
not wake the screen; the lag of the data-protection signal; an alert on a locked iPhone; the island
next to Spotify's Now Playing; update throttling; battery and thermal cost; the 8-hour end and the
restart; VoiceOver on the activity; signing the extension with the Personal Team; real sounds and
real speech (needs microphone authorization).

## 6. Device test protocol (pending; one step per message)

No microphone (demo scenes, `devicectl … launch … --hs-island-demo <scene> --hs-export-diagnostics`):

| # | Step | Looks for |
|---|---|---|
| D1 | Install the Debug build; launch `ambient`; go to the Home Screen | Extension signs and runs; compact island as in S2/S3; answer iOS's Live Activities prompt |
| D2 | Launch `knock`, lock the iPhone before the knock (9 s), keep the screen off | **Screen stays off, no sound, no vibration**; after waking: icon-only Lock Screen entry |
| D3 | Same with the Always-On display | Dimmed icon updates without waking |
| D4 | Turn "Expand for important events" on; `knock` unlocked; then `knock` locked at 2 s, 8 s and 20 s after locking | Expansion when unlocked; whether a request shortly after locking wakes the screen; when `lock=` in the export turns `locked` |

With the microphone (needs the student's authorization each time):

| # | Step | Looks for |
|---|---|---|
| D5 | Start Listening with AirPods and Spotify playing; play sounds | Island beside Now Playing (minimal presentation expected); Spotify unaffected |
| D6 | 10 minutes locked (together with A3 of the background tests) | Icons keep following sounds; export: updates, `classifierFailures` |
| D7 | 30–60 minutes off the charger with the activity on, then off | Battery and thermal difference |
| D8 | Real knock / speech with transcription on | Episode text; summary only in the expanded island |
