import Foundation
import HearingSenseDomain

/// Which table an icon came from.
public enum SoundSymbolLevel: String, Hashable, Sendable, Codable {
    /// A symbol chosen for this exact classifier label (`dog_bark` → dog).
    case label
    /// The symbol of the label's event kind (`engine_idling` → road vehicle).
    case kind
    /// The symbol of the kind's category (a label or kind this table does not know).
    case category
}

public struct SoundSymbol: Hashable, Sendable {
    /// SF Symbol name.
    public var name: String
    public var level: SoundSymbolLevel

    public init(name: String, level: SoundSymbolLevel) {
        self.name = name
        self.level = level
    }
}

/// SF Symbols for the icon-only presentation of sounds (Window 5).
///
/// Three levels, most specific first: classifier label → event kind → category. Every label of
/// Apple's built-in classifier resolves to a symbol through its kind (see `SoundTaxonomy.appleV1`
/// in SoundEventDetection); a label has its own entry only where a more telling symbol exists.
/// A label or kind that is not listed (a future OS, another classifier) falls back to the
/// category symbol, so nothing is ever without an icon.
///
/// An icon says what kind of sound was classified. It does not say how important the sound is
/// and it is never the only way the information is conveyed: views attach the kind's name as an
/// accessibility label.
public enum SoundSymbolCatalog {
    public static func symbol(label: SoundLabel, kindID: String, category: SoundCategory) -> SoundSymbol {
        if let name = labelSymbols[label.rawValue] { return SoundSymbol(name: name, level: .label) }
        if let name = kindSymbols[kindID] { return SoundSymbol(name: name, level: .kind) }
        return SoundSymbol(name: category.systemImage, level: .category)
    }

    public static func symbol(for event: ConfirmedAcousticEvent) -> SoundSymbol {
        symbol(label: event.primaryLabel, kindID: event.kind.id, category: event.category)
    }

    /// Every symbol name this catalog can return (for availability checks).
    public static var allSymbolNames: Set<String> {
        Set(labelSymbols.values).union(kindSymbols.values).union(SoundCategory.allCases.map(\.systemImage))
    }

    /// One symbol per event kind of the app's taxonomy.
    public static let kindSymbols: [String: String] = [
        // Speech
        "speech": "person.wave.2",
        "shouting": "exclamationmark.bubble",
        // Alerts
        "siren": "light.beacon.max",
        "vehicle_horn": "horn.blast",
        "alarm": "alarm.waves.left.and.right",
        "reverse_beeps": "truck.box",
        "bicycle_bell": "bicycle",
        // Transportation
        "road_vehicle": "car.side",
        "rail": "tram",
        "aircraft": "airplane",
        "boat": "ferry",
        "bicycle_skateboard": "bicycle",
        // Household
        "door": "door.left.hand.closed",
        "phone": "iphone.radiowaves.left.and.right",
        "beep": "dot.radiowaves.left.and.right",
        "kitchen": "fork.knife",
        "water_use": "drop",
        "appliance": "fan",
        "tools": "hammer",
        "typing_writing": "keyboard",
        "clock": "clock",
        "small_objects": "hand.tap",
        // Impacts
        "bang": "burst",
        "glass_breaking": "burst",
        "impact": "burst",
        // Human activity
        "laughter": "face.smiling",
        "crying": "exclamationmark.bubble",
        "screaming": "exclamationmark.bubble",
        "body_sounds": "lungs",
        "footsteps": "shoeprints.fill",
        "hands": "hands.clap",
        "whistling": "mouth",
        "sports": "sportscourt",
        // Animals
        "dog": "dog",
        "cat": "cat",
        "bird": "bird",
        "farm_animal": "pawprint",
        "insect": "ant",
        "wild_animal": "pawprint",
        // Music
        "music": "music.note",
        "bell": "bell",
        // Weather & nature
        "wind": "wind",
        "rain": "cloud.rain",
        "thunder": "cloud.bolt",
        "water_body": "water.waves",
        "fire": "flame",
        // Crowd
        "crowd": "person.3",
        // Other
        "mic_wind_noise": "wind",
        "whoosh": "wind",
        "unmapped": "waveform",
    ]

    /// Labels with a symbol of their own. Keys are classifier labels, verbatim.
    public static let labelSymbols: [String: String] = {
        var table: [String: String] = [
            // Speech
            "chatter": "bubble.left.and.bubble.right",
            // Alerts
            "ambulance_siren": "staroflife",
            "civil_defense_siren": "megaphone",
            "train_horn": "train.side.front.car",
            "train_whistle": "train.side.front.car",
            "foghorn": "ferry",
            "smoke_detector": "smoke",
            "alarm_clock": "alarm",
            // Transportation
            "race_car": "flag.checkered",
            "truck": "truck.box",
            "bus": "bus",
            "motorcycle": "motorcycle",
            "traffic_noise": "car.2",
            "power_windows": "car.window.right",
            "train": "train.side.front.car",
            "railroad_car": "train.side.front.car",
            "subway_metro": "tram.fill.tunnel",
            "sailing": "sailboat",
            "rowboat_canoe_kayak": "oar.2.crossed",
            "skateboard": "skateboard",
            // Household
            "door_bell": "bell.and.waves.left.and.right",
            "door_sliding": "door.sliding.left.hand.closed",
            "tap": "hand.tap",
            "telephone": "phone",
            "dishes_pots_pans": "frying.pan",
            "frying_food": "frying.pan",
            "microwave_oven": "microwave",
            "glass_clink": "wineglass",
            "boiling": "cooktop",
            "chopping_food": "carrot",
            "water_tap_faucet": "spigot",
            "sink_filling_washing": "sink",
            "bathtub_filling_washing": "bathtub",
            "toilet_flush": "toilet",
            "liquid_spraying": "sprinkler.and.droplets",
            "liquid_pouring": "waterbottle",
            "liquid_filling_container": "waterbottle",
            "underwater_bubbling": "bubbles.and.sparkles",
            "vacuum_cleaner": "robotic.vacuum",
            "electric_shaver": "mustache",
            "toothbrush": "mouth",
            "mechanical_fan": "fan.desk",
            "air_conditioner": "air.conditioner.horizontal",
            "printer": "printer",
            "saw": "wrench.and.screwdriver",
            "power_tool": "wrench.adjustable",
            "drill": "wrench.adjustable",
            "ratchet_and_pawl": "wrench.adjustable",
            "hedge_trimmer": "leaf",
            "lawn_mower": "leaf",
            "chainsaw": "tree",
            "chopping_wood": "tree",
            "writing": "pencil",
            "keys_jangling": "key",
            "coin_dropping": "centsign.circle",
            "scissors": "scissors",
            "camera": "camera",
            "drawer_open_close": "cabinet",
            "click": "computermouse",
            "crumpling_crinkling": "doc",
            "tearing": "doc",
            // Impacts
            "fireworks": "fireworks",
            "firecracker": "fireworks",
            "slap_smack": "hand.raised",
            "wood_cracking": "tree",
            // Human activity
            "baby_crying": "stroller",
            "cough": "facemask",
            "sneeze": "facemask",
            "snoring": "zzz",
            "nose_blowing": "nose",
            "person_running": "figure.run",
            "person_walking": "figure.walk",
            "basketball_bounce": "basketball",
            "bowling_impact": "figure.bowling",
            "playing_badminton": "figure.badminton",
            "playing_hockey": "figure.hockey",
            "playing_squash": "figure.squash",
            "playing_table_tennis": "figure.table.tennis",
            "playing_tennis": "tennisball",
            "playing_volleyball": "volleyball",
            "rope_skipping": "figure.jumprope",
            "scuba_diving": "figure.pool.swim",
            "skiing": "figure.skiing.downhill",
            // Animals
            "horse_clip_clop": "figure.equestrian.sports",
            "horse_neigh": "figure.equestrian.sports",
            "snake_hiss": "lizard",
            "snake_rattle": "lizard",
            "whale_vocalization": "fish",
            "bird_flapping": "bird",
            // Music
            "orchestra": "music.note.list",
            "disc_scratching": "record.circle",
            "tuning_fork": "tuningfork",
            "wind_chime": "wind",
            // Weather & nature
            "wind_rustling_leaves": "leaf",
            "raindrop": "drop",
            "thunderstorm": "cloud.bolt.rain",
            // Crowd
            "applause": "hands.clap",
            "cheering": "party.popper",
            "booing": "hand.thumbsdown",
        ]
        let groups: [(symbol: String, labels: [String])] = [
            ("engine.combustion", ["engine", "engine_knocking", "engine_starting", "engine_idling",
                                   "engine_accelerating_revving"]),
            ("mouth", ["chewing", "biting", "slurp", "gargling", "burp", "hiccup"]),
            ("bird", ["fowl", "chicken", "chicken_cluck", "rooster_crow", "turkey_gobble", "duck_quack", "goose_honk"]),
            ("music.mic", ["singing", "choir_singing", "yodeling", "rapping", "humming"]),
            ("guitars", ["plucked_string_instrument", "guitar", "electric_guitar", "bass_guitar", "acoustic_guitar",
                         "steel_guitar_slide_guitar", "guitar_tapping", "guitar_strum", "banjo", "sitar", "mandolin",
                         "zither", "ukulele"]),
            ("pianokeys", ["keyboard_musical", "piano", "electric_piano", "organ", "electronic_organ", "hammond_organ",
                           "synthesizer", "harpsichord", "accordion"]),
            ("music.quarternote.3", ["percussion", "drum_kit", "drum", "snare_drum", "bass_drum", "timpani", "tabla",
                                     "cymbal", "hi_hat", "tambourine", "rattle_instrument", "gong", "mallet_percussion",
                                     "marimba_xylophone", "glockenspiel", "vibraphone", "steelpan"]),
        ]
        for group in groups {
            for label in group.labels { table[label] = group.symbol }
        }
        return table
    }()
}
