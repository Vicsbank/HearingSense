# Window 4 Report — Context-Aware Attention Priority Engine

Date: 2026-10-10. Branch `feature/window4-attention-priority` (from
`experiment/background-acoustic-recognition`). Not merged, not pushed.
Architecture: `docs/research/ATTENTION_ENGINE_ARCHITECTURE.md`. Numbers and methods:
`docs/testing/WINDOW4_TEST_RESULTS.md`.

**Status: implemented, integrated in the app, tested on the Mac and in the iPhone Simulator with
synthetic events. Not tested on a physical iPhone and not with real sounds.**

---

## 1. Baseline for this window

Found at the start (2026-10-10):

| Item | State found | Action |
|---|---|---|
| Device results of the background research (A1, A2, CPU-only run) | In the working tree only: `results/device_background/` untracked, two documents modified | Committed on the research branch as `be7e8de` (documentation and metadata-only result files; no code) |
| The A2 fix (`UIBackgroundModes` = `audio` + `processing`) | Only an experiment plist used with `INFOPLIST_FILE=…`; the app's own `Info.plist` still had `audio` alone | **Adopted** in `apps/ios/Config/HearingSense-Info.plist`, with exactly the two keys that were tested. An `audio`-only variant is kept in `Config/Experiments/` so that A1 → A2 → A1 can be repeated |
| The rest of the research branch (classifier backends, Core ML models, hybrid switch, probe, benchmark) | One commit on top of Window 3; Apple's classifier is the default; third-party models only behind a Debug launch argument | Kept as it is. The branch was used as the base because the A2 result (342 of ≈ 342 windows in 256.5 s, 0 failures) was measured on exactly this code (`AppleSoundAnalysisBackend`), not on the Window 3 worker |

What this does not settle: A2 was one run, on USB power, without AirPods or Spotify; the 10-minute
run (A3) and a repeat are still open (`docs/testing/BACKGROUND_DEVICE_TESTS.md` §7.7). No
`BGProcessingTask` is registered; whether App Review accepts the declared mode was not looked into.
Windows 1–3 and the research assets are unchanged; before the first change the package tests were
190 passed / 1 skipped of 191.

## 2. What was built

1. **Output contract** (`HearingSenseDomain`): `AttentionEvent`, `AttentionPresentationIntent`,
   priorities, categories, reason codes, lifecycle, source records, private content.
2. **`Attention` module**: `AttentionEngine` — priority assessment with reason codes, temporal
   fusion, rejoin and deduplication, per-kind cooldowns, presentation budget, update coalescing,
   escalation, stale-source handling, expiration; three modes; preferences; the whole policy as
   data (`AttentionConfiguration.standard`). Depends on `HearingSenseDomain` only.
3. **Speech integration**: tiers (irrelevant / ordinary / informative / important) from the
   existing `SpeechSemanticResult`, an urgent-phrase rule, meaning comparison of summary revisions.
4. **`AttentionReplay` + `hs-attention-eval`**: synthetic event builders, 18 scripted scenes with
   ground-truth labels, a seeded long scene, a baseline, metrics, decision traces.
5. **App**: `AttentionController` wired to the Window 2 and 3 streams (no new audio consumer), the
   Attention card with the mode switch, Attention settings, the Attention decisions debug screen
   with synthetic event injection, attention lines in the diagnostics export and report.
6. **Tests**: 65 new test functions.

About 5 700 lines of Swift including tests.

## 3. The three modes

| | Quiet | Balanced (default) | Sensitive |
|---|---|---|---|
| Intent | fewest interruptions | important sounds, clearly relevant speech | more of what changes |
| Rain, wind | – | – | low, once |
| Music | – | – | – |
| Dog barking | – | when sustained | normal |
| Door knocking | normal | high | high |
| Car horn, glass breaking | high | high | high |
| Emergency siren | urgent | urgent | urgent |
| Ordinary speech | – | when sustained, 90 s cooldown | normal, 45 s cooldown |
| Possible spoken warning | high | high | high |
| Cooldowns | × 2 | × 1 | × 0.5 |
| Ordinary presentations per minute | 2 | 4 | 8 |

The user can switch modes at once, set each of 14 sound categories to automatic / muted / low /
normal / high, choose how much speech asks for attention (off / important only / automatic / all),
and restore the defaults. Preferences are stored on the iPhone. Full table for all 50 sound kinds:
architecture document §4.1.

## 4. Results (synthetic scenes; see the test document for method and labels)

| | Quiet | Balanced | Sensitive | Baseline (every confirmed event) |
|---|---|---|---|---|
| 18 scenes: alerts | 37 | 52 | 63 | 121 |
| 18 scenes: important events retained | 30/30 | 30/30 | 30/30 | 30/30 |
| 18 scenes: duplicates suppressed | 6/6 | 6/6 | 6/6 | 0/6 |
| 18 scenes: unnecessary alerts | 1 | 1 | 9 | 53 |
| Generated hour: alerts per hour | 22 | 51 | 86 | 180 |
| Generated hour: important retained | 18/18 | 18/18 | 18/18 | 18/18 |
| Generated hour: unnecessary alerts per hour | 0 | 0 | 22 | 93.8 |
| Engine-added delay for important events | 0 s | 0 s | 0 s | – |

Decision time per input: median 9 µs, p95 17–32 µs (release build, M1 Max). At most 16 episodes
were held at once (48 allowed); the engine was empty at the end of every run. Replaying every scene
twice gave identical decisions (3 880 compared).

Read these numbers as follows: the scenes and their labels were written in this window alongside
the engine. They demonstrate that the rules do what they are meant to do, deterministically and
without growing state. They say nothing about how often real sounds are classified correctly, and
"unnecessary" in Sensitive counts ambient sounds that the mode shows once on purpose.

## 5. Definition of done

| # | Criterion | State |
|---|---|---|
| 1 | Acoustic events enter the priority engine | Yes: `RecognitionController` → `AttentionController.receive` |
| 2 | Speech results integrate | Yes: `SpeechIntelligenceController` forwards every result; tiers, late summaries, revisions |
| 3 | Quiet / Balanced / Sensitive work | Yes; scene 15 and `theThreeModesDiffer` |
| 4 | Custom preferences work | Yes; scene 16, persisted, restore defaults |
| 5 | Decisions deterministic and explainable | Yes; every decision has reason codes; determinism run |
| 6 | Temporal fusion without invented causality | Yes; onset-order rule, wording "afterwards", scenes 6 and 7 |
| 7 | Repeated sounds do not cause alert spam | Yes; scenes 1, 2, 4 |
| 8 | New important events remain visible | Yes; scenes 3, 5, 12, 14 |
| 9 | Late summaries update existing events | Yes; scenes 10 and 11 |
| 10 | Presentation intent ready for Window 5 | Yes; `AttentionPresentationIntent`, `onIntent` |
| 11 | No regression in the existing pipeline | The 191 earlier tests pass unchanged; app builds. **Not re-verified on the iPhone** |
| 12 | Automated tests and evaluation | Done (synthetic) |
| 13 | Documentation | Done |
| 14 | Committed | On `feature/window4-attention-priority` |

## 6. Privacy and resources

On-device only; no network code. No audio is touched. The engine keeps no transcript: it reads one
once for the phrase rule and keeps flags and the validated headline, in memory. Headlines are
excluded from `Codable`, from the decision log and from every report. Switching transcription off
removes speech from the engine. No training, no downloads, no long computation (the longest run
took seconds). The microphone was not used in this window, on any device.

## 7. Known limitations

1. **No real-world validation.** All evaluation input is synthetic and hand-labelled. The policy
   table, cooldowns, thresholds and the phrase list are defaults, not tuned on recordings.
2. **No physical-iPhone test of Window 4**, and the adopted background mode rests on one run (§1).
   If the classifier stops in the background after all, the engine resolves its episodes as stale
   after 20 s and shows nothing new until the classifier returns.
3. **Importance of speech is keyword- and category-based.** The phrase list is English and short;
   a recognition error can create or hide a warning (Window 3 saw "not" → "now" once); categories
   from the language model are debatable. A title never claims more than "Possible Spoken Warning".
4. **Meaning comparison is lexical.** Synonyms count as a change (shown as a quiet update, never
   merged silently); only polarity, numbers and time words make a change critical.
5. **Fusion is a time rule with two pairs** (door or phone, then speech). Unrelated speech that
   happens to start within 8 s after a knock is grouped — worded as "afterwards", never as a cause.
   Sounds are not fused with each other.
6. **With transcription off and music playing, nearby speech is not presented**: without a
   transcript Window 3 gives no speech-or-lyrics estimate, and the engine does not guess.
7. **A sound that starts during its cooldown is not shown even if it outlasts the cooldown**
   (unless its priority rises). Chosen to avoid late pop-ups; it can hide a long second occurrence.
8. **Muting sirens, alarms or horns is allowed** and means they are not shown; the settings screen
   says so.
9. **Presentation exists only inside the app** (card and debug screen). No Live Activity, Dynamic
   Island, haptic or notification.
10. **The decision timer runs on the main actor.** Fine while the app runs (audio background mode);
    behaviour after a suspension was not tested.
11. The Release build contains the debug screens and the synthetic scenes (as it contains the
    earlier debug screens). Remove or gate them before a release.
12. Third-party classifier labels (research branch) reach the engine through the same 50 kinds;
    nothing was tuned for them.

## 8. Readiness for Window 5

Ready as an interface: Window 5 can subscribe to `AttentionController.onIntent` and read
`AttentionController.presented`; the intent separates lock-screen-safe text from speech-derived
text and carries id, revision, priority, category, timestamp, expiration, action and reasons. The
debug screen can drive it with synthetic events without a microphone.

Before relying on it on a locked iPhone: repeat A1 → A2 and run A3 (10 minutes locked) with the
new default build, then one live session with real sounds to see the engine's decisions on real
detector output. Each needs the student's microphone authorization.
