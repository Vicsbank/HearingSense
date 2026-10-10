"""Common target taxonomy for the cross-model benchmark: every model's labels are mapped to the
existing Hearing Sense event kinds (SoundTaxonomy.appleV1, 50 kinds).

- Apple labels → kind: read from docs/research/sound_analysis_labels_v1_macos27_mapped.tsv, the
  export of the production taxonomy (not re-typed here).
- AudioSet labels (YAMNet 521, EfficientAT 527) → kind: AUDIOSET_TO_KIND below, written by hand
  for this research window. Relations:
    exact   the AudioSet class is the same concept as an Apple label of that kind
    within  the AudioSet class lies inside the kind but Apple has no label of that name
    broader the AudioSet class covers more than the kind; listed for documentation, NOT scored
  AudioSet classes that are not listed are unmapped and never contribute to a kind score.
- ESC-50 classes → kind (ground truth): ESC50_TO_KIND; classes without a defensible kind are
  excluded from the ground truth (ESC50_EXCLUDED), not forced into one.
"""
import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
APPLE_TSV = ROOT / "docs" / "research" / "sound_analysis_labels_v1_macos27_mapped.tsv"

# kind: (exact, within, broader)
AUDIOSET_TO_KIND = {
    "aircraft": (["Aircraft", "Helicopter", "Fixed-wing aircraft, airplane"],
                 ["Aircraft engine", "Jet engine", "Propeller, airscrew"], []),
    "alarm": (["Alarm clock", "Smoke detector, smoke alarm"], ["Fire alarm", "Buzzer", "Car alarm"], ["Alarm"]),
    "appliance": (["Hair dryer", "Toothbrush", "Vacuum cleaner", "Electric shaver, electric razor", "Sewing machine",
                   "Mechanical fan", "Air conditioning", "Printer"], ["Electric toothbrush"], []),
    "bang": (["Gunshot, gunfire", "Artillery fire", "Fireworks", "Firecracker", "Eruption", "Boom"],
             ["Machine gun", "Fusillade", "Cap gun", "Explosion"], []),
    "beep": (["Beep, bleep"], [], []),
    "bell": (["Bell", "Church bell", "Cowbell", "Tuning fork", "Chime", "Wind chime", "Singing bowl"],
             ["Jingle bell", "Change ringing (campanology)"], []),
    "bicycle_bell": (["Bicycle bell"], [], []),
    "bicycle_skateboard": (["Bicycle", "Skateboard"], [], []),
    "bird": (["Bird", "Bird vocalization, bird call, bird song", "Chirp, tweet", "Squawk", "Pigeon, dove", "Coo",
              "Crow", "Caw", "Owl", "Hoot", "Bird flight, flapping wings"], [], []),
    "boat": (["Boat, Water vehicle", "Sailboat, sailing ship", "Rowboat, canoe, kayak", "Motorboat, speedboat"],
             ["Ship"], []),
    "body_sounds": (["Sigh", "Breathing", "Snoring", "Gasp", "Cough", "Sneeze", "Chewing, mastication", "Biting",
                     "Gargling", "Burping, eructation", "Hiccup"],
                    ["Wheeze", "Pant", "Snort", "Throat clearing", "Sniff", "Stomach rumble", "Fart", "Groan", "Grunt"], []),
    "cat": (["Cat", "Purr", "Meow"], ["Caterwaul"], []),
    "clock": (["Clock", "Tick", "Tick-tock"], [], []),
    "crowd": (["Cheering", "Applause", "Crowd", "Hubbub, speech noise, speech babble"], [], []),
    "crying": (["Crying, sobbing", "Baby cry, infant cry"], ["Whimper", "Wail, moan"], []),
    "dog": (["Dog", "Bark", "Howl", "Bow-wow", "Growling", "Whimper (dog)"], ["Yip"],
            ["Canidae, dogs, wolves", "Domestic animals, pets"]),
    "door": (["Door", "Doorbell", "Sliding door", "Slam", "Knock", "Tap"], ["Ding-dong"], []),
    "farm_animal": (["Clip-clop", "Neigh, whinny", "Moo", "Oink", "Bleat", "Fowl", "Chicken, rooster", "Cluck",
                     "Crowing, cock-a-doodle-doo", "Gobble", "Quack", "Honk"],
                    ["Horse", "Cattle, bovinae", "Pig", "Goat", "Sheep", "Turkey", "Duck", "Goose",
                     "Livestock, farm animals, working animals"], []),
    "fire": (["Fire", "Crackle"], [], []),
    "footsteps": (["Run", "Shuffle", "Walk, footsteps"], [], []),
    "glass_breaking": (["Shatter"], [], ["Glass", "Smash, crash", "Breaking"]),
    "hands": (["Finger snapping", "Clapping"], ["Hands"], []),
    "impact": (["Crack", "Thump, thud", "Slap, smack"], ["Thunk", "Whack, thwack"], ["Bang"]),
    "insect": (["Insect", "Cricket", "Mosquito", "Fly, housefly", "Bee, wasp, etc."], ["Buzz"], []),
    "kitchen": (["Dishes, pots, and pans", "Cutlery, silverware", "Chopping (food)", "Frying (food)", "Microwave oven",
                 "Blender", "Chink, clink", "Boiling"], ["Sizzle", "Stir"], []),
    "laughter": (["Laughter", "Baby laughter", "Giggle", "Snicker", "Belly laugh", "Chuckle, chortle"], [], []),
    "mic_wind_noise": (["Wind noise (microphone)"], [], []),
    "phone": (["Telephone", "Telephone bell ringing", "Ringtone"],
              ["Telephone dialing, DTMF", "Dial tone", "Busy signal"], []),
    "rail": (["Rail transport", "Train", "Railroad car, train wagon", "Train wheels squealing",
              "Subway, metro, underground"], [], []),
    "rain": (["Rain", "Raindrop"], ["Rain on surface"], []),
    "reverse_beeps": (["Reversing beeps"], [], []),
    "road_vehicle": (["Power windows, electric windows", "Skidding", "Car passing by", "Race car, auto racing", "Truck",
                      "Bus", "Motorcycle", "Traffic noise, roadway noise", "Engine", "Engine knocking", "Engine starting",
                      "Idling", "Accelerating, revving, vroom"],
                     ["Car", "Motor vehicle (road)", "Tire squeal", "Air brake", "Light engine (high frequency)",
                      "Medium engine (mid frequency)", "Heavy engine (low frequency)"], ["Vehicle"]),
    "screaming": (["Screaming"], [], []),
    "shouting": (["Shout", "Yell", "Battle cry", "Children shouting"], ["Bellow", "Whoop"], []),
    "silence": (["Silence"], [], []),
    "siren": (["Emergency vehicle", "Police car (siren)", "Ambulance (siren)", "Fire engine, fire truck (siren)", "Siren",
               "Civil defense siren"], [], []),
    "small_objects": (["Squeak", "Drawer open or close", "Zipper (clothing)", "Keys jangling", "Coin (dropping)",
                       "Scissors", "Camera", "Crushing", "Crumpling, crinkling", "Tearing", "Clicking"],
                      ["Single-lens reflex camera", "Cupboard open or close", "Shuffling cards"], []),
    "speech": (["Speech", "Whispering", "Chatter"],
               ["Male speech, man speaking", "Female speech, woman speaking", "Child speech, kid speaking",
                "Conversation", "Narration, monologue", "Speech synthesizer", "Babbling"], []),
    "sports": (["Basketball bounce"], [], []),
    "thunder": (["Thunderstorm", "Thunder"], [], []),
    "tools": (["Lawn mower", "Chainsaw", "Ratchet, pawl", "Hammer", "Sawing", "Power tool", "Drill", "Chop"],
              ["Jackhammer", "Filing (rasp)", "Sanding", "Tools", "Dental drill, dentist's drill"], []),
    "typing_writing": (["Typing", "Typewriter", "Computer keyboard", "Writing"], [], []),
    "vehicle_horn": (["Vehicle horn, car horn, honking", "Air horn, truck horn", "Train whistle", "Train horn", "Foghorn"],
                     ["Toot"], []),
    "water_body": (["Water", "Stream", "Waterfall", "Ocean", "Waves, surf", "Gurgling"], [], []),
    "water_use": (["Water tap, faucet", "Sink (filling or washing)", "Bathtub (filling or washing)", "Toilet flush",
                   "Splash, splatter", "Slosh", "Squish", "Drip", "Pour", "Trickle, dribble", "Fill (with liquid)", "Spray",
                   "Pump (liquid)"], ["Gush", "Liquid"], []),
    "whistling": (["Whistling"], [], []),
    "whoosh": (["Whoosh, swoosh, swish"], [], []),
    "wild_animal": (["Roaring cats (lions, tigers)", "Frog", "Croak", "Snake", "Rattle", "Whale vocalization"],
                    ["Roar", "Wild animals"], []),
    "wind": (["Wind", "Rustling leaves"], [], []),
}

# The Apple taxonomy puts singing and every instrument / genre under the kind "music". In AudioSet
# these are the classes from "Singing" to "Humming" and from "Music" to "Scary music" in ontology
# order, minus the bell family (kind "bell"). Names with an Apple label of the same concept:
MUSIC_EXACT = {
    "Singing", "Choir", "Yodeling", "Rapping", "Humming", "Music", "Plucked string instrument", "Guitar",
    "Electric guitar", "Bass guitar", "Acoustic guitar", "Steel guitar, slide guitar", "Tapping (guitar technique)",
    "Strum", "Banjo", "Sitar", "Mandolin", "Zither", "Ukulele", "Keyboard (musical)", "Piano", "Electric piano", "Organ",
    "Electronic organ", "Hammond organ", "Synthesizer", "Harpsichord", "Percussion", "Drum kit", "Drum", "Snare drum",
    "Bass drum", "Timpani", "Tabla", "Cymbal", "Hi-hat", "Tambourine",
}
MUSIC_RANGES = [("Singing", "Humming"), ("Music", "Scary music")]

ESC50_TO_KIND = {
    "dog": "dog", "rooster": "farm_animal", "pig": "farm_animal", "cow": "farm_animal", "hen": "farm_animal",
    "sheep": "farm_animal", "frog": "wild_animal", "cat": "cat", "insects": "insect", "crickets": "insect",
    "crow": "bird", "chirping_birds": "bird", "rain": "rain", "sea_waves": "water_body", "crackling_fire": "fire",
    "water_drops": "water_use", "pouring_water": "water_use", "toilet_flush": "water_use", "wind": "wind",
    "thunderstorm": "thunder", "crying_baby": "crying", "sneezing": "body_sounds", "coughing": "body_sounds",
    "breathing": "body_sounds", "snoring": "body_sounds", "drinking_sipping": "body_sounds", "clapping": "hands",
    "footsteps": "footsteps", "laughing": "laughter", "brushing_teeth": "appliance", "vacuum_cleaner": "appliance",
    "door_wood_knock": "door", "mouse_click": "small_objects", "keyboard_typing": "typing_writing",
    "clock_alarm": "alarm", "clock_tick": "clock", "glass_breaking": "glass_breaking", "helicopter": "aircraft",
    "airplane": "aircraft", "chainsaw": "tools", "hand_saw": "tools", "siren": "siren", "car_horn": "vehicle_horn",
    "engine": "road_vehicle", "train": "rail", "church_bells": "bell", "fireworks": "bang",
}
ESC50_EXCLUDED = {
    "door_wood_creaks": "no kind: Apple files 'squeak' under small objects, AudioSet has 'Creak'/'Squeak'; ambiguous",
    "can_opening": "no corresponding label in either taxonomy",
    "washing_machine": "no corresponding label in either taxonomy",
}
# Kinds the product cares most about (prompt §16) that have ground truth in this benchmark.
PRIORITY_KINDS = ["speech", "music", "door", "vehicle_horn", "siren", "alarm", "dog", "glass_breaking", "crying",
                  "rain", "wind", "thunder", "footsteps", "hands", "road_vehicle"]
ALERT_KINDS = ["door", "vehicle_horn", "siren", "alarm", "dog", "glass_breaking", "crying"]


def apple_label_to_kind():
    mapping = {}
    with open(APPLE_TSV) as file:
        for line in file:
            if line.startswith("#") or not line.strip():
                continue
            label, kind, _category = line.rstrip("\n").split("\t")
            mapping[label] = kind
    return mapping


def audioset_label_to_kind(labels):
    """→ {label: (kind, relation)} for the scored relations (exact, within) present in `labels`,
    plus the list of names in the table that the model does not have."""
    mapping, missing = {}, []
    for kind, (exact, within, _broader) in AUDIOSET_TO_KIND.items():
        for relation, names in (("exact", exact), ("within", within)):
            for name in names:
                if name in labels:
                    assert name not in mapping, name
                    mapping[name] = (kind, relation)
                else:
                    missing.append(name)
    bell_family = {name for names in AUDIOSET_TO_KIND["bell"][:2] for name in names} | {"Bicycle bell"}
    for first, last in MUSIC_RANGES:
        if first not in labels or last not in labels:
            continue
        for name in labels[labels.index(first): labels.index(last) + 1]:
            if name in bell_family or name in mapping:
                continue
            mapping[name] = ("music", "exact" if name in MUSIC_EXACT else "within")
    return mapping, missing


def kinds():
    return sorted(set(apple_label_to_kind().values()))


def write_mapping_table(path, yamnet, efficientat):
    """The full AudioSet → kind table (including broader and unmapped classes) for the docs."""
    scored, _ = audioset_label_to_kind(efficientat)
    broader = {name: kind for kind, (_, _, names) in AUDIOSET_TO_KIND.items() for name in names}
    with open(path, "w", newline="") as file:
        writer = csv.writer(file, delimiter="\t")
        writer.writerow(["audioset_index", "audioset_class", "kind", "relation", "scored", "in_yamnet_521"])
        for index, name in enumerate(efficientat):
            if name in scored:
                kind, relation = scored[name]
            elif name in broader:
                kind, relation = broader[name], "broader"
            else:
                kind, relation = "", "unmapped"
            writer.writerow([index, name, kind, relation, "yes" if name in scored else "no",
                             "yes" if name in yamnet else "no"])


if __name__ == "__main__":
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "audio_models"))
    import candidates

    eat, yam = candidates.efficientat_labels(), candidates.yamnet_labels()
    mapping, missing = audioset_label_to_kind(eat)
    yam_mapping, yam_missing = audioset_label_to_kind(yam)
    print("EfficientAT 527: mapped", len(mapping), "unmapped", len(eat) - len(mapping), "table names missing", missing)
    print("YAMNet 521: mapped", len(yam_mapping), "unmapped", len(yam) - len(yam_mapping), "missing", yam_missing)
    print("relations:", {r: sum(1 for v in mapping.values() if v[1] == r) for r in ("exact", "within")})
    apple = apple_label_to_kind()
    print("Apple labels", len(apple), "kinds", len(kinds()), "kinds without AudioSet mapping:",
          sorted(set(apple.values()) - {k for k, _ in mapping.values()}))
    print("ESC-50 kinds:", len(set(ESC50_TO_KIND.values())), "classes mapped", len(ESC50_TO_KIND))
    out = ROOT / "docs" / "research" / "audioset_to_hearingsense_mapping.tsv"
    write_mapping_table(out, yam, eat)
    print("wrote", out)
