# Window 9 — native CPU runtime and validation

2026-10-13/14. Branch `feature/window9-summary-postprocessing`; all inputs in this phase are
synthetic English. Mac and iOS Simulator only. No physical iPhone access or microphone capture.

This report retains the original Simulator phase. The separately authorized October 14 iPhone
repair/install phase is documented in [Window 9 iPhone validation](WINDOW9_IPHONE_VALIDATION.md).
Its native Metal inference and functioning phone Apple fallback supersede the deployment blockers
for that tested phone; the Mac/Simulator Apple catalog failure remains environment-specific.

## Native Qwen Simulator runtime

The previous stock-runtime Metal blocker is resolved through a maintained native CPU adapter.
The upstream runtime's
[troubleshooting documentation](https://github.com/ml-explore/mlx-swift/blob/0.32.3/Source/MLX/Documentation.docc/troubleshooting.md)
states that Simulator lacks MLX's required Metal GPU family features; this adapter does not
claim to provide those GPU features.

Observed failures in the stock runtime:

- Normal launch: fatal C++ exception in `mlx::core::metal::Device::Device`, constructing an
  architecture name from a null Simulator device value.
- A targeted `MLX_METAL_GPU_ARCH=applegpu_g13s` trial (the Mac's architecture) progressed further
  but aborted in `MTLSimDevice newHeapWithDescriptor`: `MTLStorageModePrivate is required for heaps`.
  MLX uses shared Metal heaps. This confirms that an architecture override is insufficient.

The adapter uses real upstream CPU buffers, events and fences, disables Simulator GPU discovery,
and selects the existing gated delta operations instead of its custom Metal kernel. A native
affine 4-bit/group-64 helper accelerates prefill and packed-weight decode without substituting
the checkpoint or responses. Simulator-only compilation guards preserve the Mac/device Metal
path. See [`runtime_patches/README.md`](../../tools/runtime_patches/README.md).
Eight Simulator runtime tests pass, including exact matrix values and independent unpacked-weight
references. Runtime source provenance is in
[`runtime_cpu_provenance.json`](../../results/window9/runtime_cpu_provenance.json).

A genuine in-process Simulator probe loaded the cached checkpoint and parsed an English recap
(113 characters, two key points; 516 prompt tokens and 83 generated tokens). Its 116 s measured
request was instrumented with a process stack sample and recorded a 3.39 s heartbeat gap.
That instrumented run is not accepted as UI responsiveness evidence; the app walk-through and
clean probe below run without stack sampling or competing builds.

An October 14 probe was interrupted by host Idle Sleep and Maintenance Sleep (confirmed in
`pmset`): it still generated the same real recap, but its 499 s wall time and 255 s heartbeat
gap are not normal inference/UI measurements. The interrupted report is preserved in
[`simulator_cpu_probe_sleep_interrupted.txt`](../../results/window9/simulator_cpu_probe_sleep_interrupted.txt).
Subsequent measurements keep the Mac awake with a temporary bounded `caffeinate -i` assertion;
no global power setting is changed.

## Environment and commands

Apple M1 Max Mac, 32 GB RAM, Xcode/SDK 27.0; iPhone 18 Pro Max Simulator (`iPhone19,3`, iOS 27.0),
UUID `7BD3EAF0-49F4-4924-A51F-F51AA44E16A7`.
Qwen model/revision and dependency versions are in
[`QWEN35_HEARING_SENSE_INTEGRATION.md`](../research/QWEN35_HEARING_SENSE_INTEGRATION.md).

```sh
python3 tools/prepare_qwen_runtime.py --checkouts /Users/vicwei/Library/Developer/Xcode/DerivedData/HearingSense-atnppvsqqyobzydcyysiplnfhywb/SourcePackages/checkouts
xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense \
  -configuration Debug -destination 'platform=iOS Simulator,id=7BD3EAF0-49F4-4924-A51F-F51AA44E16A7' \
  -toolchain org.hearingsense.toolchain.metalswift -derivedDataPath /private/tmp/hs-w9-cpu-app \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
# Repeat with -configuration Release for the shipping configuration.
xcrun simctl install 7BD3EAF0-49F4-4924-A51F-F51AA44E16A7 \
  /private/tmp/hs-w9-cpu-app/Build/Products/Debug-iphonesimulator/HearingSense.app
xcrun simctl launch --terminate-running-process --console-pty \
  7BD3EAF0-49F4-4924-A51F-F51AA44E16A7 org.hearingsense.HearingSense \
  --hs-w9-selftest --hs-w9-persist --hs-w9-expect qwen --hs-test-mode off
# Actual Apple fallback with a deliberately absent Qwen checkpoint:
xcrun simctl launch --terminate-running-process --console-pty \
  7BD3EAF0-49F4-4924-A51F-F51AA44E16A7 org.hearingsense.HearingSense \
  --hs-w9-selftest --hs-w9-persist --hs-w9-expect fallback --hs-engine qwen-missing --hs-test-mode off
# Direct native checkpoint/protocol/heartbeat probe (in-memory store):
xcrun simctl launch --terminate-running-process --console-pty \
  7BD3EAF0-49F4-4924-A51F-F51AA44E16A7 org.hearingsense.HearingSense \
  --hs-w9-runtime-probe --hs-test-mode off
# Audit the actual saved synthetic result after an acceptance-assertion repair:
# This does not perform model inference and cannot open the ordinary History store.
xcrun simctl launch --terminate-running-process --console-pty \
  7BD3EAF0-49F4-4924-A51F-F51AA44E16A7 org.hearingsense.HearingSense \
  --hs-w9-audit-synthetic-history --hs-w9-persist --hs-test-mode off
```

The Debug self-test replaces microphone input with synthetic utterances and exercises the real
app object graph, App Intents, coordinator, actual selected model, postprocessor and SwiftData. Its report
contains only state, counts, timings and model labels. `--hs-w9-persist` uses an isolated
`Window9SyntheticHistory` folder, never the normal History store. Without that flag the self-test
uses an in-memory store. A reopened store checks full summary, key points, engine label and status.

## Final results

Clean native CPU runtime probe on October 14: **3/3 checks passed**. Cold checkpoint load
**4.0 s**, request including load **116.5 s**, 516 prompt / 83 generated tokens,
**2.30 generated tokens/s**, main-actor maximum gap **251 ms**. MLX active **2.44 GB**, peak
**3.03 GB**; these counters exclude the native helper's temporary vectors and other process
memory. The Mac was kept awake, with no competing builds or process stack sampling.
Evidence: [`simulator_cpu_probe.txt`](../../results/window9/simulator_cpu_probe.txt).

Earlier implementation: **`c7726ac3e88aab9da1db4f991087ff3ef952f606`**, following **`7f6c4d3`**
(ambiguous time/history evidence) and **`c791d4a`** (completed pipeline and safe fallback).
The measured evidence and handoff documentation are committed subsequently on the same
branch; `git log -1` identifies the final handoff commit.

Runtime continuation: **`171b12408bc9ea26cd6ca6c80f8a28a92cb0bb37`** (genuine Simulator CPU
runtime), **`eb52d5b`** (generic commentary cleanup), **`02f3b9c6a6b4f671802bc01d4da28c9999e9c5a3`**
(typed numeric acceptance and a stronger, clause-bound revoked-payment check).
Final acceptance/audit source: **`ef379390b3adcc8242b8ef04efacd419043bfd22`**.
The October 13 CPU app walk-through recorded 25 passes and two assertion failures: actual text
contained `twenty-four`, but the assertions required `24`/`twenty four`. It genuinely used Qwen
with no fallback; initial recap 213.3 s, Continue 383.4 s, main-actor gap 71 ms. The original
report is preserved in
[`simulator_cpu_before_number_assertion_fix.txt`](../../results/window9/simulator_cpu_before_number_assertion_fix.txt).
The assertion fix does not change model output or postprocessing. Its ticket-payment check
adds five counterexamples, including cancellation of an unrelated bus alongside a current price.

The subsequent real Qwen workflow completed **27/28 checks**. Its only failed assertion did not
recognize the valid key-point wording `cancelling the need to bring twenty dollars`, and then
revealed that rendered bullet prefixes interfered with historical framing. The final repair
checks raw summary/key-point fields, accepts that exact bound cancellation and expands the
counterexamples to seven. Production model and postprocessing output were unchanged.
An in-app audit of the **same saved genuine Qwen record passed 5/5 checks**, including the
number and all payment claims. Missing `--hs-w9-persist` produces the expected guard refusal
before any disk store is opened. This is assertion replay, **not a fresh 28/28 model run**.
Evidence: [`simulator_cpu_before_cancellation_assertion_fix.txt`](../../results/window9/simulator_cpu_before_cancellation_assertion_fix.txt),
[`simulator_cpu_saved_output_audit.txt`](../../results/window9/simulator_cpu_saved_output_audit.txt),
[`simulator_cpu_audit_guard_refusal.txt`](../../results/window9/simulator_cpu_audit_guard_refusal.txt).
The first failed replay remains in
[`simulator_cpu_audit_before_field_fix.txt`](../../results/window9/simulator_cpu_audit_before_field_fix.txt).

| Check | Result |
|---|---|
| Complete Mac HearingSenseKit suite, latest core source | **663 passed, 9 skipped, 0 failures** (672 registered; unchanged by the runtime/Debug assertion commits) |
| Qwen package locator tests, Mac | **2 passed**, no model inference in these tests |
| Complete package in Simulator, before final edge fixes | **650 passed, 10 skipped, 0 failures** |
| Latest changed targets in Simulator | **218 passed, 0 skipped, 0 failures** (101 postprocessing, 117 conversation tests) |
| Native CPU QwenRuntime tests in Simulator | **8 passed, 0 failures**, including packed quantization and independent affine references |
| Actual Qwen default app workflow | **27/28**; sole assertion false positive repaired and the same actual saved output audited **5/5**; not relabeled as new inference |
| Final Debug and Release app builds | **Both succeeded**, including existing audio and Live Activity targets |
| Running app, actual Apple fallback + production pipeline | **Earlier 27/27 passed**; October 14 system model unavailable, current revalidation does not pass |
| Qwen selected in production setup | **Yes, actual primary**; CPU app recap and Continue report Qwen, no fallback |
| Real native Qwen Simulator inference | **Passed**: real cached checkpoint loaded and English recap parsed in the app |
| Real native Qwen on Mac | **Passed**, exact cached checkpoint through Swift MLX |

Evidence: [`simulator_final.txt`](../../results/window9/simulator_final.txt),
[`simulator_changed_targets.json`](../../results/window9/simulator_changed_targets.json),
[`regression_final.txt`](../../results/window9/regression_final.txt).
Latest core/runtime count observations:
[`regression_cpu_runtime.txt`](../../results/window9/regression_cpu_runtime.txt).
The earlier complete simulator run covers unchanged modules; the final targeted run covers all
modified conversation/postprocessing tests. Skips are optional recording/model tests or unavailable
Simulator speech APIs, not a substitute for real Qwen inference.

### Actual app acceptance and timing

Latest actual Qwen CPU recap: **212.9 s** tap to ready (model/processing 212.75 s), main-actor gap
**84 ms**, stored summary **592 characters**, separate preview **76 characters**. Continue and
Stop preserved an **827-character** final summary plus ten key points, with maximum shared speech
**11 words**. End-of-test process footprint was **2528 MB**, sampled two seconds after OFF;
this is not evidence that asynchronous native cancellation had already freed all model memory.
Its **870.7 s** Continue wall time includes host sleep (power logs show sleep/wake during the run)
and is not a normal warm inference figure. The earlier uninstrumented CPU walk-through measured
**383.4 s** speech-to-update, including cadence/conditional rewrite. Neither is an iPhone estimate.
Simulator CPU development has a 600 s per-primary-request budget; native cancellation is cooperative.

Final source builds: **Debug ARM64 and Release ARM64 + x86_64 succeeded**, including audio and
Live Activity targets. The universal Release app bundle is **105 MiB** (Debug 88 MiB), holding
no multi-gigabyte Qwen checkpoint. Detailed build observations are in
[`builds_cpu_runtime.txt`](../../results/window9/builds_cpu_runtime.txt).

October 14 Apple revalidation: the coordinator records `qwen_model_not_installed`, then attempts
the real Apple engine once. Apple throws `failure_NSError`; no summary is saved and the app
shows the unavailable state. Simulator system logs report `com.apple.UnifiedAssetFramework`
code 5000 (no model-catalog assets) and `Simulator is not supported`. A separate native Mac
`SystemLanguageModel.default` probe reports **`deviceNotEligible`**. This is a current environment
failure, not a successful Apple generation. The host build changed from macOS 27.2 `26B5101f`
to `26B5112a`; only the iOS 27.0 runtime is installed. No replacement OS/model download,
Apple Intelligence setting change or physical-device test was performed.
Evidence: [`simulator_cpu_fallback_catalog_failure.txt`](../../results/window9/simulator_cpu_fallback_catalog_failure.txt)
and [`apple_environment_20261014.txt`](../../results/window9/apple_environment_20261014.txt).
Apple's [DTS guidance](https://developer.apple.com/forums/thread/787445) explains that Simulator
uses the host's Apple model and requires eligible Apple Intelligence and matching OS versions.
These checks explain why the current fallback environment needs restoration; they do not prove
which host eligibility condition caused this particular failure.

The earlier Apple app test covered ON/OFF intents, the 120 s buffer, no automatic summaries, progress,
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

The earlier focused four-case native Continue run uses `c7726ac`:
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
The subsequent `eb52d5b` repair removes bounded generic source commentary from new drafts and
inherited Continue summaries, while preserving substantive uncertainty, prohibitions, missing
speech notices and necessary short quotations. A fresh native Mac run with the local runtime
exports preserved **9/9 enumerated facts, 0 enumerated hazards** across those four seen cases.
Three updates applied; the chatter case intentionally retained the prior recap without an update
(the evaluator's `no-summary 1` counter here denotes that expected no-op, not a missing recap).
Model update plus conditional merge/rewrite costs were **9.72 / 3.41 / 2.30 / 8.88 s**;
load **1.52 s**, MLX active **2.44 GB**, peak **3.69 GB**. A build overlapped this trial, so these
are not isolated performance measurements. Evidence:
[`native_continue_cpu_adapter.json`](../../results/window9/native_continue_cpu_adapter.json) /
[`native_continue_cpu_adapter.txt`](../../results/window9/native_continue_cpu_adapter.txt).
Topic binding, unsupported relations and claim-level consistency still require further independent
evaluation; zero enumerated hazards is not zero hallucinations.

Separate isolated native timing trial after app/model tests and builds finished: cold loading
**1.53 s**, three warm summaries **5.64 / 5.38 / 5.37 s**, about **52–53 generated tokens/s**,
537 prompt tokens and 187 generated tokens per request. MLX active **2.44 GB**, peak **3.23 GB**.
The same weights were reused across all three requests. Evidence:
[`native_latency_final.txt`](../../results/window9/native_latency_final.txt).

## Original acceptance criteria coverage

| Original checks | Evidence / status |
|---|---|
| 1–2: native Qwen load and generation in Simulator | **Passed**, real cached checkpoint and English recap in the app with native CPU execution |
| 3: Qwen default | **Passed**, actual Simulator recap and Continue use Qwen without a fallback reason |
| 4: Apple fallback | Earlier actual 27-check generation pass; current host eligibility/model-catalog failure prevents fresh Apple generation |
| 5–6: 120 s context; explicit summary requests only | Actual synthetic app test and buffer/state-machine tests pass |
| 7–10: complete recap, grounding, number equivalence, unsupported claims | App focused checks pass; native/corpus results improve retention, with documented grounding limits |
| 11–12: Continue and corrections | Actual Qwen CPU app updates; latest Mac seen cases score 9/9 with 0 enumerated hazards; limits above remain |
| 13–16: Stop, ambient listening, History, preview separation | Actual app checks, reopened synthetic disk store and presentation tests pass |
| 17: privacy | Copy limits, storage guard, temporary clearing and data model checks pass; not a universal privacy proof |
| 18: UI responsiveness | Native CPU probe **251 ms** maximum gap; actual initial app recap **84 ms**; interrupted host-sleep periods excluded from normal performance interpretation |
| 19: cancellation/timeouts/resources | Actual OFF cancellation and scripted cooperative timeout/failure tests pass; fatal runtime/OOM handling not validated |
| 20: existing audio/Live Activity build | Final Debug and Release Simulator builds pass |

## Interpretation and limits

- The CPU app tests demonstrate real Qwen inference; earlier Apple tests demonstrate actual
  fallback generation in the earlier environment. Current Apple generation is not passing.
  Coordinator/pipeline unit tests use scripted engines and establish routing/invariants only.
- The initial weaker 25-check run passed, but inspection found stale Friday/$20 key points beside
  corrected summary prose. It was not treated as acceptance. The final test inspects all full text,
  checks retained bus/flight/cupcake facts and tests revoked payments as well as schedule corrections.
- Fact recall in the small native trial uses sentence-level alternative keyword groups. Must-not
  checks cover enumerated hazards, not every possible hallucination. No-summary results count zero
  facts. This does not replace human claim-level review.
- The fixed $20 acceptance check covers raw summary/key-point claims, not titles/caveats or
  arbitrary payment paraphrases. Bare meeting-time evidence does not establish a model-added PM
  qualifier; such a qualifier remains unverified, even when the underlying clock value matches.
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

The native-Qwen-in-Simulator criterion is now met. The current host's Apple eligibility/catalog
failure remains a revalidation limitation, so do not claim all original acceptance criteria are
green in the October 14 environment. Implementation and evidence are committed on the isolated
branch for review; no merge or deployment was performed.
At final handoff, `git status --porcelain` is empty in the Window 9 worktree. Generated build
caches and ignored coverage output are outside versioned changes; other worktrees were not edited.
