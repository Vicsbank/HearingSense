# Window 2 — Device Test Protocol and Results

Protocol for the live sound-recognition pipeline. Evidence classes are kept apart:

- **Simulator** — Xcode iPhone 18 Pro Simulator (iOS 27.0) on the M1 Max; the "microphone" is the
  Mac's microphone and the classifier runs on Mac hardware.
- **Recorded file** — offline, forward-only evaluation with `hs-sound-eval` on the Mac.
- **Physical iPhone** — iPhone 18 Pro, iOS 27.2, AirPods Pro, Spotify.
- *(user)* marks observations the student reported by ear/eye; everything else was read from the app
  or screenshots.

**Status at the end of Window 2 (2026-10-09):** the student chose to test with the Xcode iPhone 18 Pro
Simulator only in this window; every physical-iPhone test below is **not run** and is carried over.

## How to run (any test)

1. Build and run `apps/ios/HearingSense.xcodeproj` (scheme HearingSense) on the Simulator or iPhone.
2. Tap **Start Listening**. The *Sound recognition* card shows the status, the current sound (only
   confirmed events), the top 3 raw labels of the latest window with scores, the input level and the
   result delay. *Recent events* lists confirmed events.
3. **Recognition diagnostics** (bottom of the main screen) shows pipeline timings, dropped buffers,
   detector counters, process CPU/memory/thermal, the window-length picker, the start/stop-stall
   experiment toggle and **Share recognition report** (text, no audio).
4. iPhone screenshots: `xcrun devicectl device capture screenshot --device <UDID> --destination shot.png`
   only while Hearing Sense is in the foreground.

Expected timing (1.5 s window, 50 % overlap): first result 1.5 s after Start; results every 0.75 s;
a continuous sound is confirmed after 2 windows (≈ 2.25 s of audio after its onset at best); a
brief sound with a single clear window (score ≥ 0.65, horns/bangs ≥ 0.85) is confirmed after 1 window.

## Results

| ID | Scenario | Expected | Evidence | Observed | Result |
|---|---|---|---|---|---|
| S0 | Simulator smoke test: start, live classification, diagnostics, stop | Real labels update every 0.75 s; no drops; stop ends session | Simulator, 2026-10-09 | 48 kHz mono input; 370 buffers / 37 s, 0 dropped, 0 gaps; 48 windows; result delay mean 10.7 ms (p95 13.5); analyze-with-result mean 10.0 ms; analysis CPU 1.3 % of audio time; process CPU 7.7 % of one core, 31 MB, thermal nominal. Statuses seen: "Analyzing…", "No reliable classification (maybe laughter 0.70)", "Sound present, not recognized" at −53 dBFS room noise. No confirmed events (no deliberate sounds). Screenshots `docs/device-tests/window2-simulator/01–04` | **Pass (Simulator only)** |
| L-sim | Label inventory, Simulator | 303 labels = taxonomy | Simulator | 303, exact match, window range 0.5–15 s (`05_classifier_labels_303.jpg`) | **Pass (Simulator only)** |
| L | Label inventory on the physical iPhone | Count, coverage vs taxonomy | Physical iPhone | — | Not run |
| A | Quiet room, 2 min | Status mostly "Quiet"/"Sound present, not recognized"; no high-confidence unrelated events | Physical iPhone | — | Not run |
| B | Speech near the phone | `speech` event confirmed in ≈ 2–3 s | Physical iPhone | — | Not run |
| C | Knock on a table/door | Record the actual label(s); `door` kind expected but not assumed | Physical iPhone | — | Not run |
| D | Music from another device | `music` event | Physical iPhone | — | Not run |
| E | Rain/wind playback (state source) | Record labels; distinguish playback from outdoor | Physical iPhone | — | Not run |
| F | Car-horn recording (safe playback only) | Record labels; `vehicle_horn` needs 2 windows ≥ 0.5 or one ≥ 0.85 | Physical iPhone | — | Not run |
| G | Speech + music overlapping | Both kinds may be active; no flicker | Physical iPhone | — | Not run |
| H | AirPods Pro + ANC + Spotify + listening | Capture and classification continue; Spotify plays; A2DP route | Physical iPhone | — | Not run |
| I | Lock screen ≥ 1 min (then longer) | Classifier windows continue while locked (log line "Background interval … classifier windows (≈ N expected)") | Physical iPhone | — | Not run |
| J | Route change / interruption (AirPods out, Siri, call) — **ask the student first** | Events end on interruption; capture restarts after route change | Physical iPhone | — | Not run |
| S | Start/stop stall, before vs after (keep-session toggle off/on) with Spotify | Student reports stall at Start and at Stop for each setting; log shows session steps and timings | Physical iPhone | — | Not run |

Offline (recorded-file) evaluation results are in `docs/WINDOW2_SOUND_ANALYSIS_REPORT.md` §6.

## Step-by-step instructions for the physical tests

Do one step at a time; report what you see, then continue.

- **L**: Recognition diagnostics → Classifier labels on this device. Read "Labels" and "Matches
  taxonomy" (or tap *Share label inventory* and AirDrop/save the text).
- **A**: Quiet room, phone on a table, Start Listening, do not speak for 2 minutes. Then open
  Recognition diagnostics and Share the report.
- **B**: Speak normally ~50 cm from the phone for 10 s. Note when "Speech" appears.
- **C**: Knock 3 times on a table/door ~1 m away; wait 5 s; repeat once. Note the raw labels shown.
- **D**: Play music from another device ~1 m away for 20 s.
- **E**: Play a rain or wind recording from another device (say which recording), 20 s.
- **F**: Play a car-horn recording from another device at moderate volume (never in real traffic).
- **G**: Talk while music plays, 20 s.
- **H**: Connect AirPods Pro, enable ANC, play Spotify, Start Listening, repeat B and D; report music
  quality by ear.
- **I**: With H running, lock the phone for ≥ 1 min (longer if possible), unlock, open the Event
  log and look for "Background interval … classifier windows".
- **S**: With Spotify playing on AirPods: Start/Stop three times with the toggle **off**, then three
  times with it **on**; report whether you hear the stall at Start and at Stop in each case.
- **J**: Only when agreed: remove one AirPod / ask Siri something while listening; report the status.
