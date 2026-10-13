# Window 9 — native Qwen integration

2026-10-13. Branch `feature/window9-summary-postprocessing`, worktree `.claude/worktrees/window9`.
Continued from Claude's `09db91f`; the `03f5802` snapshot already includes Window 8 UI work.
Other worktrees were left alone. Nothing was merged, pushed, installed on, or run on a physical iPhone.

## Status

Qwen is the configured primary engine. Real Qwen summaries run through the native Swift MLX
implementation on the Mac. **They do not run in iOS Simulator**: the pinned MLX runtime requires
Metal features that Simulator does not provide. The app detects this before MLX initialization
and uses Apple's on-device model with `qwen_simulator_runtime_unsupported` recorded as the fallback reason.
The user's native-Qwen-in-Simulator completion criterion remains blocked; this is not a completed
Qwen simulator deployment. The Mac executable is an evaluation tool, never an inference service for the app.

## Verified checkpoint and runtime

| Item | Value |
|---|---|
| Model | `mlx-community/Qwen3.5-4B-MLX-4bit` |
| Cached revision | `32f3e8ecf65426fc3306969496342d504bfa13f3` |
| Architecture | `qwen3_5`, `Qwen3_5ForConditionalGeneration`; text config `qwen3_5_text`, 32 hybrid linear/full attention layers |
| Quantization | 4-bit affine, group size 64; source config dtype bfloat16 |
| License | Apache 2.0, as declared in the cached model card |
| Chat template | Cached tokenizer/template; `enable_thinking: false`, greedy temperature 0 |
| Runtime | mlx-swift-lm **3.32.3**, mlx-swift **0.32.3**, swift-transformers **1.3.5** |
| Dependencies | App and Qwen package `Package.resolved` committed; no Python inference in the app |

`MLXLLM/LLMModelFactory.swift` registers `qwen3_5` and `qwen3_5_text`.
`MLXLLM/Models/Qwen35.swift` implements the text model and strips vision tensors from this
multimodal checkpoint when used for text. This is the requested checkpoint, not a substitute model.
The already cached checkpoint is about 2.9 GB including vision weights. No new weights were downloaded
during the Codex continuation, and none are in Git or the app bundle.

## Execution and routing

`QwenRuntime` isolates MLX dependencies from `HearingSenseKit`. `QwenSummarizationEngine` owns a
reusable model container in an actor and creates a fresh chat session per request. The tokenizer
reads local files; the engine does not download or send speech anywhere. The model and runtime
identity are available in diagnostics, including the full cached revision. A manually installed
folder whose name is not a snapshot hash reports revision `unknown`; it does not pretend to be verified.

`SummarizationCoordinator` prefers Qwen and tries Apple once after an unavailable engine or a
recoverable Swift initialization/inference error or timeout. Primary/fallback limits are 40/25 s;
after two primary failures, a five-minute cooldown prevents repeated initialization failures.
The app's outer initial request limit allows both attempts (66 s). Timeouts use cooperative
cancellation: an uncooperative native call can delay return. Fatal C++ assertions and process OOM
cannot be recovered by a Swift `catch`; Simulator is guarded specifically to prevent its known abort.
There is no claim of validated physical-device resource-exhaustion behavior.

Drafts carry their actual engine and fallback reason. Saved records have optional `engineLabel`
and `fallbackReason`, permitting old records without these fields. Apple is identified by the public
`SystemLanguageModel.default` API; the API does not expose a fixed weight revision or an AFM 3 Core
identifier. Production never routes to a cloud model.

The model is prepared when sufficient speech is buffered, without generating a summary, reused
across requested summaries, and released after 180 s of idle time or when listening is switched off.
Normal speech does not initiate a recap. Actor execution and async model streaming keep the main
actor free; simulator heartbeat results are in the validation report.

Apple recap/update/rewrite now use the shared plain JSON protocol. Schema-constrained recap
generation threw `ParsingError` in this OS 27 Simulator; plain JSON succeeded. Every parsed answer
still passes the production grounding, quality and privacy checks. Optional Apple restatement and
verification still use schema generation and may fail safely.

## Pipeline and Continue

The default postprocessor separates typed English normalization, clause-level evidence checks,
slot-specific correction resolution, copying limits, and quality editing. See
[`W9_POSTPROCESSING_DESIGN.md`](W9_POSTPROCESSING_DESIGN.md) for code boundaries and limitations.
Only clear contradictions are removed deterministically; uncertain relations/paraphrases are
retained and counted as unverified. This is a conservative lexical system with typed values,
not a general semantic entailment model. A kept claim is not necessarily verified.
An added AM/PM qualifier with only bare-time evidence stays unverified (`time_qualifier_added`);
the compatible clock fact is preserved. Retained compound outdated statements are visibly
marked `Superseded:` and cannot supply current evidence or strong duplicate coverage in later merges.
Shorter old key points linked to that compound's corrected slot receive the same visible history
and uncertainty label; unchanged slots and separately named unrelated events remain current.
A generated explicit venue pair can provide this historical link only after the compound was
already marked superseded; it never independently establishes a replacement fact.

Continue asks for an addition after meaningful new speech and a pause (minimum 20 s between
updates), then merges it. A complete rewrite is requested only when a correction cannot be merged
without losing an earlier fact. The rewrite must preserve each previous statement's own values,
content/relation stems and polarity, allowing only the explicitly corrected slot to change.
This conservative retention check may reject valid paraphrases. Full summaries and key points
remain distinct from the Dynamic Island preview; Stop saves the complete result and clears
temporary speech while ambient listening continues.

The second-stage model verifier is **off by default**. The optional `uncertainOnly` policy makes
one batched evidence request, with an 8 s limit. Missing, malformed or timed-out verdicts leave
statements unverified. Unknown/duplicate JSON verdicts are not interpreted as rejection.
Real benefit and cost are measured in the validation report rather than inferred from mocks.

## Reproduce with the existing cache

From this worktree:

```sh
swift test --package-path packages/HearingSenseKit
cd packages/QwenRuntime
xcodebuild build -scheme hs-qwen-eval -configuration Release \
  -destination 'platform=macOS' -toolchain org.hearingsense.toolchain.metalswift \
  -derivedDataPath /private/tmp/hs-w9-eval -disableAutomaticPackageResolution
cd ../..
/private/tmp/hs-w9-eval/Build/Products/Release/hs-qwen-eval fresh \
  --modes legacy,window9,window9_verified --texts --json /private/tmp/w9-fresh.json
/private/tmp/hs-w9-eval/Build/Products/Release/hs-qwen-eval latency --runs 3
# Re-score existing synthetic native outputs without another model run:
/private/tmp/hs-w9-eval/Build/Products/Release/hs-qwen-eval rescore \
  --input results/window9/native_final.json --json /private/tmp/w9-rescored.json
# Focus a new trial on Continue without repeating the recap comparison:
/private/tmp/hs-w9-eval/Build/Products/Release/hs-qwen-eval fresh --only-continue --modes window9
```

The installed local toolchain is `~/Library/Developer/Toolchains/HSMetalSwift.xctoolchain`
(`org.hearingsense.toolchain.metalswift`). Claude installed the Metal tools before this continuation;
the system default `xcrun metal` still needs the explicit toolchain. The setup script is preserved
as provenance; do not rerun a toolchain download when the installed toolchain suffices.
`QwenModelLocator` checks the explicit `--hs-qwen-model-dir` / `HS_QWEN_MODEL_DIR`, app Application
Support, then the exact host Hugging Face snapshot on Mac/Simulator. This host cache strategy does
not overcome MLX's Simulator GPU limitation.

## Eventual iPhone requirements

No physical-device validation was authorized or performed. A future separately authorized phase needs:

1. A supported Apple GPU/device and genuine device execution of this exact checkpoint.
2. Model delivery outside the app bundle: atomic installation, space checks, shard completeness,
   model revision/checksum manifest, license attribution and a user-visible download/removal policy.
3. Measured cold/warm latency, memory pressure, thermal behavior, background operation and cancellation
   on that device. Mac and Simulator timings are not iPhone estimates.
4. An actual old-store SwiftData migration test; adding optional fields is compatible in intent,
   but the new synthetic store does not prove migration from every older schema.
5. More independent English evaluation of attribution, pronouns, arbitrary venue names, correction
   chains and unsupported relations. Generic venue key points whose topic is ambiguous can remain
   as visibly uncertain history, and general relation checks remain lexical. Both current corpora are
   regression material used during development.

Changing to Core ML would require a separate verified conversion of this hybrid architecture;
it is not a way to relabel Mac/Python output as successful native Simulator inference. No conversion,
fine-tuning, training or additional model download was undertaken.
