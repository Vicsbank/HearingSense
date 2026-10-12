# Dynamic Island, Live Activity and Action Button: What the Public APIs Allow (Window 7)

Written 2026-10-11 for Window 7. It records what the app relies on, how each point was checked,
and what is still an assumption. Three levels of evidence are used and never mixed:

- **SDK**: the declaration exists in the iOS 27.0 SDK of Xcode 27 (read from the module
  interface), and the app compiles and links against it.
- **Simulator**: seen to work in the iOS 27.0 Simulator (iPhone 18 Pro Max) in this window.
- **Device (earlier)**: observed on the iPhone 18 Pro in Window 5 (`docs/testing/WINDOW5_TEST_RESULTS.md`).
- **Not verified**: taken from Apple's documentation or expected from the API's contract; no
  run of this project has shown it. Nothing of Window 7 ran on a physical iPhone.

## 1. Summary

| Question | Answer | Evidence |
|---|---|---|
| Can the Action Button switch listening on and off? | Yes, through an App Intent the user assigns to it (Settings → Action Button → Shortcut). The app cannot read the button itself and cannot assign the shortcut for the user. | SDK; assignment and the press **not verified** |
| Can that intent start the microphone while the app is not on screen? | The API made for it is `AudioRecordingIntent` (iOS 18): the app must show a Live Activity while it records. The intent adopts it. | SDK; behaviour **not verified** |
| Can a button inside the expanded Dynamic Island run code? | Yes: `Button(intent:)` with a `LiveActivityIntent`, which iOS runs in the app's process. | SDK; `perform()` runs in the Simulator when called directly; a real touch on the island **not verified** |
| Can the app open the expanded presentation itself? | No. It appears when the user touches and holds the island, or when an update carries an `AlertConfiguration` — and then iOS decides. | Device (earlier) for both; no API exists for anything else |
| Does touch and hold run anything? | No. It only shows the expanded views. | By construction: the views contain three buttons and a link, nothing else |
| How long does a Live Activity last? | Apple documents up to eight hours active; the system then ends it. | **Not verified** (no 8-hour run); the app's handling is unit-tested |
| Does an eight-hour activity mean eight hours of microphone? | No. They are separate limits. | Device (earlier): 35 minutes locked, once |
| Is an ActivityKit alert a Critical Alert? | No. Critical Alerts are a notification entitlement Apple grants on request; this app has none and schedules no notification at all. | Code |

## 2. Action Button

**What exists.** The Action Button runs a system action or a shortcut. An app offers shortcuts
by declaring App Intents and an `AppShortcutsProvider`. There is no API for the hardware press
(no event, no "is the Action Button assigned to me" query, no way to assign it from the app).

**What the app does.** `apps/ios/HearingSense/Listening/ListeningIntents.swift`:

| Intent | Protocols | Offered in Shortcuts |
|---|---|---|
| `ToggleHearingSenseIntent` | `AudioRecordingIntent`, `LiveActivityIntent` | yes (the one for the Action Button) |
| `StartHearingSenseIntent` | `AudioRecordingIntent`, `LiveActivityIntent` | yes (for automations) |
| `StopHearingSenseIntent` | `AppIntent` | yes (for automations) |

The built app's extracted intent metadata (`Metadata.appintents/extract.actionsdata`) lists the
toggle and start intents with the system protocols *AudioRecording*, *SessionStarting* and
*ForegroundContinuable* (**SDK**, build output).

`supportedModes = [.background, .foreground(.dynamic)]` (iOS 26): the intent runs without
opening the app and calls `continueInForeground` only when the microphone permission has never
been asked for, because iOS shows that prompt only while the app is on screen.

**Not verified, each needing the iPhone:**

1. The shortcut appears in Settings → Action Button → Shortcut and a long press runs it.
2. ON from the Home Screen with the app not running: the process is launched in the background,
   the audio session activates, the Live Activity is requested.
3. ON from a locked iPhone. The intent keeps the default authentication policy (allowed while
   locked); whether iOS asks to unlock for an intent that starts recording is unknown.
4. OFF from the background and from a locked iPhone.
5. What iOS shows for the intent's short answer ("Hearing Sense is on.").
6. Whether iOS stops a recording that was started by an `AudioRecordingIntent` when its Live
   Activity ends (Apple's documentation states that the activity is required for the duration).
   This matters for the eight-hour limit (§5) and for a user who swipes the activity away.

**What the app cannot do.** Intercept the button; make the button do one thing on a short
press and another on a long press; stop the user from assigning a different shortcut. The
conversation controls are kept away from the button by not offering them to Shortcuts at all
(`isDiscoverable == false`): the Shortcuts app and the Action Button's shortcut picker do not list them.

## 3. Controls inside a Live Activity

**What exists.** Since iOS 17 a Live Activity's views may contain `Button(intent:)` and
`Toggle(isOn:intent:)`, and `Link` / `widgetURL` to open the app. Nothing else responds to
touch: no gestures, no text input, no scrolling. The views are rendered by the system from the
activity's content state and cannot run code or keep state.

An intent that adopts `LiveActivityIntent` is performed in the **app's** process. The type has
to be compiled into the widget extension too, because the button that names it is drawn there.
The app keeps these types in `apps/ios/Shared/HearingSenseActions.swift`, a folder that is a
member of both targets.

**What the app does.**

| State of the content | Controls in the bottom region |
|---|---|
| Listening, nothing asked | **Summarize last 2 min** |
| Summary being written | text only |
| Summary ready | **Continue** · Open (link) |
| Following a conversation | **Stop** · Open (link) |
| Paused, or not updating | none |

`Summarize`, `Continue` and `Stop` are `LiveActivityIntent`s; "Open" and a tap anywhere else
use `hearingsense://conversation`, received in the app with `onOpenURL`.

**Evidence.** Both targets build with the three intents in their metadata (**SDK**). In the
Simulator self-test the intents' `perform()` was called directly and drove the whole sequence
(**Simulator**, see the acceptance report). Not shown by any run: a real touch on a button in
the expanded island, that iOS routes it to the app's process while the app is in the
background, how long that takes, and that the link opens the conversation screen.

**Fallbacks that already exist.** If a button press should ever not reach the app (the app was
terminated: the activity then shows "Not updating" and no controls), a tap opens the app, where
the same three controls are on the main screen and on the conversation screen.

**Limits to design for.**

- The expanded presentation is small (roughly 160 points high). A summary is cut to three
  lines there (`IslandPolicy.maximumSummaryLength` = 240 characters); the whole text is in the app.
- The content state is limited in size (Apple: 4 KB). A full content state with a clipped
  summary encodes to under 1.5 KB (unit test).
- A button gives no result back to the island. The app answers by updating the activity
  ("Summarizing", then "Summary ready").
- On the Lock Screen the app shows no controls and no text beyond a generic state, by its own
  rule (speech-derived text never appears there).

## 4. Asking for attention: `AlertConfiguration`

**What exists.** `Activity.update(_:alertConfiguration:)`. With an alert configuration iOS
presents the update prominently: on an iPhone with a Dynamic Island the expanded presentation
is shown for a moment; on the Lock Screen the activity is brought forward and the screen can
light up; a sound can play. iOS decides: Focus, the device's state and system limits can
suppress it, and nothing reports back whether it was presented. There is no API that
guarantees an expansion.

**Device (earlier).** Window 5, D4: with the setting on, an alert update expanded the island on
the unlocked iPhone. On the locked iPhone, with a silent sound file, two alert updates (2 s and
20 s after locking) did not light the screen, play a sound or vibrate, as the student observed.
Two observations are not a guarantee.

**What the app does.**

- Ordinary sounds and scene changes: plain `Activity.update`, never an alert configuration.
- A **verified** acoustic episode of priority high or urgent (the attention engine's decision,
  not marked uncertain) produces a request; `AlertGate` passes it to iOS when "Prominent alerts
  for urgent sounds" is on (**on by default** since the decision of 2026-10-11) and the iPhone
  is judged unlocked. While it is judged locked, or the app cannot tell, the request is passed
  only if the user opted in to "Also when the iPhone is locked" (off by default). Otherwise the
  update is silent and the island shows the warning icon with its priority mark.
- A speech episode never produces a request (`IslandPolicy.speechMayRequestExpansion == false`).
- A summary the user asked for produces one request when it is ready, under its own setting
  ("Show the summary when it is ready", on by default), through the same lock gate.
- The alert's title and body are generic words. They never contain speech.
- The sound is a silent file unless "Play the alert sound" is on.

**What the default (on) cannot rule out.** The lock state can only be estimated (data protection
lags the lock by 4–12 s, measured in Window 5; iOS's earlier notice closed the gap in two
instrumented runs). An alert in those seconds can light a locked screen although the user did
not opt in. The settings screen says so, and Window 8 measures it on the iPhone.

**Not the same as.** *Critical Alerts* (notifications that ignore the mute switch and Focus)
need an entitlement from Apple and are for health, safety and security apps. *Time Sensitive
notifications* are notifications too. Hearing Sense schedules no notification of any kind, and
an ActivityKit alert follows the system's ordinary rules. The app is an awareness aid and makes
no claim to detect emergencies.

## 5. Lifetime

| Limit | Source | Handling |
|---|---|---|
| Active for up to 8 hours, then ended by the system | Apple's documentation; **not verified** | `ActivityLifetimePolicy` (decision of 2026-10-11): the app does not work around the limit. A running activity is never replaced. When the system ends it at the limit, listening goes on, the app logs it, and no activity is requested for that session; the next session gets its own. |
| Can be requested only while the app is on screen (or by an intent made for it) | Apple's documentation; **Simulator**: requests at launch succeeded | `LiveActivityController` retries in `appBecameActive` |
| The user can remove the activity | — | Removed before its time: shown again when the user opens the app while still listening |
| A stale date marks content as outdated | **Device (earlier)** | Stale after 15 minutes without an update; drawn as "Not updating". A keep-alive update is sent every 10 minutes. |
| Updates may be throttled by the system | Apple's documentation; **Device (earlier)**: 256–282 updates per hour were all delivered in 35 and 5 minute runs | Icon changes are limited to 12 per minute and coalesced |

One listening session uses one activity; leftovers of an earlier launch are ended at launch. The Simulator self-test saw
exactly one activity alive after nine toggles.

The eight-hour figure is about the *presentation*. How long the microphone, the sound
classifier and the transcriber keep running in the background is a separate question with
separate evidence: 35 minutes locked without a classifier failure, once, on a charger
(Window 5, D6). No battery measurement exists.

## 6. What the Simulator cannot show

- The Action Button (no hardware, no Settings entry).
- The island's reaction to touch. Screenshots taken with `simctl` often omit the island.
- The lock state: the Simulator has no usable lock signal, so `AlertGate` holds back every
  request there (`lock_state_unknown`) unless `--hs-assume-unlocked` is passed.
- `SpeechTranscriber`: not available in the Simulator. The summary path was exercised with
  written sentences entering where transcribed utterances would.
- Anything about the microphone, AirPods, Spotify, battery or heat.

## 7. Device steps that would settle the open points

In order, each one needing the student's authorization and one step per message
(`docs/testing/WINDOW7_ACCEPTANCE_REPORT.md` §5 has the full list): assign the shortcut and
toggle from the app in the foreground; toggle from the Home Screen; toggle from the locked
iPhone; touch and hold the island and press Summarize with transcription off (no speech
needed); the same with synthetic speech played from the Mac; Continue and Stop; a siren clip
with "Expand for important events" on and off; swipe the activity away while listening.
