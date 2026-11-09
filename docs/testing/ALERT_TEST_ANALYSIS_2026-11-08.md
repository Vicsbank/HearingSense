# Real-sound alert test on iPhone — analysis, 2026-11-08

**Evidence: physical iPhone** (iPhone 18 Pro, iOS 27.3), real microphone, ESC-50 recordings played
through the MacBook Pro speakers (volume 75 %). Run and recorded by a parallel session (Window 10)
at 17:35–17:40 MST; this document is an independent analysis of its export. Debug build of
2026-11-09T00:34Z (source `main` a54eb52), launch arguments `--hs-transcription-off --hs-autostart
--hs-export-diagnostics --hs-autostop-after 280`. Phone unlocked, Settings in front, app in the
background. Attention mode: Balanced. Transcription locked off: 0 utterances.

Files: `results/alert_test_2026-11-08/` (diagnostics export: metadata only; playback log;
`per_clip.txt` from `tools/analyze_alert_test.py`). Clip onset offsets come from the recording session.
Clock offset between Mac and iPhone (both network-synced) is not measured.

## Per clip (12 clips, 20 s apart)

Latency = sound onset → alert request (expansion handed to ActivityKit 3–9 ms later).

| Clip | Expected | Recognized as | Alert | Latency |
|---|---|---|---|---|
| knock `1-101336-A-30` | alert | Door or knock 1.00 | yes | 0.78 s |
| siren `1-31482-A-42` | alert (urgent) | Siren 0.78 | yes | 4.01 s |
| car horn `1-17124-A-43` | alert | not recognized (fan 0.54) | no | — |
| dog `1-110389-A-0` | icon only | Dog 0.68 | no (correct) | — |
| alarm clock `1-13613-A-37` | alert | Phone ringing 0.97, then Alarm 0.66 | yes | 2.54 s |
| glass `1-20133-A-39` | alert | not recognized | no | — |
| knock `1-103995-A-30` | alert | not recognized | no | — |
| siren `1-54084-A-42` | alert (urgent) | Siren 0.80 (+ Horn/foghorn 0.97) | yes | 1.82 s |
| car horn `1-19026-A-43` | alert | **Horn 0.98** | **no — suppressed** | — |
| dog `1-100032-A-0` | icon only | Dog 0.86 | no (correct) | — |
| alarm clock `1-14262-A-37` | alert | not recognized | no | — |
| glass `1-84536-A-39` | alert | Breaking glass 1.00 | yes | 1.42 s |

Summary:

- **Alerts: 5 of 10** alert-worthy clips (siren 2/2, knock 1/2, alarm 1/2, glass 1/2, horn 0/2).
- **Recognition of the right kind: 6 of 10**; the 6th (horn) lost its alert to a pipeline rule.
- **False alerts: 0** (no alert outside the clip windows; both dogs icon only).
- Alert latency median **1.82 s** (0.78–4.01 s, n = 5).
- The app's own `--hs-autostop-after` stop fired (`last end: time_limit`; Live Activity ended 280 s
  after launch). This was unverified in R1.
- Not verified: whether iOS visibly expanded the island (no screen captures were analyzed).

## Finding 1 — a lingering siren blocks a new car-horn alert (pipeline, fixable)

`IslandPipeline` sends an alert only when the new episode is the lead (`candidate.id == leadID`).
`selectLead` keeps the current lead in contention after it is resolved and ranks by priority first.
The urgent siren ended at 00:37:48.5 but stayed lead until it expired at 00:38:03.5; the car horn
(high, safety-relevant, active) was confirmed at 00:38:01.99, could not become lead, and its alert
candidate was dropped. When the siren expired 1.5 s later the horn became lead, without an alert.
`alertRequestsRateLimited` stayed 0, so the statistics do not show this loss.

**Fixed (same day, Mac only, not yet on the iPhone)** in `IslandPipeline`:

1. `selectLead`: an active episode of at least `protectedPriority` (high) goes before a resolved
   one, whatever the resolved one's priority, and without waiting for the minimum hold.
2. An expansion request whose episode is not in front is kept and sent when that episode reaches
   the front while still active (rate limit unchanged); if the episode ends first it is counted in
   the new `IslandStatistics.alertsLostToLead`, shown in the diagnostics report as "lost behind
   another episode".

Tests: two new `IslandPipelineTests` (the device sequence, and the pending/lost cases) failed
before and pass after; package tests 700 pass. Scripted scenes (`hs-attention-eval island`,
synthetic): 57 runs, 0 rule violations; scene 15 gains one expansion in each mode (a request the
old rule lost), the 60-minute soak is unchanged. Device confirmation needs a repeat of this test.

## Finding 2 — clip-specific recognition misses (Apple classifier)

Four clips were not recognized. Loudness does not explain it: missed glass `1-20133` is as loud as
the recognized `1-84536` (loudest 0.5 s −8.3 dBFS each), and a quieter siren (−19 dBFS) was
recognized. Glass `1-20133` and knock `1-103995` were also missed in R1 (2026-10-11), so these
recordings fail repeatedly. With two clips per kind the per-kind rates are not statistically
meaningful.

## Next test

Repeat with more clips per kind (at least 5 different recordings each for siren, horn, alarm,
glass, knock), plus 8–10 negative kinds (rain, keyboard, footsteps, sneeze, door creak, crying,
music) to measure false alerts, 25 s apart so episodes do not overlap, Auto-Lock set to Never by
the student, and island strip captures to verify the visible expansion.
