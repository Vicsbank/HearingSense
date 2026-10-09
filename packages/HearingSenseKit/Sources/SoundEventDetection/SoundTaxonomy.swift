import HearingSenseDomain

/// How a kind of sound typically unfolds in time. Selects the default confirmation rule.
public enum TemporalProfile: String, CaseIterable, Hashable, Sendable, Codable {
    /// Short, often single sounds: knock, horn, door slam, gunshot, clap.
    case transient
    /// Repeating or bursty: sirens, alarms, barking, laughter, footsteps.
    case intermittent
    /// Sustained: speech, music, rain, engines, crowds.
    case continuous
}

/// One trackable kind and the classifier labels that feed it.
public struct SoundKindDefinition: Hashable, Sendable {
    public let kind: SoundEventKind
    public let profile: TemporalProfile
    public let labels: [SoundLabel]
    /// False for kinds that must never become events (`silence`).
    public let producesEvents: Bool
}

/// Maps raw classifier labels → event kinds → semantic categories, and labels → display names.
///
/// The single source of truth for the mapping; nothing else in the app should hard-code label
/// strings. Labels are kept verbatim (`SoundLabel`). A label the table does not know (e.g. a
/// label added by a future OS) maps to the `unmapped` kind in category `.other`, so it is still
/// visible and can be reported, never silently dropped.
public struct SoundTaxonomy: Sendable {
    public let model: SoundModelID
    public let definitions: [SoundKindDefinition]
    public let silenceLabel: SoundLabel
    public let unmappedKind: SoundKindDefinition
    private let byLabel: [SoundLabel: SoundKindDefinition]
    private let displayNames: [SoundLabel: String]

    init(model: SoundModelID, definitions: [SoundKindDefinition], silenceLabel: SoundLabel,
         displayNames: [SoundLabel: String])
    {
        self.model = model
        self.definitions = definitions
        self.silenceLabel = silenceLabel
        self.displayNames = displayNames
        unmappedKind = SoundKindDefinition(
            kind: SoundEventKind(id: "unmapped", displayName: "Unrecognized label", category: .other),
            profile: .intermittent, labels: [], producesEvents: true)
        var index: [SoundLabel: SoundKindDefinition] = [:]
        for definition in definitions {
            for label in definition.labels {
                precondition(index[label] == nil, "Label \(label) is mapped twice")
                index[label] = definition
            }
        }
        byLabel = index
    }

    /// All labels the table maps explicitly.
    public var mappedLabels: Set<SoundLabel> { Set(byLabel.keys) }

    public func definition(for label: SoundLabel) -> SoundKindDefinition {
        byLabel[label] ?? unmappedKind
    }

    public func isMapped(_ label: SoundLabel) -> Bool { byLabel[label] != nil }

    public func category(for label: SoundLabel) -> SoundCategory {
        definition(for: label).kind.category
    }

    public func displayName(for label: SoundLabel) -> String {
        displayNames[label] ?? label.generatedDisplayName
    }

    /// Compares the labels a classifier reports with this table.
    public func coverage(of knownLabels: [SoundLabel]) -> Coverage {
        let known = Set(knownLabels)
        return Coverage(knownCount: known.count,
                        notInTaxonomy: known.subtracting(mappedLabels).sorted(),
                        notReportedByClassifier: mappedLabels.subtracting(known).sorted())
    }

    public struct Coverage: Hashable, Sendable {
        public var knownCount: Int
        /// Labels the classifier can produce that this table does not map (→ `.other`).
        public var notInTaxonomy: [SoundLabel]
        /// Labels in this table that the classifier on this OS does not report.
        public var notReportedByClassifier: [SoundLabel]
        public var isExactMatch: Bool { notInTaxonomy.isEmpty && notReportedByClassifier.isEmpty }
    }
}

// MARK: - Apple SoundAnalysis classifier version 1

extension SoundTaxonomy {
    /// Mapping for `SNClassifierIdentifier.version1` (303 labels enumerated on macOS 27.2; the
    /// iPhone comparison is in docs/research/IOS_SOUND_CLASSIFICATIONS.md). Rationale per kind:
    /// docs/research/SOUND_CATEGORY_MAPPING.md.
    public static let appleV1 = SoundTaxonomy(
        model: .appleSoundClassifierV1,
        definitions: [
            // Speech
            kind("speech", "Speech", .speech, .continuous, ["speech", "whispering", "chatter"]),
            kind("shouting", "Shouting", .speech, .intermittent, ["shout", "yell", "battle_cry", "children_shouting"]),

            // Alerts
            kind("siren", "Siren", .alerts, .intermittent,
                 ["siren", "police_siren", "ambulance_siren", "fire_engine_siren", "emergency_vehicle", "civil_defense_siren"]),
            kind("vehicle_horn", "Horn", .alerts, .transient, ["car_horn", "air_horn", "train_horn", "train_whistle", "foghorn"]),
            kind("alarm", "Alarm", .alerts, .intermittent, ["smoke_detector", "alarm_clock"]),
            kind("reverse_beeps", "Reversing beeps", .alerts, .intermittent, ["reverse_beeps"]),
            kind("bicycle_bell", "Bicycle bell", .alerts, .transient, ["bicycle_bell"]),

            // Transportation
            kind("road_vehicle", "Road vehicle", .transportation, .continuous,
                 ["car_passing_by", "race_car", "truck", "bus", "motorcycle", "traffic_noise", "vehicle_skidding",
                  "power_windows", "engine", "engine_knocking", "engine_starting", "engine_idling",
                  "engine_accelerating_revving"]),
            kind("rail", "Train", .transportation, .continuous,
                 ["rail_transport", "train", "railroad_car", "train_wheels_squealing", "subway_metro"]),
            kind("aircraft", "Aircraft", .transportation, .continuous, ["aircraft", "helicopter", "airplane"]),
            kind("boat", "Boat", .transportation, .continuous,
                 ["boat_water_vehicle", "sailing", "rowboat_canoe_kayak", "motorboat_speedboat"]),
            kind("bicycle_skateboard", "Bicycle or skateboard", .transportation, .intermittent, ["bicycle", "skateboard"]),

            // Household
            kind("door", "Door or knock", .household, .transient,
                 ["door", "door_bell", "door_sliding", "door_slam", "knock", "tap"]),
            kind("phone", "Phone ringing", .household, .intermittent, ["telephone", "telephone_bell_ringing", "ringtone"]),
            kind("beep", "Beep", .household, .intermittent, ["beep"]),
            kind("kitchen", "Kitchen sounds", .household, .intermittent,
                 ["dishes_pots_pans", "cutlery_silverware", "chopping_food", "frying_food", "microwave_oven",
                  "blender", "glass_clink", "boiling"]),
            kind("water_use", "Running water", .household, .continuous,
                 ["water_tap_faucet", "sink_filling_washing", "bathtub_filling_washing", "toilet_flush", "water_pump",
                  "liquid_splashing", "liquid_sloshing", "liquid_squishing", "liquid_dripping", "liquid_pouring",
                  "liquid_trickle_dribble", "liquid_filling_container", "liquid_spraying", "underwater_bubbling"]),
            kind("appliance", "Appliance", .household, .continuous,
                 ["hair_dryer", "vacuum_cleaner", "electric_shaver", "toothbrush", "sewing_machine",
                  "mechanical_fan", "air_conditioner", "printer"]),
            kind("tools", "Tools", .household, .intermittent,
                 ["hammer", "saw", "power_tool", "drill", "hedge_trimmer", "lawn_mower", "chainsaw",
                  "ratchet_and_pawl", "chopping_wood"]),
            kind("typing_writing", "Typing or writing", .household, .intermittent,
                 ["typing", "typewriter", "typing_computer_keyboard", "writing"]),
            kind("clock", "Clock ticking", .household, .continuous, ["clock", "tick", "tick_tock"]),
            kind("small_objects", "Handling objects", .household, .transient,
                 ["zipper", "keys_jangling", "coin_dropping", "scissors", "camera", "squeak", "drawer_open_close",
                  "crumpling_crinkling", "tearing", "crushing", "click"]),

            // Impacts
            kind("bang", "Bang or explosion", .impacts, .transient,
                 ["gunshot_gunfire", "artillery_fire", "fireworks", "firecracker", "eruption", "boom"]),
            kind("glass_breaking", "Breaking glass", .impacts, .transient, ["glass_breaking"]),
            kind("impact", "Thud or impact", .impacts, .transient, ["thump_thud", "slap_smack", "wood_cracking"]),

            // Human activity (non-speech)
            kind("laughter", "Laughter", .humanActivity, .intermittent,
                 ["laughter", "baby_laughter", "giggling", "snicker", "belly_laugh", "chuckle_chortle"]),
            kind("crying", "Crying", .humanActivity, .intermittent, ["crying_sobbing", "baby_crying"]),
            kind("screaming", "Screaming", .humanActivity, .transient, ["screaming"]),
            kind("body_sounds", "Breathing, coughing or eating", .humanActivity, .intermittent,
                 ["sigh", "breathing", "snoring", "gasp", "cough", "sneeze", "nose_blowing", "chewing", "biting",
                  "gargling", "burp", "hiccup", "slurp"]),
            kind("footsteps", "Footsteps", .humanActivity, .intermittent, ["person_running", "person_shuffling", "person_walking"]),
            kind("hands", "Clapping or snapping", .humanActivity, .transient, ["finger_snapping", "clapping"]),
            kind("whistling", "Whistling", .humanActivity, .intermittent, ["whistling"]),
            kind("sports", "Sports", .humanActivity, .intermittent,
                 ["basketball_bounce", "bowling_impact", "playing_badminton", "playing_hockey", "playing_squash",
                  "playing_table_tennis", "playing_tennis", "playing_volleyball", "rope_skipping", "scuba_diving",
                  "skiing"]),

            // Animals
            kind("dog", "Dog", .animals, .intermittent,
                 ["dog", "dog_bark", "dog_howl", "dog_bow_wow", "dog_growl", "dog_whimper"]),
            kind("cat", "Cat", .animals, .intermittent, ["cat", "cat_purr", "cat_meow"]),
            kind("bird", "Bird", .animals, .intermittent,
                 ["bird", "bird_vocalization", "bird_chirp_tweet", "bird_squawk", "pigeon_dove_coo", "crow_caw",
                  "owl_hoot", "bird_flapping"]),
            kind("farm_animal", "Farm animal", .animals, .intermittent,
                 ["horse_clip_clop", "horse_neigh", "cow_moo", "pig_oink", "sheep_bleat", "fowl", "chicken",
                  "chicken_cluck", "rooster_crow", "turkey_gobble", "duck_quack", "goose_honk"]),
            kind("insect", "Insect", .animals, .continuous, ["insect", "cricket_chirp", "mosquito_buzz", "fly_buzz", "bee_buzz"]),
            kind("wild_animal", "Wild animal", .animals, .intermittent,
                 ["lion_roar", "frog", "frog_croak", "snake_hiss", "snake_rattle", "whale_vocalization", "coyote_howl",
                  "elk_bugle"]),

            // Music
            kind("music", "Music", .music, .continuous,
                 ["music", "singing", "choir_singing", "yodeling", "rapping", "humming",
                  "plucked_string_instrument", "guitar", "electric_guitar", "bass_guitar", "acoustic_guitar",
                  "steel_guitar_slide_guitar", "guitar_tapping", "guitar_strum", "banjo", "sitar", "mandolin", "zither",
                  "ukulele", "keyboard_musical", "piano", "electric_piano", "organ", "electronic_organ", "hammond_organ",
                  "synthesizer", "harpsichord", "percussion", "drum_kit", "drum", "snare_drum", "bass_drum", "timpani",
                  "tabla", "cymbal", "hi_hat", "tambourine", "rattle_instrument", "gong", "mallet_percussion",
                  "marimba_xylophone", "glockenspiel", "vibraphone", "steelpan", "orchestra", "brass_instrument",
                  "french_horn", "trumpet", "trombone", "bowed_string_instrument", "violin_fiddle", "cello",
                  "double_bass", "wind_instrument", "flute", "saxophone", "clarinet", "oboe", "bassoon", "harp",
                  "harmonica", "accordion", "bagpipes", "didgeridoo", "shofar", "theremin", "disc_scratching"]),
            kind("bell", "Bell or chime", .music, .intermittent,
                 ["bell", "church_bell", "cowbell", "tuning_fork", "chime", "wind_chime", "singing_bowl"]),

            // Weather & nature
            kind("wind", "Wind", .weatherNature, .continuous, ["wind", "wind_rustling_leaves"]),
            kind("rain", "Rain", .weatherNature, .continuous, ["rain", "raindrop"]),
            kind("thunder", "Thunder", .weatherNature, .intermittent, ["thunderstorm", "thunder"]),
            kind("water_body", "Water", .weatherNature, .continuous,
                 ["water", "stream_burbling", "waterfall", "ocean", "sea_waves", "gurgling"]),
            kind("fire", "Fire", .weatherNature, .continuous, ["fire", "fire_crackle"]),

            // Crowd
            kind("crowd", "Crowd", .crowd, .continuous, ["crowd", "babble", "cheering", "applause", "booing"]),

            // Other
            kind("mic_wind_noise", "Wind noise on the microphone", .other, .continuous, ["wind_noise_microphone"]),
            kind("whoosh", "Whoosh", .other, .transient, ["whoosh_swoosh_swish"]),
            SoundKindDefinition(kind: SoundEventKind(id: "silence", displayName: "Silence", category: .other),
                                profile: .continuous, labels: ["silence"], producesEvents: false),
        ],
        silenceLabel: "silence",
        displayNames: [
            "chatter": "Chatter (conversation)",
            "battle_cry": "Battle cry",
            "chuckle_chortle": "Chuckle",
            "emergency_vehicle": "Emergency vehicle",
            "reverse_beeps": "Reversing beeps",
            "power_windows": "Power windows",
            "engine_accelerating_revving": "Engine revving",
            "train_wheels_squealing": "Train wheels squealing",
            "subway_metro": "Subway / metro",
            "boat_water_vehicle": "Boat",
            "rowboat_canoe_kayak": "Rowboat / canoe / kayak",
            "motorboat_speedboat": "Motorboat",
            "door_bell": "Doorbell",
            "tap": "Tap (light knock)",
            "telephone_bell_ringing": "Telephone bell ringing",
            "dishes_pots_pans": "Dishes, pots and pans",
            "cutlery_silverware": "Cutlery",
            "water_tap_faucet": "Tap water (faucet)",
            "sink_filling_washing": "Sink filling",
            "bathtub_filling_washing": "Bathtub filling",
            "liquid_trickle_dribble": "Trickling liquid",
            "typing_computer_keyboard": "Typing on a computer keyboard",
            "ratchet_and_pawl": "Ratchet",
            "tick_tock": "Tick-tock",
            "crumpling_crinkling": "Crumpling",
            "gunshot_gunfire": "Gunshot",
            "eruption": "Eruption (explosion)",
            "boom": "Boom (explosion)",
            "thump_thud": "Thump",
            "slap_smack": "Slap",
            "whoosh_swoosh_swish": "Whoosh",
            "wind_noise_microphone": "Wind noise on the microphone",
            "wind_rustling_leaves": "Wind in leaves",
            "dog_bow_wow": "Dog bark (bow-wow)",
            "bird_vocalization": "Bird call",
            "bird_chirp_tweet": "Bird chirp",
            "pigeon_dove_coo": "Pigeon / dove coo",
            "fowl": "Fowl (poultry)",
            "keyboard_musical": "Keyboard (musical)",
            "steel_guitar_slide_guitar": "Slide guitar",
            "rattle_instrument": "Rattle (instrument)",
            "marimba_xylophone": "Marimba / xylophone",
            "violin_fiddle": "Violin",
            "disc_scratching": "Record scratching",
            "person_running": "Running footsteps",
            "person_shuffling": "Shuffling footsteps",
            "person_walking": "Walking footsteps",
            "crying_sobbing": "Crying",
            "playing_table_tennis": "Table tennis",
            "playing_badminton": "Badminton",
            "playing_hockey": "Hockey",
            "playing_squash": "Squash",
            "playing_tennis": "Tennis",
            "playing_volleyball": "Volleyball",
        ]
    )

    private static func kind(_ id: String, _ name: String, _ category: SoundCategory, _ profile: TemporalProfile,
                             _ labels: [SoundLabel]) -> SoundKindDefinition
    {
        SoundKindDefinition(kind: SoundEventKind(id: id, displayName: name, category: category),
                            profile: profile, labels: labels, producesEvents: true)
    }
}
