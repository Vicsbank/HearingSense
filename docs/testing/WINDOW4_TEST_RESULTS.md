# Window 4 — Test Results (Attention Priority Engine)

Date: 2026-10-10. Branch `feature/window4-attention-priority`.
Machine: MacBook Pro M1 Max, macOS 27.2, Swift 6.4, Xcode 27. Simulator: iPhone 18 Pro, iOS 27.0.
Architecture: `docs/research/ATTENTION_ENGINE_ARCHITECTURE.md`.

**What kind of evidence this is.** Everything here was obtained with *scripted, synthetic* events
(model id `synthetic.replay`) fed to the production `AttentionEngine`. The scenes, their timing and
their ground-truth labels were written by hand in this window, together with the engine, and both
were adjusted while the engine was developed. The results show that the engine implements its
rules on these scripts, deterministically and within bounds. **They are not a measurement of
real-world accuracy**, and no physical-iPhone test of Window 4 was run (no microphone was used).

---

## 1. Automated tests

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | Mac | **256 tests: 255 passed, 1 skipped** (opt-in real language-model test). 65 are new (`AttentionTests`); the 191 from Windows 1–3 and the research window are unchanged |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27.0 Simulator, iPhone 18 Pro | **261 tests: 257 passed, 4 skipped** (3 recognizer tests — no `SpeechTranscriber` in the Simulator — and the opt-in test), `TEST SUCCEEDED` |
| App build, Debug | iOS Simulator | **Succeeded**, 0 Swift warnings |
| App build, Release, unsigned | generic iOS device | **Succeeded**; built `Info.plist` has `UIBackgroundModes = [audio, processing]` |
| App launch, attention card, settings and debug screens, synthetic injection | iPhone 18 Pro Simulator, microphone off | Works; screenshots in `docs/device-tests/window4-simulator/` (§6) |
| Any physical-iPhone test of Window 4 | iPhone 18 Pro | **Not run** |

`AttentionTests` (65 test functions, several run once per mode):

- 22 scenario tests: the 18 scenes of the test plan with expectations per mode, determinism of every
  scene, the generated one-hour scene in each mode, the baseline.
- 43 engine tests: policy table (every taxonomy kind has a row; base priorities of the brief),
  preferences (defaults, JSON round trip, tolerant decoding), priority (confidence is not
  importance, urgent needs more than weak evidence, conditional sounds, minor sounds, repetition
  escalation, a reason code on every decision), cooldowns and budget (per mode, warning signals
  never held back, deferred and released or dropped), speech (urgent-phrase rules, semantic
  signatures, warning in every mode, negated keyword, sticky warning, partial transcripts cause no
  decisions, speech attention settings, cooldown bypass, warning after the presentation timed out,
  music ambiguity, both arrival orders of knock and speech, speech long after a knock, warning
  after a knock), state (mode switch on active events, snapshot order, bounds, deadlines without
  polling, intent contract, private text never encoded, unknown and out-of-order inputs,
  transcription switched off, playback, session end).

## 2. Evaluation method

Tool: `hs-attention-eval` (package `AttentionReplay`), release build, on the Mac.

```bash
cd packages/HearingSenseKit
swift run -c release hs-attention-eval scenarios --json ../../results/attention_eval_window4/scenarios_summary.json
swift run -c release hs-attention-eval soak --hours 1 --json ../../results/attention_eval_window4/soak_60min_summary.json
swift run -c release hs-attention-eval trace 06-knock-then-speech --mode balanced   # decision by decision
swift run -c release hs-attention-eval determinism
```

Each run takes a few seconds. Output of the runs reported here: `results/attention_eval_window4/`.

**Replay.** A scene is a list of engine inputs with times. Sounds imitate the detector
(confirmation 1.6 s after the start, an update every 5 s, the end 2–5 s after the last evidence);
speech events publish detected / partial / final / summary / completed revisions. The replayer
feeds the inputs in order and delivers a tick at every `nextDeadline`, then lets 180 s pass.

**Baseline.** "Display every confirmed event": one alert for every confirmed sound event, one for
every new speech event and one for every new summary revision.

**Alert.** A `SHOW`, or an `UPDATE` whose intent has an interruption other than `none`. Quiet
content updates, suppressions, deferrals and endings are not alerts.

**Labels** (ground truth of a scripted source; independent of the mode):

| Label | Definition | An alert on it is |
|---|---|---|
| important | Should lead to an alert in every mode: warning signal, knock, possible spoken warning, a new independent occurrence of one of these | required |
| optional | Depends on mode and context: dog, ordinary or informative speech, phone | neither required nor an error |
| ambient | Background sound: rain, wind, traffic, footsteps | unnecessary; Sensitive mentions it once at low priority by design |
| irrelevant | Music, probable lyrics, handling noise, anything muted | unnecessary |
| duplicate | A repeat of something already reported | unnecessary |

**Metrics.** Important-event retention = important sources with at least one alert / important
sources. Duplicate suppression = duplicate sources without any alert / duplicate sources.
Unnecessary alerts = alerts on ambient, irrelevant or duplicate sources; reduction = 1 − engine /
baseline. An alert is attributed to the source whose input caused it (for timer decisions, to the
episode's first source). Decision time = wall-clock duration of `AttentionEngine.process` per input.

## 3. The 18 scenes

Columns: engine alerts / baseline alerts; important retained; duplicates suppressed; unnecessary
alerts engine / baseline. Q = Quiet, B = Balanced, S = Sensitive.

| # | Scene | Alerts Q · B · S (baseline) | Important | Duplicates suppr. | Unnecessary Q · B · S (baseline) | What the run shows |
|---|---|---|---|---|---|---|
| 1 | Continuous rain, 10 min with a 17 s gap | 0 · 0 · 1 (2) | – | 1/1 | 0 · 0 · 1 (2) | Sensitive shows rain once at low priority, takes it down after 20 s and never again; the resumed rain is suppressed |
| 2 | Repeated music, sung words | 0 · 0 · 0 (5) | – | – | 0 · 0 · 0 (5) | `music_context`, `low_relevance`; lyrics `possibly_lyrics` |
| 3 | Car horn during rain | 1 · 1 · 2 (2) | 1/1 | – | 0 · 0 · 1 (1) | Horn shown at once, `high`, `safety_relevant`, `new_event` |
| 4 | Repeated vs independent horns | 3 · 3 · 3 (6) | 3/3 | 3/3 | 0 · 0 · 0 (3) | Three bursts → three episodes; honks inside a burst are quiet updates "Repeated n times" |
| 5 | Siren during cooldowns | 5 · 6 · 6 (7) | 3/3 | 1/1 | 0 · 0 · 0 (1) | Both sirens `urgent` with no delay; in Quiet with `rate_limit_bypassed`; second dog suppressed |
| 6 | Door knock followed by speech | 1 · 1 · 1 (3) | 1/1 | – | 0 (0) | One episode: present, update (speech joined), update (summary), dismiss |
| 7 | Unrelated speech near a knock | 1 · 2 · 2 (2) | 1/1 | – | 0 (0) | No fusion: the conversation began 10 s before the knock |
| 8 | Transcription disabled | 0 · 2 · 2 (6) | – | 1/1 | 0 · 0 · 0 (2) | "Nearby Speech", `transcription_off`, no private text |
| 9 | Possible lyrics | 1 · 1 · 1 (4) | 1/1 | – | 0 · 0 · 0 (3) | Sung "watch out" and "fire" never alert; the spoken warning over music does, at `normal`, uncertain |
| 10 | Late summary | 0 · 1 · 1 (2) | – | – | 0 (0) | Summary 4.5 s later: quiet update of the same id |
| 11 | Summary revisions | 0 · 2 · 2 (5) | – | – | 0 (0) | Reworded → suppressed; reversed → immediate update; extended → deferred, then quiet update |
| 12 | Three high-priority events in 0.5 s | 3 · 3 · 3 (4) | 3/3 | – | 0 · 0 · 0 (1) | Three episodes, none deferred |
| 13 | Expiration and cleanup | 4 · 4 · 4 (3) | 3/3 | – | 0 (0) | Stale siren resolved after 20 s; alarm escalated once (the 4th alert), taken down while sounding; engine empty at the end |
| 14 | 44 events in 12 s | 4 · 7 · 12 (44) | 3/3 | – | 0 · 0 · 3 (28) | Knock, horn and glass shown with no delay; state bounded |
| 15 | Mode comparison | 5 · 7 · 9 (11) | 5/5 | – | 0 · 0 · 2 (3) | See §4 |
| 16 | Preference changes | 4 (6) | 1/1 | – | 1 (3) | Mode switch shows rain at once (the one unnecessary alert, on an ambient source after the script switches to Sensitive); mute takes it down; muted dog, speech attention off, and a High override behave as set. The scene sets its own preferences, so the three rows are equal |
| 17 | Background lifecycle | 4 · 4 · 5 (5) | 4/4 | – | 0 · 0 · 1 (1) | Classifier stall → `source_stale`; session end dismisses; clean restart |
| 18 | Unavailable models | 1 · 4 · 5 (4) | 1/1 | – | 0 (0) | Generic speech with `model_unavailable`; "watch out" is still recognized by the phrase rule without the language model |

Totals over the 18 scenes (30 important, 6 duplicate sources; 121 baseline alerts, 53 of them
unnecessary):

| Mode | Alerts | Important retained | Duplicates suppressed | Unnecessary alerts (reduction vs 53) | Alerts by label |
|---|---|---|---|---|---|
| Quiet | 37 | 30/30 | 6/6 | 1 (98.1 %) | important 31, optional 5, ambient 1 |
| Balanced | 52 | 30/30 | 6/6 | 1 (98.1 %) | important 31, optional 20, ambient 1 |
| Sensitive | 63 | 30/30 | 6/6 | 9 (83.0 %) | important 32, optional 22, ambient 9 |

"Important 31/32" exceeds 30 because an escalation (the alarm, the fused warning) is a second alert
on the same source. The single unnecessary alert in Quiet and Balanced is scene 16's rain after the
script itself switches to Sensitive. Sensitive's nine are ambient sounds shown once at low
priority, which is that mode's policy.

These totals are over 30 hand-written important events. A 100 % on them means the engine does what
the scripts were written to check.

## 4. Differences between the three modes (scene 15)

| Event | Quiet | Balanced | Sensitive |
|---|---|---|---|
| Rain | not shown | not shown | shown once, low |
| Wind | not shown | not shown | shown once, low |
| Music | not shown | not shown | not shown |
| Dog barking (8 s) | not shown | shown (condition met), normal | shown, normal |
| Door knock | shown, normal | shown, high | shown, high |
| Car horn | shown, high | shown, high | shown, high |
| Emergency siren | shown, urgent | shown, urgent | shown, urgent |
| Glass breaking | shown, high | shown, high | shown, high |
| Ordinary speech | not shown | shown once sustained, normal | shown, normal |
| "Watch out" | shown, high | shown, high | shown, high |
| Alerts (baseline 11) | 5 | 7 | 9 |

This matches the policy table of the brief and is asserted by `theThreeModesDiffer`.

## 5. Generated long scene, latency, stability

A seeded generator (`ScenarioLibrary.soak`, seed 20261010) places a random mix of ambient,
irrelevant, optional, important and immediately repeated events. The mix is invented; an important
event is only scripted when its kind has been silent for a minute, and lyrics come with a music
event. The rates below describe this script, not a real hour.

**One simulated hour** (166 sources: 18 important, 8 duplicate, 29 ambient, 61 irrelevant, 50
optional; 1 267 inputs):

| Mode | Alerts/h (baseline 180) | Important | Duplicates suppr. | Unnecessary alerts/h (baseline 93.8) | Engine-added delay p50 / p95 | Max episodes / deferred | Left at the end |
|---|---|---|---|---|---|---|---|
| Quiet | 22 | 18/18 | 8/8 | 0 | 0 / 0 s | 7 / 0 | 0 |
| Balanced | 51 | 18/18 | 8/8 | 0 | 0 / 2.5 s | 7 / 1 | 0 |
| Sensitive | 86 | 18/18 | 8/8 | 22 (all ambient, low priority) | 0 / 0 s | 7 / 0 | 0 |

**Eight simulated hours** (same seed; 162 important, 52 duplicate sources): important 162/162 and
duplicates 52/52 in every mode; unnecessary alerts/h 0 (Quiet), 0 (Balanced), 26.1 (Sensitive)
against a baseline of 90.2; at most 7 episodes at once; 0 left at the end.

"False alerts per simulated hour" in the sense of the brief is the unnecessary-alert rate above.
The 2.5 s p95 delay in Balanced is the wait for ordinary speech to be sustained; important events
had no engine-added delay in any run.

**Decision time** (`AttentionEngine.process`, wall clock, release build, M1 Max):

| Run | Inputs | Median | p95 | Max |
|---|---|---|---|---|
| 18 scenes × 3 modes | 2 249 | 9.0 µs | 31.8 µs | 247 µs |
| 1 simulated hour × 3 modes | 3 982 | 9.1 µs | 18.8 µs | 92 µs |
| 8 simulated hours × 3 modes | 32 571 | 9.1 µs | 17.2 µs | 172 µs |

In the Simulator (Debug build) the app's own counter showed a mean of about 0.4 ms over the first
few dozen inputs, dominated by a 3.9 ms first call. No iPhone figure exists.

**Memory and queues.** Engine state is bounded by construction (48 episodes, 8 sources per
episode); the largest number of episodes at once was 7 in the long scenes and 16 in the burst
scene; nothing was left after any run. Process memory of the tool rose from 4.2 to 6.9 MB over the
three one-hour runs; that figure includes the harness, which keeps every decision for the report.
A capacity test with a limit of 5 episodes confirms eviction of the least important first.

**Determinism.** `hs-attention-eval determinism`: every scene and a 30-minute generated scene
replayed twice in each mode — 3 880 decisions compared, 0 runs differ.

## 6. Simulator check of the app (microphone off)

`docs/device-tests/window4-simulator/`:

| File | Shows |
|---|---|
| `01_attention_card_idle.jpg` | Main screen with the Attention card: mode switch (Balanced), "Nothing needs attention" |
| `02_debug_active_tracked_cooldowns.jpg` | Injected events: "Possible Spoken Warning" with its summary shown inside the app, Alarm (high), Dog (normal); lyrics tracked as "Speech Or Music (uncertain)"; cooldowns for dog and speech |
| `03_debug_fusion_knock_then_speech.jpg` | Injected knock, then speech: one episode "Door or knock · Nearby speech afterwards" with both sources and "Grouped by closeness in time only"; the alarm escalated to urgent |
| `04_debug_inject_synthetic_events.jpg` | The injection list (sounds, speech variants, scene picker) |

This is Simulator evidence of the wiring and the screens, with synthetic events. The live path
(microphone → classifier → engine) was not exercised in this window.

## 7. Not tested

- Any physical iPhone: real sounds, AirPods and Spotify, the lock screen, the background (the A2
  configuration is now the app's default but was not re-run), battery and heat.
- The live microphone path in the Simulator with the attention card.
- Real `SpeechSemanticResult` sequences from the speech engine into the attention engine (the
  integration is by type and by the scripted sequences; Window 3's engine tests are unchanged).
- Whether the thresholds, cooldowns and phrase list suit real environments.
