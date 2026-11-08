# Window 8 — UI redesign: visual QA and crash fix (2026-10-11)

Build `aef0abb-w8dirty-ui2` (Debug, uncommitted work in this worktree). Installed on the iPhone 18 Pro.

## Shortcut crash

- Evidence: two crash reports from the iPhone (`HearingSense-2026-10-11-220624.ips`, `…220640.ips`), process
  Hearing Sense, role Background, `EXC_BREAKPOINT` in `AppIntents` on a cooperative thread.
- Failing operation (disassembly of the device's AppIntents at the faulting address): `Fatal error:
  AudioRecordingIntent was performed with an active audio session but without a Live Activity`
  (`AppIntents/PerformActionExecutorTask.swift:935`).
- Cause in the app: `ToggleHearingSenseIntent.perform()` returned as soon as the microphone was on; the Live
  Activity is requested by a queued job that had not run yet.
- Fix: every intent that can leave the microphone on awaits the Live Activity
  (`LiveActivityController.ensureRunning`, `ListeningController.requireLiveActivityForIntent`). When there is
  none (Live Activities off, "Show in Dynamic Island" off, request refused) listening is switched off again and
  the intent says why.
- **Not verified on the iPhone**: the intent was not run through Shortcuts or the Action Button after the fix
  (the phone automation needs the passcode entered on the phone). No new crash report existed after installing.

## Screens checked (iPhone 18 Pro Simulator, iOS 27.0, synthetic input, microphone off)

| Screen | Light | Dark | Text size AX-Large |
|---|---|---|---|
| Listen, off | ok | – | – |
| Listen, on (sound "Dog") | ok | ok | ok |
| Settings | ok | ok | ok (rows wrap) |
| Action Button | ok | – | ok |
| History (3 sample summaries; empty) | ok | ok | – |
| Summary page (sample) | ok | – | – |
| Conversation (captions screen) | ok (its own high-contrast style, unchanged) | – | – |

Real Dynamic Island of the Simulator (touch and hold): listening with the Summary button; summarizing with the
progress bar; summary ready (title, three lines of text, Open); following (text, Stop). Compact and Lock
Screen presentations: in-app preview only.

## Corrections made from screenshots

1. Expanded island: icon, text and timer were on different rows (the centre region lies below the camera);
   icon and timer are moved down to the text's row.
2. Summary ready: text plus a row of buttons exceeded the system's 160-point limit and the buttons were cut
   off. The text now has the bottom region; the state's one control (Open, Stop) sits beside the camera.
   "Continue" is in the app only.
3. Open/Stop lost its title in the narrow trailing region: the label keeps its own width.
4. Summary title stood away from the icon (the system insets the centre region symmetrically): centred.
5. History: the empty state was a list row and "Delete All" a permanent button; now an overlay and a menu
   that exists only when there are summaries.

## Not checked

Physical iPhone (only: installs, launches, test mode off, no crash report). Lock Screen presentation on a real
lock screen. The summary's expansion when it is ready (`Activity.update(_:alertConfiguration:)` is requested
as before, silent sound, only while the iPhone is judged unlocked; iOS decides).

Debug aids added: `--hs-screen settings|actionbutton|developer`, `--hs-island-conversation
summarizing|ready|following|notice`, `--hs-sample-history`.

---

# Dynamic Island summary redesign (2026-10-11, build `aef0abb-w8dirty-ui3`)

Reference: the student's screenshot from the iPhone 18 Pro (title cut to "Meeting with Ms. W…", text cut at the
bottom, "Someone said tomorrow, tomorrow, …").

## Why the summary was incomplete (cases A–E)

| Case | Finding |
|---|---|
| A model output | Not the cause of the cut text. The wording "Someone said …" is asked for by the prompts (main instructions and the restating of copied sentences). |
| B cut before ActivityKit | Yes: the pipeline shortened the text to 240 characters with "…". |
| C clipped by SwiftUI | Yes: `lineLimit(3)`; the title sat in the centre region, which the system narrows to the space between two equal insets. |
| D island cannot hold it | Yes: 160 points; a title and two lines of 20-point text is what fits. |
| E Open | Led to the live conversation screen (captions scroll it), not to the saved summary. |

The full summary was always saved whole; only its presentation in the island was cut.

## Changes

- Summary layout: small header beside the camera (sound icon + "Summary"/"Following", and one small control:
  Open, or Stop) and one full-width column below it on one leading edge: title 22 pt semibold, preview 20 pt.
- Two levels: the full summary (saved, History) and the island preview (`IslandSummaryPreview`): one or two
  whole sentences chosen from the summary's key points and sentences, no model call, never a fragment; a title
  that is too long ends at a word. Dynamic Type is followed up to xLarge in this layout.
- Open: `hearingsense://summary/<id>` → that summary's page in History.
- Language: `RecapText.tidied` removes narration openers that name no one and a word said twice in a row, before
  the checks; `RecapText.sentences` no longer ends a sentence after "Ms.", "Dr." and the like.
- Summary prompts: unchanged. Three rewrites were measured with `hs-semantic-eval recap --split dev` and reverted
  (facts 13/13 → 4/13 and 8/13; a restating variant lost a key point). With the final code: 13/13, 3/3 summaries.

## Checked on the Simulator's real expanded island (iPhone 18 Pro, touch and hold)

Summary button before generation · short summary · medium · long (a fact that fits is chosen) · long title
("Meeting with Ms. Wang about the science fair schedule" → "Meeting with Ms. Wang") · following (Stop) ·
accessibility text size (found: the header label was squeezed → text size capped at xLarge; not captured again
after the cap) · Open from the island with the app in the background → the summary's page.
Loading state: captured before this redesign only; its code path is unchanged.
The island is black in both appearances; Light/Dark was checked for the app screens earlier.

Tests: IslandPresentationTests 118, ConversationUnderstandingTests 66, all passed (new: `IslandSummaryPreviewTests`,
`RecapTidyingTests`).

## Not verified / limits

- Nothing of this was seen on the physical iPhone; the build is installed, the launch from the Mac was refused
  (phone locked).
- "Someone said …" can still appear: when taking it away would leave a sentence exactly as it was spoken, the
  narrated form is kept (a saved summary never repeats a spoken sentence word for word).
- The preview holds about 66 characters. A fact longer than that is shortened at a clause or, when that could
  change its meaning, at a word with "…".
- `simctl openurl` cannot open the link (the scheme is not registered; the Live Activity delivers it directly).

---

# Dynamic Island interaction fix (2026-10-11, build `aef0abb-w8dirty-ui4`)

- Open button removed. A touch on the island outside its buttons opens the app (`widgetURL`): the page of the
  summary the island shows (`hearingsense://summary/<id>`), otherwise the first screen.
- Two buttons along the bottom in every state, equal weight: **Summary** and **Continue**; **Stop** takes
  Continue's place while a conversation is followed. Each is a `LiveActivityIntent`.
  - Summary while following brings the growing summary up to date (state machine: `summarizeRequested` in
    `continuing`).
  - Continue without a summary writes one first and follows when it is ready (controller).
- Height: the island is at most 160 pt. Measured on the Simulator's island, below the camera row there is room
  for a title (17 pt semibold), two lines of 15-pt text and a 32-pt button row. The preview limit is 92
  characters, up to three whole sentences. A third line of text does not fit beside the buttons (tried: the
  buttons were cut off).
- Summary quality: the transcript of the summary in the screenshot is not kept (by design), so whether "Vic is a
  student in their family" was supported cannot be looked up. The checks are lexical: a sentence passes when its
  words were said. Added `unsupported_combination`: the supporting words have to stand within 80 words of each
  other. The prompts are unchanged (see above).

Checked on the Simulator's real expanded island: summary ready (medium, long), following (Stop), summarizing
(progress bar + both buttons), touch on the text → summary page, touch on Continue → the app logs
`Live Activity control: continueUnderstanding` and does not open. Not captured: the short summary and the idle
state with the new buttons (same layout with less text). Continue-from-nothing and Summary-while-following were
not run end to end with the language model. Nothing was seen on the physical iPhone.

Tests: IslandPresentationTests 118, ConversationUnderstandingTests 68, passed; `hs-semantic-eval recap --split
dev` 13/13 facts, 3/3 summaries.

---

# Dynamic Island final layout and summary grounding (2026-10-12, build `aef0abb-w8dirty-ui5`)

## Layout

Small "Summary" header beside the camera (sound icon + label, session timer on the right); no title of the
model's; body `.body` = 17 pt at the default text size, three lines, left-aligned; two buttons of 32 pt below.
Top and bottom content margins of the expanded island are 8 pt (with the system's defaults the third line pushed
the buttons out of the 160-pt limit — seen and corrected on the Simulator's island). The app measures the text
(`fitsIslandPreview`: body font, 314 pt) and shows the best fact plus as many further whole facts as fill the
three lines; nothing is scaled down or cut by the view.

## Grounding (`ConversationSummarizing.evidence`, `ConversationRecapEngine.grounded`)

After the lexical checks the on-device model reads every statement of the recap against the numbered transcript
in one request (cited line + verdict); a statement it does not find is left out (`ungrounded_statement`). No
answer in 10 s: nothing is removed. A reading that rejects two thirds or more is not believed.

Measured with `hs-semantic-eval ground` (31 statements with known answers, 3 invented transcripts, Mac):

| variant | true kept | false caught | time |
|---|---|---|---|
| one request per statement, verdict only | 15/15 | 4/15 | 1.8 s each |
| one request, up to three cited lines + verdict + word check against the lines | 11/15 | 14/15 | 8.1 s |
| **one request, one cited line + verdict (adopted)** | **15/15** | **12/15** | **5.4 s** |

"Vic is a student in their family." and "Vic had a boring day." are among the caught ones. Missed: a wrong day
for the meeting, an invented due date, an invented "the teacher asked". It is a small model reading: it lowers
the number of invented statements, it does not establish correctness.

`hs-semantic-eval recap` with the step: dev 13/13 facts, 3/3 negations, 3/3 summaries, model time median 11.4 s
(was 7.4 s); held-out 26/26 facts, 4/4 negations, 5/5 summaries, median 12.5 s.

Not changed: the summary prompts; the Window 7 rule that a copied spoken sentence is restated or left out
(an option to keep a short one, `RecapValidator.keptCopyMaximumWords`, exists and is off).

## End-to-end (Simulator, real on-device model, synthetic sentences, microphone off): 33 checks, 0 failed

`--hs-w7-selftest --hs-test-allow model`, run twice (the second time on the final code). New checks: Continue
without a summary writes one and then follows (A); Summary while following updates the summary, 8.8 s (B); the
island's link is the saved summary's page (E); the saved summary is whole (731 characters, 9 key points) while
the island shows 86. Existing checks cover Stop → saved and completed (C), listening goes on after Stop (D),
no sentence word for word and captions deleted after Stop (G).

Seen on the Simulator's real island: summary ready (one long fact), following (two facts, three lines, Summary +
Stop), summarizing (progress bar, Summary + Continue). Touch on the island → summary page and touch on a button →
its action were seen with the previous build's identical wiring.

Tests: IslandPresentationTests 119, ConversationUnderstandingTests 72, passed.

## iPhone

Installed and launched from the Mac: diagnostics report build `aef0abb-w8dirty-ui5`, app active, test mode off;
no new crash report. iPhone-use was not needed and is not installed. The island itself was not looked at on the
iPhone.

---

# Short verbatim sentences enabled (2026-10-12, build `aef0abb-w8dirty-ui6`)

Approved by the student: a summary may keep a spoken sentence of up to 12 words as it was said
(`RecapValidator.keptCopyMaximumWords = 12`, on by default). Kept: the Window 7 rule for longer copies (restated
or left out), no two kept copies next to each other, at most 3 kept copies per recap, the overall verbatim share
limit (0.65), and the rolling transcript stays in memory (a recap holds no utterance list). Words are counted
by `RecapText.words`, which segments Chinese/Thai/Korean text with `NLTokenizer`; Chinese numerals and
weekday/time words, "不/没/未…" negations and the Chinese full stop are handled in the checks and the island preview.

Tests (focused): IslandPresentationTests 120, ConversationUnderstandingTests 84, all passed — short exact fact kept,
long copy refused, adjacent copies not both kept, cap of three, mostly-transcript summary refused, facts kept
when the model used the speaker's words, Chinese and mixed text (segmentation, invented Chinese time caught,
negation, short kept / long refused, island preview split and clause cut). `hs-semantic-eval recap --split dev`:
13/13 facts, 3/3 negations, 3/3 summaries. The simulator self-test was not rerun after this change.
Not verified: Chinese summaries from the real model (the evaluation scenes are English).
Limit: the grounding step is the model reading, not proof of accuracy; lexical overlap is not proof either.
