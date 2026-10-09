# Sound Category Mapping — Apple SoundAnalysis `version1` → Hearing Sense

Window 2 (2026-10-09). Source of truth in code:
`packages/HearingSenseKit/Sources/SoundEventDetection/SoundTaxonomy.swift` (`SoundTaxonomy.appleV1`).
The tables below were generated from that code via `hs-sound-eval labels`
(`docs/research/sound_analysis_labels_v1_macos27_mapped.tsv`); regenerate them if the taxonomy changes.

## Three levels, kept separate

| Level | Type | Example | Who uses it |
|---|---|---|---|
| A. Raw classifier label | `SoundLabel` (original identifier, never renamed) | `dog_bark`, score 0.62 | Detector input, diagnostics, evaluation |
| B. Event kind → semantic category | `SoundEventKind` (`id`, display name, `SoundCategory`) | kind `dog` → category `animals` | Grouping synonymous labels; UI; later windows |
| C. Confirmed acoustic event | `ConfirmedAcousticEvent` | "Dog", started 12:03:41, peak 0.81, 4 windows | Windows 3–5 |

A raw label (A) is **evidence**, not an event. Only the temporal detector turns evidence into (C).
The intermediate *kind* exists because the model reports many synonyms for one real source
(`dog`, `dog_bark`, `dog_bow_wow`, `dog_growl`): the detector tracks one event per kind, so the label
flicker `dog_bark → dog → dog_growl` stays one event.

## How the suggested taxonomy changed after inspecting the real label inventory

| Suggestion | Decision | Reason (from the actual 303 labels) |
|---|---|---|
| SPEECH incl. "Conversation" | `speech` = `speech`, `whispering`, `chatter`; separate kind `shouting` | There is no `conversation` label; `chatter` is the closest. Kept linguistic speech only, because Window 3 will gate transcription on this category; crying/screaming/laughter would trigger it uselessly |
| ALERTS: alarm, siren, warning beeps | Kept; **horns moved here** (`car_horn`, `air_horn`, `train_horn`, `train_whistle`, `foghorn`) and `bicycle_bell` | Horns and bicycle bells exist to warn; for a user with ANC the meaning matters more than the vehicle. Category ≠ priority: Window 4 decides importance |
| TRANSPORTATION | Vehicles and engines, grouped as road / rail / aircraft / boat / bicycle-skateboard | 27 labels; `emergency_vehicle` placed in `siren` (its sound is the siren) |
| HOUSEHOLD | Renamed display "Home & devices"; doors/knock, phone, kitchen, water use, appliances, tools, typing, clock, handling objects, `beep` | 67 labels; `door_bell` grouped with `knock` as kind `door` ("someone at the door") |
| HUMAN_ACTIVITY | Laughter, crying, screaming, body sounds, footsteps, clapping, whistling, sports | `screaming` and `crying` kept out of `speech` (see above) |
| ANIMALS | dog, cat, bird, farm animal, insect, wild animal | 42 labels |
| WEATHER | "Weather & nature": wind, rain, thunder, water bodies, fire | `wind_noise_microphone` is **not** weather (it is the microphone being blown) → `other` |
| PUBLIC_ENVIRONMENTS | Replaced by `crowd` (`crowd`, `babble`, `cheering`, `applause`, `booing`) | No labels for announcements, stations or ambience exist in the model |
| — | **New: `impacts`** ("Bangs & impacts"): gunshot, artillery, fireworks, firecracker, eruption, boom, glass breaking, thud, slap, wood cracking | These have no sensible home in the suggested list and are attention-relevant; fireworks/gunshot are acoustically similar, so they share kind `bang` |
| OTHER | `wind_noise_microphone`, `whoosh_swoosh_swish`, `silence` (never an event), and any unknown label | Unknown labels (e.g. added by a future OS) map to kind `unmapped` in `other` — visible, never dropped |

Bells: `bell`, `church_bell`, `chime`, `wind_chime`, `cowbell`, `tuning_fork`, `singing_bowl` follow
the model's music-instrument ontology (kind `bell`, category `music`); `bicycle_bell` is the exception
(alerts). `singing`, `rapping`, `humming`, `choir_singing`, `yodeling` are music, not speech.

## Temporal profiles

Each kind has a profile that selects its default confirmation rule (`DetectionPolicy.standard`, see
`docs/WINDOW2_SOUND_ANALYSIS_REPORT.md` §5):

- **transient** — short sounds that may occupy one or two windows: door/knock, horns, bicycle bell,
  bangs, glass breaking, thuds, screaming, clapping, handling objects, whoosh.
- **intermittent** — repeating or bursty: sirens, alarms, reversing beeps, phone ringing, beeps,
  kitchen, tools, typing, shouting, laughter, crying, body sounds, footsteps, whistling, sports,
  animals (except insects), thunder, bells, bicycle/skateboard.
- **continuous** — sustained: speech, music, road/rail/air/boat traffic, running water, appliances,
  clock, insects, wind, rain, water bodies, fire, crowd, microphone wind noise.

## Complete mapping (303 labels → 50 kinds → 11 categories)

Counts per category: speech 7 · alerts 15 · transportation 27 · household 67 · impacts 10 ·
human activity 39 · animals 42 · music 74 · weather & nature 14 · crowd 5 · other 3.

### Speech (`speech`) — 2 kinds, 7 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `speech` | Speech | continuous | `speech`, `whispering`, `chatter` |
| `shouting` | Shouting | intermittent | `shout`, `yell`, `battle_cry`, `children_shouting` |

### Alerts & sirens (`alerts`) — 5 kinds, 15 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `bicycle_bell` | Bicycle bell | transient | `bicycle_bell` |
| `vehicle_horn` | Horn | transient | `car_horn`, `air_horn`, `train_whistle`, `train_horn`, `foghorn` |
| `reverse_beeps` | Reversing beeps | intermittent | `reverse_beeps` |
| `siren` | Siren | intermittent | `emergency_vehicle`, `police_siren`, `ambulance_siren`, `fire_engine_siren`, `siren`, `civil_defense_siren` |
| `alarm` | Alarm | intermittent | `alarm_clock`, `smoke_detector` |

### Transportation (`transportation`) — 5 kinds, 27 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `boat` | Boat | continuous | `boat_water_vehicle`, `sailing`, `rowboat_canoe_kayak`, `motorboat_speedboat` |
| `road_vehicle` | Road vehicle | continuous | `power_windows`, `vehicle_skidding`, `car_passing_by`, `race_car`, `truck`, `bus`, `motorcycle`, `traffic_noise`, `engine`, `engine_knocking`, `engine_starting`, `engine_idling`, `engine_accelerating_revving` |
| `rail` | Train | continuous | `rail_transport`, `train`, `railroad_car`, `train_wheels_squealing`, `subway_metro` |
| `aircraft` | Aircraft | continuous | `aircraft`, `helicopter`, `airplane` |
| `bicycle_skateboard` | Bicycle or skateboard | intermittent | `bicycle`, `skateboard` |

### Home & devices (`household`) — 10 kinds, 67 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `tools` | Tools | intermittent | `lawn_mower`, `chainsaw`, `ratchet_and_pawl`, `hammer`, `saw`, `power_tool`, `drill`, `hedge_trimmer`, `chopping_wood` |
| `door` | Door or knock | transient | `door`, `door_bell`, `door_sliding`, `door_slam`, `knock`, `tap` |
| `small_objects` | Handling objects | transient | `squeak`, `drawer_open_close`, `zipper`, `keys_jangling`, `coin_dropping`, `scissors`, `camera`, `crushing`, `crumpling_crinkling`, `tearing`, `click` |
| `kitchen` | Kitchen sounds | intermittent | `dishes_pots_pans`, `cutlery_silverware`, `chopping_food`, `frying_food`, `microwave_oven`, `blender`, `glass_clink`, `boiling` |
| `water_use` | Running water | continuous | `water_tap_faucet`, `sink_filling_washing`, `bathtub_filling_washing`, `toilet_flush`, `liquid_splashing`, `liquid_sloshing`, `liquid_squishing`, `liquid_dripping`, `liquid_pouring`, `liquid_trickle_dribble`, `liquid_filling_container`, `liquid_spraying`, `water_pump`, `underwater_bubbling` |
| `appliance` | Appliance | continuous | `hair_dryer`, `toothbrush`, `vacuum_cleaner`, `electric_shaver`, `sewing_machine`, `mechanical_fan`, `air_conditioner`, `printer` |
| `typing_writing` | Typing or writing | intermittent | `typing`, `typewriter`, `typing_computer_keyboard`, `writing` |
| `phone` | Phone ringing | intermittent | `telephone`, `telephone_bell_ringing`, `ringtone` |
| `clock` | Clock ticking | continuous | `clock`, `tick`, `tick_tock` |
| `beep` | Beep | intermittent | `beep` |

### Bangs & impacts (`impacts`) — 3 kinds, 10 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `bang` | Bang or explosion | transient | `gunshot_gunfire`, `artillery_fire`, `fireworks`, `firecracker`, `eruption`, `boom` |
| `impact` | Thud or impact | transient | `wood_cracking`, `thump_thud`, `slap_smack` |
| `glass_breaking` | Breaking glass | transient | `glass_breaking` |

### Human sounds (`humanActivity`) — 8 kinds, 39 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `screaming` | Screaming | transient | `screaming` |
| `laughter` | Laughter | intermittent | `laughter`, `baby_laughter`, `giggling`, `snicker`, `belly_laugh`, `chuckle_chortle` |
| `crying` | Crying | intermittent | `crying_sobbing`, `baby_crying` |
| `body_sounds` | Breathing, coughing or eating | intermittent | `sigh`, `breathing`, `snoring`, `gasp`, `cough`, `sneeze`, `nose_blowing`, `chewing`, `biting`, `gargling`, `burp`, `hiccup`, `slurp` |
| `whistling` | Whistling | intermittent | `whistling` |
| `footsteps` | Footsteps | intermittent | `person_running`, `person_shuffling`, `person_walking` |
| `hands` | Clapping or snapping | transient | `finger_snapping`, `clapping` |
| `sports` | Sports | intermittent | `basketball_bounce`, `bowling_impact`, `playing_badminton`, `playing_hockey`, `playing_squash`, `playing_table_tennis`, `playing_tennis`, `playing_volleyball`, `rope_skipping`, `scuba_diving`, `skiing` |

### Animals (`animals`) — 6 kinds, 42 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `dog` | Dog | intermittent | `dog`, `dog_bark`, `dog_howl`, `dog_bow_wow`, `dog_growl`, `dog_whimper` |
| `cat` | Cat | intermittent | `cat`, `cat_purr`, `cat_meow` |
| `farm_animal` | Farm animal | intermittent | `horse_clip_clop`, `horse_neigh`, `cow_moo`, `pig_oink`, `sheep_bleat`, `fowl`, `chicken`, `chicken_cluck`, `rooster_crow`, `turkey_gobble`, `duck_quack`, `goose_honk` |
| `wild_animal` | Wild animal | intermittent | `lion_roar`, `frog`, `frog_croak`, `snake_hiss`, `snake_rattle`, `whale_vocalization`, `coyote_howl`, `elk_bugle` |
| `bird` | Bird | intermittent | `bird`, `bird_vocalization`, `bird_chirp_tweet`, `bird_squawk`, `pigeon_dove_coo`, `crow_caw`, `owl_hoot`, `bird_flapping` |
| `insect` | Insect | continuous | `insect`, `cricket_chirp`, `mosquito_buzz`, `fly_buzz`, `bee_buzz` |

### Music (`music`) — 2 kinds, 74 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `music` | Music | continuous | `singing`, `choir_singing`, `yodeling`, `rapping`, `humming`, `music`, `plucked_string_instrument`, `guitar`, `electric_guitar`, `bass_guitar`, `acoustic_guitar`, `steel_guitar_slide_guitar`, `guitar_tapping`, `guitar_strum`, `banjo`, `sitar`, `mandolin`, `zither`, `ukulele`, `keyboard_musical`, `piano`, `electric_piano`, `organ`, `electronic_organ`, `hammond_organ`, `synthesizer`, `harpsichord`, `percussion`, `drum_kit`, `drum`, `snare_drum`, `bass_drum`, `timpani`, `tabla`, `cymbal`, `hi_hat`, `tambourine`, `rattle_instrument`, `gong`, `mallet_percussion`, `marimba_xylophone`, `glockenspiel`, `vibraphone`, `steelpan`, `orchestra`, `brass_instrument`, `french_horn`, `trumpet`, `trombone`, `bowed_string_instrument`, `violin_fiddle`, `cello`, `double_bass`, `wind_instrument`, `flute`, `saxophone`, `clarinet`, `oboe`, `bassoon`, `harp`, `harmonica`, `accordion`, `bagpipes`, `didgeridoo`, `shofar`, `theremin`, `disc_scratching` |
| `bell` | Bell or chime | intermittent | `bell`, `church_bell`, `cowbell`, `tuning_fork`, `chime`, `wind_chime`, `singing_bowl` |

### Weather & nature (`weatherNature`) — 5 kinds, 14 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `wind` | Wind | continuous | `wind`, `wind_rustling_leaves` |
| `thunder` | Thunder | intermittent | `thunderstorm`, `thunder` |
| `water_body` | Water | continuous | `water`, `stream_burbling`, `waterfall`, `ocean`, `sea_waves`, `gurgling` |
| `rain` | Rain | continuous | `rain`, `raindrop` |
| `fire` | Fire | continuous | `fire`, `fire_crackle` |

### Crowd (`crowd`) — 1 kinds, 5 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `crowd` | Crowd | continuous | `cheering`, `applause`, `booing`, `crowd`, `babble` |

### Other (`other`) — 3 kinds, 3 labels

| Kind (`id`) | Display name | Temporal profile | Labels (original identifiers) |
|---|---|---|---|
| `mic_wind_noise` | Wind noise on the microphone | continuous | `wind_noise_microphone` |
| `whoosh` | Whoosh | transient | `whoosh_swoosh_swish` |
| `silence` | Silence | (no events) | `silence` |

## Labels that are difficult to interpret

Kept verbatim; noted so later windows do not over-trust them.

| Label | Issue | Handling |
|---|---|---|
| `silence` | A model output, not a measured level; also appears on very quiet input | Never an event; used (with the measured RMS) only for the "Quiet" status |
| `wind_noise_microphone` | Wind hitting the mic, not weather | `other` |
| `chatter` | Several people talking; closest thing to "conversation" | `speech` |
| `emergency_vehicle` | Vehicle or its siren? | `siren` kind (alerts) |
| `water`, `gurgling` | Tap water vs. river vs. rain is ambiguous | `water_body` (weather & nature); tap water has specific labels in `water_use` |
| `tap` | Light knock, not a water tap | `door` kind |
| `bell`, `chime` | Doorbell? church? instrument? | `bell` kind in music; doorbells have `door_bell` |
| `beep`, `click` | Generic device sounds; could be an appliance alert | `beep` own kind (household); `click` in handling objects |
| `boom`, `eruption` | Explosion-like sounds, also triggered by thumps and wind | `bang` kind with stricter rule |
| `thump_thud`, `slap_smack`, `crushing` | Very generic impacts | transient kinds; expect false positives |
| `fowl`, `insect`, `bird` | Parent classes that co-fire with children | Grouped per kind; detector uses the best label |
| `engine_knocking` | Engine sound, not someone knocking | `road_vehicle`, never `door` |
| `rattle_instrument` vs `ratchet_and_pawl` | Easily confused names | music vs tools |
| `scuba_diving`, `skiing`, `playing_*` | Activity labels without a distinctive single sound | `sports` |
| `power_windows`, `camera`, `writing` | Quiet mechanical sounds; low scores in practice | Mapped, rarely confirmed |
| `air_horn` | Fired on ordinary street traffic in DEMAND STRAFFIC with 1 s windows (unverified ground truth) | `vehicle_horn` has a stricter rule (§5 of the report) |
