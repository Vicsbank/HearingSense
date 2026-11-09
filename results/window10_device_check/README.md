# Window 10 device check (2026-11-08, physical iPhone 18 Pro, iOS 27.3)

Evidence: physical iPhone, Debug build of a54eb52 (test mode off). Mac speakers at 75 % volume,
phone next to the Mac. Diagnostics are metadata only (no audio, transcripts or summary text).
Phone clock is UTC (Mac local time + 7 h); both clocks are network-synchronized (not measured).

## Sound → Dynamic Island (`w10_sound_latency.tsv`)

12 ESC-50 clips, 20 s apart, transcription locked off. Latency = island update handed to
ActivityKit minus the clip's measured onset. iOS rendering after the update is not included.

- Detected 8/12. Missed: car_horn 1-17124, glass 1-20133, knock 1-103995 (one window 0.49),
  alarm 1-14262 (one window 0.52).
- Detected: 0.77–4.02 s, median about 1.5 s. Single-window confirmations 0.8–1.4 s;
  two-window confirmations 1.8–4.0 s (siren 1-31482: 4.0 s).
- Island pipeline after confirmation: about 5 ms, except when an ended urgent episode still
  held the island: car_horn 1-19026 was confirmed in 0.5 s but shown 1.5 s later (at the siren's
  EXPIRE), and a foghorn "Horn" episode during the siren was never shown. Window 5 shows the
  same pattern (`results/device_window5/d5a_real_sounds_diag.txt`, horn at 22:47:49–50).

## Summary request (`w10_summary_diag.txt`)

Synthetic two-voice dialog (macOS `say`, 15 lines, about 75 s, fictional school logistics) played
from the Mac; Summary tapped by automation about 3 s after the end. Engine Qwen3.5-4B (Metal);
request to result 10.82 s (model 10.66 s); 26 utterances, 154 words.
Manual check against the script: times, room, deadline change, amount, payment method and
place correct; two wrong items ("free tape" added to the items to bring; "meal trip" instead of
"field trip"); one personal detail omitted. Whether these came from speech recognition or the
model was not checked (the transcript was not inspected). One synthetic summary is now in the
phone's History.

## Offline check: shorter classifier hop (`offline_overlap/`)

Mac, forward-only, `hs-sound-eval evaluate --window 1.5 --overlap {0.5,0.75}` (new `--overlap`
option), LibriSpeech 500 / GTZAN 300 / DEMAND, current `DetectionPolicy.standard` (2 hits).
Hop 0.75 → 0.375 s confirms speech/music 0.375 s sooner (median 2.25 → 1.875 s), but false
events rise sharply: DEMAND alert-category events 1 → 6, vehicle_horn on GTZAN 7 → 10, other
kinds on speech-only clips 121 → 330 (insect 37 → 107, small_objects 37 → 112). Two hits of
heavily overlapping windows are no longer independent evidence. Not adopted.
