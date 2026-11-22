# Commit hash map (2026-11-22)

Before the repository was made public, the author email in every commit was replaced with
the GitHub noreply address. Commit contents, messages and dates are unchanged, but every hash
changed. Documents written before 2026-11-22 cite the old hashes; this table maps each old
hash to the new one. Short hashes in documents match the start of the old hash.

| Old hash | New hash | Subject |
|---|---|---|
| `7905f0bf63` | `09e177eaa8` | Window 1 baseline: repository audit and native iOS foundation |
| `679494e8de` | `bf74b982f9` | Baseline: add data/README.md omitted from the reconstructed Window 1 commit |
| `6f41d90de5` | `b924fafbad` | Window 2: real-time Apple SoundAnalysis recognition and acoustic event detection |
| `b5ce69bd81` | `170b13783c` | Window 3 (work in progress): on-device speech intelligence pipeline |
| `c5a5d59fe5` | `85ccbae54c` | Window 3 (work in progress): add activation and music-transcript evaluation summaries |
| `36c54336e6` | `5a1d98d5de` | Window 3: on-device speech intelligence with a speech relevance gate, evaluation and documentation |
| `c162732454` | `8ba2f59f6d` | Window 3: physical-iPhone tests, fixes for the recognizer limit and background classifier stall |
| `0d6236d62e` | `5964cfba4f` | Research window: background acoustic inference, classifier backends and model benchmark |
| `be7e8de547` | `61a2331afe` | Research window: first physical-iPhone background runs (A1, A2, CPU-only MN10) |
| `dad1cc5ef9` | `7b012918de` | Window 4: context-aware attention priority engine |
| `dc1f6cf314` | `11255771e0` | Window 5: Dynamic Island and Live Activity with two-channel presentation |
| `1d0672116a` | `36d480b7be` | Window 5 device session: D1-D6 results, faster icon channel, fewer false alerts |
| `eddc45076d` | `d8a81be628` | Window 5 retest R1: speech without a summary is icon-only, icon de-duplication and cooldowns |
| `c92cdc60f2` | `de2c39b827` | Window 6 phase 2: acoustic icon redesign with app-drawn glyphs and a debug gallery |
| `1c91bc6d28` | `4229af9cec` | Window 6 phases 3-5: semantic attention goals, two-minute recap, continued understanding, history |
| `ead23f3563` | `a309f84143` | Window 6 phase 6: validation, recap evaluation, Simulator demo, reports and handoff |
| `e455e1c080` | `12004740fe` | Window 6.1: semantic engine optimization, configuration frozen before the sealed evaluation |
| `a979cf9453` | `209216c833` | Window 6.1: sealed evaluation, reports, handoff |
| `54181f8ff9` | `21a6c6dea4` | Window 6.2: development set 3, independently authored sealed set 2, research probes |
| `06d36c7c3d` | `363f38cd6b` | Window 6.2 (work in progress): staged reasoner, one turn per utterance, serving order, expiry, repetition second look |
| `80f80b6915` | `264b0a2f5e` | Window 6.2: semantic engine reworked for precision and backpressure, configuration frozen before the sealed evaluation |
| `197d0d0aca` | `5c86bcb488` | Window 6.2: sealed evaluation, regression, reports, handoff |
| `98413b7f4b` | `d369ad5214` | Window 6.3: development set 4, independently authored sealed set 3, JSON-described research probe |
| `eb85b0e1e7` | `71ae125c33` | Window 6.3 (work in progress): listener identity, audience cues, narrow concern question, name rescue, cut-off and no-change rules, context policy, about-me line in the app |
| `1e269b8392` | `19faae7819` | Window 6.3: personal relevance (listener identity, audience cues, narrow concern question), context policy, speaker's-word rules; configuration frozen before the sealed evaluation |
| `da90073a9f` | `05b398e345` | Window 6.3: research log up to the freeze |
| `56358da3b7` | `32e8b9eb78` | Window 6.3: names told by their form where the system has no name tagger (iOS Simulator) |
| `5375c4e45b` | `590e53b175` | Window 6.3: demo sentences and about line, simulator screenshots, decide command, table generator |
| `778489c0ed` | `5fd665c5ef` | Window 6.3, after the sealed evaluation: the rule for another group no longer decides by itself |
| `8c592f4185` | `7fc41ce54a` | Window 6.3: sealed runs of record, tables, recount, and an account of an accidental second invocation that was stopped |
| `cd4faab197` | `b02d005580` | Window 6.3: tests independent of machine load and of the name tagger; benchmark document draft |
| `89bdf92cb4` | `6a67f9fcda` | Window 6.3: sealed evaluation, streams, regression, reports, handoff |
| `df2a699948` | `686b3f704e` | Window 6.3: research log, events after the freeze |
| `faf8b35961` | `0c4f61dcce` | Window 7 baseline: Window 6 (ead23f3) with the uncommitted Window 5 post-R1 work |
| `f6d9849efa` | `ebe6d439ac` | Window 7 milestone 1: personal semantic attention removed from the app |
| `4bd67015ee` | `70bd989ed4` | Window 7 milestone 2: listening session switch and the Action Button intent |
| `15859d2e5a` | `26a0393c62` | Window 7 milestones 3 and 4: Dynamic Island controls and the summary on request |
| `262eed48d0` | `1b0d20ebc0` | Window 7 milestone 5: acoustic scene awareness and the alert rules for acoustic events |
| `159b876908` | `5ef688e587` | Window 7: record the stabilization commit in the documents |
| `f765725207` | `254c2c7970` | Window 7 milestone 6: stabilization, a transcript-in-summary fix, reports and handoff |
| `9788704021` | `3a0d673cbc` | Window 7: note that no touch on the island was tried, also not in the Simulator |
| `68cb1a8e76` | `c23f516cf9` | Window 7 final decisions: prominent alerts on by default, no Live Activity replacement, copied sentences restated in memory |
| `aef0abb061` | `8dabee7f4c` | Window 8 preflight: read-only audit and physical-device test plan |
| `03f5802087` | `940b8607a0` | Window 9 base: snapshot of Window 8 working tree (aef0abb + uncommitted UI redesign and recap work, copied read-only) |
| `80c7e350a7` | `376e2adfb0` | Window 9: delegation rules and summary-postprocessing-xhigh subagent |
| `094f0fa9bb` | `fb1e449ab8` | Window 9: English judged regression corpus (from benchmark, not held-out) and SummaryPostprocessing target skeleton |
| `28e068a5f9` | `b48a154892` | Window 9: summarization engine abstraction, coordinator with Apple fallback, Qwen runtime package (unbuilt), engine labels in records |
| `09db91fa0e` | `f23f0196b2` | Window 9: postprocessing wired into the recap engine (Window 9 default, legacy kept for measurement), rewrite-on-correction, engine records, self-test, eval tool |
| `c791d4a68c` | `46d3672fcf` | Window 9: finish native engines, safe simulator fallback and conservative recap postprocessing |
| `7f6c4d3851` | `b54d69ebdf` | Window 9: keep ambiguous time qualifiers unverified and isolate superseded evidence |
| `c7726ac3e8` | `6a4de80922` | Window 9: mark corrected digest facts as historical and harden native evaluation |
| `e499169c59` | `c19dc42ce6` | Window 9: record native and simulator validation with exact runtime blocker |
| `eb52d5b4cc` | `532f9282b9` | Remove stale generic source commentary during Continue |
| `171b12408b` | `47835421c8` | Run the pinned Qwen checkpoint natively on Simulator CPU |
| `02f3b9c6a6` | `cf6d139253` | Check typed numbers and revoked ticket payments in Window 9 acceptance |
| `ef379390b3` | `0e3e1614b2` | Audit saved native Qwen results with cancellation-aware acceptance checks |
| `ef440e571f` | `5424175e9c` | Document native Simulator Qwen validation and current Apple environment limitation |
| `c33804a04c` | `f0310b49d0` | Enable native iPhone Qwen deployment and preserve recap facts within copy limits |
| `5a02c54c42` | `7d54fede98` | Record final iPhone Qwen and Apple acceptance and Release installation |
| `06eb67ba6b` | `60e604943d` | Local model comparison: benchmark tools, results and reports |
| `ae83ae14a9` | `f0b6f62fcc` | Window 8 work in progress: UI redesign, device test mode, Action button setup, island summary preview |
| `e19e490c22` | `d7cd67554b` | Window 5 post-R1 work in progress: session time limit, warning near-miss log, settings audit |
| `e29bb18f17` | `37f16c449e` | Window 9 work in progress: stability validation, summary request view, UI tests and results |
| `a54eb52269` | `9445159e41` | Update README and CLAUDE.md for Window 9 and the single main branch |
| `33f6ce0a1b` | `70a56173f1` | Send alerts for active warnings that arrive while an ended episode lingers |
| `b2fd00ff33` | `098f6df4a7` | Keep acoustic warnings on the island until acknowledged; add Window 10 device check |
