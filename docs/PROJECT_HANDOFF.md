# Project Handoff — Hearing Sense iOS 2.0

Last updated: 2026-10-11, end of **Window 6.3** (personal relevance) on its own branch; the Window
6.2, 6.1, 6 and 5 paragraphs below describe their branches.

**Window 6.3 status: code complete on `feature/window6-3-personal-relevance`, branched from Window
6.2 `197d0d0` in a fifth worktree (`.claude/worktrees/window6-3`). Not merged, not pushed, not
rebased; the Window 5 checkout and the Window 6, 6.1 and 6.2 worktrees were not touched. Mac (real
language model, synthetic text) and iOS Simulator only: no microphone, no iPhone, no training, no
download, same Apple model.** The question of the window: does a sentence apply to *this* listener?
New: an optional "About me" line in the app; rules that compare whom a sentence names with the
listener's own words (`AudienceAnalyzer`); one narrow question to the model for a sentence that calls
a person by name ("theirs or everyone's?"); an alert when the listener's own name is called; cut-off
sentences, "nothing changes" and marked reminders taken at the speaker's word; the sentence before
given only to a sentence that leans on it. On a new sealed set by another author (315 sentences,
unseen goals, run once after the freeze `1e269b8`): Window 6.2 148 true alerts / 67 false / 4 missed
(precision 68.8 %, recall 97.4 %) → Window 6.3 as frozen **140 / 41 / 12 (77.3 %, 92.1 %)**.
**Neither 95 % target was met.** Seven of the eight new misses came from one rule ("another group"),
which removed only four false alerts; it was switched off after the sealed run
(`Configuration.holdsBackOtherGroups = false`; the frozen configuration is
`Configuration.window6_3Frozen`). A recount of the same runs for the shipped setting gives 147 / 45 /
5 (76.6 %, 96.7 %) — a recount, not an independent measurement. Found on the way: the app of Window
6.2 gave every sentence the three before it, which no benchmark had done; 22 of 315 decisions
depended on them, 3 of 315 now. **Throughput is unchanged** (about 35 sentences a minute on the Mac):
every cheaper request either lost correct alerts or saved 10–25 % at best. In the iOS Simulator the
system's name tagger has no data; names are then told by their form (which path an iPhone takes is
unknown). Read `docs/research/WINDOW6_3_PERSONAL_RELEVANCE.md`, then
`docs/testing/WINDOW6_3_BENCHMARK.md`. Open for the student: ship this branch in place of Window
6.2's engine (recommended), sentences for a group the listener is not in as the next piece of work
(needs a new held-out set), iPhone validation, and how to bring the five branches together.

**Window 6.2 status: code complete on `feature/window6-2-precision-backpressure`, branched from
Window 6.1 `a979cf9` in a fourth worktree (`.claude/worktrees/window6-2`). Not merged, not
pushed, not rebased; the Window 5 checkout and the Window 6 and 6.1 worktrees were not touched.
Mac (real language model, synthetic text) and iOS Simulator only: no microphone, no iPhone, no
training, no download, same Apple model.** On a new sealed set by another author (264 sentences,
unseen goals, run once after the freeze): precision 76.5 % (Window 6.1) → **83.8 %**, false
alerts 35 → 22, recall 99.1 % → 99.1 %, implicit relevance 50/50 → 49/50, important events
19/19, urgent 12/12. **The 95 % precision target was not met**; 12 of the 22 false alerts are
sentences said to another person or group in the same place. Decisions no longer depend on the
order of the conversation in normal use (a session per sentence). Streams on the Mac: median
end-to-end 8.0 s → 3.0 s at a sentence every 1.5 s, 12.0 s → 5.3 s at one a second (p95 there
21 s → 31 s, by design); the model's capacity, about 35 sentences a minute, is unchanged;
overload is reported. Read `docs/research/PRECISION_AND_BACKPRESSURE_REPORT.md`, then
`docs/testing/WINDOW6_2_BENCHMARK.md`. Open for the student: whether to ship this engine in
place of Window 6.1's (recommended), the addressee problem as the next piece of work, and how to
bring the four branches together.

**Window 6.1 status: code complete on `feature/window6-semantic-optimization`, branched from
Window 6 `ead23f3` in a third worktree (`.claude/worktrees/window6-opt`). Not merged, not pushed,
not rebased; Window 5's uncommitted work and Window 6's worktree were not touched. Mac (real
language model, synthetic text) and iOS Simulator (package tests, app builds, the scripted
conversation) only: no microphone, no iPhone, no training, no download, same Apple model.**
Sealed set (220 new utterances, run once per configuration): recall 73.3 % → **98.1 %**, implicit
relevance 76.2 % → **97.6 %**, important events 11/16 → 16/16, short urgent instructions 8/12 →
12/12; **precision 90.6 % → 86.6 % (target 95 % not met; false alerts doubled, 8 → 16 of 96)**.
One judgement 2.74 s → 1.2–1.4 s on the Mac; end to end at a sentence every 3 s: p50 1.47 s
(was 3.86 s). Read `docs/research/SEMANTIC_OPTIMIZATION_REPORT.md`, then
`docs/testing/SEMANTIC_OPTIMIZATION_BENCHMARK.md`. Open decision for the student: ship the
Window 6.1 engine as frozen (recommended) or with independent judgements (`sessionTurns: 1`)
after a test on a new unseen set; then bring the three branches together.

**Window 6 status: code complete on `feature/window6-semantic-intelligence`, branched from the
committed Window 5 state `eddc450` in a separate worktree (`.claude/worktrees/window6`) because
another session was still working on Window 5 in the main checkout. Not merged, not pushed.
Verified on the Mac (395 package tests; evaluation tools) and in the iOS Simulator (package
tests, Debug and Release builds, the Window 6 screens, a scripted conversation through the real
language model). Nothing ran on the iPhone (the student's instruction for this window). All
speech text was synthetic.** It adds: a revised icon for every classifier label with nine
glyphs drawn by the app; attention goals in the user's words matched by model reasoning
(`SemanticAttentionEngine`); a two-minute recap behind an Action Button shortcut with continued
understanding and live captions; saved summaries. Held-out synthetic evaluation of goal
matching: precision 91 %, recall 86 %, 0 of 7 important events missed (keyword baseline: recall
40 %). Read `docs/WINDOW6_SEMANTIC_INTELLIGENCE_REPORT.md`, then
`docs/testing/WINDOW6_EVALUATION_RESULTS.md`, `docs/research/SEMANTIC_MODEL_COMPARISON.md` and
`docs/research/ACOUSTIC_ICON_COVERAGE.md`. **The Window 5 session's uncommitted work is not in
this branch**; the files both changed are listed in the report §10. Next: the student decides
how to bring the two branches together, then the device steps in the report §11.

**Window 5 status: code complete on `feature/window5-dynamic-island` (branched from the Window 4
branch; committed as `dc1f6cf`, with the changes of the device session on top — see `git status`;
not merged, not pushed); verified on the Mac (package tests), on the iPhone 18 Pro Simulator and,
on 2026-10-10 with the student's authorization, on the physical iPhone 18 Pro for the device steps
D1–D4: synthetic demo scenes, microphone off. Compact, expanded and Lock Screen presentations work
on the device; silent updates did not wake the locked screen (student-observed). D5–D6 then ran
with the real microphone (classification only; 34.9 minutes locked, 0 classifier failures, 256
updates per hour). After that session the icon rules, the alert-protection rule and two detection
rules were revised (kind `door_movement` split from `door`; `screaming` needs two windows), speech
without a summary became icon-only in the island, and a 5-minute retest R1 ran on the iPhone
(confirmation → update median 0.02 s instead of 2.2 s; 282 updates per hour). R1 found four more
problems; their fixes are unit-tested and replayed on the recordings but **have not run on the
iPhone** (the final build is installed). Next: R2–R3 (test results §9), microphone authorization
needed. Commits: `dc1f6cf` (Window 5), `1d06721` (device session), then the retest commit.** Read `docs/WINDOW5_DYNAMIC_ISLAND_REPORT.md`, then
`docs/testing/WINDOW5_TEST_RESULTS.md` (§5 device results, §7 the remaining device steps).
Next window: **Window 6 — Integration, Evaluation and Optimization** (not started; do not start it
without the student's instruction).

Window 4 status (2026-10-10, earlier the same day): code complete on `feature/window4-attention-priority` (branched from the
research branch `experiment/background-acoustic-recognition`); verified on the Mac (256 package
tests: 255 passed, 1 opt-in skipped) and on the iPhone 18 Pro Simulator (261 tests: 257 passed, 4
skipped; app builds Debug and Release; attention screens checked with synthetic events, microphone
off). All evaluation input is scripted and synthetic. No physical-iPhone test of Window 4 was
run.** The app's Info.plist now declares `audio` + `processing` (the configuration of device run
A2). Read `docs/WINDOW4_ATTENTION_PRIORITY_REPORT.md`, then
`docs/research/ATTENTION_ENGINE_ARCHITECTURE.md` and `docs/testing/WINDOW4_TEST_RESULTS.md`.
(Window 5 has since been done; see the first paragraph.)

Earlier status paragraphs follow unchanged, oldest first.

Window 3 status (2026-10-09): **code complete; verified on the Mac (unit tests, real recognizer and language
model on files), on the iPhone 18 Pro Simulator (unit tests, app build, level-1 live check) and,
after the student authorized it on 2026-10-09, on the physical iPhone 18 Pro with the screen on
(live transcript and validated summary ≈ 2 s after the speech).** Two defects found on the device
were fixed. **Open problem found on the device: with the screen locked or the app in the
background Apple's built-in sound classifier fails, so neither sounds nor speech are recognized
there** (§8, first row; `docs/testing/WINDOW3_TEST_RESULTS.md` §10.6). Window 2's device tests
(`docs/testing/WINDOW2_DEVICE_TESTS.md`) are still open.
(Window 4 has since been done; see the first paragraph.)

Git: `main` = reconstructed Window 1 baseline (`7905f0b`, `679494e`); Window 2 on
`feature/window2-sound-analysis` (`6f41d90`); Window 3 on `feature/window3-speech-intelligence`,
branched from the Window 2 branch; the research window on
`experiment/background-acoustic-recognition` (`0d6236d`, device results `be7e8de`), branched from
the Window 3 branch; Window 4 on `feature/window4-attention-priority`, branched from the research
branch; Window 5 on `feature/window5-dynamic-island`, branched from the Window 4 branch. The history is linear: each branch contains the ones before it. Nothing is merged or
pushed; there is no remote. Merging is the student's decision.

**Research window (2026-10-10), branch `experiment/background-acoustic-recognition`** (from the
Window 3 branch): background sound recognition. Mac work complete and committed; **no
physical-iPhone test of this window has been run** (approved by the student "for later"; the
phone was not connected). Read `docs/BACKGROUND_RECOGNITION_DECISION.md` first, then
`docs/testing/BACKGROUND_DEVICE_TESTS.md` (the next thing to do), `docs/research/
BACKGROUND_INFERENCE_INVESTIGATION.md`, `AUDIO_MODEL_COMPARISON.md`, `BACKGROUND_MODEL_BENCHMARK.md`.
Summary: Apple's classifier is still the default and still fails in the background; a CPU-only
Core ML backend (YAMNet / EfficientAT) and a hybrid switching backend exist behind
`AcousticClassifierBackend` and are selectable in Debug builds with `--hs-classifier`; on recorded
files Apple is the most accurate at 1–2 s, EfficientAT MN10 needs a 2 s window repeated into its
10 s input to work at all on short audio and then matches Apple on alert events. Provisional
decision: hybrid. Third-party models and ESC-50 are downloaded under `models/third_party/` and
`data/esc50/` (not committed); regenerate the Core ML models with
`tools/experiments/audio_models/convert_coreml.py` and copy them into the app with
`install_app_models.sh` before building. Tests: `swift test` 191 (190 passed, 1 opt-in skipped).
Do not start Window 4 before the device tests unless the student says so.

**Research window, second session (2026-10-10): first device runs** — A1, A2 and a short CPU-only
run, once each, on the iPhone 18 Pro (`docs/testing/BACKGROUND_DEVICE_TESTS.md` §7, raw
diagnostics in `results/device_background/`; documentation and result files only, no code change,
not committed at the time of writing). Results: (1) with `UIBackgroundModes = audio` the built-in
classifier fails in the background and when locked, as in Window 3; (2) **with `audio` +
`processing` (experiment build, `INFOPLIST_FILE=Config/Experiments/HearingSense-Info-processing.plist`)
it kept running in both — 342 of ≈ 342 windows in 256 s — and recognized a dog bark, a siren and a
knock played while the phone was locked**; (3) the CPU-only EfficientAT MN10 keeps running when
locked (32.8 ms per window) but labelled 0 of 6 played clips correctly; (4) the probe could not
test the GPU hypothesis, because the iPhone places the probe model on the CPU under every compute
unit setting. One run per configuration, on USB and charging: **not replicated, no 10-minute run
(A3), no battery data.** The shipping Info.plist is unchanged (`audio` only) and
`docs/BACKGROUND_RECOGNITION_DECISION.md` (hybrid with MN10) predates these runs. (Update, Window 4:
the student's Window 4 brief named Apple's classifier as the preferred one and asked for the A2
fix to be part of the baseline; the mode is now in `apps/ios/Config/HearingSense-Info.plist`, and
`Config/Experiments/HearingSense-Info-audio-only.plist` reproduces A1. These result files were
committed as `be7e8de`.) Next: §7.7 of the device test
document (repeat A1 → A2, then A3), each needing the student's microphone authorization. The
iPhone was driven with iphone-use (approved by the student; rules in the session memory) and
`devicectl`. The app's "Transcribe nearby speech" switch persists between launches and was found
on: check that it is off before any run that is meant to be without transcription.

Each Claude Code window starts without memory of earlier windows. Read this file first, then the
files listed in §11. Update this file at the end of every window.

---

## 1. Objective

Hearing Sense iOS 2.0 — *Intelligent Environmental Awareness*: an iPhone app that keeps people who
wear noise-cancelling headphones (AirPods) aware of their surroundings. While the user plays
Spotify / Apple Music, the app listens through the iPhone microphone, recognizes sound events with
Apple's Sound Analysis, transcribes and summarizes relevant speech on device (Speech, Foundation
Models), ranks events with a deterministic Attention Priority Engine, and shows what matters in the
app, a Live Activity and the Dynamic Island. Everything runs on the iPhone; no remote AI inference.
It is an awareness aid, not a safety or emergency system.

## 2. Hard constraints

- **No model training or fine-tuning** (including resuming, pilot runs, background or scheduled
  training) without a separate approval request: model + dataset, M1 Max best/conservative time
  estimates, resources, expected benefit, checkpoint/recovery plan, and the student's maximum
  allowed time. Forward-only inference, evaluation and model inspection are allowed.
- The Mac (M1 Max, 32 GB) is the student's daily school computer: no long or background workloads
  without approval; large downloads need approval with sizes shown.
- Do not delete, move or overwrite research assets (`models/`, `results/`, `data/`, `docs/` reports,
  `ml/`, `src/`, `tools/`). See `docs/EXISTING_PROJECT_AUDIT.md` §8.
- Do not fabricate results. Label evidence as Mac / Simulator / physical iPhone; never claim device
  validation from the Simulator.
- Apple-native frameworks first; no new third-party dependencies without a reason.
- Privacy: no audio persistence or upload; transcripts opt-in and minimal; diagnostics carry metadata only.
- (W3) **No microphone recording or transcription of real conversations without the student's
  authorization.** The Mac/Simulator microphone picks up real speech in the student's room; sound
  classification there was done before, transcription was deliberately not attempted.
- (W3) Physical-iPhone tests stay pending until the student explicitly authorizes them.
- Communicate with the student in Chinese; code, comments and docs in English.

## 3. Existing codebase (before iOS 2.0)

Music genre/emotion research, preserved unchanged (details: `docs/EXISTING_PROJECT_AUDIT.md`):

- Legacy science-fair models (trained in the original Windows phase): EfficientNet-B0 emotion
  (9 GEMS, Emotify) and CNN+GRU genre (10 GTZAN), FastAPI web app — `src/`, `models/*.pth`.
- macOS phase (2026-10-09, **evaluation and conversion only — no training**): Essentia pretrained
  models converted to `models/coreml/HearingSenseMusic.mlpackage` (16 kHz, 4.992 s window, CC BY-NC-SA),
  evaluation round 1 (`docs/evaluation_results.md`, `results/eval/`), forward-only ML tests (12/12 pass).
- `app/`: an abandoned macOS Swift package scaffold that does not build.

## 4. Completed in Window 1

1. Audit of the repository and the macOS phase → `docs/EXISTING_PROJECT_AUDIT.md`.
2. Architecture and decision log → `docs/IOS_ARCHITECTURE.md`.
3. Audio routing analysis with device results → `docs/AUDIO_ROUTING_FEASIBILITY.md`.
4. Roadmap for Windows 2–6 → `docs/IOS_DEVELOPMENT_ROADMAP.md`.
5. `packages/HearingSenseKit` — module `HearingSenseAudio` (capture, levels, session policies, route
   snapshots/assessment, session events, diagnostic log, throughput) + 26 tests.
6. `apps/ios/HearingSense.xcodeproj` — SwiftUI app: branding, Start/Stop, permission handling,
   status card with “MIC ON”, real level meter + 10 s history, route summary, policy picker,
   route diagnostics (share report), event log, interruption/route-change/media-reset handling,
   background-coverage measurement, `UIBackgroundModes = audio`, placeholder app icon.
7. Apple SoundAnalysis label list enumerated via the real API on macOS →
   `docs/research/sound_analysis_labels_v1_macos27.txt` (303 labels).
8. Physical-device tests on iPhone 18 Pro + AirPods Pro + Spotify (§7), screenshots in
   `docs/device-tests/2026-10-09/`.
9. `.gitignore` extended (Xcode/SwiftPM user state); `README.md` gained a repository overview.

## 4b. Completed in Window 2

1. `HearingSenseDomain` (Foundation only): `SoundLabel`, `ClassifierScore`, `AudioTimeRange`,
   `RawSoundPrediction`, `ClassificationFrame`, `SoundCategory` (11), `SoundEventKind`,
   `AcousticEventCandidate`, `ConfirmedAcousticEvent`, `AcousticEventUpdate`, `EnvironmentStatus`.
2. `SoundEventDetection`: `SoundRecognitionEngine` (real-time `SNAudioStreamAnalyzer` consumer of
   `MicrophoneCapture`), `SoundTaxonomy.appleV1` (303 labels → 50 kinds → 11 categories),
   `DetectionPolicy.standard` + `SoundEventDetector` (thresholds, k-of-n, instant confirm,
   hysteresis, timeouts, foghorn-vs-music suppression), `SoundClassifierCatalog`, diagnostics.
3. `hs-sound-eval` (macOS): forward-only evaluation of the production engine on local files;
   results in `results/sound_eval_window2/`.
4. App: `RecognitionController`, recognition card (status, current sound, category, score, top-3 raw
   labels, input level, result delay, candidates), recent events, event history, recognition
   diagnostics (pipeline timings, drops, detector counters, CPU/memory/thermal, window picker,
   stall experiment, share report), classifier-label screen (per-device inventory + share).
5. `AudioSessionController`: skips redundant session calls, logs step timings; opt-in "keep session
   active when stopped" experiment (default off).
6. Docs: `WINDOW2_SOUND_ANALYSIS_REPORT.md`, `research/IOS_SOUND_CLASSIFICATIONS.md`,
   `research/SOUND_CATEGORY_MAPPING.md`, `research/sound_analysis_labels_v1_macos27_mapped.tsv`,
   `testing/WINDOW2_DEVICE_TESTS.md`, Simulator screenshots in `device-tests/window2-simulator/`;
   architecture, roadmap, routing feasibility updated.
7. Git initialized; `.gitignore` excludes all dataset content and per-clip evaluation dumps.

## 4c. Completed in Window 3

Full report: `docs/WINDOW3_SPEECH_INTELLIGENCE_REPORT.md`; architecture:
`docs/research/SPEECH_INTELLIGENCE_ARCHITECTURE.md`; numbers and methods:
`docs/testing/WINDOW3_TEST_RESULTS.md`.

1. `HearingSenseDomain`: `SpeechSemanticResult` and its parts (speech event id, state, output level,
   category, transcript + recognition quality, summary + reliability, details, acoustic context /
   speech relevance, latency, model availability).
2. `HearingSenseAudio`: `AudioStreamClock` (moved from SoundEventDetection; shared time base).
3. `SpeechPipeline`: `PreRollAudioBuffer` (5 s ring), `SpeechAudioTap`, `AppleSpeechTranscriber`
   (`SpeechAnalyzer` + `SpeechTranscriber`, one analyzer per utterance), `TranscriptAssembler`.
4. `SemanticSummary`: `FoundationModelInterpreter` (`SystemLanguageModel.default`, guided
   generation), `SpeechSemanticAnalyzer`, `SummaryValidator`, `UtteranceAnalysis`, `RuleBasedInterpreter`.
5. `SpeechIntelligence`: `SpeechIntelligenceEngine` (serial command queue), `SpeechActivityTracker`
   (speech candidates, music context), `SpeechRelevanceGate` (speech / speech over music / possibly
   music), configuration, diagnostics.
6. `hs-speech-eval` (macOS): forward-only evaluation; summaries in `results/speech_eval_window3/`.
7. App: `Speech/SpeechIntelligenceController`, `Views/SpeechIntelligenceViews` (card + diagnostics);
   `ListeningController` attaches the speech tap and session calls; `RecognitionController` forwards
   classifier windows and events; `NSSpeechRecognitionUsageDescription` added.
8. Tests: 103 new package tests (pre-roll buffer, assembler, validator, analyzer, tracker, relevance
   gate, engine with scripted recognizer/model, real recognizer on synthetic speech).
9. Tools/data: `tools/make_speech_test_signals.sh` + `tools/speech_test_sentences.tsv` (20 synthetic
   sentences in `data/test_signals/window3/`, not committed).

## 4d. Completed in Window 4

Full report: `docs/WINDOW4_ATTENTION_PRIORITY_REPORT.md`; architecture:
`docs/research/ATTENTION_ENGINE_ARCHITECTURE.md`; numbers and methods:
`docs/testing/WINDOW4_TEST_RESULTS.md`.

1. Baseline: device results of the research window committed on its branch (`be7e8de`); Window 4
   branched from there; `UIBackgroundModes` = `audio` + `processing` adopted in the app's Info.plist.
2. `HearingSenseDomain/Attention.swift`: `AttentionEventID`, `AttentionPriority` (ambient, low,
   normal, high, urgent), `AttentionCategory` (15), `AttentionReason` (reason codes),
   `AttentionLifecycle`, `AttentionSourceRecord`, `AttentionPrivateContent`, `AttentionEvent`,
   `AttentionPresentationIntent` (the brief's "PresentationIntent"), `PresentationAction`,
   `PresentationInterruption`.
3. `Attention` (Domain only): `AttentionEngine` (value type; `process(_:)`, `nextDeadline`,
   `snapshot`), `AttentionInput`, `AttentionDecision`, `AttentionAction`, `AttentionMode`,
   `AttentionPreferences`, `AttentionConfiguration.standard` (policy table for all 50 sound kinds,
   mode tunings, speech rules, fusion pairs, bounds), `SpeechAssessment`, `SemanticSignature`.
4. `AttentionReplay`: `SyntheticSoundEvent`, `SyntheticSpeech`, `ScenarioBuilder`,
   `ScenarioLibrary` (18 scenes, `soak`, single-event scenes), `AttentionReplayer` (baseline,
   labels, metrics), playback into a running engine. `hs-attention-eval` (macOS).
5. App: `Attention/AttentionController` (owned by `ListeningController`), `Views/AttentionViews`
   (card with mode switch, settings, decisions screen with synthetic injection);
   `RecognitionController` and `SpeechIntelligenceController` forward their outputs;
   `DebugDiagnosticsExporter` adds attention counters; two new package products linked in
   `project.pbxproj`.
6. Tests: `AttentionTests` (65 test functions). Results: `results/attention_eval_window4/`.
   Screenshots: `docs/device-tests/window4-simulator/`.

## 4e. Completed in Window 5

Full report: `docs/WINDOW5_DYNAMIC_ISLAND_REPORT.md`; numbers, methods and the device protocol:
`docs/testing/WINDOW5_TEST_RESULTS.md`. The student's two briefs (two-channel presentation; never
wake a locked screen) are summarized in §1 of the report.

1. `IslandPresentation` (Domain only): `SoundSymbolCatalog` (303 labels → SF Symbols; table in
   `docs/research/sound_symbol_mapping_v1.tsv`), `AmbientIconStream` + `AmbientIconPolicy.standard`,
   `IslandContent` (the activity's content state), `IslandSettings`, `IslandPipeline` +
   `IslandPolicy.standard`, `AlertGate`, `DeviceLockEstimate`.
2. `IslandViews`: `HearingSenseActivityAttributes`, the compact / minimal / expanded / Lock Screen
   view pieces.
3. Xcode: new app-extension target `HearingSenseWidgets` (`apps/ios/HearingSenseWidgets/`,
   `Config/HearingSenseWidgets-Info.plist`, bundle id `org.hearingsense.HearingSense.Widgets`),
   embedded in the app; `NSSupportsLiveActivities` as a build setting; package products
   IslandPresentation and IslandViews linked to both targets (ids `4A5E…0040`–`0066`).
4. App: `Presentation/LiveActivityController` (owned by `ListeningController`), `Views/
   LiveActivityViews` (card, settings, preview/debug with demo scenes), `Resources/hs-silence.wav`;
   `ListeningController` forwards sound events, intents, session start / pause / end;
   `AttentionController.onInjectedSound`; diagnostics export and report extended.
5. `AttentionReplay/IslandReplayer` and `hs-attention-eval island | island-trace | island-symbols`.
   Results: `results/island_eval_window5/`. Screenshots: `docs/device-tests/window5-simulator/`.
6. Tests: `IslandPresentationTests` (47 at the commit; 49 after the device session).
7. Device session (2026-10-10, after the commit): secondary-only changes are not sent as updates of
   their own; the lock estimate honours iOS's early lock notice; demo scenes can be timed from the
   moment the app leaves the screen; per-update log in the export; injection order fixed.
8. After D5–D6 (real microphone): icon channel rewritten to "newest sound first" with an idle hold;
   only high-priority episodes and speech summaries are protected; resolved episodes do not return;
   taxonomy kind `door_movement`; `screaming` confirmation rule; `hs-attention-eval
   island-device-trace`.
9. Student's decisions before the retest, and the retest R1: speech without a summary is icon-only
   in the island (`IslandPolicy.speechNeedsSummary`); same-kind de-duplication, switch cooldown and
   "timely or not at all" in the icon channel; `--hs-autostop-after`. After R1: `door_slam` moved to
   `door_movement`, strong sounds ignore the same-kind cooldown, 20 s protection for high-priority
   episodes, 3.5 s minimum display. 58 tests in `IslandPresentationTests`, 314 in the package.

## 4f. Completed in Window 6

Full report: `docs/WINDOW6_SEMANTIC_INTELLIGENCE_REPORT.md`; numbers and methods:
`docs/testing/WINDOW6_EVALUATION_RESULTS.md`.

1. Icons: `IslandPresentation/CustomSoundGlyph` (9 names with the prefix `hs.`),
   `IslandViews/SoundSymbolImage` (draws an SF Symbol or a glyph), revised `SoundSymbolCatalog`
   (table `docs/research/sound_symbol_mapping_v2.tsv`), label-specific VoiceOver names,
   `Views/SoundIconGalleryView` (Debug), `hs-attention-eval island-icon-sheets <dir>`.
2. `SemanticAttention`: `AttentionGoal`, `SemanticAttentionEngine` (actor; gate, cache, first
   pass, judgement, verifier, novelty, bounded queue, pause), `FoundationModelRelevanceReasoner`,
   `EvidenceVerifier`, `KeywordGoalScorer` and `SentenceEmbeddingScorer` (baselines).
3. `Attention`: new input `.semantic(SemanticAttentionSignal)`; a goal match is an episode of
   its own ("Matches Your Goal", kind `goal_match`); reasons `goal_match`, `repeated_statement`.
4. `ConversationUnderstanding`: `RollingConversationBuffer`, `ConversationRecapEngine` +
   `RecapValidator`, `FoundationModelRecapSummarizer`, `ConversationSessionMachine`,
   `ConversationRecord`, `ConversationHistoryStoring`.
5. `HearingSenseDomain`: `SpeechSemanticResult.recentUtterances` / `volatileText` (each
   finalized utterance on its own; cleared with the transcript). `SemanticSummary`:
   `SummaryPolicy.writesHeadlines` (off in the app: no automatic 2–3 word headline).
6. App: `Conversation/` (`ConversationIntelligenceController`, `ConversationHistoryStore` with
   SwiftData, `ConversationIntents`), `Views/ConversationViews`; wiring in `ListeningController`;
   two package products linked (ids `4A5E…0070`–`0073`).
7. `SemanticEvaluation` + `hs-semantic-eval`: development and held-out utterances, synthetic
   conversations with facts, metrics. Results: `results/semantic_eval_window6/`,
   `results/conversation_eval_window6/`.
8. Tests: `SemanticAttentionTests` (41), `ConversationUnderstandingTests` (34), 3 in
   `IslandPresentationTests/Window6PresentationTests`, 3 new in `SoundSymbolCatalogTests`.

## 4g. Completed in Window 6.1

Report: `docs/research/SEMANTIC_OPTIMIZATION_REPORT.md`; numbers:
`docs/testing/SEMANTIC_OPTIMIZATION_BENCHMARK.md`; raw output: `results/semantic_optimization/`.

1. `SemanticAttention`: `FoundationModelRelevanceReasoner` styles (`window6`, `compact`,
   `reasoned`, `lean`), `.optimized` (lean, session kept for six utterances), second look
   (`confirm`), group requests (`judgeTogether`, off), `ReasonerTiming`;
   `ModelInferenceScheduler` (priority classes, bounded waiting, aging, timeouts, cancellation,
   statistics); `SemanticAttentionEngine` reworked (scheduler, lane for warning-like sentences,
   second look, late mark, reported drops, early evaluation of partial transcripts,
   `Configuration.window6` for comparisons); `StablePartialDetector`; `EvidenceVerifier`
   (extractive headline, fixed-word reason, second look); `UtteranceGate.isLikelyUrgent`
   (order cue from three kinds of signal); repetition markers in the novelty check.
2. `SemanticEvaluation`: `semantic_dev2.txt` (171), `semantic_sealed.txt` (220, spent),
   `SemanticConfusion` (TP/FP/FN/TN and the category groups), `SemanticStreamBenchmark`
   (throughput, early evaluation, recap contention). `hs-semantic-eval`: `run --config
   window6|optimized --set dev2|sealed`, `latency`, `throughput`, `speculation`, `contention`,
   `together`, `cues`. `tools/run_semantic_ablation.sh`, `tools/semantic_confusion_table.py`.
3. App: `ConversationIntelligenceController` uses `.optimized`, runs the recap through the
   engine's scheduler (no more pausing of goal matching), offers stable partial transcripts,
   reports the new counters. Nothing else in the app changed.
4. Tests: 31 new (`ModelInferenceSchedulerTests`, `SemanticOptimizationTests`); 426 in the package.

## 4h. Completed in Window 6.2

Report: `docs/research/PRECISION_AND_BACKPRESSURE_REPORT.md`; numbers:
`docs/testing/WINDOW6_2_BENCHMARK.md`; raw output and the working notes in order:
`results/window6_2/` (`RESEARCH_LOG.md`).

1. `SemanticAttention`: `FoundationModelRelevanceReasoner` styles `window6`, `lean` (Window 6.1,
   `.window6_1`) and `staged` (`.current`, used by the app): a session per sentence, prepared by
   the engine when its line is empty; the answer's form in the instructions, not in the request;
   `Reuse` (while sentences wait the session continues for up to four, goals said again) and
   `asksKindFirstWhenBusy`; second look for warnings too, told which accepted statements a
   sentence may repeat (`SemanticRepetition.candidates`, answer `saidBefore`). The styles
   `compact` and `reasoned` and the group request (`judgeTogether`) were removed.
   `SemanticAttentionEngine`: one scheduler turn per utterance (first answer and second look),
   `ServingOrder.newestWhenBehind` (newest first while behind and speech keeps arriving, oldest
   first in a pause), `expired` after `maximumWait` (30 s) as a stage of its own, idle
   preparation, the second judgement of sentences a continued session called silent
   (`rechecksContinuedAnswers`), presets `Configuration.window6` and `.window6_1` for
   comparisons, new counters. `EvidenceVerifier`: urgent only with the second look's agreement.
2. `SemanticEvaluation`: `semantic_dev3.txt` (223), `semantic_sealed2.txt` (265, another author,
   spent; one item excluded by rule), profiles defined in the data files (`@profile`),
   `SemanticProbe` (raw model answers, checks, costs, lead times, stream timeline),
   `SemanticStreamBenchmark` with arrival patterns. `hs-semantic-eval`: `run --config
   window6|window6_1|window6_2 [--reuse N --steps|--no-steps --seed S]`, `throughput --pattern
   3.0|1.5|1.0|bursty|dense [--mix sparse]`, `probe`, `probe-check`, `probe-cost`, `probe-lead`,
   `probe-stream`, `probe-text`. `tools/run_window6_2_streams.sh`,
   `tools/run_window6_2_sealed.sh` (refuses a second run), `tools/semantic_queue_sim.py`,
   `tools/semantic_model_process_summary.py`.
3. App: `ConversationIntelligenceController` uses `.current`, reports the new counters and
   exposes `uncheckedSentences`; `ConversationViews` shows one line under the matches when
   sentences were not checked. Nothing else in the app changed.
4. Tests: 439 in the package (17 new: `SemanticBackpressureTests`, `SemanticPromptTests`, six in
   `SemanticOptimizationTests`; four of Window 6.1 removed with the group request).

## 4i. Completed in Window 6.3

Report: `docs/research/WINDOW6_3_PERSONAL_RELEVANCE.md`; numbers:
`docs/testing/WINDOW6_3_BENCHMARK.md`; raw output and the working notes in order:
`results/window6_3/` (`RESEARCH_LOG.md`, `sealed/README.md`).

1. `SemanticAttention`: new file `ListenerIdentity.swift` — `ListenerIdentity` (names and group labels
   read from the listener's own text: names and the labels of the about line by rule, labels inside
   goals copied by the model and checked), `AudienceCue` and `AudienceAnalyzer` (whom a sentence names:
   `listenerNamed`, `listenerGroup`, `otherGroup`, `otherPerson`, `unknownPerson`; a form-based
   fallback where the system's name tagger has no data), `SemanticText.isCutOff`,
   `SemanticText.leansOnContext`. `SemanticRelevanceReasoning` gained `describeListener(about:goals:)`
   and `concern(of:)` (`NamedConcern`: theirs / everyones); `ListenerProfile` (identity and the goal
   about being spoken to, found by rule). `FoundationModelRelevanceReasoner`: `.current` now reads a
   leaning sentence together with the one before it in the second look; `.window6_2` keeps the old
   behaviour. `SemanticAttentionEngine`: `setGoals(_:about:)`, `listener`, a step between the first
   answer and the second look (`placed`), switches `usesAudienceCues`, `holdsBackOtherGroups` (off),
   `alertsWhenCalledByName`, `holdsBackCutOffSentences`, `takesSpeakersAtTheirWord`,
   `givesContextOnlyToLeaningSentences`; presets `Configuration.window6_2` and `.window6_3Frozen`; new
   counters. `EvidenceVerifier`: corrections `another_group`, `said_to_someone_else`,
   `audience_unknown`, `called_by_name`, `cut_off`, `no_change_marker`; reasons for the list ("Said
   to someone by name", "The sentence was cut off", "Someone said your name").
   `SemanticAttentionDecision.audience` (the kind of cue only, never the words).
2. `SemanticEvaluation`: `semantic_dev4.txt` (225), `semantic_sealed3.txt` (315, another author,
   spent), `@about` lines in data files, `SemanticSpecProbe` (requests described by JSON),
   conversation context in `SemanticEvaluator` and `SemanticStreamBenchmark`, new category groups in
   `SemanticConfusion`. `hs-semantic-eval`: `run --config window6_2|window6_3|window6_3_frozen
   [--conversation 3] [--no-audience --no-name --no-cutoff --no-word --no-joined --context-always
   --hold-other-groups]`, `probe2`, `identity`, `audience`, `decide`, `prior`. Tools:
   `tools/w63_specs.py`, `w63_variants.py`, `w63_probe.sh`, `w63_score.py`, `w63_engine.sh`,
   `w63_errors.py`, `w63_tables.py`, `w63_recount.py`, `run_window6_3_streams.sh`,
   `run_window6_3_sealed.sh` (ran once).
3. App: `AttentionGoalStore` stores the about line (`about.txt` beside `goals.json`, file-protected);
   `ConversationIntelligenceController` has `aboutMe`, `setAboutMe`, `listener`, `listenerSummary` and
   hands the line to the engine; `AttentionGoalsView` has a section "About me (optional)" that shows
   what was understood. The scripted demo has an about line and two more sentences.
4. Tests: 473 in the package on the Mac, 478 on the Simulator (34 new in
   `PersonalRelevanceTests.swift`; one more in `SemanticPromptTests`; two timing tests of Window 6.2
   given wider margins).

## 5. Repository structure (current)

```
apps/ios/                      iOS app (Xcode 27 project, synchronized folders)
  HearingSense/HearingSenseApp.swift   @main entry point
  HearingSense/Listening/      ListeningController (orchestrator), ListeningState, DeviceInfo
  HearingSense/Recognition/    RecognitionController (W2: engine outputs → UI state; W3: forwards to speech)
  HearingSense/Speech/         SpeechIntelligenceController (W3: speech engine outputs → UI state, privacy; W4: forwards results)
  HearingSense/Attention/      AttentionController (W4: attention engine, preferences, deadline timer, injection)
  HearingSense/Presentation/   LiveActivityController (W5: the one Live Activity, lock estimate, settings, demo scenes)
  HearingSense/Resources/      hs-silence.wav (W5: silent alert sound)
  HearingSenseWidgets/         W5 widget extension target: HearingSenseWidgetBundle, HearingSenseLiveActivity
  HearingSense/Experiments/    research window: background probe, experimental classifier switch (Debug)
  HearingSense/Diagnostics/    DebugDiagnosticsExporter (Debug)
  HearingSense/Views/          ContentView, StatusCard, LevelMeterView, RouteDiagnosticsView, DiagnosticLogView,
                               RecognitionViews (W2), SpeechIntelligenceViews (W3), AttentionViews (W4),
                               LiveActivityViews (W5)
  HearingSense/Assets.xcassets AppIcon (placeholder), AccentColor
  Config/HearingSense-Info.plist  UIBackgroundModes=audio+processing since W4 (other Info keys are build settings)
  Config/HearingSenseWidgets-Info.plist  NSExtension dictionary of the widget extension (W5)
  Config/Experiments/          Info.plist variants for device experiments (audio-only = A1, processing = A2)
packages/HearingSenseKit/      Swift package (iOS 26, macOS 26): Sources/{HearingSenseAudio, HearingSenseDomain,
                               SoundEventDetection, SoundEvaluationTool, SpeechPipeline, SemanticSummary,
                               SpeechIntelligence, SpeechEvaluationTool, ModelBenchmarkTool, Attention,
                               AttentionReplay, AttentionReplayTool, IslandPresentation, IslandViews},
                               Tests/{HearingSenseAudioTests, SoundEventDetectionTests, SpeechPipelineTests,
                               SemanticSummaryTests, SpeechIntelligenceTests, AttentionTests,
                               IslandPresentationTests}
docs/                          this handoff, architecture, audit, feasibility, roadmap, WINDOW2 and WINDOW3 reports,
                               device-tests/, research/, testing/
results/sound_eval_window2/    W2 offline evaluation summaries (JSON)
results/speech_eval_window3/   W3 evaluation summaries (JSON; no music transcripts)
results/background_benchmark/  research window: model benchmark summaries
results/device_background/     research window: metadata-only diagnostics of the first iPhone runs (A1, A2, MN10)
results/attention_eval_window4/ W4 replay output (synthetic scenes; JSON summaries and tables)
results/island_eval_window5/   W5 replay output: Live Activity commands over the W4 scenes (synthetic)
tools/                         + make_speech_test_signals.sh, speech_test_sentences.tsv (W3)
src/ ml/ tools/ models/ results/ data/ app/   legacy & research assets (unchanged)
```

## 6. Main technical decisions

Full list: `docs/IOS_ARCHITECTURE.md` §9. Most important:

- Session policy (verified on device): `playAndRecord`, mode `default`, options `mixWithOthers`,
  `allowBluetoothA2DP`, `defaultToSpeaker`; preferred input = built-in mic; no HFP, no ducking.
- Deployment target iOS 26.0, iPhone only, Swift 6 (app default MainActor, package nonisolated).
- Extension seam: `AudioStreamConsumer` on `MicrophoneCapture` (audio thread, return fast).
- Attention decisions deterministic; Foundation Models only for summaries, with fallback; never
  `PrivateCloudComputeLanguageModel`.
- Xcode file-system-synchronized groups: add Swift files to folders; no `project.pbxproj` edits needed
  (new *package products* still need entries — Window 2 added HearingSenseDomain and SoundEventDetection).
- (W2) Sound pipeline: tap copies channel 0 → actor on a serial `DispatchSerialQueue` owns the
  analyzer (FIFO via `queue.async` + `assumeIsolated`); never blocks the tap; bounded backlog with
  counted drops. Classifier window **1.5 s, overlap 0.5** (result every 0.75 s).
- (W2) Three levels: raw label → kind/category → confirmed event. Consumers act only on
  `ConfirmedAcousticEvent`. All thresholds live in `DetectionPolicy.standard` (provisional).
- (W2) Detector is deterministic (frame timestamps only); test with scripted frames
  (`Tests/SoundEventDetectionTests/FrameScript.swift`).
- (W3) The speech pipeline is a second consumer of the same microphone tap (no second capture
  session) and uses the same `AudioStreamClock`, so classifier windows address buffered audio.
- (W3) Transcription starts on speech *candidates* (one window ≥ 0.30) from a 5 s pre-roll buffer;
  measured on 30 short human utterances: first word kept 29/30 with the buffer, 1/30 without.
- (W3) One `SpeechAnalyzer` per utterance with a contiguous timeline from 0. Do **not** reuse an
  analyzer across a gap or after a mid-stream `finalize` (corrupt results, measured). Use
  `finalizeAndFinishThroughEndOfInput()`; `finalize(through: time)` hung in a probe.
- (W3) **The iOS Simulator has no `SpeechTranscriber`** (`isAvailable == false`); Foundation Models
  works there. Verify transcription on the Mac (`swift test`, `hs-speech-eval`) or on the iPhone.
- (W3) A model headline is shown only after deterministic validation; otherwise the result stays at
  transcript level. Never `PrivateCloudComputeLanguageModel`, never `SFSpeechRecognizer`.
- (W3) Speech vs. music is an explicit estimate (`SpeechRelevance`); probable lyrics are not sent
  to the language model.
- (W3) Engine state changes only on one serial command queue; background results carry the
  session generation. Tests drive it with `drivesItself: false`, `pump()` and `drain()`.
- (W3) All speech thresholds live in `SpeechIntelligenceConfiguration` (`activation`, `relevance`,
  `summary`, endpoint and conversation timings); provisional until device data exists.
- (W4) Background modes `audio` + `processing` (device run A2, once); Apple's classifier is the
  only default. The hybrid / third-party path stays Debug-only research code.
- (W4) The attention engine is a value type; inputs carry their time; the host sends one `.tick`
  at `nextDeadline`. Never give it a clock or a timer of its own (determinism, replay).
- (W4) Priority = policy table per sound kind and mode (`AttentionConfiguration.standard`) plus
  preferences; classifier scores are not read; evidence quality only gates. Change policy there,
  not in the engine.
- (W4) Titles and subtitles are generic and lock-screen safe; speech-derived text is
  `privateContent` / `privateDetail`, never encoded, logged or exported. Keep it that way.
- (W4) Contract type is `AttentionPresentationIntent` (Foundation owns the name `PresentationIntent`).
- (W4) New package products need `project.pbxproj` entries (Attention, AttentionReplay were added
  by hand with ids `4A5E…003A`–`003D`).
- (W5) One Live Activity with two channels: ordinary sounds as an icon (`AmbientIconStream`, fed by
  every confirmed event), attention episodes with text (only from `AttentionController.onIntent`).
  Never create an alert from the icon channel and never show text for it.
- (W5) `IslandPipeline` is a value type without a clock, like the attention engine; change rules in
  `IslandPolicy.standard` / `AmbientIconPolicy.standard`, not in the controller.
- (W5) **Never wake a locked screen**: plain `Activity.update`, no notifications, Lock Screen view
  icon-only at every priority. An alert configuration is attached only through `AlertGate`;
  "Expand for important events" is off by default. Do not turn it on by default without device
  evidence (D4 in the test protocol).
- (W5) The lock state is an estimate (passcode + protected data + "signal observed on this
  installation"). The Simulator reports a passcode and available data while locked.
- (W5) Speech summaries go into the activity content only with `showsSpeechSummaries`; never into
  the Lock Screen view, alert texts, logs or exports (`IslandContent.redactedSummary`).
- (W5) The widget extension only places views from `IslandViews`; keep logic out of it. A new
  symbol name must pass `SoundSymbolCatalogTests.everySymbolNameExistsOnThisSystem`.
- (W5) `Activity` is not Sendable under Swift 6: hold it on the main actor and bind it to a
  `nonisolated(unsafe)` local before awaiting its methods (see `LiveActivityController.perform`).
- (W5, after the device session) Icon channel: the newest confirmed sound wins for 5 s, then the
  highest-ranked ongoing one. Do not go back to rank-only selection: on the device it hid every
  sound behind continuous speech. Episodes below `IslandPolicy.protectedPriority` (high) without a
  summary give way to newer ordinary sounds.
- (W5, after the device session) `SoundTaxonomy.appleV1` has 51 kinds: `door_movement` (labels
  `door`, `door_sliding`, `door_slam`; icon only, two-window confirmation) is separate from `door`
  (knock, bell, tap). Earlier documents say 50.
- (W5) A timed microphone test must end by itself: `--hs-autostop-after <s>` in the app and an
  exit trap in the Mac script that relaunches the app without `--hs-autostart`. Never leave the
  microphone on while waiting for the student (D6 ran 35 minutes instead of 10 that way).
- (W5) Force transcription off for a run with launch arguments after `--`:
  `devicectl … launch … org.hearingsense.HearingSense -- --hs-autostart -speech.transcriptionEnabled NO`
  (argument-domain default; the stored switch is not changed) and check "Transcription switch: off"
  in the export before any sound. The switch was found on before R1 and the UI toggle through
  iphone-use did not change it.
- (W5) Evaluate icon-rule changes on recorded device events before a device run:
  `hs-attention-eval island-device-trace results/device_window5/<export>.txt`.
- (W5) `xcrun simctl io screenshot` often omits the Dynamic Island; capture through the Simulator
  itself. The app's own activity is not shown in the island while the app is on screen.

## 7. Verification results (Window 1)

(Window 2 results follow in §7b.)

### Build and tests

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | macOS 27.2, Swift 6.4 | **21/21 passed** (iOS-only tests excluded on macOS) |
| `xcodebuild test -scheme HearingSenseKit` | iOS 27.0 Simulator, iPhone 17 | **26/26 passed** |
| App build, Debug | iOS 27.0 Simulator | **Succeeded**, no Swift warnings |
| App build, Release, unsigned | generic iOS device | **Succeeded** |
| App launch | iOS 27.0 Simulator (simctl, screenshot) | Launches; UI renders |
| Install + run, Debug, Personal Team signing | **iPhone 18 Pro, iOS 27.2** | **Succeeded** |
| ML unit tests | `.venv` Python 3.12 | 12/12 passed (forward-only) |
| Legacy `app/` package | `swift build` | Fails (missing sources) — pre-existing |

### Physical-device tests — 2026-10-09, iPhone 18 Pro (iOS 27.2), AirPods Pro, Spotify

| # | Scenario | Result |
|---|---|---|
| T1 | Built-in mic, no AirPods: permission, start, level follows speech/claps, stop | **Pass** (meter behaviour observed by the student) |
| T2 | AirPods Pro + ANC, start listening | **Pass — target route**: in = iPhone Microphone (Bottom data source), out = AirPods Pro **Bluetooth A2DP** (2 ch); capture 48 kHz mono; IO buffer 10 ms; input latency 11.9 ms; output latency 163 ms |
| T2 | AirPods capabilities | iOS reports high-quality Bluetooth recording **supported** and far-field capture **supported** (not used) |
| T3a | Listening, then Spotify plays | **Pass**: both run; music quality normal (student), route unchanged (screenshot) |
| T3b | Spotify playing, Stop/Start listening | **Pass with glitch**: Spotify never paused; **~0.5 s music stall at each start and stop** (student); `routeConfigurationChange` logged each time |
| T4 | Screen locked while listening + Spotify | **Pass for ≤ 40 s**: 7.3 s → 100 % coverage (73 buffers); 39.7 s → 100 % coverage (397 buffers); no interruptions; music continued |

Measured: tap buffers arrive as 4 800 frames (100 ms) at 48 kHz although 4 096 were requested.

### Not verified

- Simulator microphone capture (skipped; device test done instead).
- Background/lock longer than 40 s (the student chose 40 s as sufficient for Window 1).
- Apple Music; phone-call / Siri interruptions; AirPods disconnect or ANC/Transparency switching
  mid-session; the three experimental policies; battery and thermal impact.
- Whether AirPods produced an audible click when listening started (asked in T2, not answered).
- SoundAnalysis label list on iOS (only macOS enumerated).

## 7b. Verification results (Window 2)

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | macOS 27.2, Swift 6.4 | **58/58 passed** (37 new SoundEventDetection + 21 Window 1) |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27.0 Simulator, **iPhone 18 Pro** | **63/63 passed** (37 + 26) |
| App build, Debug | iOS 27.0 Simulator, iPhone 18 Pro | **Succeeded**, 0 Swift warnings |
| Live listening (Mac mic) | iPhone 18 Pro Simulator | Works: 37 s, 370 buffers, 0 dropped, 48 windows; result delay ≈ 11 ms after window end; process CPU 7.7 % of one core, 31 MB (Mac hardware) |
| Label inventory | macOS 27.2; iOS 27.0 Simulator | **303 labels, exact match with the taxonomy** |
| Label inventory | physical iPhone | **Not run** |
| Offline evaluation, 1.5 s windows | Recorded files (Mac) | Speech recall 99.8 % [98.9, 100] (510 utterances); music recall 100 % [98.7, 100] (300 GTZAN); music falsely confirmed on speech 0.2 %; 0/510 alert events on speech; alert events on held-out music clips 1.0 % [0.3, 2.9] after the foghorn rule. **No accuracy for alerts/knocks/animals/weather** (no annotated data) |
| Any physical-iPhone test (AirPods/Spotify, lock screen, stall, interruptions) | iPhone 18 Pro | **Not run in Window 2** |

## 7c. Verification results (Window 3)

Details and methods: `docs/testing/WINDOW3_TEST_RESULTS.md`. All measurements are from the Mac.

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | macOS 27.2, Swift 6.4 | **160 passed, 1 skipped** (opt-in real-model test) of 161: 103 new + 58 from Windows 1–2 |
| `HS_RUN_MODEL_TESTS=1 swift test --filter realModel` | Mac, real language model | passed |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27.0 Simulator, iPhone 18 Pro | **162 passed, 4 skipped** of 166 (3 recognizer tests: no `SpeechTranscriber` in the Simulator; 1 opt-in) |
| App build, Debug / Release unsigned | Simulator / generic iOS device | **Succeeded**, 0 Swift warnings |
| Speech recognition, LibriSpeech dev-clean, 200 utterances | Recorded files (Mac) | WER 1.60 % clean; 2.66 % cafeteria +10 dB; 5.26 % traffic 0 dB; 15.4 % cafeteria 0 dB; 3.06 % / 17.4 % music +10 / 0 dB |
| Pre-roll buffer, 30 shortest human utterances, real time | Recorded files (Mac) | First word kept 29/30 with 5 s pre-roll vs 1/30 with 0.25 s; WER 3.8 % vs 43.8 % |
| End to end, 20 synthetic sentences, real time | Synthetic speech (Mac) | 20/20 transcript and validated summary; final transcript 0.93 s and summary 3.14 s (median) after the end of speech |
| Summaries, 38 sentences as text | Real language model (Mac) | 37 shown, 1 guardrail fallback; 14/14 negated sentences keep a negation (rule check); manual review: 30 faithful, 4 incomplete, 3 ambiguous, 0 reversed |
| Speech relevance gate, holdout clips | Recorded files (Mac) | Songs with anything sent to the language model 170/299 → 18/299; spoken words kept 99 % at +10 and +5 dB over music, 84 % at 0 dB; clean speech unchanged |
| Complete pipeline in real time with music | Recorded files (Mac) | 1 of 20 songs treated as conversation; 12/15 summaries for speech over music at +10 dB, 10/15 at 0 dB |
| Live microphone, transcription off | Simulator | "Nearby Speech" (level 1) shown; screenshots in `docs/device-tests/window3-simulator/` |
| Live transcription and summary, screen on | **Physical iPhone** | Works: final transcript 0.81 s, language model 0.68 s, summary 2.00 s after the speech (means; n = 22 / 15 / 14); first words of "Yes." / "Watch out!" kept; AirPods Pro + Spotify fine |
| Locked screen / app in background | **Physical iPhone** | **0 of 3 sentences detected** (3 of 3 with the screen on): the built-in sound classifier fails in the background |
| Music from a loudspeaker | **Physical iPhone** | 3 clips: sung pop → nothing or one text-less "Nearby Speech"; rap → "Speech Unclear" without a summary; relevance labels differ from the file-based evaluation |
| Noisy place, 15 min battery/thermal, text removed after Stop | Physical iPhone | **Not run** |

## 7d. Verification results (Window 4)

Details and methods: `docs/testing/WINDOW4_TEST_RESULTS.md`. All evaluation input is scripted and
synthetic; none of it is real-world accuracy.

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | macOS 27.2, Swift 6.4 | **255 passed, 1 skipped** of 256 (65 new + 191 earlier) |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27.0 Simulator, iPhone 18 Pro | **257 passed, 4 skipped** of 261 |
| App build, Debug / Release unsigned | Simulator / generic iOS device | **Succeeded**, 0 Swift warnings; built Info.plist has `audio`, `processing` |
| 18 scripted scenes, three modes | Mac, `hs-attention-eval scenarios` | Important retained 30/30 in every mode; duplicates suppressed 6/6; alerts 37 / 52 / 63 (Quiet / Balanced / Sensitive) vs 121 for "show every confirmed event"; unnecessary alerts 1 / 1 / 9 vs 53 |
| Generated one-hour scene (seed 20261010) | Mac, `hs-attention-eval soak` | Important 18/18, duplicates 8/8; unnecessary alerts per hour 0 / 0 / 22 vs 93.8; at most 7 episodes; none left |
| Decision time per input | Mac, release build | median 9 µs, p95 17–32 µs |
| Determinism | Mac | 3 880 decisions, two replays identical |
| Attention card, settings, decisions screen, injection of synthetic events | Simulator, microphone off | Works (fusion "Door or knock · Nearby speech afterwards", alarm escalation, lyrics suppressed); screenshots in `docs/device-tests/window4-simulator/` |
| Live microphone → attention engine | Simulator / iPhone | **Not run** |
| Anything on the physical iPhone, including the new default background mode | iPhone 18 Pro | **Not run in Window 4** |

## 7e. Verification results (Window 5)

Details and methods: `docs/testing/WINDOW5_TEST_RESULTS.md`. All input is scripted and synthetic.

| Check | Environment | Result |
|---|---|---|
| `swift test` (package) | macOS 27.2, Swift 6.4 | **302 passed, 1 skipped** of 303 (47 new + 256 earlier) |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27.0 Simulator, iPhone 18 Pro | **304 passed, 4 skipped** of 308 |
| App + widget extension build, Debug / Release unsigned | Simulator / generic iOS device | **Succeeded**, 0 Swift warnings; extension embedded |
| Engine + pipeline over 18 scenes × 3 modes and a generated hour | Mac, `hs-attention-eval island` | 0 rule violations in 57 runs; 105 / 123 / 133 updates per hour (scenes), 163 / 226 / 291 (generated hour) |
| Compact island: ordinary sound = icon, attention = coloured icon + mark | Simulator, demo scenes, microphone off | Works; screenshots in `docs/device-tests/window5-simulator/` |
| Expanded island with text (knock; speech summary) | Simulator, `--hs-assume-unlocked` | Works |
| Lock Screen entry icon-only | Simulator | Works |
| Lock estimate | Simulator | First version said "unlocked" on a locked Simulator and sent an expansion request; final version: `unknown`, silent update |
| D1–D4 with synthetic demo scenes, microphone off (compact / expanded / Lock Screen rendering, Spotify split island, silent updates while locked, automatic expansion on) | **Physical iPhone 18 Pro**, iOS 27.2 | Rendering as designed; locked screen not woken, no sound, no vibration, also when an expansion request reached iOS 2 s and 20 s after locking (student-observed, once each, silent sound); data protection lags the lock by 4–12 s; evidence in `docs/device-tests/2026-10-10-window5/`, `results/device_window5/` |
| D5–D6 with the real microphone, classification only, clips from the Mac speakers | **Physical iPhone 18 Pro** | Island follows real sounds; Spotify on the phone speaker splits the island and keeps playing; 34.9 min locked: 2 793 windows, 0 failures, 256 updates/h; D6's subjective checks (screen wake, sound, vibration, Lock Screen content) **not verified** |
| Retest R1: revised rules, 5 minutes, real microphone, transcription forced off and checked | **Physical iPhone 18 Pro** | Confirmation → update median 0.02 s (D6: 2.22 s); 282 updates/h; a 5-clip burst gave 2 updates; 3 dog clips one icon; "Nearby Speech" without a summary stayed an icon; `door` icon only; knock alert with expansion. Found: a false alert from `door_slam`, a strong sneeze hidden by the same-kind cooldown, a 48 s door episode, a 1.0 s icon; the siren clip was not recognized |
| Final rules (four fixes after R1) | Mac tests and replay of the recorded events (simulation) | 314 package tests pass; on the D6 / R1 recordings 247–359 icon changes per hour, 58 of 73 / 90 of 104 / 23 of 37 confirmed sounds become the icon; **not run on the device** |
| Battery (D7), speech text with real speech (D8), 8-hour limit | Physical iPhone | **Not run** (postponed by the student) |

## 7i. Verification results (Window 6.3)

Details: `docs/testing/WINDOW6_3_BENCHMARK.md`. Synthetic text; Mac and Simulator only.

| Check | Environment | Result |
|---|---|---|
| `swift test` | Mac | **473 passed** |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27 Simulator, iPhone 18 Pro Max | **TEST SUCCEEDED** (478) |
| App Debug (Simulator) / Release unsigned (generic device) | — | **Succeeded** |
| Scripted conversation in the app | iOS 27 Simulator, microphone off | About line read ("Name: Alex · Yours: study group B"); "Alex, can you bring the charger tomorrow?" listed as a match (`docs/device-tests/window6-3-simulator/`) |
| Sealed set 3 (315), Window 6.2 / **6.3 as frozen** | Mac, real language model, once each after the freeze `1e269b8` | 148/67/4/88 (68.8 %, 97.4 %) / **140/41/12/114 (77.3 %, 92.1 %)** |
| … 6.3 as shipped (rule for another group off) | recount of the two runs, not independent | 147/45/5/110 (76.6 %, 96.7 %) |
| … each sentence with the three before it | Mac | 6.2: 150/74/2/81, 22 of 315 decisions differ from each sentence alone; 6.3: 140/44/12/111, 3 differ |
| … 6.3 while sentences wait | Mac | 134/40/18/115 (recall 88.2 %); 11 of 315 differ |
| Development set 4, Window 6.2 → 6.3 as frozen (shipped, recount) | Mac | 89/38/6 (70.1 %, 93.7 %) → 90/14/5 (86.5 %, 94.7 %) (90/22/5: 80.4 %, 94.7 %) |
| Development sets 3 and 2, Window 6.3 | Mac | 91/7/3 (92.9 %, 96.8 %) and 78/4/4 (95.1 %, 95.1 %) |
| Streams, Window 6.2 against 6.3 | Mac | Sentences handed in with the three before them, as the app does. Decided per minute under overload: 6.2 19–27, 6.3 21–32 (fewer second looks, not faster requests); end to end p50 at a sentence every 3 / 1.5 / 1 s: 6.2 2.20 / 4.21 / 6.90 s, 6.3 1.33 / 3.88 / 5.91 s; tails as in Window 6.2. Single runs |
| Anything on the physical iPhone; real speech; the name tagger on a device | — | **Not run** |

## 7h. Verification results (Window 6.2)

Details: `docs/testing/WINDOW6_2_BENCHMARK.md`. Synthetic text; Mac and Simulator only.

| Check | Environment | Result |
|---|---|---|
| `swift test` | Mac | **439 passed** |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27 Simulator, iPhone 18 Pro Max | **TEST SUCCEEDED** (444) |
| App Debug (Simulator) / Release unsigned (generic device) | — | **Succeeded** |
| Scripted conversation in the app | iOS 27 Simulator, microphone off | Matches shown (`docs/device-tests/window6-2-simulator/goals.png`) |
| Sealed set 2 (264), Window 6 / 6.1 / **6.2** | Mac, real language model, once each after the freeze `80f80b6` | 71/17/44/111 (80.7 %, 61.7 %) / 114/35/1/93 (76.5 %, 99.1 %) / **114/22/1/106 (83.8 %, 99.1 %)** as TP/FP/FN/TN (precision, recall) |
| Sealed set 2, Window 6.2 while sentences wait | Mac | 113/22/2/106; 4 of 264 decisions differ from normal operation |
| Development sets 3 and 2 together, Window 6.1 → 6.2 | Mac | precision 87.4 % → 93.4 %, recall 98.3 % → 96.0 % |
| Order of the sentences | Mac | A session per sentence: 0 of 214 raw answers differ; Window 6.1's kept session: 25 of 214 flip |
| One sentence every 3 s / 1.5 s / 1 s, end to end p50 (p95) | Mac | 6.1: 1.43 (2.53) / 8.03 (11.86) / 11.99 (21.16) s; 6.2: 1.31 (2.11) / 3.00 (6.77) / 5.31 (31.25) s |
| Not evaluated at a sentence a second (of 35) | Mac | 6.1: 4 (1 relevant); 6.2: 2 (0 relevant), reported as expired |
| Window 6.1's sealed set and Window 6's held-out set (both read; not independent) | Mac | 6.2: 100/8/5/88 (92.6 %, 95.2 %) and 52/8/6/39 (86.7 %, 89.7 %) |
| Anything on the physical iPhone; real speech; real partial transcripts | — | **Not run** |

## 7g. Verification results (Window 6.1)

Details: `docs/testing/SEMANTIC_OPTIMIZATION_BENCHMARK.md`. Synthetic text; Mac and Simulator only.

| Check | Environment | Result |
|---|---|---|
| `swift test` | Mac | **426 passed** (31 new) |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27 Simulator, iPhone 18 Pro Max | **TEST SUCCEEDED** |
| App Debug (Simulator) / Release unsigned (generic device) | — | **Succeeded** |
| Window 6 held-out set reproduced before any change | Mac, real language model | TP 50, FP 5, FN 8, TN 42: identical to Window 6 |
| Sealed set (220), Window 6 pipeline | Mac, real language model, once | TP 77 FP 8 FN 28 TN 88: precision 90.6 %, recall 73.3 % |
| Sealed set (220), Window 6.1 | Mac, real language model, once | TP 103 FP 16 FN 2 TN 80: precision 86.6 %, recall 98.1 % |
| One judgement | Mac | 2.74 s → 1.2–1.4 s (75 → about 32 output tokens) |
| One sentence every 3 s, end to end | Mac | p50 / p95 / p99 3.86 / 8.89 / 9.69 s → 1.47 / 2.21 / 2.92 s |
| One sentence every 1.5 s | Mac | Window 6 dropped 11 of 37; Window 6.1 none, but p95 20.6 s |
| Recap while sentences arrive | Mac | Window 6 dropped 9 of 20; Window 6.1 none; recap 7.0 s |
| Anything on the physical iPhone; real speech; real partial transcripts | — | **Not run** |

## 7f. Verification results (Window 6)

Details: `docs/testing/WINDOW6_EVALUATION_RESULTS.md`. Synthetic text; Mac and Simulator only.

| Check | Environment | Result |
|---|---|---|
| `swift test` | Mac | **395 passed** (81 new) |
| `xcodebuild test -scheme HearingSenseKit-Package` | iOS 27 Simulator, iPhone 18 Pro Max | **TEST SUCCEEDED** |
| App Debug (Simulator) / Release unsigned (generic device) | — | **Succeeded** |
| Goal matching, held-out set (119 utterances, 3 profiles) | Mac, real language model | pipeline precision 90.9 %, recall 86.2 %, false alerts 11.6 % of irrelevant, important missed 0/7, repeats alerted 0/4; keyword 62.2 % / 39.7 %; sentence embedding 56.2 % / 93.1 % with 88.4 % false alerts |
| Goal matching, time per utterance | Mac | first pass 0.61 s; full judgement 2.73 s; to a verdict 3.57 s (median) |
| Recaps, 5 held-out conversations | Mac, real language model | facts 26/26, negations 4/4, 6.8 s median; manual read: 2 of 56 statements unsupported |
| Icons | Mac renderings, Simulator gallery | 303/303 mapped; reviewed at island sizes |
| Scripted conversation: goal matches, recap, continue, captions, history | Simulator, microphone off, real language model | Works; island states not visible in screenshots |
| App Intent / Action Button, background, locked phone | — | **Not run** |
| Anything on the physical iPhone | — | **Not run in Window 6** |

## 8. Known issues

| Issue | Impact | Suggested handling |
|---|---|---|
| **(W6.3) Precision 77 % on sealed set 3; target 95 %** | One alert in four is false on unseen sentences. 15 of 41: a sentence for a group the listener is not in, of a kind they never mentioned ("Stunt team, safety briefing in two minutes") | Rules cannot know it and the model, asked, says everyone is the listener. Next: the group cue as a narrow question to the model; "what are you here" in the about line; a new held-out set first |
| (W6.3) The rule for another group is off | On unseen data it lost 7 correct alerts for 4 false ones ("The laundry room closes at eight" for a listener in dorm 6) | `holdsBackOtherGroups`; the cue is still reported. Do not switch it on without a new unseen set |
| (W6.3) The system's name tagger has no data in the iOS Simulator | There a name is told by its form (commas, capitals, "you"); which path an iPhone takes is unknown | Check `AudienceAnalyzer.tagsNames` on the device first |
| (W6.3) Names and labels are read from free text by rule | "Mika (that's me)" was not read; "sorting team" was lost (tagged as a verb); a label was copied out of a goal about what the listener wants to hear | The app shows what was understood under the about line; say there to write "My name is …". Labels from goals are the weakest part |
| (W6.3) Recall drops to 88 % while sentences wait (sealed set 3) | Six correct alerts silent when a continued session answers | They are judged again when nothing waits (W6.2); measure on the iPhone |
| (W6.3) The right goal is named for two correct alerts in three | The user sees the wrong goal in the list | Asking for the goal in a step of its own names it better (92 % under load); not changed |
| (W6.3) Five branches to bring together | Window 5 (uncommitted work in the main checkout), 6, 6.1, 6.2, 6.3 (each on top of the one before; 6.3 changes three app files) | The student's decision; 6 → 6.1 → 6.2 → 6.3 fast-forward |
| **(W6.2) Precision 83.8 % on sealed set 2; target 95 %** | About one alert in six is false. 12 of 22 false alerts: a sentence said to another person or group in the same place ("Basses, stay behind" for an alto; "Arthur, your daughter is on the phone") | Its own piece of work: the listener's names and groups from the goals, compared with the addressee before the model is asked; write a set for it first. Do not tune on `semantic_sealed2.txt` |
| (W6.2) A sentence that needs the one before it alerts too easily | 6 of 8 such irrelevant sentences on sealed set 2 | Not addressed |
| (W6.2) The model's capacity is unchanged, about 35 sentences a minute (Mac) | Faster speech for longer than half a minute: decisions up to 30 s late, then given up and counted (`expired`); a second judgement can come a minute late | Measure on the iPhone first |
| (W6.2) While sentences wait, 3–4 of 223 decisions depend on what was said before | Only under load; missed alerts are repaired in the next pause, false ones are not | `Reuse.never` removes it at the price of more expired sentences (measured, benchmark §7) |
| (W6.2) Four branches to bring together | Window 5 (uncommitted work in the main checkout), 6, 6.1, 6.2 (each on top of the one before; 6.2 changes two app files) | The student's decision; 6 → 6.1 → 6.2 fast-forward |
| **(W6.1) Precision 86.6 % on the sealed set, below Window 6's 90.6 %** | Twice as many false alerts (16 of 96 negatives); 7 are plain unrelated sentences | Suspected, not verified: a session kept for six utterances carries a pattern on. Write a new unseen set and compare `sessionTurns` 6 and 1 (the sealed set is spent) |
| (W6.1) A verdict of `urgent` skips the second look | Seen in the Simulator demo: an ordinary sentence presented as a possible warning | Count `urgent` only with kind `warning`; not changed after the sealed run, measure on a new set |
| (W6.1) The same configuration varies from run to run | 5 and 8 false alerts on the development set | A kept session makes a judgement depend on the sentences before it; `sessionTurns: 1` removes that at 1.2 s more per judgement when there is no pause |
| (W6.1) About 31–33 sentences per minute (Mac) | Faster speech for long: decisions up to 20 s late, then reported as dropped | Unknown on the iPhone; measure there first |
| (W6.1) A recap holds the model for about 7 s | A spoken warning outside the phrase rule waits for it | Running beside the recap gained nothing (measured); the phrase rule and acoustic alerts are not affected |
| (W6.1) A kept session holds the last few utterances in memory | Until it is replaced, the session ends or speech data is cleared | `forget()` is called from `reset()`; say so in the privacy text if this ships |
| (W6.1) Three branches to bring together | Window 5 (uncommitted work in the main checkout), Window 6, Window 6.1 (on top of Window 6; one app file changed) | The student's decision; Window 6.1 fast-forwards from Window 6 |
| **(W6) Nothing of Window 6 ran on the iPhone** | Model speed and availability in the background and when locked, the Action Button shortcut, battery and heat are unknown | Device steps in `docs/WINDOW6_SEMANTIC_INTELLIGENCE_REPORT.md` §11 |
| **(W6) Two branches to bring together** | Window 6 was built from `eddc450` while Window 5 work continued uncommitted in the main checkout | Commit Window 5 first, then rebase or merge Window 6; overlapping files are listed in the report §10 |
| (W6) A full goal judgement takes 2.7 s on the Mac | In fast conversation the bounded queue drops the oldest utterances | Measure on the iPhone; options in `docs/research/SEMANTIC_MODEL_COMPARISON.md` §4 |
| (W6) Goals unlike the prompt's examples are matched worse | Shop-worker profile: 8 of 14 found | Per-goal examples; write a new held-out set before tuning (the current one has been seen) |
| (W6) Recaps can misstate | An announcement worded as an agreement; one reversed statement in a development scene | Lexical checks cannot catch it; key points and the temporary transcript are shown beside the summary |
| (W6) Topic change without a pause is not a boundary | Two topics in one recap | Pause-based segmentation only |
| **(W5) The four fixes made after retest R1 have not run on the iPhone** | `door_slam` as a door sound, strong sounds ignoring the same-kind cooldown (15 s), 20 s protection of high-priority episodes, 3.5 s minimum display: tested on the Mac and replayed on recorded events only | R2–R3 in `docs/testing/WINDOW5_TEST_RESULTS.md` §9 (microphone authorization needed); the final build is installed |
| (W5) Faster icons cost updates | Measured 256/h (first rules, D6) and 282/h (revised, R1) in a lively room; the final rules replay to about 250–360 icon changes per hour | Bounded by 12 changes per minute; `AmbientIconPolicy.firstVersion` keeps the calmer rules for comparison; battery unmeasured (D7 postponed) |
| (W5) "Nearby Speech" rule lives in the presentation layer | The island shows speech without a summary as an icon only (student's decision), but the attention engine still creates the episode: the app's Attention card can show a "Nearby Speech" the island does not | Move the rule into `SpeechAssessment` (about a dozen Window 4 tests use textless speech as their vehicle and need rework) |
| (W5) The in-app stop of a timed test is unconfirmed | `--hs-autostop-after` was added; in R1 the export was written 0.7 s before it was due, then the Mac relaunched the app | In the next timed run pull the export a few seconds after the stop is due, before relaunching |
| (W2, seen in R1) A siren clip was not recognized in a loud room | The most important kind of miss; 3 of 3 in the earlier, quieter runs | Repeat in R2; no scores are kept, so log candidate scores of warning kinds in the export if it repeats |
| (W2/W4, found in W5) False alerts and misrecognitions with real sound | D6: 6 of 9 high-priority episodes in 10 minutes were room sounds; rain, footsteps, glass clips misrecognized; "Nearby Speech" 12 times in 17 minutes with transcription off | `door` / `screaming` addressed (one room, one evening: provisional). Open: whether textless "Nearby Speech" should be an episode at all in Quiet/Balanced (student's decision); re-tune with more device data |
| (W5) The lock state is an estimate | Data protection lags the lock by 4–12 s (measured). The estimate now also treats iOS's early "will become unavailable" notice as locked (seen at the moment of locking in two runs; not yet exercised in a device run) | Keep automatic expansion off by default until the notice has been seen reliably; an undocumented Darwin notification could serve as an extra veto — the student's decision, not adopted |
| (W5) Automatic expansion is off by default | The island never expands by itself unless the user turns the setting on; text needs a touch and hold | On the device an expansion request did not wake the locked screen in two runs (silent sound, Always-On on). The student may decide to turn the default on; repeat with the alert sound on first |
| (W5) A stopped app leaves a frozen island | After a crash, termination or suspension the last icon stays for up to 15 minutes (stale date) | Shorter stale date with more keep-alive updates, or accept; seen with the demo scenes, which iOS suspends 26–27 s after leaving the screen |
| (W5) Activity update rate is unmeasured on a device | iOS may throttle; energy cost unknown | D6 / D7; lower `AmbientIconPolicy.maximumChangesPerMinute` or raise `minimumDisplay` if needed |
| (W5) Attention episodes use category-level icons | "Door or knock" and a doorbell share an icon | Carry the kind or label in `AttentionPresentationIntent` if wanted (a Window 4 contract change) |
| (W5) Haptics and the app icon refresh were not done | Roadmap items 3 and 5 partly open | Haptics conflict with the no-vibration requirement when locked; decide with the student |
| **(W4) No real-world validation of the attention engine** | Policy table, cooldowns, thresholds and the phrase list are defaults checked only on hand-written scenes | One live session with real sounds (authorization needed), then adjust `AttentionConfiguration.standard`; full list in `docs/WINDOW4_ATTENTION_PRIORITY_REPORT.md` §7 |
| (W4) The adopted Background-processing mode rests on one device run | If the classifier stops in the background after all, the attention engine ends its episodes as stale after 20 s and shows nothing new | Repeat A1 → A2 → A1 and run A3 with the default build (`docs/testing/BACKGROUND_DEVICE_TESTS.md` §7.7); App Review implications of the declared mode not checked |
| (W4) Importance of speech is keyword- and category-based | English phrase list; a recognition error can create or hide a warning | Titles say "Possible Spoken Warning"; keep the transcript reachable; extend rules per language if needed |
| (W4) With transcription off and music playing, nearby speech is not presented | Without a transcript there is no speech-or-lyrics estimate | By design; revisit if Window 3 gains a relevance estimate without transcription |
| (W4) Release build contains the debug screens and synthetic scenes | App size and surface | Gate with `#if DEBUG` or remove before a release |
| **(W2+W3) Nothing is recognized in the background or with the screen locked** (see the W4 row above: `processing` is now declared) | Measured on the iPhone 18 Pro (iOS 27.2): `SNClassifySoundRequest(.version1)` fails with `com.apple.SoundAnalysis` error 2 from 0.44 s after the app enters the background until it returns; capture continues. No sound events, no speech activation. Blocks the pocket / lock-screen use case and Window 5's purpose. Other developers report the same (Apple forums 811582, 757715, 765376; GPU work not permitted in the background — unverified here) | **The student has to choose** (not decided): (a) a speech trigger that does not need the classifier in the background, e.g. signal level or the Speech framework's voice-activity module, with the recognizer as the check — speech only, no music gate, more recognizer use; (b) a different sound classifier as a Core ML model on CPU / Neural Engine — needs a model (download or training, both need approval) and forum reports say even CPU-only custom models failed for some; (c) accept foreground-only for now and say so; (d) file Feedback with Apple. `SpeechTranscriber` and Foundation Models did run in the background in one trial (model 6.1 s instead of 0.7 s). **Update 2026-10-10 (device, one run):** adding the Background-processing mode to `UIBackgroundModes` made the built-in classifier run in the background and when locked; not replicated yet and not adopted — see `docs/testing/BACKGROUND_DEVICE_TESTS.md` §7 |
| (W3) Device validation is thin | A few sessions, one speaker near the phone, loudspeaker playback, on a charger | Open: P7, P8, P9 in `docs/testing/WINDOW3_TEST_RESULTS.md` §9; other speakers need their consent |
| (W3) A recognition error reversed the meaning once on the iPhone ("not" → "now") | The validator cannot catch errors made before the summary | Keep the transcript visible with every summary; Window 4 must not treat a headline as fact; show recognition quality |
| (W3) Relevance-gate labels differ on the device | Speech over a pop song was labelled plain "nearby speech"; a rap clip was not labelled "possibly music" (it ended as "Speech Unclear") | Re-calibrate with recordings made by the phone (needs authorization to record) |
| (W3) Simulator cannot transcribe | Levels 2–3 cannot be exercised in the Simulator; recognizer tests are skipped there | Use the Mac for recognizer tests; optionally run the app as "My Mac (Designed for iPhone)" (needs the Mac registered in the student's developer account — their decision) |
| (W3) ≈ 2 s from the end of a sentence to its summary on the iPhone (≈ 3 s on the Mac) | Slower than a glance-and-go alert | ≈ 0.8 s is the wait for the final transcript, ≈ 0.7 s the language model; consider showing the transcript-level result first, or a shorter endpoint |
| (W3) Summaries can be incomplete or ambiguous although validated | 3 of 37 manually reviewed headlines were ambiguous ("Store Won't Open Ten") | Keep the transcript reachable from any summary; Window 4 should not treat a headline as fact |
| (W3) Speech vs. music is an estimate | ≈ 6 % of songs still produce something for the language model (mostly rap); ≈ 16 % of spoken words at 0 dB over music are held as "possibly music"; TV/podcast speech counts as nearby speech | Window 4: lowest priority for `possiblyMusic`, lower for `speechOverMusic`; re-tune with device recordings |
| (W3) English only; validator rules are English keyword rules | Other languages get no validated summaries | Add per-language rules or restrict the feature to English; Chinese needs the speech model downloaded |
| (W3) Categories are often debatable (model overuses "reminder") | Weak signal for prioritization | Prefer rule-based `details` (negation, question, time) and keywords in Window 4 |
| (W3) `NSSpeechRecognitionUsageDescription` added defensively | The student reported no prompt on the iPhone | Keep the key |
| (W3) Recognizer limit on the iPhone | "Maximum number of recognizers reached" with three analyzers; limit inferred to be two | Fixed by dropping the standby analyzer and retrying starts; do not add further concurrent analyzers (e.g. a second language) without testing on the device |
| (W3) Thresholds chosen on read/synthetic speech and GTZAN, on the Mac | May not transfer to a phone on a table or in a pocket | Re-run `hs-speech-eval` after collecting device data (with authorization) |
| ~0.5 s media stall at Start/Stop listening | Noticeable but acceptable for manual start/stop | W2: redundant calls skipped + keep-session experiment added; **effect not measured** — device Test S (feasibility §3) |
| No physical-device validation of Window 2 | Thresholds, quiet level, latency, CPU on iPhone unknown | Run `docs/testing/WINDOW2_DEVICE_TESTS.md` (L, A, B, C, D, H, I, S first) |
| Thresholds provisional; no event-annotated environmental data | Alert/knock/animal/weather reliability unknown | Device tests with controlled playback; consider a small annotated set (download needs approval) |
| Minor kinds fire on clean speech (`click`, `mosquito_buzz`, `writing`, `sigh`) | Noise in the event list | Window 4 should give these kinds low priority; or raise their thresholds after device data |
| Quiet threshold −60 dBFS is a guess | Simulator room noise (−53 dBFS) shows as "sound present, not recognized" | Calibrate in Test A |
| Engine output is a single-consumer `AsyncStream` | Later modules cannot subscribe directly | Forward `.event` updates from `RecognitionController` (app layer) |
| Git identity is repo-local (`vicwei`, account email) | Commit author name may not be what the student wants | `git config user.name "…"` in the repo |
| Personal Team signing | App expires after 7 days; re-run from Xcode to reinstall | Fine for development |
| Xcode wrote the student's `DEVELOPMENT_TEAM` into `project.pbxproj` | Other machines must pick their own team | Acceptable; not a secret |
| `AVAudioSession` calls on the main actor | Simulator logs a runtime "hang risk" warning for `setActive` | iOS 27 `activate(options:completionHandler:)` is available (needs `#available`); adopt only after device testing |
| App scheme has no test action | `xcodebuild test -scheme HearingSense` fails (“no test bundles”) | Run package tests from `packages/HearingSenseKit` (§10); the package scheme is now `HearingSenseKit-Package` |
| Interruption ended without `shouldResume` keeps state “Paused” | Untested path | Test with a phone call in Window 2 |
| Navigation title duplicates the brand header | Cosmetic | Window 5 UI pass |
| Placeholder app icon | Cosmetic | Window 5 |

## 9. Remaining tasks (by window)

See `docs/IOS_DEVELOPMENT_ROADMAP.md`. First: the student's decision on background detection (§8,
first row). Carried over from Window 3 (physical iPhone): P7–P9 in
`docs/testing/WINDOW3_TEST_RESULTS.md` §9. Carried over from
Window 2 (physical iPhone, one step at a time): label inventory (L), quiet room (A, calibrate quiet threshold), speech/knock/music/overlap
(B, C, D, G), AirPods + Spotify (H), lock screen ≥ 1 min then ≥ 15 min (I), start/stop stall with
the keep-session toggle off/on (S), playback rain/wind/horn (E, F), interruptions (J, ask first);
plus Window 1's open items (calls, AirPods disconnect, Apple Music, battery/thermal).
Window 4 is done (§4d). Open from it: the device checks in
`docs/WINDOW4_ATTENTION_PRIORITY_REPORT.md` §8. Window 5 is done in code (§4e). Open from it: the
device protocol D1–D8 (`docs/testing/WINDOW5_TEST_RESULTS.md` §6). Then Window 6.

## 10. How to build, test and run

```bash
# Package tests on the Mac (fast)
cd packages/HearingSenseKit && swift test

# Package tests on the iOS Simulator (includes iOS-only tests; the student uses the iPhone 18 Pro Simulator)
cd packages/HearingSenseKit && xcodebuild test -scheme HearingSenseKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro'

# App build for the Simulator
xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense -destination 'platform=iOS Simulator,name=iPhone 18 Pro'

# Offline sound evaluation (forward-only, ~2 min on the M1 Max; needs data/ downloaded)
cd packages/HearingSenseKit && swift run -c release hs-sound-eval evaluate --window 1.5
swift run -c release hs-sound-eval labels     # label inventory with taxonomy mapping

# Window 3: synthetic test sentences (macOS text-to-speech), then speech evaluation (forward-only)
tools/make_speech_test_signals.sh
cd packages/HearingSenseKit
swift run -c release hs-speech-eval availability            # which on-device models exist here
swift run -c release hs-speech-eval transcribe --libri 200  # WER on LibriSpeech (~1 min)
swift run -c release hs-speech-eval summarize --repeat 2    # Foundation Models on 38 sentences (~4 min)
swift run -c release hs-speech-eval pipeline --set tts      # real-time end to end, 20 sentences (~4 min)
HS_RUN_MODEL_TESTS=1 swift test --filter realModel          # opt-in real language-model test

# Window 4: attention engine on scripted scenes (synthetic input; seconds each)
swift test --filter AttentionTests
swift run -c release hs-attention-eval scenarios            # 18 scenes × 3 modes, baseline, metrics
swift run -c release hs-attention-eval trace 06-knock-then-speech --mode balanced   # decision by decision
swift run -c release hs-attention-eval soak --hours 1       # generated long scene
swift run -c release hs-attention-eval determinism

# Window 5: Live Activity presentation (synthetic input; seconds each)
swift test --filter IslandPresentationTests
swift run -c release hs-attention-eval island              # engine + pipeline over all scenes: update counts, rule checks
swift run -c release hs-attention-eval island-trace 06-knock-then-speech
swift run -c release hs-attention-eval island-symbols      # label → kind → category → SF Symbol (TSV)

# Window 5 in the Simulator without a microphone (Debug build; the island shows the activity only
# while the app is not on screen, so go to the Home Screen a few seconds after launch)
xcrun simctl launch --terminate-running-process booted org.hearingsense.HearingSense \
  --hs-island-demo knock            # idle | ambient | knock | siren | speech
#   add --hs-assume-unlocked to see the automatic expansion (layout checks only)

# Window 5 on the iPhone without a microphone (phone unlocked for `launch`). Without a listening
# session iOS suspends the app about 27 s after it leaves the screen, so time the scene from that moment:
xcrun devicectl device process launch --device $D --terminate-existing org.hearingsense.HearingSense \
  --hs-island-demo knock --hs-demo-after-background --hs-demo-key-at 10 --hs-export-diagnostics
#   then lock the phone (or go Home): the knock comes 10 s later; read the export as above
#   (it holds the Live Activity report with a per-update log)
```

In the app the same scenes can be injected without the microphone: Attention card → "Attention
decisions (debug)" → "Inject synthetic events".

Recognizer tests need macOS (they are reported as skipped in the Simulator) and the synthetic
test signals; without the signals they are skipped too.

In the Simulator the app listens through the Mac's microphone; results are Simulator evidence,
not iPhone evidence.

Device tests from the Mac without touching the phone (Debug builds; the phone must be unlocked for
`launch`):

```bash
D=<UDID>   # xcrun devicectl list devices
xcodebuild -project apps/ios/HearingSense.xcodeproj -scheme HearingSense -configuration Debug \
  -destination "id=$D" -derivedDataPath <dir> -allowProvisioningUpdates build
xcrun devicectl device install app --device $D <dir>/Build/Products/Debug-iphoneos/HearingSense.app
# start listening right after launch and export metadata-only diagnostics every 5 s
xcrun devicectl device process launch --device $D --terminate-existing org.hearingsense.HearingSense \
  --hs-autostart --hs-export-diagnostics
xcrun devicectl device copy from --device $D --domain-type appDataContainer \
  --domain-identifier org.hearingsense.HearingSense \
  --source Documents/hearing-sense-diagnostics.txt --destination diag.txt   # works while locked
xcrun devicectl device process launch --device $D --terminate-existing org.hearingsense.HearingSense  # mic off
```

The export (`apps/ios/HearingSense/Diagnostics/DebugDiagnosticsExporter.swift`, `#if DEBUG`) holds
states, counters, timings and the event log — no audio, no transcripts, no summaries. Locking,
unlocking and tapping still need the student. Ask before playing sounds through the Mac speakers.

On the iPhone: open `apps/ios/HearingSense.xcodeproj` in Xcode, Signing & Capabilities → Team =
the student's Personal Team, select the iPhone as destination, Run. Device screenshots:
`xcrun devicectl device capture screenshot --device <UDID> --destination shot.png`
(take them only while Hearing Sense is in the foreground). In the app, **Audio route diagnostics →
Share** exports the route snapshot and event log as text.

Window 6 commands (Mac; synthetic text; the language model is used forward-only):

```bash
cd packages/HearingSenseKit
swift test --filter SemanticAttentionTests
swift test --filter ConversationUnderstandingTests
swift run hs-semantic-eval judge "The exam has been postponed until Friday."   # one utterance
tools/run_semantic_eval.sh dev            # ~4 min; also: dev no-triage | heldout | heldout no-triage
swift run hs-semantic-eval recap --split dev --texts
swift run hs-attention-eval island-icon-sheets <dir>
# Simulator, microphone off (use a simulator no other session is using):
tools/build_ios_sim.sh <derived data dir>
tools/window6_sim_screens.sh <UDID> <dir>/Build/Products/Debug-iphonesimulator/HearingSense.app <out dir>
#   launch arguments: --hs-conversation-demo (scripted conversation, nothing stored)
#                     --hs-screen conversation|summary|history|goals|privacy|icons
#                     -speech.automaticHeadlines YES (Window 3's headline per stretch of speech)
```

Do not tune prompts or rules on `semantic_heldout.txt` or `semantic_sealed.txt` (both have been
read). Window 6.1 commands are in `docs/testing/SEMANTIC_OPTIMIZATION_BENCHMARK.md` §10.

Window 6.3 facts worth knowing before touching the semantic engine (Mac): the model cannot compare
a name or a group with the listener's (five ways of asking, all failed; asked "is the listener that
person?" it said yes 148 times of 148), but it copies whom a sentence names correctly and answers a
narrow question well ("this sentence was said to one person by name: theirs or everyone's?", 16 of
17); so comparisons belong in code and narrow questions to the model. A request has a floor of about
0.5 s; text the system holds is not free (a continued session gets 0.05 s slower per turn; four
turns is the optimum); a plain one-number answer is 40 % faster and keeps recall but lets half as
many false candidates through again; short instructions lose correct alerts; a sentence-embedding
score ranks relevant sentences no better than chance. The answer's field names and form change the
answers. The system refuses a request that lists a goal about danger together with free text
("unsafe content"): ask goal by goal. A rule that worked on a development set I wrote lost more than
it gained on the sealed set another author wrote: write the development set the way a stranger would.
Never edit a script while it runs. Commands: `docs/testing/WINDOW6_3_BENCHMARK.md` §3.

Window 6.2 facts worth knowing before touching the semantic engine (Mac): reading costs about
1 ms per token the system does not hold, writing about 30 ms per token; a session prepared 0.7 s
ahead has read its instructions, one prepared and asked in the same instant is slower than an
unprepared one; the first answer is better *without* its form in the request, the second look
needs it; a kept session answers differently depending on what came before unless the goals are
said again; told that a first reading found a sentence relevant, the model agrees; worked
examples in the instructions trade recall for precision; the parts of a streamed answer arrive
together at the end. Commands: `docs/testing/WINDOW6_2_BENCHMARK.md` §3.

Window 6.1 facts worth knowing before touching the semantic engine: the time of a judgement is
its output tokens (about 40 ms each); the system keeps what **one** session has read, so any
other session (second look, recap, a prepared spare) makes the next judgement read everything
again unless the judging session is made ready again; a longer session text slows every answer;
the model does not keep an unconstrained answer format; sentence embeddings do not separate
relevant from irrelevant sentences; judging several sentences in one request loses relevant ones.

## 11. Files to read first (in order)

1. `docs/PROJECT_HANDOFF.md` (this file)
2. `docs/IOS_ARCHITECTURE.md` — module map, contracts (§4), constraints
3. `docs/AUDIO_ROUTING_FEASIBILITY.md` — verified routing behaviour and open device tests
4. `docs/IOS_DEVELOPMENT_ROADMAP.md` — your window's scope and acceptance criteria
5. `docs/EXISTING_PROJECT_AUDIT.md` — what the research assets are and what must be preserved
6. `docs/WINDOW2_SOUND_ANALYSIS_REPORT.md` — sound pipeline, rules, evaluation, limitations
7. `docs/testing/WINDOW2_DEVICE_TESTS.md` — open device tests
8. `docs/WINDOW3_SPEECH_INTELLIGENCE_REPORT.md`, `docs/research/SPEECH_INTELLIGENCE_ARCHITECTURE.md`,
   `docs/testing/WINDOW3_TEST_RESULTS.md` — speech pipeline, measurements, limitations, pending device tests
9. `docs/WINDOW4_ATTENTION_PRIORITY_REPORT.md`, `docs/research/ATTENTION_ENGINE_ARCHITECTURE.md`,
   `docs/testing/WINDOW4_TEST_RESULTS.md` — attention engine, policy, Window 5 interface, results, limits.
   Code (W4): `Sources/HearingSenseDomain/Attention.swift`, `Sources/Attention/{AttentionEngine,
   AttentionPolicy, AttentionPreferences, SpeechAssessment, AttentionTypes}.swift`,
   `Sources/AttentionReplay/{ScenarioLibrary, AttentionReplayer}.swift`,
   `apps/ios/HearingSense/Attention/AttentionController.swift`, `Views/AttentionViews.swift`.
   Also `docs/BACKGROUND_RECOGNITION_DECISION.md` and `docs/testing/BACKGROUND_DEVICE_TESTS.md`.
9a. `docs/WINDOW5_DYNAMIC_ISLAND_REPORT.md`, `docs/testing/WINDOW5_TEST_RESULTS.md` — Live Activity
   design, the no-screen-wake rules, results, device protocol. Code (W5): `Sources/IslandPresentation/
   {IslandPipeline, AmbientIconStream, AlertGate, IslandContent, SoundSymbolCatalog}.swift`,
   `Sources/IslandViews/IslandViews.swift`, `apps/ios/HearingSenseWidgets/HearingSenseLiveActivity.swift`,
   `apps/ios/HearingSense/Presentation/LiveActivityController.swift`, `Views/LiveActivityViews.swift`.
9b. Code (W3): `Sources/HearingSenseDomain/SpeechSemantics.swift`, `Sources/SpeechIntelligence/
   {SpeechIntelligenceEngine, SpeechActivityTracker, SpeechRelevanceGate, SpeechIntelligenceTypes}.swift`,
   `Sources/SpeechPipeline/{PreRollAudioBuffer, AppleSpeechTranscriber}.swift`, `Sources/SemanticSummary/
   {SpeechSemanticAnalyzer, SummaryValidator, FoundationModelInterpreter}.swift`,
   `apps/ios/HearingSense/Speech/SpeechIntelligenceController.swift`
10. Code (W1–W2): `packages/HearingSenseKit/Sources/HearingSenseAudio/MicrophoneCapture.swift`,
   `AudioStreamConsumer.swift`, `Sources/HearingSenseDomain/AcousticEvent.swift`,
   `Sources/SoundEventDetection/{SoundRecognitionEngine, SoundAnalysisWorker, SoundEventDetector,
   DetectionPolicy, SoundTaxonomy}.swift`, `apps/ios/HearingSense/Listening/ListeningController.swift`,
   `apps/ios/HearingSense/Recognition/RecognitionController.swift`

9d. `docs/research/SEMANTIC_OPTIMIZATION_REPORT.md`, `docs/testing/SEMANTIC_OPTIMIZATION_BENCHMARK.md`.
   Code (W6.1): `Sources/SemanticAttention/{ModelInferenceScheduler, StablePartialDetector,
   SemanticAttentionEngine, FoundationModelRelevanceReasoner}.swift`,
   `Sources/SemanticEvaluation/{SemanticConfusion, SemanticStreamBenchmark}.swift`.

9c. `docs/WINDOW6_SEMANTIC_INTELLIGENCE_REPORT.md`, `docs/testing/WINDOW6_EVALUATION_RESULTS.md`,
   `docs/research/SEMANTIC_MODEL_COMPARISON.md`, `docs/research/ACOUSTIC_ICON_COVERAGE.md`. Code (W6):
   `Sources/SemanticAttention/{SemanticAttentionEngine, EvidenceVerifier, FoundationModelRelevanceReasoner}.swift`,
   `Sources/ConversationUnderstanding/{RollingConversationBuffer, ConversationRecapEngine, ConversationSession}.swift`,
   `apps/ios/HearingSense/Conversation/ConversationIntelligenceController.swift`, `Views/ConversationViews.swift`.

## 12. Recommended next steps

000000. (After Window 6.3) Student decides: (a) ship the Window 6.3 branch in place of Window
   6.2's engine (recommended: a third fewer false alerts on unseen sentences, recall within one
   sentence in 150 by recount, decisions that no longer depend on what was said before); (b) the
   next piece of work — sentences for a group the listener is not in (`docs/research/
   WINDOW6_3_PERSONAL_RELEVANCE.md`, Recommendations 2), which needs a new held-out set before any
   change; (c) iPhone validation of the name path, the timing and real transcripts, each step with
   authorization; (d) how to bring Window 5, 6, 6.1, 6.2 and 6.3 together. Do not tune on
   `semantic_sealed3.txt` or any earlier sealed set.

00000. (After Window 6.2; superseded by the step above) Student decides: (a) ship the Window 6.2 engine in place of Window
   6.1's (recommended: fewer false alerts at the same recall, decisions independent of order,
   overload visible); (b) whether the next window attacks the addressee problem (known issues,
   first row); (c) how to bring Window 5, 6, 6.1 and 6.2 together. Then the device steps of
   `docs/research/SEMANTIC_OPTIMIZATION_REPORT.md` §8, each with authorization. Do not tune on
   `semantic_sealed2.txt`, `semantic_sealed.txt` or `semantic_heldout.txt`; a new question needs
   a new unseen set.

0000. (After Window 6.1; superseded by the step above) Student decides: (a) ship the Window 6.1 engine as frozen or test
   `sessionTurns: 1` on a new unseen set first; (b) how to bring Window 5, 6 and 6.1 together.
   Then the device steps of `docs/research/SEMANTIC_OPTIMIZATION_REPORT.md` §8, one at a time,
   each with authorization. Do not tune on `semantic_sealed.txt` or run it to compare variants.

000. (After Window 6) Bring the branches together (Window 5's uncommitted work first), then the
   device steps of the Window 6 report §11, one at a time, each with the student's authorization.
   Decisions for the student: whether the cough and sneeze glyphs read well on the real island;
   whether goal matches may expand the island; whether an open-source model is worth a test
   after iPhone timings exist.

00. (After Window 5) D1–D6 and the retest R1 are done (2026-10-10/11). Next: with the final build
   (installed) run R2–R3 of `docs/testing/WINDOW5_TEST_RESULTS.md` §9 (microphone authorization;
   the student watches the locked screen in R3). D7 and D8 are postponed by the student. Open
   decisions for the student: "Expand for important events" on by default or not; whether textless
   "Nearby Speech" stays an attention episode; committing the changes made after `dc1f6cf`. D6
   also served as A3 (classifier 35 minutes locked without a failure, once). Window 6 only when
   the student asks, on a new branch from `feature/window5-dynamic-island`.
0. (After Window 4) With the student's microphone authorization: repeat A1 → A2 and run A3 with the
   default build; one live session with real sounds and the Attention decisions screen open; then
   adjust `AttentionConfiguration.standard` if needed. Start Window 5 only when the student asks,
   on a new branch from `feature/window4-attention-priority`.
1. Student decides whether to merge the feature branches into `main` (linear history:
   window 2 → window 3 → research → window 4; not done automatically; nothing is pushed).
2. When the student authorizes device testing: Window 3 tests P0–P9 and the open Window 2 tests,
   one step per message, screenshots only with the app in the foreground, the student decides what
   is spoken.
3. Re-tune `SpeechIntelligenceConfiguration` and `DetectionPolicy.standard` from device results and
   re-run `hs-speech-eval` / `hs-sound-eval` to check nothing regressed.
4. (Done.) Window 4 was started on 2026-10-10 at the student's request.
