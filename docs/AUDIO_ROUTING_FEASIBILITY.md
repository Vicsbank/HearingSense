# Audio Routing Feasibility — AirPods + Media + Environmental Microphone

Highest-priority technical uncertainty of Hearing Sense iOS 2.0: can the app keep listening to the
environment while the user plays Spotify / Apple Music on AirPods with Active Noise Cancellation,
including with the screen locked?

Status after Window 1 (2026-10-09): **the core scenario works on a real iPhone 18 Pro with AirPods
Pro and Spotify**, for the durations tested. Details, evidence and the remaining gaps follow.
Window 2 (same day) changed only redundant-call handling and added an opt-in experiment (§3); the
session configuration is unchanged and **was not re-tested on the device** in Window 2.

---

## 1. Chosen configuration

Policy `builtInMicWithBluetoothMedia` (“iPhone mic + AirPods media”), implemented in
`packages/HearingSenseKit/Sources/HearingSenseAudio/AudioSessionPolicy.swift`:

| Setting | Value | Why |
|---|---|---|
| Category | `playAndRecord` | Only category that records **and** accepts `mixWithOthers` |
| Mode | `default` | Header note: `mixWithOthers` is documented with the default mode |
| Options | `mixWithOthers` | Other apps keep playing; our activation does not interrupt them |
| | `allowBluetoothA2DP` | Bluetooth output may stay on the high-quality A2DP profile while recording |
| | `defaultToSpeaker` | Without headphones, other apps' audio stays on the speaker instead of the earpiece |
| | *not* `allowBluetoothHFP` | Avoids switching AirPods to the call-quality hands-free profile |
| | *not* `duckOthers` | Music volume is not lowered |
| Preferred input | Built-in microphone (set after activation) | iPhone mic gives environmental audio without touching the AirPods link |
| Background | `UIBackgroundModes = audio` (`apps/ios/Config/HearingSense-Info.plist`) | Lets a capture that was started in the foreground continue in the background / locked |

Three experimental policies exist in the app for comparison (not yet tested on device):
iPhone mic in `measurement` mode, AirPods mic over HFP, AirPods mic with iOS 26
`bluetoothHighQualityRecording`.

---

## 2. What is supported, verifiable, device-only, or restricted

### 2.1 Supported by Apple documentation (SDK headers, iOS 27.0 SDK)

- `allowBluetoothA2DP` with `playAndRecord`: “allowing a paired Bluetooth A2DP device to appear as an
  available route for output, while recording through the category-appropriate input”
  (`AVAudioSessionTypes.h`).
- `allowBluetoothHFP`: Bluetooth HFP input; selecting an HFP input moves output to HFP as well.
  If one device supports both HFP and A2DP, HFP gets priority when both options are set.
- `bluetoothHighQualityRecording` (iOS 26+, not Mac Catalyst): full-bandwidth Bluetooth audio in both
  directions on routes that support it (“certain AirPods models”); default mode only; may increase
  input latency. Capability readable via `AVAudioSessionPortDescription.bluetoothMicrophoneExtension`.
- `farFieldInput` (iOS 26.2+): requires `allowBluetoothHFP`.
- `mixWithOthers`: valid with `playAndRecord`; `duckOthers` lowers others' volume (not used).
- Record permission: `AVAudioApplication.requestRecordPermission()` (iOS 17+).
- iOS 27 adds `AVAudioNode.installAudioTap(…tapProvider: @Sendable …)` and deprecates the classic
  `installTap` (deployment target 26.0 keeps the classic API without warnings).

### 2.2 Verified with code / APIs (no device needed)

- The policy maps to the intended `CategoryOptions` (unit tests `categoryOptionsMapping`,
  `everyPolicyMixesAndNeverDucks`, `recommendedPolicyKeepsBluetoothOutputOnA2DP`; 26 tests pass on
  the iOS 27 Simulator).
- Interruption / route-change notification parsing (unit tests with synthetic notifications).
- The app builds for iOS Simulator (Debug) and generic iOS device (Release, unsigned) with Xcode 27.0.

### 2.3 Verified on a physical device (2026-10-09)

Device: iPhone 18 Pro (iPhone19,2), iOS 27.2. Headphones: AirPods Pro (“Vic's Final AirPods Pro”).
Media: Spotify. App build: Debug, signed with a Personal Team, installed from Xcode 27.0.
Screenshots: `docs/device-tests/2026-10-09/`. Observations marked *(user)* were reported by the
student by ear/eye; everything else was read from device screenshots taken with `devicectl`.

| # | Test | Result | Evidence |
|---|---|---|---|
| T1 | Built-in mic, no AirPods: permission prompt, start, level responds to silence/speech/claps, stop | **Pass** | Permission granted; meter and history graph followed speech and claps *(user)*; Stop released the mic |
| T2 | AirPods Pro connected, ANC on, start listening | **Pass — target route** | Input `iPhone Microphone` (MicrophoneBuiltIn, 1 ch, data source *Bottom* of 3); output `AirPods Pro` (BluetoothA2DPOutput, 2 ch); capture 48 kHz · 1 ch; level −27 dBFS live (`02_…`, `03_…`, `04_…`) |
| T2 | Session parameters | Recorded | playAndRecord / Default; options mixWithOthers, defaultToSpeaker, allowBluetoothA2DP; 48 000 Hz; IO buffer 10.0 ms; input latency 11.9 ms; output latency 163.0 ms |
| T2 | AirPods microphone capabilities (reported on the A2DP port) | Recorded | High-quality Bluetooth recording: supported; far-field capture: supported. AirPods mic not in available inputs (HFP not allowed by this policy — intended) |
| T3a | Listening first, then Spotify starts playing | **Pass** | Spotify in Dynamic Island, Hearing Sense still Listening, target route kept (`05_…`); music quality normal, no stutter, no volume drop *(user)* |
| T3b | Spotify playing, Stop then Start listening | **Pass with glitch** | Spotify not paused, listening resumes (`06_…`); **~0.5 s playback stall at each start and stop** *(user)*. Event log shows a `routeConfigurationChange` at each activation/deactivation |
| T4 | Screen locked while listening + Spotify playing | **Pass (≤ 40 s)** | Event log: background 7.3 s → captured 7.3 s (73 buffers, 100 %); background 39.7 s → captured 39.7 s (397 buffers, 100 %); no interruption or route events; music continued *(user)* (`07_…`) |

Additional measurement: 397 buffers in 39.7 s = 10 buffers/s, i.e. iOS delivered **4 800-frame
(100 ms) tap buffers** although 4 096 frames were requested.

### 2.4 Requires further physical-device testing (not done yet)

| Open test | Why it matters |
|---|---|
| Lock / background for ≥ 5–30 min | Only ≤ 40 s verified; long sessions could be suspended or terminated (memory pressure, thermal) |
| Apple Music (and other players) instead of Spotify | Different apps may configure sessions differently |
| Media app started **after** listening, from a stopped state, and Siri / navigation prompts | Non-mixable sessions activating later |
| Incoming phone call / FaceTime during listening | Expected `interruptionBegan`/`Ended(shouldResume)`; auto-resume path untested |
| AirPods removed / disconnected mid-session; switching ANC ↔ Transparency | Route change + `AVAudioEngineConfigurationChange` restart path untested |
| Experimental policies (measurement mode, HFP, high-quality Bluetooth) | Effect on music quality, latency and whether `mixWithOthers` still holds |
| The 0.5 s stall at start/stop | Whether it can be reduced (see §3) |
| Battery drain and thermal impact over 30–60 min | Feasibility for real use |
| Starting listening from a Live Activity / Shortcut while backgrounded | Expected to fail (see §2.5) — confirm the exact error |

### 2.5 Restricted by iOS (do not attempt)

- No public API exposes the AirPods ANC/feed-forward microphone audio or other private streams; the
  only AirPods microphone access is the normal Bluetooth input (HFP / high-quality recording).
- No public API to switch AirPods noise-control mode (ANC / Transparency / Adaptive).
- An app cannot **start** recording while in the background (`AVAudioSession` reports
  `cannotStartRecording`); listening must be started in the foreground and then continues.
- The orange microphone indicator and the system privacy indicators are always shown while recording.
- iOS may suspend or terminate background apps under resource pressure; continuous monitoring is
  best-effort, which is one reason the app must not be presented as a safety system.

---

## 3. Known issue: ~0.5 s media stall at start/stop

Observed in T3b (Window 1). Probable cause (hypothesis, **still not verified**): activating or
deactivating a recording-capable session, or starting/stopping the input of the IO unit,
reconfigures the audio hardware (duplex IO, buffer size, Bluetooth link parameters), which briefly
interrupts the shared output stream.

### Window 2 investigation (code inspection + Simulator; no device measurement yet)

Per Start, Window 1 called `setCategory` → `setActive(true)` → `setPreferredInput` → engine start;
per Stop: engine stop → `setActive(false, .notifyOthersOnDeactivation)`. Each of these can trigger a
route reconfiguration (Window 1's log showed a `routeConfigurationChange` at each start and stop).

Changes (no change to the verified category/mode/options or to the A2DP route):

1. `AudioSessionController.activate` skips `setCategory` when category, mode and options already
   match, skips `setActive(true)` when this controller already activated the session, and skips
   `setPreferredInput` when the same port is already preferred. Each step is logged with its
   duration (log line format: "Activation steps: setCategory <ms> | skipped, setActive(true) <ms> | skipped,
   setPreferredInput <ms>").
   Engine start/stop durations are logged too.
2. Experiment toggle **Recognition diagnostics → "Keep audio session active when stopped"**
   (default off). With it on, Stop removes the tap and stops the engine (microphone off, orange
   indicator off) but does not deactivate the session; the next Start then only starts the engine.
   Turning the toggle off while stopped deactivates the session.

What this can and cannot fix:

- If the stall comes from session (de)activation or redundant reconfiguration, the toggle should
  remove the stall at Stop and at the following Start.
- If it comes from enabling/disabling the input of the IO unit (engine start/stop), it will remain;
  that would be an iOS hardware route transition and should be documented as unavoidable rather
  than worked around with unstable routing tricks.
- iOS 27 adds `AVAudioSession.activate(options:completionHandler:)` /
  `deactivate(options:completionHandler:)`. The Simulator logged a runtime "hang risk" warning for
  the synchronous `setActive` on the main thread. Adopting the async API (behind `#available(iOS 27)`)
  would remove main-thread blocking; there is no evidence it changes the audible stall. Not adopted
  in Window 2.

**Measurement still required (Test S, `docs/testing/WINDOW2_DEVICE_TESTS.md`)**: Spotify on AirPods;
three Start/Stop cycles with the toggle off and three with it on; the student reports by ear whether
the stall occurs at Start and at Stop; the event log provides the step timings. Until then, the
default stays the Window 1 behaviour (deactivate on Stop), which is verified to hand audio back to
other apps cleanly.

## 4. How to re-run the device tests

1. Open `apps/ios/HearingSense.xcodeproj`, choose your Personal Team under Signing & Capabilities,
   select the iPhone as run destination, press Run.
2. Follow T1–T4 above. Use **Audio route diagnostics → Share** to export the full text report
   (route snapshot + event log; contains no audio).
3. Screenshots can be taken from the Mac:
   `xcrun devicectl device capture screenshot --device <UDID> --destination shot.png`.
