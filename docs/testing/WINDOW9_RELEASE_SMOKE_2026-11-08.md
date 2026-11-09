# Window 9 Release smoke test on iPhone — 2026-11-08

Build: `main` at `a54eb52`, Release, development-signed (team 86G57JQY76), signed 17:12 MST.
Installed in place on iPhone 18 Pro (`iPhone19,2`), **iOS 27.3** (earlier reports used 27.2).
Driver: iphone-use 0.17.15 over USB, plus `devicectl`. Microphone never started; no speech,
no summaries generated. Evidence type: **physical iPhone** (UI only) and **Mac** (package tests).

## Results

| Check | Result |
| --- | --- |
| Install in place | Pass; existing data kept (Settings shows 10 saved summaries). |
| Launch from the new bundle | Pass; process path matches the new installation. |
| Cold launch to "Start Listening" visible (includes driver overhead) | 1.34 / 1.42 s; third run: launch call 1.17 s |
| Listen screen idle state | "Not Listening", microphone off. |
| Settings, Sound Priorities, Speech Data & Privacy, Action Button pages | All open and return; no crash. Privacy page: microphone off, 0 sentences held. |
| History tab | Opens (content not read). |
| Tab switching Listen → Settings → Listen → History → Listen | Pass. |
| Mac package tests (`swift test`) | **698 pass, 0 fail** after the corpus fix below. |

## Findings

1. **Regression corpus missing from the main checkout.** `CorpusRegressionTests` failed because
   `data/summary_regression/en_judged_v1.json` (not in Git) was lost with the deleted Window 9
   worktree. It was rebuilt with `tools/summary_regression/build_corpus.py` from tag
   `archive/local-model-comparison` (`results/summary_model_bench/judging/main`): 44 conversations,
   264 judged summaries, the count the test expects. The data is synthetic.
2. A Settings switch appears twice in the automation element tree (labelled row plus unlabelled
   inner switch). This is how XCUITest exposes a SwiftUI `Toggle`, not a VoiceOver defect.
3. One `devicectl` screenshot right after launch captured the Home Screen instead of the app
   (the app was not in front). It was deleted immediately. It showed the Hearing Sense "ear"
   island icon and the orange microphone dot; Release code has no automatic listening start, so
   the source of that microphone use is **not verified**. The app was terminated as a precaution.

## Not tested

Listening, sound alerts, transcription, Summary/Continue, Dynamic Island, lock-screen and
background behaviour, battery and heat: these need the microphone and were not authorized.
