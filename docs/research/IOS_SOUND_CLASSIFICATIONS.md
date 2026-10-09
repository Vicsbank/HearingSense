# Apple SoundAnalysis Classifications on iOS — Inventory and Verification

Window 2 (2026-10-09). Classifier: `SNClassifySoundRequest(classifierIdentifier: .version1)` —
the only built-in classifier identifier in the iOS 27.0 / macOS 27 SDKs (`SNTypes.h`).

## 1. Reproducible enumeration mechanism

The same API call is used everywhere, so results are comparable:

```swift
let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
request.knownClassifications        // [String], framework order
request.windowDurationConstraint    // .durationRange / .enumeratedDurations
request.windowDuration, request.overlapFactor   // defaults
```

Implemented once in `SoundClassifierCatalog.load()` (SoundEventDetection) and used by:

| Where | How to run | Output |
|---|---|---|
| macOS | `cd packages/HearingSenseKit && swift run -c release hs-sound-eval labels` | `docs/research/sound_analysis_labels_v1_macos27_mapped.tsv` (label, kind, category) |
| Tests (macOS + iOS Simulator) | `SoundTaxonomyTests.matchesTheLiveClassifierInventory` | Fails if the live inventory differs from the taxonomy |
| App (Simulator or iPhone) | Recognition diagnostics → **Classifier labels on this device** → *Share label inventory* | Same text format, with platform line and taxonomy coverage |

`SoundTaxonomy.coverage(of:)` reports labels the device has but the taxonomy lacks (they would map
to `other`) and taxonomy labels the device does not report.

## 2. Results

| Platform | Evidence | Labels | Default window / overlap | Window constraint | vs. taxonomy |
|---|---|---|---|---|---|
| macOS 27.2 (M1 Max) | Window 1 file + `hs-sound-eval labels` (2026-10-09) | **303** | 3.0 s / 0.5 | range 0.5 … 15.0000625 s | exact match; identical order to `sound_analysis_labels_v1_macos27.txt` |
| iOS 27.0 Simulator, iPhone 18 Pro (on the Mac) | App screen, screenshot `docs/device-tests/window2-simulator/05_classifier_labels_303.jpg`; unit test passed on the Simulator | **303** | 3 s / 0.5 | range 0.5 … 15.0000625 s | **exact match** |
| iPhone 18 Pro, iOS 27.2 (physical) | **Not yet verified** — needs the device (see `docs/testing/WINDOW2_DEVICE_TESTS.md`, test L) | — | — | — | — |

Differences macOS ↔ iOS Simulator: **none** in labels, order-independent set, defaults or constraint.
The Simulator runs the iOS runtime's copy of SoundAnalysis on Mac hardware, so it is evidence about
the iOS framework build, not about the iPhone's Neural Engine path. Until the physical check is
done, the claim "the iPhone exposes the same 303 labels" is an expectation, not a verified fact.

Total supported labels (verified on macOS 27.2 and the iOS 27.0 Simulator): **303**. The identifiers
are lower-case snake_case strings (e.g. `dog_bark`) and are preserved unchanged as `SoundLabel`;
human-readable names come from `SoundTaxonomy.displayName(for:)` (curated overrides, otherwise
`dog_bark` → "Dog bark").

The full list with kinds and categories: `docs/research/sound_analysis_labels_v1_macos27_mapped.tsv`.
Grouping rationale and difficult labels: `docs/research/SOUND_CATEGORY_MAPPING.md`.

## 3. Labels most relevant to Hearing Sense

Chosen for awareness value to someone wearing ANC headphones (relevance ≠ reliability; see the
Window 2 report for measured behaviour):

- **Speech / voices**: `speech`, `chatter`, `shout`, `yell`, `children_shouting`, `whispering`
- **Warning signals**: `siren`, `police_siren`, `ambulance_siren`, `fire_engine_siren`,
  `emergency_vehicle`, `civil_defense_siren`, `car_horn`, `air_horn`, `train_horn`, `reverse_beeps`,
  `bicycle_bell`, `smoke_detector`, `alarm_clock`
- **Someone at the door / calling**: `knock`, `door_bell`, `door`, `telephone_bell_ringing`, `ringtone`
- **People in distress**: `screaming`, `baby_crying`, `crying_sobbing`
- **Sudden danger cues**: `glass_breaking`, `gunshot_gunfire`, `boom`, `vehicle_skidding`
- **Traffic context**: `traffic_noise`, `car_passing_by`, `bus`, `truck`, `motorcycle`, `train`, `subway_metro`
- **Animals near the user**: `dog_bark`, `dog_growl`
- **Context**: `music`, `crowd`, `babble`, `rain`, `wind`, `thunder`

## 4. Labels that are difficult to interpret

See `SOUND_CATEGORY_MAPPING.md` § "Labels that are difficult to interpret" (e.g. `silence`,
`wind_noise_microphone`, `tap`, `water`, `bell`, `beep`, `boom`, `engine_knocking`).
