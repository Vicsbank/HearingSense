# Window 9 — validation and remaining blocker

2026-10-13. Branch `feature/window9-summary-postprocessing`; all inputs in this phase are
synthetic English. Mac and iOS Simulator only. No physical iPhone access or microphone capture.

## Native Qwen Simulator blocker

**Real Qwen inference in Simulator: blocked, not passed.** The app links the native Swift runtime
and builds, but the pinned runtime's own
[troubleshooting documentation](https://github.com/ml-explore/mlx-swift/blob/0.32.3/Source/MLX/Documentation.docc/troubleshooting.md)
states that Simulator lacks MLX's required Metal GPU family features.

Observed failures before adding the guard:

- Normal launch: fatal C++ exception in `mlx::core::metal::Device::Device`, constructing an
  architecture name from a null Simulator device value.
- A targeted `MLX_METAL_GPU_ARCH=applegpu_g13s` trial (the Mac's architecture) progressed further
  but aborted in `MTLSimDevice newHeapWithDescriptor`: `MTLStorageModePrivate is required for heaps`.
  MLX uses shared Metal heaps. This confirms that an architecture override is insufficient.

The runtime is not patched to fake success. A Simulator-specific availability check now runs
before any MLX allocation/cache operation. The coordinator records
`qwen_simulator_runtime_unsupported` and tries Apple. Native Swift Qwen inference is separately
tested on the Mac using the same runtime and checkpoint; it is not used to answer app requests.

## Environment and commands

Apple M1 Max Mac, Xcode/SDK 27.0; iPhone 18 Pro Max Simulator (`iPhone19,3`, iOS 27.0),
UUID `7BD3EAF0-49F4-4924-A51F-F51AA44E16A7`.
Qwen model/revision and dependency versions are in
[`QWEN35_HEARING_SENSE_INTEGRATION.md`](../research/QWEN35_HEARING_SENSE_INTEGRATION.md).

```sh
xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense \
  -configuration Debug -destination 'platform=iOS Simulator,id=7BD3EAF0-49F4-4924-A51F-F51AA44E16A7' \
  -toolchain org.hearingsense.toolchain.metalswift -derivedDataPath /private/tmp/hs-w9-app \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
# Repeat with -configuration Release for the shipping configuration.
xcrun simctl install 7BD3EAF0-49F4-4924-A51F-F51AA44E16A7 \
  /private/tmp/hs-w9-app/Build/Products/Debug-iphonesimulator/HearingSense.app
xcrun simctl launch --terminate-running-process --console-pty \
  7BD3EAF0-49F4-4924-A51F-F51AA44E16A7 org.hearingsense.HearingSense \
  --hs-w9-selftest --hs-w9-persist --hs-w9-expect fallback --hs-test-mode off
```

The Debug self-test replaces microphone input with synthetic utterances and exercises the real
app object graph, App Intents, coordinator, Apple model, postprocessor and SwiftData. Its report
contains only state, counts, timings and model labels. `--hs-w9-persist` uses an isolated
`Window9SyntheticHistory` folder, never the normal History store. Without that flag the self-test
uses an in-memory store. A reopened store checks full summary, key points, engine label and status.

## Final results

Final implementation: **`c7726ac3e88aab9da1db4f991087ff3ef952f606`**, following **`7f6c4d3`**
(ambiguous time/history evidence) and **`c791d4a`** (completed pipeline and safe fallback).
The measured evidence and handoff documentation are committed subsequently on the same
branch; `git log -1` identifies the final handoff commit.

| Check | Result |
|---|---|
| Complete Mac HearingSenseKit suite, final code | **660 passed, 9 skipped, 0 failures** (669 registered; parameterized runs counted separately by Swift Testing) |
| Qwen package locator tests, Mac | **2 passed**, no model inference in these tests |
| Complete package in Simulator, before final edge fixes | **650 passed, 10 skipped, 0 failures** |
| Final changed targets in Simulator | **215 passed, 0 skipped, 0 failures** (98 postprocessing, 117 conversation tests) |
| Final Debug and Release app builds | **Both succeeded**, including existing audio and Live Activity targets |
| Running app, actual Apple fallback + production pipeline | **27/27 acceptance checks passed** |
| Qwen selected in production setup | **Yes, configured primary**; deliberately skipped in Simulator |
| Real native Qwen Simulator inference | **Blocked** by runtime GPU/heap requirements |
| Real native Qwen on Mac | **Passed**, exact cached checkpoint through Swift MLX |

Evidence: [`simulator_final.txt`](../../results/window9/simulator_final.txt),
[`simulator_changed_targets.json`](../../results/window9/simulator_changed_targets.json),
[`regression_final.txt`](../../results/window9/regression_final.txt).
The earlier complete simulator run covers unchanged modules; the final targeted run covers all
modified conversation/postprocessing tests. Skips are optional recording/model tests or unavailable
Simulator speech APIs, not a substitute for real Qwen inference.

### Actual app acceptance and timing

The final app test covered ON/OFF intents, the 120 s buffer, no automatic summaries, progress,
Apple fallback identity/reason, English numbers, explicit corrections in **summary and key points**,
Continue additions and retention of unrelated facts, repetition, full summary versus preview,
Stop while ambient listening stays on, temporary context clearing, disk reopening, and OFF cancellation.
Initial tap to ready: **10.0 s** (Apple model/processing 9.93 s); Continue from new synthetic speech
to accepted update: **24.4 s** including the standard 20 s update cadence.
Largest observed main-actor heartbeat delay: **18 ms**. Stored summary: **403 characters**;
preview selection is separate. Maximum consecutive shared speech: **11 words**. App process at end:
**31 MB**, excluding the OS-managed model's memory and not representing iPhone memory.

Timeout, cooldown and recoverable engine failures are additionally exercised with scripted engines.
OFF cancellation runs in the actual app. Fatal MLX abort/OOM recovery is not proven or promised.

### Native English regression comparison

The 12 recap cases and four Continue cases were written during Window 9 development, then reused
for debugging. They are **seen regression data**, not independent held-out validation.
Every mode processes the same raw draft for each initial recap; Continue makes new real model calls
per mode because each mode supplies a different previous recap.

The complete comparison ran at `c791d4a`; subsequent `7f6c4d3` adds ambiguity flags and excludes
marked history from current evidence. Source outputs/timings are
[`native_final.json`](../../results/window9/native_final.json) and
[`native_final.txt`](../../results/window9/native_final.txt). Final scoring is in
[`native_rescored.json`](../../results/window9/native_rescored.json) /
[`native_rescored.txt`](../../results/window9/native_rescored.txt): it fixes Foundation splitting
the reserved `Superseded:` label and counts unavailable summaries as zero facts. Re-scoring makes
no model calls and does not alter any saved summary.

| Recap mode | Important facts present | Enumerated must-not violations | No recap |
|---|---:|---:|---:|
| Raw native Qwen draft | 42/44 | 0 | 0 |
| Earlier production postprocessor (`legacy`) | 17/44 | 0 | 6/12 |
| Window 9, verifier off (default) | **42/44** | 0 | **0/12** |
| Window 9, uncertain-only model verifier | 39/44 | 0 | 1/12 |

The new default preserves the measured important facts that the raw model produced, while the
old validator rejects many correct number forms/paraphrases. This table does **not** prove zero
unsupported claims. In the seen judged corpus, the new deterministic module removed **11/2059
supported units (0.5%)**, apart from 5.0% repeat/filler drops. Of **423 units containing unsupported
claims**, **43 (10.2%) were removed** and **204 (48.2%) were only flagged and retained**.
For the Qwen production subset: **4/398 supported units removed (1.0%)**; **7/77 unsupported units
removed (9.1%)**, **37/77 flagged (48.1%)**. Flagging is not hallucination removal.

Median extra processing cost: legacy **3.66 s**, new default **0.014 s**, optional verifier
**2.64 s** (maximum **6.19 s**). The verifier reduced measured recall without reducing the enumerated
recap hazards in this trial, supporting its default-off policy. Continue comparison at `c791d4a`:
default **8/9 facts with 1 enumerated hazard**, verifier **9/9 with 1 hazard** after accurate reserved-label
scoring. In that earlier run, a generic venue key point still asserted the old auditorium;
the scorer's enumerated hazards did not detect that isolated key point.

Native initial model median **5.87 s**, maximum **9.99 s** (the log's printed median selects the upper
middle sample and says 6.01 s). Default total median **5.89 s**. Cold checkpoint loading **1.97 s**;
MLX active **2.44 GB**, peak **3.38 GB** after the recap set. Builds overlapped part of this comparison;
the small isolated warm timing trial below is a separate measurement, not an iPhone projection.

The final focused four-case native Continue run uses `c7726ac`:
**8/9 facts, 0 enumerated stale-plan hazards**. Update model plus merge/rewrite cost:
**8.97 s** plan correction, **3.18 s** new facts, **1.89 s** nothing new (intentionally unchanged),
**7.27 s** double venue/price correction. Cold loading in this separate trial was **2.42 s**;
MLX active **2.44 GB**, peak **3.71 GB** after all Continue cases. These costs include conditional
rewrite attempts; the ordinary new-facts case only adds and merges.
Evidence: [`native_continue_final.json`](../../results/window9/native_continue_final.json) /
[`native_continue_final.txt`](../../results/window9/native_continue_final.txt).

The previous four-case run had one enumerated stale-plan hazard and retained an additional generic
auditorium key point. Its outputs remain in
[`native_continue_before_digest_fix.json`](../../results/window9/native_continue_before_digest_fix.json).
The final repair marks those shortened old key points `Superseded:`/unverified, while retaining
the unchanged recital time and, in a regression counterexample, a separate workshop at the same venue.
It adds no model calls. The strict recall check still misses the book-club plan distributed across
Friday/time and library sentences; inspection confirms those current details are present.
Generic model commentary such as "No other changes or uncertainties were mentioned" can still
survive a merge and become misleading. Topic binding, unsupported relations and claim-level
consistency require further independent evaluation; zero enumerated hazards is not zero hallucinations.

Separate isolated native timing trial after app/model tests and builds finished: cold loading
**1.53 s**, three warm summaries **5.64 / 5.38 / 5.37 s**, about **52–53 generated tokens/s**,
537 prompt tokens and 187 generated tokens per request. MLX active **2.44 GB**, peak **3.23 GB**.
The same weights were reused across all three requests. Evidence:
[`native_latency_final.txt`](../../results/window9/native_latency_final.txt).

## Original acceptance criteria coverage

| Original checks | Evidence / status |
|---|---|
| 1–2: native Qwen load and generation in Simulator | **Blocked**; actual native Mac execution only |
| 3: Qwen default | Production setup and scripted routing test pass; Simulator selects Apple after the explicit guard |
| 4: Apple fallback | Real app generation and saved identity/reason pass |
| 5–6: 120 s context; explicit summary requests only | Actual synthetic app test and buffer/state-machine tests pass |
| 7–10: complete recap, grounding, number equivalence, unsupported claims | App focused checks pass; native/corpus results improve retention, with documented grounding limits |
| 11–12: Continue and corrections | App focused cases pass; final native cases score 8/9 with 0 enumerated hazards; limits above remain |
| 13–16: Stop, ambient listening, History, preview separation | Actual app checks, reopened synthetic disk store and presentation tests pass |
| 17: privacy | Copy limits, storage guard, temporary clearing and data model checks pass; not a universal privacy proof |
| 18: UI responsiveness | Real Apple fallback heartbeat passes; native Qwen Simulator UI execution unavailable |
| 19: cancellation/timeouts/resources | Actual OFF cancellation and scripted cooperative timeout/failure tests pass; fatal runtime/OOM handling not validated |
| 20: existing audio/Live Activity build | Final Debug and Release Simulator builds pass |

## Interpretation and limits

- The app self-test demonstrates real Apple fallback generation, not Qwen Simulator inference.
  Coordinator/pipeline tests use scripted engines and establish routing and invariant behavior only.
- The initial weaker 25-check run passed, but inspection found stale Friday/$20 key points beside
  corrected summary prose. It was not treated as acceptance. The final test inspects all full text,
  checks retained bus/flight/cupcake facts and tests revoked payments as well as schedule corrections.
- Fact recall in the small native trial uses sentence-level alternative keyword groups. Must-not
  checks cover enumerated hazards, not every possible hallucination. No-summary results count zero
  facts. This does not replace human claim-level review.
- The 264 previously judged summaries were already seen during development. Their unit-level
  regression numbers distinguish **removed**, **flagged but retained**, and repeat/filler drops;
  flagged claims are not reported as hallucinations eliminated.
- Privacy checks allow necessary copies up to 12 words within the established aggregate limits;
  ordinary transcripts/audio are not stored. Synthetic test fixtures and output are explicitly
  synthetic. Tests cannot establish privacy for every possible natural conversation.
- Live Activity code compiles and the self-test checks its state and preview separation. Real
  iPhone Lock Screen/Action Button/background behavior is not validated by Simulator.
- MLX OOM/process abort recovery, real-device model installation, old SwiftData store migration,
  long conversations and physical-device latency remain unvalidated.

The Window 9 task's native-Qwen-in-Simulator criterion therefore remains unmet even when the
available fallback workflows pass. Completed implementation and evidence are committed on the
isolated branch for review; no merge or deployment was performed.
At final handoff, `git status --porcelain` is empty in the Window 9 worktree. Generated build
caches and ignored coverage output are outside versioned changes; other worktrees were not edited.
