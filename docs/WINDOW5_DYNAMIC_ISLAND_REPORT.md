# Window 5 Report — Dynamic Island and Live Activity

Date: 2026-10-10. Branch `feature/window5-dynamic-island` (from
`feature/window4-attention-priority`). Not merged, not pushed. Numbers, methods and the device test
protocol: `docs/testing/WINDOW5_TEST_RESULTS.md`.

**Status: implemented, integrated in the app, tested on the Mac, in the iPhone 18 Pro Simulator and
— device steps D1–D4 — on the physical iPhone 18 Pro, always with synthetic events and the
microphone off — and, for D5–D6, with the real microphone (sound classification only) and clips
from a loudspeaker. The icon and alert rules were revised after D6 and the revised rules have not
run on the device yet. Battery cost (D7) and speech text with real speech (D8) are postponed.**

Device summary (details and evidence: `docs/testing/WINDOW5_TEST_RESULTS.md` §5): the compact,
expanded and Lock Screen presentations render as designed; icon changes are smooth; with Spotify
playing the island splits and Hearing Sense keeps both compact icons; silent updates on a locked
iPhone did not wake the display, sound or vibrate (student-observed, Always-On enabled); with
automatic expansion turned on the island expanded for about 4 s when unlocked, and an expansion
request sent 2 s and 20 s after locking did not wake the screen either (one observation each,
silent alert sound).

---

## 1. What the student asked for

Two briefs, both pasted on 2026-10-10:

1. *Design revision* — two channels: ordinary confirmed sounds as an **icon only** (no text, no
   alert) in the compact and minimal Dynamic Island, for all ≈ 303 classifier labels; important
   events and meaningful speech summaries as **text in the expanded** island. A lightweight
   `AmbientIconStream` on the Window 2 events, separate from Window 4; Window 4 is never bypassed
   for alerts; an ambient update never overwrites an attention episode.
2. *UX requirement* — Hearing Sense stays in the island for the whole session. Unlocked: compact
   icon, important events may expand. **Locked: silent updates only, an icon-focused Lock Screen
   layout whatever the priority, never wake the screen, no sound, no vibration, no notifications.**
   Do not assume the lock state can be detected reliably; if it cannot, not waking the screen has
   precedence over automatic expansion.

## 2. What was built

```
Window 2  ConfirmedAcousticEvent ─┬─▶ AttentionEngine (W4) ─▶ AttentionPresentationIntent ─┐
                                  │                                                         ├─▶ IslandPipeline ─▶ IslandCommand
                                  └─▶ AmbientIconStream ─▶ one icon ────────────────────────┘        │
                                                                                                     ▼
                                              AlertGate (lock estimate, setting) ◀── LiveActivityController ──▶ ActivityKit
                                                                                                     │
                                                                              widget extension draws IslandContent
```

| Piece | Where | What it does |
|---|---|---|
| `SoundSymbolCatalog` | `Sources/IslandPresentation` | SF Symbol for a sound: label → kind → category. All 303 labels resolve; table in `docs/research/sound_symbol_mapping_v1.tsv` |
| `AmbientIconStream` | `Sources/IslandPresentation` | Confirmed sound events → at most one icon. Value type, no clock |
| `IslandPipeline` | `Sources/IslandPresentation` | Joins the icon with the attention engine's intents into `IslandContent`; produces start / update / end commands and expansion *requests* |
| `AlertGate`, `DeviceLockEstimate` | `Sources/IslandPresentation` | Whether an expansion request may be passed to iOS |
| `IslandViews`, `HearingSenseActivityAttributes` | `Sources/IslandViews` | The SwiftUI pieces of the three presentations, shared by app and extension |
| `HearingSenseWidgets` (new Xcode target) | `apps/ios/HearingSenseWidgets` | The widget extension: places the pieces in the island regions and on the Lock Screen |
| `LiveActivityController` | `apps/ios/HearingSense/Presentation` | Owns the one activity: start, silent updates, end, leftovers, restart after iOS ends it, lock estimate, settings, diagnostics |
| `LiveActivityViews` | `apps/ios/HearingSense/Views` | "Dynamic Island" card (mirror of the island inside the app), settings, preview/debug screen with mic-free demo scenes |
| `IslandReplayer`, `hs-attention-eval island…` | `Sources/AttentionReplay`, tool | Engine + pipeline over the Window 4 scenes: commands, counts, rule checks |

Nothing in Windows 1–4 changed its behaviour. Window 4 got one debug hook
(`AttentionController.onInjectedSound`) so that synthetic sound events also reach the icon channel.

## 3. The two channels

### 3.1 Ambient awareness — icon only

`AmbientIconStream` reads every `AcousticEventUpdate`, including the ones the attention engine
suppresses as ambient. It never produces text, an alert or a priority.

| Rule (`AmbientIconPolicy.standard`) | Value | Why |
|---|---|---|
| Only confirmed events | — | The detector's k-of-n confirmation is the temporal smoothing of the classifier |
| Evidence quality | ≥ moderate | A weak event gets an icon only when a later update raises its quality |
| Which icon | the newest confirmed sound for 5 s, then the highest-ranked sound still going on | Revised after the device session: with rank alone, speech in a room hid every other sound and the student saw a strong sneeze not appear |
| Minimum display | 2 s (first version 4 s) | A shown icon is not replaced earlier |
| Linger after the sound ended | 5 s | A knock stays visible long enough to be seen |
| A sound that is over | keeps the icon if it has it, does not get it late | No 4 s appearance of something that ended earlier |
| Back to the plain glyph | 5 s after the last icon would go | A following sound replaces the icon directly: one update instead of two |
| Changes per minute | ≤ 12 | Bound on updates |
| Stale | 20 s without an update | Same bound as the attention engine (classifier stopped) |
| Excluded | `mic_wind_noise` | A recording artifact, not a sound around the user |

Icons: 161 labels have a symbol of their own, 141 use their kind's symbol, `silence` (never an
event) falls to the category; 120 distinct symbols. An unknown label or kind falls back to its
kind, then its category. Every name is checked against the system's symbol set in a test (macOS
27.2 and the iOS 27.0 Simulator); on the device the app replaces a name the OS does not have with
a generic waveform.

### 3.2 Important attention — expanded content

Only `AttentionPresentationIntent`s create an attention episode in the island. The pipeline keeps
the engine's presented episodes, shows the one with the highest priority (newest first; an equal
priority waits 3 s, a higher one replaces at once; a resolved episode does not come back to the
front) and removes each at the engine's dismissal or expiry.

Protected, as the brief words it, are a high-priority event and a speech summary: while one is
shown the ambient icon is tracked underneath and comes back afterwards; in the expanded view it
appears as a small secondary glyph. An episode of lower priority without a summary (a dog,
"Nearby Speech" with transcription off) gives way to an ordinary sound that appeared after it.
(Revised after the device session: such episodes held the island for most of 35 minutes in a room
with people talking.)

Text: the engine's generic title ("Door or knock", "Siren") and subtitle. For speech, when "Show
speech summaries" is on and the engine supplied a validated summary, the summary is the headline
and the generic title the caption (“Biology Test Tomorrow” / Nearby Speech).

### 3.3 The three presentations

| Presentation | Listening | Ordinary sound | Attention episode |
|---|---|---|---|
| Compact | ear | ear · sound icon (mint) | episode icon in the priority colour · mark (● normal, ! high, !! urgent) |
| Minimal | ear | sound icon | episode icon |
| Expanded | "Listening", session timer | "Listening" — no text about the sound | icon, headline, caption, mark, time since it appeared, "Uncertain", "+N more", secondary ambient icon |
| Lock Screen | icon, "Hearing Sense · Listening", timer | the same with the sound icon | the same with the episode icon and mark — **no title, no speech text, at any priority** |

Colour is never the only carrier (mark and accessibility label). A stale activity (the app stopped
updating it for 15 minutes) is drawn as "Not updating".

## 4. Never waking the screen

- Every update is `Activity.update(_:)` **without** an alert configuration unless §4.1 allows one.
  No `UNUserNotificationCenter` call exists anywhere in the app.
- The Lock Screen view is the same icon-focused layout for every priority.
- Recognition does not depend on the display; the activity simply holds the latest state for the
  next time the screen is on.

### 4.1 Automatic expansion is off by default

The only way an app can ask iOS to expand the island is an alert configuration, and Apple's
documentation does not say what that does on a locked iPhone. iOS also has no "is the device
locked" query. What the app can use is data protection (passcode set + protected data available),
and the Simulator run showed how that fails: **a locked Simulator reported a passcode and
available data, the estimate said "unlocked", and the app sent an expansion request while locked.**

Following the brief's rule (not waking the screen first), the final design is:

1. "Expand for important events" is **off** by default. The island then never expands by itself;
   the text is one touch-and-hold away.
2. When the user turns it on, a request is sent only if the estimate is `unlocked`, which requires
   a passcode, available protected data, **and** that this installation has seen protected data
   become unavailable at least once (so the signal is known to exist on this device). `locked` and
   `unknown` both mean a silent update. In the Simulator the estimate is now `unknown`.
3. Residual risk with the setting on, stated in the settings screen: for a few seconds after
   locking, protected data is still available (measured on the iPhone: unavailable 4–12 s after the
   lock button), so a request can still be sent in that window. Two things were learned on the
   device: iOS's "protected data will become unavailable" notice arrives at the moment of locking,
   and the estimate now treats a pending notice as `locked`; and in the two runs in which a
   request did reach iOS on a locked iPhone (2 s after locking, and forced 20 s after locking) the
   screen did not light up and there was no sound or vibration. Both are few observations with the
   silent sound file, so the default stays off.
4. The alert sound is a bundled silent file unless "Play the alert sound" is on. Whether iOS still
   plays a haptic with a silent sound is not known.

Expansion requests come from the attention engine only: priority `high` / `urgent` once per
episode (again when the priority rises), at least 6 s apart except for `urgent`, and the first
speech summary of an episode. That last one is a deliberate difference from Window 4, which
delivers a late summary with "no interruption": the summary is only readable expanded.
`IslandPolicy.alertsOnFirstSummary = false` restores the engine's suggestion.

## 5. Session lifetime and update load

- One activity per session. Leftovers of a terminated launch are ended at launch and before every
  start. All ActivityKit calls run on one serial queue.
- Started at Start Listening (the app is on screen then, which iOS requires). An interruption shows
  "Paused" and keeps the activity; Stop ends it at once.
- Apple's documented limits (checked 2026-10-10): active for up to 8 hours, then removed from the
  island and kept on the Lock Screen up to 4 more hours; static + dynamic data ≤ 4 KB; updating and
  ending from the background is allowed, starting needs the foreground; **no update budget is
  documented** for updates made by the app. When iOS or the user ends the activity while listening
  continues, the app starts it again the next time it is opened (it cannot from the background).
- Load control: identical content is never re-sent; quiet changes within 1 s are coalesced; the
  icon channel is bounded as in §3.1; a keep-alive every 10 minutes moves the stale date.
- Replay of the Window 4 scenes (synthetic; counts commands the app would send, not what iOS
  does): first 105 / 123 / 133 updates per hour for the 18 scenes (Quiet / Balanced / Sensitive)
  and 163 / 226 / 291 for the generated hour. A breakdown showed that 26–35 % of them changed only
  a secondary detail of an attention episode (the small ambient icon, "+N more"), which only the
  expanded view draws. Those are no longer sent by themselves: now 73 / 82 / 88 and
  127 / 168 / 188 per hour, 130 of the latter being icon changes of a deliberately dense scene;
  0 rule violations in 57 runs. The rate during real listening has not been measured.
- Real listening on the iPhone (D6, 34.9 minutes locked in a lived-in room, first rules):
  **256 updates per hour**, 9 ms per call, no failed classifier window. With the revised icon rules
  the recorded events replay to roughly 300–480 icon changes per hour in that room: faster icons
  cost updates. Not yet run on the device.
- If the app stops without ending the activity (crash, termination, or suspension when no
  listening session keeps it alive), the island keeps its last content until the stale date, up to
  15 minutes. Seen on the iPhone with the demo scenes.

## 6. Privacy

- The activity's content leaves the app's memory: iOS keeps it for the widget extension. It holds
  an icon name, generic titles, and — only with "Show speech summaries" on and only for the episode
  in front — the validated summary. With the switch off no spoken word enters the content (tested
  on the encoded form).
- The Lock Screen view never shows the summary; the expanded view marks it `privacySensitive()`.
  Whether iOS redacts that on a locked iPhone is not verified.
- Alert title and body are generic titles. Logs, the diagnostics export and the shared report use
  `IslandContent.redactedSummary`, which prints `<speech summary>` instead of the text.

## 7. Settings (Dynamic Island card → Dynamic Island settings)

| Setting | Default |
|---|---|
| Show in the Dynamic Island | on |
| Icons for ordinary sounds | on |
| Expand for important events | **off** |
| Play the alert sound | off |
| Show speech summaries | on (needs "Transcribe nearby speech", which stays opt-in) |

## 8. Limitations

1. **Device evidence is thin.** D1–D4 ran once each with scripted events; D5–D6 ran once with the
   microphone in one room, on USB power. The revised icon and alert rules (test results §6.1) have
   not run on the device. Unknown: battery cost; throttling by iOS; the activity after 8 hours; an
   expansion request with the alert sound on; the minimal presentation; D6's subjective checks.
1a. **Recognition quality limits the island.** In D6 six of nine high-priority episodes in ten
   minutes were room sounds (now addressed for `door` and `screaming` only); rain, footsteps and
   breaking glass clips were misrecognized; with music from the phone's own speaker a dog and a
   knock were not heard.
2. The lock estimate cannot be made reliable with documented API (§4.1).
3. Attention icons are category-level (Window 4's `symbolName`); the specific label icons are used
   by the ambient channel only.
4. Rank table, display times and limits of the icon channel are untuned defaults.
5. iOS shows its own one-time "Allow Live Activities from Hearing Sense?" prompt on the Lock
   Screen (seen in the Simulator). "Don't Allow" turns the feature off in Settings; the app then
   reports "Live Activities are off in Settings".
6. All text is English. The release build still contains the debug screens.
7. Not done from the roadmap's Window 5 list: haptics (left out on purpose: the locked-screen
   requirement forbids vibration and the unlocked case has the expansion) and the app icon refresh.
8. The widget extension is a second bundle id (`org.hearingsense.HearingSense.Widgets`) signed with
   the same Personal Team; built, signed and installed on the iPhone on 2026-10-10.
9. A stopped app leaves a frozen icon for up to 15 minutes (§5). A shorter stale date costs
   keep-alive updates; not changed yet.

## 9. Next steps

D1–D6 are done (`docs/testing/WINDOW5_TEST_RESULTS.md` §5–§6). Next: the retest R1–R2 of the
revised rules (§8 there), with microphone authorization. D7 (battery) and D8 (transcription) are
postponed by the student.
