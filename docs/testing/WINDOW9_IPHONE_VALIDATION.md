# Window 9 — authorized iPhone installation and native validation

2026-10-14 (America/Denver). The student's new instruction to repair and install on the connected
iPhone superseded the earlier Simulator-only scope for this phase. Tests use fixed synthetic English
from `Window9SelfTest`, never microphone audio or ordinary conversations. No merge or push.

Device: iPhone 18 Pro (`iPhone19,2`), iOS 27.2 (`24B5110a`). Device identifiers, account details,
provisioning profiles and complete system logs remain outside Git.

Validated source commit: `c33804a04c71ca6e0ec05bef388e6aaafe31dd69`, branch
`feature/window9-summary-postprocessing`. Both final native workflows pass **28/28**. The final
Release build is installed in place and launches successfully; bundle size 56,239,639 bytes
(about 54 MiB), with the ~3 GB checkpoint kept outside the bundle. Debug aids are excluded from
Release. Native walkthrough evidence comes from Debug; Release is separately build/install/launch
evidence, not a repeated Release-mode inference test. Microphone use was never started.

## Deployment and runtime correction

The exact existing `mlx-community/Qwen3.5-4B-MLX-4bit` revision
`32f3e8ecf65426fc3306969496342d504bfa13f3` was materialized from the Mac cache and transferred by
cable. No model download, training, conversion, hosted service or app-bundle weights were added.
The phone verified 13 regular files / 3,061,133,243 bytes against the SHA-256 manifest before
atomically activating the revision directory under Application Support. The model directory is
excluded from backup. The installer rejects corruption, symlinks, unlisted files and an unknown
existing target; it never overwrites History or settings. Six native synthetic installer checks pass.
Checksums ensure this cable transfer's integrity; they are not signed remote-update authentication.

The first genuine Metal load was killed by iOS (`signal 9`). The contemporaneous system report
identifies HearingSense as frontmost with `per-process-limit`, at 216,136 resident 16-KiB pages
(about 3.54 GB). This was an actual failure, not a model-availability assertion.

Fixes: the app requests Apple's Increased Memory Limit capability, and the physical-device MLX
allocator cache is capped at 64 MiB before loading. The student explicitly approved updating this
app's developer capability/profile and logged into Xcode; the rebuilt signed app contains the
entitlement. A fresh cold load also refuses insufficient iOS process headroom (3.6 GB, based on the
measured MLX peak plus overhead), allowing the coordinator to attempt Apple rather than knowingly
enter a jetsam-prone load. This snapshot check cannot guarantee immunity to later memory pressure.
The entitlement follows [Apple's documented capability](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
and the [upstream MLX example](https://github.com/ml-explore/mlx-swift-examples/blob/main/Applications/MLXChatExample/MLXChatExample.entitlements).

Native runtime remains mlx-swift-lm 3.32.3 / mlx-swift 0.32.3 / swift-transformers 1.3.5, affine
4-bit/group 64. Device execution uses native Metal; Simulator CPU adapters are compile-time gated.
The corrected native phone probe passes 3/3: load 1.858 s; total request 8.990 s; 516 prompt / 83
generated tokens; 41.17 generated tokens/s; main-actor gap 10 ms; MLX active 2,444,750,532 bytes,
peak 3,034,562,212 bytes. MLX counts are not the entire process footprint or OS-managed Apple model.

## Actual-output postprocessing fixes

The first phone Apple fallback run passed 26/28, exposing a stale $20 instruction and a 14-word
source passage. Its lowercase sentence starts caused Foundation to group unrelated claims.
Explicit English sentence stops now isolate corrections; embedded and inherited >12-word copies
must pass bounded, fact-preserving restatement. Rewrites use that same path. Final-save checks
cover summary and all key points, including joins, independently of aggregate copied share.
Six fixed-phone-fixture regressions and a low-share/embedded-copy save regression cover these issues.
The existing short-copy tests use a safely paraphrased surrounding draft so they continue testing
the original short-copy contract without also introducing the newly identified unsafe long passage.

The first repaired Qwen workflow passed 27/28: its sole failure inspected all prior synthetic History
records, including the earlier failed Apple record. The harness now requires a newly created record
ID and examines that run's completed record. Earlier failed records/reports remain intact. A new
running-app walkthrough is required; this harness edit does not retroactively turn 27/28 into 28/28.

Final core Mac checks: 685 registered, 676 passed, 9 opt-in/unsupported skips, no failures.
These deterministic/scripted tests prove policies and wiring; native model evidence is separate.

The rebuilt final Debug app then completed a **fresh 28/28 Qwen walkthrough** on the phone. Qwen
was the actual default generator, without fallback. Tap-to-ready 7.7 s; longest main-actor gap 3 ms;
Continue 32.7 s from speech injection, including the 20 s update cadence; final saved summary 828
characters. The new record's longest source-word run was 9 words. Dates, free-ticket correction,
unrelated flight/bus/cupcake facts, full History/disk reopen, preview separation and OFF cancellation
all passed. End process footprint was 585 MB after resource release, not its peak.

After the final shared postprocessing changes below, the **same final Debug binary was rerun with
Qwen and again passed 28/28**: initial recap 8.6 s, Continue 33.9 s including cadence, main-actor gap
6 ms, final summary 828 characters, longest source run 9 words, end footprint 587 MB after release.
`results/window9/phone_qwen_final.txt` holds this latest run; the earlier measurements above describe
the preceding successful run, not a new independent factual benchmark.

A subsequent genuine Apple run passed 25/28: the hard copy limit correctly prevented long copying,
but the old Apple restatement instructions merely requested a speaker prefix, losing the cupcake
quantity when that unsafe answer was rejected. Its free-ticket wording was correct; the fixture's
payment assertion did not yet recognize the explicit `no need for [the] amount` clause without
punctuation before the next topic. Apple's prompt/structured-output guide now demand actual
reordering with every fact/qualifier preserved, equivalent numerical spellings permitted, and no
invented speaker. The assertion additionally checks unconditional, whole-clause waivers while
rejecting wrong-topic, conditional and double-negated controls. The 25/28 report remains evidence;
these changes require another genuine walkthrough, not rescoring that report.

The next phone run passed 26/28: payment and copy-limit checks passed, but both quantity-retention
checks still failed. A separate Debug-only probe, operating exclusively on the immutable fixed
fixture/static caveat, captured Apple's actual raw draft and restatement answers. The draft contains
the cupcake quantity; both rewritten answers simply repeat it verbatim despite the revised prompt.
That confirms real postprocessing loss after an unsafe model answer, not an absent model fact or
another spelling assertion. The fixed synthetic evidence is `results/window9/phone_apple_draft_echo.json`.
This probe never accepts dynamic transcript input or reads captions/History; its artifact is separate
from ordinary diagnostics, and it does not exist in Release builds.

The final bounded correction formats a uniquely located, unquoted two-word tens-plus-unit integer
using the normalizer's existing typed readings/tables. Other numeric kinds, identifiers, literal
quotes, repeated/ambiguous spans and temporal contexts are excluded. It is eligible only for an
already-overlong source run: it cannot bypass short-copy count/adjacency limits. Every candidate
must still pass the ordinary numerical/negation/content, grounding, whole-copy, consecutive-copy
and aggregate-copy checks. Only the number's spelling changes, e.g. words to digits; names, units
and qualifiers stay untouched. Diagnostics record `formatted_cardinal`. Larger/unsupported forms
retain the bounded model-restatement/failure path. This avoids the observed Apple echo without
extra inference or a fixture-specific replacement dictionary.

**Fresh final Apple fallback: 28/28 pass.** Actual Apple identity and missing-Qwen reason are
recorded; no Qwen output is fabricated. Tap-to-ready 3.9 s; main-actor gap 3 ms; Continue 24.7 s
including cadence; final stored summary 575 characters; longest source run 12 words. Quantity,
unrelated facts, corrected dates/payment, disk reopen, full-summary/preview separation and clean
cancellation all pass. Process footprint after release 23 MB excludes Apple's system-managed model.
See `results/window9/phone_apple_final.txt`; all earlier failed native reports remain intact.

## Reproduction

Use the pinned source preparation in `tools/prepare_qwen_runtime.py` and the existing custom Metal
toolchain. Build on the authorized development team, using a locally selected connected destination:

```sh
xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense \
  -configuration Debug -destination "platform=iOS,id=$PHONE_UDID" \
  -toolchain org.hearingsense.toolchain.metalswift -derivedDataPath /private/tmp/hs-w9-phone \
  -disableAutomaticPackageResolution
```

Developer-account updates require separate explicit authorization; do not add
`-allowProvisioningUpdates` merely to evade a signing error. The student authorized it in this run.
Prepare the payload with `tools/prepare_cached_qwen_payload.py`, copying only into the reserved
`.incoming-<revision>` folder in the app's model root. Launch Debug with `--hs-w9-install-cached-model
--hs-test-mode locked --hs-synthetic-capture` and read the named model-install report before inference.
Do not overwrite a verified existing revision or export ordinary History.

Native probe arguments: `--hs-w9-runtime-probe --hs-test-mode locked --hs-test-allow model
--hs-test-session-limit 600 --hs-synthetic-capture`.
Full test: replace the probe flag with `--hs-w9-selftest --hs-w9-persist --hs-w9-expect qwen`.
Forced fallback: additionally `--hs-engine qwen-missing`, with `--hs-w9-expect fallback`.
These permit inference only: microphone/transcription remain prohibited. Synthetic disk records
use `Window9SyntheticHistory`, never the ordinary store. The test temporarily disables auto-lock
and restores it at completion; Metal inference must stay foregrounded. Release excludes test aids.

## Remaining limits

This is a small seen synthetic regression, not independent English factual-accuracy validation.
No real microphone/transcription, lock-screen/background Metal inference, thermal/endurance,
low-memory pressure injection or migration from every historical store schema was tested.
The ordinary app data was preserved by an in-place update; no uninstall/reset occurred.
The automatic review rejected exporting the pre-existing private History backup. That export was
not retried; only named new synthetic reports/store and the current memory-failure diagnostics were read.
Production delivery still needs a user-facing download/removal and storage-budget policy. The cable
installer is an explicit development workflow, not an automatic multi-GB background download.
