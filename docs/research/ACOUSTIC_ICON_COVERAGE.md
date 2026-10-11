# Acoustic Icon Mapping and Coverage (Window 6)

The icon a sound gets in the Dynamic Island, for every label of Apple's built-in sound
classifier (`SNClassifySoundRequest`, version 1: 303 labels, enumerated in Window 1). The
classifier itself is unchanged; this is presentation only.

- Table: `docs/research/sound_symbol_mapping_v2.tsv` (label, kind, category, symbol, level,
  drawn by). Regenerate with `swift run hs-attention-eval island-symbols`. The Window 5 table
  (`sound_symbol_mapping_v1.tsv`) is kept for comparison.
- Code: `Sources/IslandPresentation/SoundSymbolCatalog.swift`, `CustomSoundGlyph.swift`;
  drawings in `Sources/IslandViews/SoundSymbolImage.swift`.
- Pictures: `docs/device-tests/window6-icons/` (rendered on the Mac from the widget's views).
- In the app: Diagnostics → "Sound icon gallery (debug)", with search and filters.

## 1. Coverage

| | Labels |
|---|---|
| Total labels mapped | **303 of 303** |
| Icon chosen for the label itself | 160 |
| Icon of the label's kind (the sound shares its meaning with its kind) | 142 |
| Icon of the category | 1 (`silence`, which never becomes an event) |
| Unresolved | 0 |
| Distinct icons | 126 |
| Drawn by the app (9 glyphs) | 15 labels |
| SF Symbols | 288 labels |

The mapping is deterministic: label → kind → category, the most specific entry wins. A label
this table does not know (a future OS) gets its category's icon, so nothing is ever without one.

## 2. What changed from Window 5

| Sound | Window 5 | Window 6 |
|---|---|---|
| Coughing | face mask (kind: lungs) | **drawn**: head with an open mouth and short cough marks |
| Sneezing | face mask | **drawn**: head with an open mouth and a spray of droplets |
| Snoring | "zzz" | **drawn**: sleeping face with Z marks |
| Laughter (6 labels) | smiling face | **drawn**: laughing face, eyes closed, mouth open |
| Crying, baby crying | exclamation bubble / stroller | **drawn**: crying face with tears |
| Screaming | exclamation bubble | **drawn**: face with wide eyes and a wide open mouth |
| Whistling | mouth | **drawn**: face with pursed lips and a note |
| Knock, and the door kind | closed door | **drawn**: door with impact marks |
| Glass breaking | burst | **drawn**: pane of glass with cracks |
| Speech | person with waves | speech bubble (`bubble.left.fill`) |
| Chatter | two outline bubbles | two filled bubbles |
| Whispering | (speech) | bubble with dots |
| Shouting (4 labels) | exclamation bubble | filled exclamation bubble (same family as speech) |
| Insects (5 labels) | ant | ladybug (reads as "insect" at small sizes) |
| Wind chime | wind lines | bell |
| Smoke detector | smoke cloud | alarm with waves (the kind's icon) |

The brief's other examples already had a fitting SF Symbol and keep it: applause and clapping
(clapping hands), footsteps (shoe prints; walking and running figures), siren (beacon with
rays), dog, rain (rain cloud; a drop for `raindrop`), wind, music (note).

VoiceOver: the icon's spoken name follows the icon. A label with its own icon is announced by
its own name ("Coughing", "Knocking"), not by the kind's ("Body sounds"). The names are in one
table (`SoundSymbolCatalog.spokenLabelNames`) keyed by label, which is what a translation would
replace.

## 3. Custom glyphs

SF Symbols has no cough, sneeze, laughing or crying face, whistle, knock or broken glass. The
nine glyphs are original SwiftUI drawings (no downloaded assets): a filled part and a stroked
part with one round line, in the foreground colour, so they never depend on colour. They take
their size from the font like a symbol and are drawn 1.2× the reference symbol to match the
visual weight of pictorial symbols beside them. A symbol name beginning with `hs.` selects one;
everything that carries a symbol name (`IslandContent`, `AmbientIcon`) is unchanged.

Design limits, stated plainly: at 15 points a glyph is about 18 points wide. The cough and the
sneeze are the same head with different marks (dashes or dots); they are told apart by the
marks only. The head with an open mouth can be read as a game character. Whether they are
recognized at a glance is for the student to judge on a real Dynamic Island; the renderings
show shape and size, not a display.

## 4. Fallbacks that share a picture

Sounds without an icon of their own that keep a broader one. None is mapped to a picture of
something unrelated; these are the ones where the picture is less specific than the sound.

| Labels | Icon | Why |
|---|---|---|
| cow, pig, sheep; frog, coyote, elk, lion | paw print | SF Symbols has no farm or wild animals except those used |
| chicken, rooster, duck, goose, turkey, owl, crow, pigeon | bird | no specific birds |
| horse (2) | rider on a horse | the only horse symbol |
| snake (2) | lizard | the only reptile |
| whale | fish | the only sea animal |
| helicopter | airplane | no helicopter symbol |
| hair dryer, sewing machine | fan | appliance kind; the `dryer` symbol is a clothes dryer and was rejected as misleading |
| electric shaver, toothbrush | moustache, mouth | where it is used, not what it is |
| lawn mower, hedge trimmer; chainsaw, chopping wood | leaf; tree | what it works on |
| most wind, brass and bowed instruments (21) | music note | no trumpet, violin, flute or drum symbols; guitars, keyboards and percussion have group icons |
| gunshot, explosion, thump | burst | an impact |
| zipper, squeak, crushing | tapping hand | small handling sounds |
| breathing, sigh, gasp | lungs | breath (lungs are kept for breathing only) |
| chewing, biting, slurping, gargling, burp, hiccup | mouth | mouth sounds |
| smoke detector | alarm with waves | an alarm; no detector symbol |

Candidates for further custom glyphs, by how often they matter: a drum, a horse, a frog, a
helicopter. Not drawn in this window.

## 5. Verification

- `SoundSymbolCatalogTests`: every label resolves; every kind has an icon; every SF Symbol name
  exists on the installed system; every custom glyph is used; the icons named in the brief are
  the ones returned; a cough is not lungs or a mask.
- Renderings reviewed at compact (15 pt), minimal (14 pt) and expanded (26 pt) sizes on black,
  and at 15 and 28 pt on white.
- Smoothing, persistence and anti-flicker rules (`AmbientIconStream`) are unchanged; their tests
  pass with the new names.
- Not verified: appearance on a physical Dynamic Island and on the Lock Screen.
