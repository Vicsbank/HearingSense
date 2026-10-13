# Window 9 worktree — agent delegation rules

Worktree: `.claude/worktrees/window9`, branch `feature/window9-summary-postprocessing`, based on Window 8 HEAD `aef0abb`.
Never merge or push from here, never touch other worktrees, never access the physical iPhone without the student's authorization in chat.

## Roles

**Main agent (Sonnet 5.5, high effort)** — owns overall coordination, Qwen runtime integration, all Swift wiring outside postprocessing, builds, unit tests, Simulator testing, all Git operations, and the final integration/review of anything a subagent returns.

**`summary-postprocessing-xhigh` subagent (Opus 5.5, xhigh effort)** — defined in `.claude/agents/summary-postprocessing-xhigh.md`. No shell, edit tools only.

## Automatic delegation

Delegate to `summary-postprocessing-xhigh` (Agent tool, `subagent_type: "summary-postprocessing-xhigh"`) without asking the student first whenever a task involves any of:

- implementing or changing summary postprocessing logic (grounding checks, semantic-equivalence checks, restatement, fail-closed fallbacks);
- reviewing such code, or reviewing a summarizer's outputs for hallucination risk;
- deciding what transcript-derived data may be logged, exported or persisted (transcript privacy review).

Do **not** delegate: Qwen runtime integration, Swift wiring/UI, builds, test runs, Simulator, Git, or coordination.

Each delegation brief must contain: the goal, the exact **Owned files** list (the only files the subagent may edit), the call sites to read, the invariants to preserve, and "report format per your definition".

## Concurrency rule (no overlapping edits)

1. One edit-capable subagent at a time; run it in the foreground. No parallel subagents that could edit.
2. While the subagent runs on a brief, the main agent does not edit any file in that brief's Owned files. The main agent may work only on disjoint files.
3. The subagent edits nothing outside Owned files; needs elsewhere come back as requests.
4. Before delegating, the main agent checks `git status --short` and confirms no Owned file has uncommitted changes of its own; after return, it reviews `git diff` of those files, then builds/tests before accepting.
5. Review-only briefs (no edits) may run alongside main-agent edits.

## Privacy

Raw transcript text never goes to logs, diagnostics, exports, committed fixtures or reports. Use synthetic sentences in tests.
