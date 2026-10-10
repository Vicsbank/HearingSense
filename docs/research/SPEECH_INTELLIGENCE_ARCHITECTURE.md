# Speech Intelligence Architecture (Window 3)

How Hearing Sense turns nearby speech into a short on-device summary. Describes the code as it is
on branch `feature/window3-speech-intelligence`; measurements are in
`docs/testing/WINDOW3_TEST_RESULTS.md`, the narrative report in
`docs/WINDOW3_SPEECH_INTELLIGENCE_REPORT.md`.

No model was trained or fine-tuned. Everything uses Apple's pretrained on-device models.

---

## 1. Pipeline

```
MicrophoneCapture (one AVAudioEngine input tap, Window 1)
 ├─▶ SoundRecognitionEngine (Window 2) ──▶ classifier windows (1.5 s, every 0.75 s) + sound events
 │                                              │ forwarded by the app's RecognitionController
 └─▶ SpeechAudioTap ─▶ PreRollAudioBuffer       ▼
        (last 5 s, memory only)        SpeechActivityTracker            stage A of the relevance gate
                 │                      speech candidate, music context
                 │  read from the estimated onset        │ began / ended
                 ▼                                       ▼
        UtteranceTranscription  ◀──────────  SpeechIntelligenceEngine (serial command queue)
        (SpeechAnalyzer + SpeechTranscriber,             │
         one analyzer per utterance)                     │ final utterance
                 │ partial / final text                  ▼
                 └────────────────────────▶  SpeechRelevanceGate          stage B: speech / speech
                                                         │                 over music / possibly music
                                                         ▼
                                             SpeechSemanticAnalyzer
                                             (Foundation Models + SummaryValidator + rules fallback)
                                                         ▼
                                             SpeechSemanticResult updates ─▶ app UI (W3), Attention
                                                                            Priority Engine (W4)
```

Modules (Swift package `packages/HearingSenseKit`):

| Module | Depends on | Contents |
|---|---|---|
| `HearingSenseAudio` (+) | AVFAudio | `AudioStreamClock` (moved here from SoundEventDetection so both pipelines stamp buffers identically) |
| `HearingSenseDomain` (+) | Foundation | `SpeechSemanticResult` and its parts (`SpeechEventID`, `SpeechProcessingState`, `SpeechOutputLevel`, `SpeechSemanticCategory`, `SpeechTranscript`, `TranscriptQuality`, `SpeechSummary`, `SummaryReliability`, `SpeechSemanticDetails`, `SpeechRelevance`, `SpeechAcousticContext`, `SpeechLatency`, `TranscriptionAvailability`, `SemanticModelAvailability`) |
| `SpeechPipeline` | Speech, AVFAudio, Audio, Domain | `PreRollAudioBuffer`, `SpeechAudioTap`, `SpeechTranscribing` / `UtteranceTranscription` protocols, `AppleSpeechTranscriber`, `TranscriptAssembler`, `TranscriptText` |
| `SemanticSummary` | FoundationModels, Domain | `SemanticInterpreting` protocol, `FoundationModelInterpreter`, `SpeechSemanticAnalyzer`, `SummaryValidator`, `UtteranceAnalysis`, `RuleBasedInterpreter`, `SummaryPolicy` |
| `SpeechIntelligence` | all of the above + SoundEventDetection | `SpeechIntelligenceEngine`, `SpeechActivityTracker` / `SpeechActivationPolicy`, `SpeechRelevanceGate` / `SpeechRelevancePolicy`, configuration, diagnostics, outputs |
| `hs-speech-eval` (macOS tool) | all | forward-only evaluation commands |

App target: `Speech/SpeechIntelligenceController` (observable state, privacy handling, logging of
metadata only), `Views/SpeechIntelligenceViews` (card on the main screen, diagnostics screen).
`ListeningController` adds `speech.engine.audioTap` as a second consumer of the existing capture
and calls `sessionWillStart()` / `sessionDidEnd()` wherever it does so for sound recognition.
`RecognitionController` forwards every classifier window and event update to the speech engine.

## 2. Apple APIs used (verified against the iOS 27.0 / macOS 27.0 SDK interfaces and at run time)

| API | Use | Notes from testing |
|---|---|---|
| `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` | On-device speech-to-text | Options `[.volatileResults, .fastResults]`, attributes `[.audioTimeRange, .transcriptionConfidence]`. No server mode exists for this module |
| `SpeechTranscriber.isAvailable`, `.supportedLocale(equivalentTo:)`, `.installedLocales` | Availability | **`isAvailable` is false in the iOS 27.0 Simulator**; true on macOS 27.2 (M1 Max). iPhone not checked yet |
| `AssetInventory.status(forModules:)`, `.assetInstallationRequest(supporting:)`, `AssetInstallationRequest.downloadAndInstall()` | Model assets | An installed model reports `.supported` until `assetInstallationRequest` is called (it returns nil when nothing needs downloading, after which the status is `.installed`). Downloading only happens in `AppleSpeechTranscriber.installModel()`, on a user action |
| `SpeechAnalyzer(modules:options:)`, `prepareToAnalyze(in:)`, `start(inputSequence:)`, `finalizeAndFinishThroughEndOfInput()`, `cancelAndFinishNow()` | Streaming analysis | See §4 for the behaviours that shaped the design |
| `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` | Input format | 16 kHz mono Int16 on macOS 27.2; microphone audio is converted with `AVAudioConverter` |
| `SpeechAnalyzer.Options(priority:modelRetention: .processLifetime)`, `SpeechModels.endRetention()` | Model lifetime | `prepare()` loads the model with a short-lived analyzer; it stays loaded until `endRetention()` when listening stops. No standby analyzer: on the iPhone 18 Pro a third simultaneous recognizer failed with "Maximum number of recognizers reached" (limit inferred to be two); a failed start is retried from the pre-roll buffer |
| `AnalyzerInput(buffer:bufferStartTime:)` | Timestamps | Contiguous timeline starting at 0 per analyzer |
| `SystemLanguageModel.default`, `.availability`, `.supportsLocale(_:)` | Language model availability | Available on macOS 27.2 and in the iOS 27.0 Simulator (which uses the Mac's model). `PrivateCloudComputeLanguageModel` is never referenced |
| `LanguageModelSession(model:instructions:)`, `prewarm()`, `respond(to:generating:options:)` | Guided generation | One session per request; `GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 100)` |
| `@Generable`, `@Guide` | Typed output | `GeneratedInterpretation { headline, category, subject, timeOrNumber }` |

Not used: `SFSpeechRecognizer` (may use servers), `DictationTranscriber`, `SpeechDetector` (the
sound classifier already gates the recognizer; in a probe its results stream produced nothing when
used next to a transcriber).

Deployment target stays iOS 26.0; the package's macOS platform was raised from 15 to 26 so the
same code builds for `swift test`.

## 3. Pre-roll audio buffer

Problem: the classifier needs 1.5 s for one window; the sound detector confirms speech after two
(≈ 2.25 s). A sentence like "Your package arrived." is over by then.

`PreRollAudioBuffer` (`SpeechPipeline`):

- Ring of mono Float32 samples at the input rate, `capacity × sampleRate` frames (5 s at 48 kHz =
  240 000 frames ≈ 0.96 MB). Capacity is configurable (`SpeechIntelligenceConfiguration.preRollSeconds`, 0.1–30 s).
- **Timestamps**: positions come from `AudioStreamClock.Placement`, the clock Window 2 uses, so a
  classifier window's `audioTime` addresses the same samples. Capture gaps reported by the clock
  (`AVAudioTime.sampleTime` jumps) are zero-filled, so later audio keeps its time.
- **Writer** (audio tap thread): `append` takes an unfair lock for a bounded `memcpy`; it allocates
  only when a segment starts (first buffer, sample-rate change, capture restart, new session).
- **Readers**: any number, each with its own `Cursor`; `read(from:)` copies out and reports
  `skippedFrames` if the reader fell more than the capacity behind, or `.discontinuity` if the
  stream restarted. Readers never block the writer for longer than a copy.
- **Format changes**: a new clock segment or session discards the content (a restarted engine
  means the real-world timeline was interrupted anyway).
- **Privacy**: memory only; `clear()` zeroes the samples (called on Stop); a disabled buffer
  (transcription off) stores nothing.

Activation uses it like this: on the first qualifying window (audio range `[t, t + 1.5]`) the
engine starts the recognizer at `t − leadIn` (0.75 s), clamped to audio that is still buffered and
has not been transcribed before, feeds everything up to "now" at once, then keeps feeding live
audio every 60 ms. The recognizer processes buffered audio much faster than real time (real-time
factor ≈ 0.035 on the Mac), so it catches up within a fraction of a second.

## 4. Transcription strategy and the measurements behind it

All measured on macOS 27.2 (M1 Max) with `SpeechAnalyzer` + `SpeechTranscriber`, en-US:

| Observation | Consequence |
|---|---|
| Creating + preparing an analyzer: ≈ 0.08–0.24 s the first time, ≈ 5 ms afterwards (model retained) | A new analyzer per utterance is cheap; `prepare()` at Start pays the first-time cost |
| Buffers whose `bufferStartTime` starts at 100 s: no results, `finalize(through:)` never returned | Every analyzer gets a timeline starting at 0; an offset maps results to the session clock |
| A forward gap in the timeline (4.8 s → 10 s): next final result was `",......"` | Never feed a gap: audio is contiguous within an utterance |
| `finalize(through: nil)` mid-stream, then more audio: the next final was degraded ("really G. After all … but but little of, you Ith.") although its volatile text had been right | No mid-stream finalize; an utterance ends with `finalizeAndFinishThroughEndOfInput()` and a fresh analyzer continues |
| Volatile results: every ≈ 4 s with `.volatileResults` alone, every ≈ 1 s with `.fastResults` | `.fastResults` is on |
| Natural finals can lag: 4.7 s after a sentence in one probe, ≈ 0.8 s after short sentences in the pipeline runs | Finals are used when they come, plus an explicit endpoint: transcript unchanged for 1.6 s of audio → finish the utterance |
| Results lag behind the audio fed | An utterance is always finished, never cancelled for "no text yet" (a test with scripted timing lost the first word otherwise) |

Utterance life cycle inside `SpeechIntelligenceEngine`:

1. **Start** on speech activity (or right after the previous utterance while activity continues,
   at the exact audio position where that one stopped: no audio is skipped or transcribed twice).
2. **Feed**: pre-roll, then live audio.
3. **End** when the transcript has been stable for `endpointSilence` (1.6 s), the utterance
   reached `maximumUtteranceDuration` (30 s), speech activity ended, or the capture restarted.
4. **Finalize** in the background; a `finalizationTimeout` (3 s wall clock) promotes the partial
   text if the recognizer never answers.
5. Failures: counted; the recognizer restarts while speech continues; after 3 failures in a row
   the session degrades to detection only until availability is refreshed.

`TranscriptAssembler` merges results per utterance: volatile text replaces volatile text, finals
append, repeated finals (same audio range, or same words right after) are dropped and counted,
punctuation-only results are ignored.

## 5. Speech activation and the speech relevance gate

### Stage A — before transcription (`SpeechActivityTracker`, `SpeechActivationPolicy`)

Per classifier window: `speech` = best score among the labels of the kinds `speech` and `shouting`
(`speech`, `whispering`, `chatter`, `shout`, `yell`, `battle_cry`, `children_shouting`), `music` =
best score among the 74 music labels, `vocal` = best score among `singing`, `choir_singing`,
`rapping`, `humming`, `yodeling`.

| Context | A window counts as speech when |
|---|---|
| No music context | `speech ≥ 0.30` (a *candidate*: below the detector's 0.5, one window instead of two) |
| Music context: `music ≥ 0.5` now, or in ≥ 2 of the last 4 windows | `speech ≥ 0.90`, **or** `speech ≥ 0.80` and `vocal ≤ 0.20` |

Activity ends after 2.25 s of audio without a qualifying window. No extra delay is added in a
music context (the first qualifying window activates).

### Stage B — after transcription, before the language model (`SpeechRelevanceGate`, `SpeechRelevancePolicy`)

For each final utterance, over the classifier windows that overlap its audio range (by ≥ 0.5 s
or half the utterance):

| Condition | `SpeechRelevance` | Effect |
|---|---|---|
| Music in < 34 % of the windows | `nearbySpeech` | Interpreted |
| Music context and (≥ 34 % of windows with `speech ≥ 0.9` and recognizer confidence ≥ 0.5), or (≥ 50 % with `speech ≥ 0.8` and confidence ≥ 0.8) | `speechOverMusic` | Interpreted; flagged as less certain |
| Music context otherwise | `possiblyMusic` | **Not sent to the language model.** Transcript kept, headline "Speech Or Music", no summary, category unknown |

Why these cues: on the design data the share of windows with a strong speech score separated
spoken segments from lyric segments with AUC 0.96 (median 0.92 for speech 10 dB above music, 0.00
for lyrics, whose 90th percentile is also 0.00); recognizer confidence added AUC 0.86. Window-level
scores alone do not separate them (17 % of all music windows have `speech ≥ 0.3`, 1.4 % ≥ 0.9).

What it cannot do, by construction:

- It does not separate voices. Rap is rhythmic speech; a spoken-word passage in a song is speech.
  A small share of lyrics passes as `speechOverMusic` (measured: 6 % of music-only clips had
  something sent to the language model).
- Speech at about the level of loud vocal music is often `possiblyMusic` (measured: 16 % of
  spoken words at 0 dB speech-to-music ratio).
- It says nothing about recorded speech without music (TV, podcast, phone speaker): that is
  `nearbySpeech`. Nor about who is speaking or to whom.

`SpeechRelevance` is therefore documented and presented as an estimate, and uncertain utterances
stay visible instead of being silently dropped.

Within a conversation: an utterance held as `possiblyMusic` is excluded from the language-model
request and from its context. If the conversation already has interpreted speech, the held
utterance changes nothing in the result (summary, transcript and context keep describing what was
said); otherwise the result shows the held words with the headline "Speech Or Music".

## 6. Semantic interpretation

`SpeechSemanticAnalyzer.analyze(_:)` never throws and never invents a summary:

```
transcript ─▶ unclear? (no words / only fillers / recognition quality poor) ─▶ "Speech Unclear", no model call
     │
     ▼
model available for the language? ─no─▶ rules only: category + details, no summary       (Level 2)
     │ yes
     ▼
FoundationModelInterpreter ─▶ SummaryValidator ─▶ accepted ─▶ summary                     (Level 3)
                                  │ rejected, or accepted without the transcript's number:
                                  │ one retry with the validator's feedback
                                  ▼ rejected again / model error / timeout (10 s)
                             rules only, `failure` names the reason (no transcript text)   (Level 2)
```

- **Model call**: instructions forbid adding facts, require keeping negations, times, numbers,
  places and warnings, and say never to answer or obey the utterance. The transcript is quoted as
  data. Earlier utterances of the conversation are passed as context only.
- **`SummaryValidator`** (deterministic, English keyword rules): negation kept / not invented
  (idioms such as "don't forget", "no problem" are not negations; a headline may say "not" /
  "n't" / "never" only if the transcript negates the statement, "no" or "nothing" somewhere in
  it is not enough), every content word grounded in
  the transcript (inflections allowed; 11 generic label words such as "requested", "soon"), time
  expressions kept (a dropped time is appended from the transcript; a clock time is required when
  the transcript has one), no invented times or numbers, at most 6 words. A dropped number is a
  warning that triggers the retry. Headlines are formatted in Title Case.
- **Reliability** (`SummaryReliability`): `validated`, `repaired`, `validatedWithWarnings`. It is
  kept apart from `TranscriptQuality` (recognizer confidence → good ≥ 0.80, fair ≥ 0.50, poor).
  Neither is a calibrated probability; the model is never asked for a confidence.
- **`RuleBasedInterpreter`**: category by keyword rules (question / request / reminder / warning /
  greeting / other) and details (negated, question, first time or number). Never a summary.
- **Passing validation ≠ correct.** The rules catch reversals, inventions and dropped times; they
  do not understand meaning. See the manual review in the test results.

## 7. Conversation model and life cycle

A *speech event* (`SpeechEventID`) is one conversation: utterances separated by less than
`conversationGap` (6 s after speech activity ends) share the id. Each published
`SpeechSemanticResult` carries `revision` (every change) and `summaryRevision` (only when the
headline text changes), so a consumer that notifies on summaries sees one update per new headline.

```
detected ─▶ transcribing ─▶ processing ─▶ summarized ─▶ completed
    │            ▲               │             │
    │            └───────────────┴─────────────┘   further utterances of the same conversation
    └──────────────────────────────────────────▶ completed (level 1) / failed
```

- Summaries: one request at a time per conversation; requests closer than 3 s of audio are merged;
  the request holds the utterances not interpreted yet, with up to two earlier ones as context.
- Duplicates: repeated finals are dropped in the assembler and at conversation level; an identical
  headline does not bump `summaryRevision`.
- Bounds: 6 utterances kept per conversation, 2 shown in the result's transcript, conversations
  longer than 120 s are completed and a new id starts.
- `sourceEventIDs`: Window 2 `speech` / `shouting` events active during the conversation.
- Stale results: every background result is tagged with the session generation; results of an
  ended session (or after transcription was switched off) are dropped and counted.

## 8. Layered fallback

| Level | Condition | Result |
|---|---|---|
| 1 Detection | Transcription off, unsupported device (e.g. Simulator), model not installed, or repeated recognizer failures | "Nearby Speech", no transcript |
| 2 Transcript | Transcription works; language model unavailable (device not eligible, Apple Intelligence off, model not ready, unsupported language), failed, timed out, or its headline was rejected twice; or the utterance is `possiblyMusic` / unclear | Real transcript; headline "Speech Detected", "Speech Unclear" or "Speech Or Music"; rule-based category |
| 3 Summary | Both models available and the headline passed validation | Validated headline + category + details |

Sound recognition never depends on any of this: the speech engine is a separate consumer, and a
failure in it only changes its own outputs.

## 9. Concurrency

- `SpeechIntelligenceEngine` turns every input into a command on one `AsyncStream` consumed by a
  single task; the state lives in a private actor whose methods are only called from that task.
  Commands take effect in order; there is no re-entrancy to reason about.
- Slow work runs in child tasks that report back as commands tagged with the session generation:
  recognizer `finish()`, the finalization deadline, the semantic request.
- At most one `.pump` command is queued (`PumpGate`), so a slow recognizer cannot build a backlog.
- `PreRollAudioBuffer`, `SpeechAudioTap`: `OSAllocatedUnfairLock`; the tap never awaits.
- `AppleUtteranceTranscription` is an actor that owns the non-Sendable `AVAudioConverter` and
  analyzer objects.
- Swift 6 language mode throughout. One documented use of `withLockUnchecked` (the tap's sample
  pointer is read synchronously inside the call). No `@unchecked Sendable`, no `nonisolated(unsafe)`.
- `drain()` exists for deterministic replay and tests (`drivesItself: false` + `pump()`).

## 10. Privacy

| Requirement | Implementation |
|---|---|
| Local inference only | `SpeechTranscriber` (no server mode) and `SystemLanguageModel.default`; no networking code in the app; `PrivateCloudComputeLanguageModel`, `SFSpeechRecognizer`, `DictationTranscriber` unused |
| No audio upload or storage | Audio exists only in the ring buffer and in buffers handed to the frameworks |
| Bounded pre-roll | Fixed ring (≈ 1 MB), zeroed on Stop, not filled while transcription is off |
| No transcript persistence | Results live in memory: 20 speech events in the app, 6 utterances per conversation in the engine. `UserDefaults` stores only the two switches |
| No transcripts in logs | The diagnostic log and shared reports contain states, counts, timings and relevance only; model error messages are reduced to the error kind |
| Visible when active | Badge "TEXT OFF / TEXT ON / TRANSCRIBING" on the card, next to the existing "MIC ON" |
| Independent switch | "Transcribe nearby speech" (default **off**, remembered); sound classification is unaffected |
| Cleanup | Stop: recognizer cancelled, pending model call cancelled, buffer zeroed, transcripts removed from the list (unless the debug option "Keep transcripts after stopping" is on). Switching transcription off discards all speech events |
| Permissions | `NSMicrophoneUsageDescription` (existing); `NSSpeechRecognitionUsageDescription` added defensively — whether iOS shows a speech-recognition prompt for `SpeechAnalyzer` with app-supplied audio is unverified (needs the iPhone) |

Model assets: the speech model is a system asset that Apple's `AssetInventory` downloads on
request. The app only requests it when the user taps "Download speech model".

## 11. Contract for Window 4

Consume `SpeechIntelligenceOutput.result(SpeechSemanticResult)` from the app layer
(`SpeechIntelligenceController.events` / the engine's single-consumer `outputs` stream):

- Key by `id`; treat a higher `summaryRevision` as "new headline", everything else as progress.
- Use `level`, `category`, `details`, `summary.reliability`, `transcript.quality` and
  `acousticContext.relevance` as advisory inputs. `isPossiblyMusic` results should get the lowest
  priority; `speechOverMusic` is less certain than `nearbySpeech`.
- `state.isTerminal` ends the event. `sourceEventIDs` links to Window 2 events.
- Do not persist `transcript` or show it outside the app without the user's opt-in.
- The engine has no notion of importance, of who is speaking, or of whether speech is addressed
  to the user.

## Addendum (2026-10-09): findings from the physical iPhone

Details: `docs/testing/WINDOW3_TEST_RESULTS.md` §10.

- **Recognizer limit.** See the model-lifetime row in the API table above (decision D29).
- **The activation signal disappears in the background.** `SNClassifySoundRequest(.version1)` fails
  while the app is in the background or the screen is locked; capture, `SpeechTranscriber` and
  Foundation Models keep working (one trial; the language model was about nine times slower).
  The pipeline's first stage therefore has no input there. The engine ends speech activity after
  `classifierStallTimeout` (3 s) without a classifier window, so it stops transcribing instead of
  transcribing everything (D30).
- **A background trigger is an open design question.** Candidates: signal-level onset detection or
  the Speech framework's voice-activity module in front of the recognizer (speech only; no music
  scores, so the relevance gate would have only transcript confidence to work with), or a custom
  Core ML sound classifier that is allowed to run in the background (needs a model). Not decided,
  not implemented.
- **Relevance gate on acoustic playback.** Thresholds were set on digital mixes; music recorded
  by the phone from a loudspeaker produced different scores (speech over a pop song was labelled
  plain nearby speech). Needs device recordings.

