# Hearing Sense — project rules for agents

Hearing Sense iOS 2.0: an iPhone app that keeps people wearing noise-cancelling headphones aware of
their surroundings, fully on device. Read `README.md`, then `docs/PRODUCT_ARCHITECTURE_FINAL.md` and
the top of `docs/PROJECT_HANDOFF.md`.

## Repository

- `main` is the only branch and holds Window 9. Older work is in the `archive/*` tags. Documents
  written before 2026-11-08 name branches and `.claude/worktrees/...` folders that no longer exist.
- Remote: `origin` = `github.com/Vicsbank/HearingSense` (private). Commit and push only when the
  student asks.
- Not in Git: `data/`, the Qwen checkpoint, `packages/RuntimeDependencies/` (patched MLX sources,
  from `tools/prepare_qwen_runtime.py`), build folders and `.venv/`.

## Hard constraints

- **No model training or fine-tuning** without a separate approval request (model and dataset, M1 Max
  time estimates, resources, expected benefit, checkpoint plan, the student's maximum time).
  Forward-only inference, evaluation and model inspection are allowed.
- The Mac (M1 Max, 32 GB) is the student's daily school computer: no long or background workloads
  without approval; large downloads need approval with sizes shown.
- Do not delete, move or overwrite research assets (`models/`, `results/`, `data/`, `docs/` reports,
  `ml/`, `src/`, `tools/`).
- Do not fabricate results. Label evidence as Mac, Simulator or physical iPhone; never claim device
  validation from the Simulator.
- No access to the physical iPhone, and no microphone recording or transcription of real
  conversations, without the student's authorization in chat.
- Apple-native frameworks first; no new third-party dependencies without a reason.
- Communicate with the student in Chinese; code, comments and docs in English.

## Privacy

No audio is stored or uploaded. Raw transcript text never goes to logs, diagnostics, exports,
committed fixtures or reports; use synthetic sentences in tests.

## Build and test

```bash
cd packages/HearingSenseKit && swift test
xcodebuild build -project apps/ios/HearingSense.xcodeproj -scheme HearingSense -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

More commands in `docs/PROJECT_HANDOFF.md` §10.

## Summary postprocessing subagent

`summary-postprocessing-xhigh` (`.claude/agents/summary-postprocessing-xhigh.md`; edit tools only, no shell).

Delegate to it whenever a task involves:

- implementing or changing summary postprocessing logic (grounding checks, semantic-equivalence
  checks, restatement, fail-closed fallbacks);
- reviewing such code, or reviewing a summarizer's outputs for hallucination risk;
- deciding what transcript-derived data may be logged, exported or persisted.

Do not delegate Qwen runtime integration, Swift wiring or UI, builds, test runs, the Simulator, Git or
coordination. Each brief names the goal, the exact files the subagent may edit, the call sites to
read and the invariants to keep.

Only one edit-capable subagent runs at a time. While it works, the main agent edits no file in its
list. Before delegating, check `git status --short` for uncommitted changes in those files. After it
returns, review the `git diff`, then build and test before accepting.
