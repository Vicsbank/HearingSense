import Attention
import Foundation
import HearingSenseDomain

/// The scripted scenes used by the tests, the replay tool and the app's debug screen.
///
/// Each scene is written by hand: its sounds, their timing and their labels are choices of the
/// author, not recordings. Running them shows how the engine's rules behave on these inputs.
public enum ScenarioLibrary {
    /// The eighteen scenes of the Window 4 test plan, in its order.
    public static var all: [AttentionScenario] {
        [continuousRain, repeatedMusic, carHornDuringRain, repeatedAndIndependentHorns, sirenDuringCooldown,
         knockFollowedBySpeech, unrelatedSpeechNearKnock, transcriptionDisabled, possibleLyrics, lateSummary,
         summaryRevisions, simultaneousHighPriority, expirationAndCleanup, rapidBurst, modeComparison,
         preferenceChanges, backgroundLifecycle, unavailableModels]
    }

    public static func scenario(id: String) -> AttentionScenario? { all.first { $0.id == id } }

    // 1
    public static var continuousRain: AttentionScenario {
        var scene = ScenarioBuilder(id: "01-continuous-rain", title: "Continuous rain",
                                    summary: "Ten minutes of rain with one short gap.")
        scene.sound("rain", at: 0, duration: 180, label: .ambient, name: "rain", endAfter: 3)
        scene.sound("rain", at: 200, duration: 400, label: .duplicate, name: "rain resumes after 17 s", endAfter: 3)
        scene.quiet(until: 660)
        return scene.build()
    }

    // 2
    public static var repeatedMusic: AttentionScenario {
        var scene = ScenarioBuilder(id: "02-repeated-music", title: "Repeated music",
                                    summary: "Three songs with pauses; sung words are recognized as possible lyrics.")
        scene.sound("music", at: 0, duration: 180, label: .irrelevant, name: "song 1", endAfter: 3)
        scene.speech(at: 30, label: .irrelevant, name: "lyrics in song 1") { speech in
            speech.partial("oh baby", at: 32)
            speech.final("oh baby watch out for my love", at: 36, quality: .fair, relevance: .possiblyMusic)
            speech.completed(at: 44)
        }
        scene.sound("music", at: 200, duration: 180, label: .irrelevant, name: "song 2", endAfter: 3)
        scene.sound("music", at: 400, duration: 120, label: .irrelevant, name: "song 3", endAfter: 3)
        scene.speech(at: 430, label: .irrelevant, name: "lyrics in song 3") { speech in
            speech.final("help me help me now", at: 436, quality: .poor, relevance: .possiblyMusic)
            speech.completed(at: 444)
        }
        scene.quiet(until: 560)
        return scene.build()
    }

    // 3
    public static var carHornDuringRain: AttentionScenario {
        var scene = ScenarioBuilder(id: "03-horn-during-rain", title: "Car horn during rain",
                                    summary: "A horn sounds while rain has been falling for 40 seconds.")
        scene.sound("rain", at: 0, duration: 120, label: .ambient, name: "rain", endAfter: 3)
        scene.sound("vehicle_horn", at: 40, duration: 1.5, label: .important, name: "car horn")
        scene.quiet(until: 150)
        return scene.build()
    }

    // 4
    public static var repeatedAndIndependentHorns: AttentionScenario {
        var scene = ScenarioBuilder(id: "04-repeated-vs-independent-horns", title: "Repeated and independent horns",
                                    summary: "Three honks in one burst, a second burst a minute later, a third after three minutes.")
        scene.sound("vehicle_horn", at: 10, duration: 1, label: .important, name: "horn, burst 1")
        scene.sound("vehicle_horn", at: 14, duration: 1, label: .duplicate, name: "same burst, 4 s later")
        scene.sound("vehicle_horn", at: 18, duration: 1, label: .duplicate, name: "same burst, 8 s later")
        scene.sound("vehicle_horn", at: 70, duration: 1, label: .important, name: "horn, burst 2")
        scene.sound("vehicle_horn", at: 73, duration: 1, label: .duplicate, name: "same burst, 3 s later")
        scene.sound("vehicle_horn", at: 200, duration: 1, label: .important, name: "horn, burst 3")
        scene.quiet(until: 240)
        return scene.build()
    }

    // 5
    public static var sirenDuringCooldown: AttentionScenario {
        var scene = ScenarioBuilder(id: "05-siren-during-cooldown", title: "Emergency siren during cooldowns",
                                    summary: "Several ordinary events use up the presentation budget and start cooldowns; then two separate sirens pass.")
        scene.sound("phone", at: 2, duration: 4, label: .optional, name: "phone ringing")
        scene.sound("door", at: 6, duration: 1, label: .important, name: "door knock")
        scene.sound("bicycle_bell", at: 10, duration: 1, label: .optional, name: "bicycle bell")
        scene.sound("dog", at: 11, duration: 6, label: .optional, name: "dog barking")
        scene.sound("siren", at: 13, duration: 18, label: .important, name: "siren 1", endAfter: 5)
        scene.sound("dog", at: 50, duration: 6, label: .duplicate, name: "dog again within its cooldown")
        scene.sound("siren", at: 90, duration: 12, label: .important, name: "siren 2, a minute after the first ended",
                    endAfter: 5)
        scene.quiet(until: 150)
        return scene.build()
    }

    // 6
    public static var knockFollowedBySpeech: AttentionScenario {
        var scene = ScenarioBuilder(id: "06-knock-then-speech", title: "Door knock followed by speech",
                                    summary: "A knock, speech two seconds later, then its summary.")
        scene.sound("door", at: 1, duration: 1, label: .important, name: "door knock")
        scene.speech(at: 3, label: .optional, name: "speech after the knock") { speech in
            speech.partial("your package", at: 4)
            speech.final("your package arrived", at: 5, category: .announcement)
            speech.summary("Package Arrived", at: 5.8, category: .announcement)
            speech.completed(at: 12)
        }
        scene.quiet(until: 60)
        return scene.build()
    }

    // 7
    public static var unrelatedSpeechNearKnock: AttentionScenario {
        var scene = ScenarioBuilder(id: "07-unrelated-speech-near-knock", title: "Unrelated speech near a door knock",
                                    summary: "A conversation has been going on for ten seconds when someone knocks.")
        scene.speech(at: 0, label: .optional, name: "conversation that started earlier") { speech in
            speech.partial("so then we went", at: 2)
            speech.final("so then we went to the store", at: 4, category: .casualConversation)
            speech.final("and it was closed", at: 9, category: .casualConversation)
            speech.final("so we came back home", at: 15, category: .casualConversation)
            speech.completed(at: 24)
        }
        scene.sound("door", at: 10, duration: 1, label: .important, name: "door knock")
        scene.quiet(until: 70)
        return scene.build()
    }

    // 8
    public static var transcriptionDisabled: AttentionScenario {
        var scene = ScenarioBuilder(id: "08-transcription-disabled", title: "Speech transcription disabled",
                                    summary: "Three stretches of speech while the user has transcription switched off.")
        for (index, start) in [0.0, 30, 200].enumerated() {
            let key = scene.speech(at: start, label: index == 1 ? .duplicate : .optional,
                                   name: index == 1 ? "speech again 20 s after the first ended" : "nearby speech, no text",
                                   transcription: .disabledByUser) { speech in
                speech.detected(at: start + 3)
                speech.completed(at: start + 8)
            }
            // The sound classifier reports the same speech as its own event.
            scene.sound("speech", at: start + 0.5, duration: 6, label: .optional, endAfter: 3, partOf: key)
        }
        scene.quiet(until: 260)
        return scene.build()
    }

    // 9
    public static var possibleLyrics: AttentionScenario {
        var scene = ScenarioBuilder(id: "09-possible-lyrics", title: "Possible music and lyrics",
                                    summary: "Sung warnings in a song, then a spoken warning over the same music.")
        scene.sound("music", at: 0, duration: 120, label: .irrelevant, name: "music", endAfter: 3)
        scene.speech(at: 10, label: .irrelevant, name: "sung: watch out") { speech in
            speech.final("watch out here I come", at: 14, category: .warning, quality: .fair, relevance: .possiblyMusic)
            speech.completed(at: 22)
        }
        scene.speech(at: 40, label: .irrelevant, name: "sung: fire") { speech in
            speech.final("fire", at: 42, quality: .poor, relevance: .possiblyMusic)
            speech.completed(at: 50)
        }
        scene.speech(at: 70, label: .important, name: "spoken over music: watch out") { speech in
            speech.final("watch out", at: 72, category: .warning, relevance: .speechOverMusic)
            speech.completed(at: 80)
        }
        scene.quiet(until: 150)
        return scene.build()
    }

    // 10
    public static var lateSummary: AttentionScenario {
        var scene = ScenarioBuilder(id: "10-late-summary", title: "Late speech summary",
                                    summary: "The summary of a sentence arrives 4.5 seconds after its transcript.")
        scene.speech(at: 0, label: .optional, name: "reminder with a late summary") { speech in
            speech.partial("we have a biology", at: 1.5)
            speech.final("we have a biology test tomorrow", at: 3)
            speech.summary("Biology Test Tomorrow", at: 7.5, category: .reminder, timeOrNumber: "tomorrow")
            speech.completed(at: 14)
        }
        scene.quiet(until: 70)
        return scene.build()
    }

    // 11
    public static var summaryRevisions: AttentionScenario {
        var scene = ScenarioBuilder(id: "11-summary-revisions", title: "Meaningful summary revisions",
                                    summary: "One conversation whose summary is reworded, reversed, then extended.")
        scene.speech(at: 0, label: .optional, name: "conversation about a package") { speech in
            speech.final("the package has not arrived", at: 3, category: .announcement, isNegated: true)
            speech.summary("Package Has Not Arrived", at: 4, category: .announcement, isNegated: true)
            // Same statement, other words.
            speech.summary("The Package Hasn't Arrived", at: 8, category: .announcement, isNegated: true)
            // The opposite statement.
            speech.final("oh the package has now arrived", at: 13, category: .announcement)
            speech.summary("Package Has Now Arrived", at: 14, category: .announcement)
            // More detail, three seconds later.
            speech.final("it is at the front door", at: 16, category: .announcement)
            speech.summary("Package Arrived At Front Door", at: 17, category: .announcement)
            speech.completed(at: 30)
        }
        scene.quiet(until: 90)
        return scene.build()
    }

    // 12
    public static var simultaneousHighPriority: AttentionScenario {
        var scene = ScenarioBuilder(id: "12-simultaneous-high-priority", title: "Simultaneous high-priority events",
                                    summary: "A siren, breaking glass and a horn within half a second, during music.")
        scene.sound("music", at: 0, duration: 40, label: .irrelevant, name: "music", endAfter: 3)
        scene.sound("siren", at: 5, duration: 15, label: .important, name: "siren", endAfter: 5)
        scene.sound("glass_breaking", at: 5.2, duration: 1, label: .important, name: "breaking glass")
        scene.sound("vehicle_horn", at: 5.5, duration: 1, label: .important, name: "horn")
        scene.quiet(until: 80)
        return scene.build()
    }

    // 13
    public static var expirationAndCleanup: AttentionScenario {
        var scene = ScenarioBuilder(id: "13-expiration-cleanup", title: "Event expiration and cleanup",
                                    summary: "A knock that ends, a siren that never reports its end, an alarm that outlasts its presentation; then silence.")
        scene.sound("door", at: 0, duration: 1, label: .important, name: "door knock")
        scene.sound("siren", at: 20, duration: 4, label: .important, name: "siren without an end event", ends: false)
        scene.sound("alarm", at: 60, duration: 150, label: .important, name: "alarm for 150 s", endAfter: 5)
        scene.quiet(until: 320)
        return scene.build()
    }

    // 14
    public static var rapidBurst: AttentionScenario {
        var scene = ScenarioBuilder(id: "14-rapid-burst", title: "Rapid event burst",
                                    summary: "Forty-four events in twelve seconds, most of them handling noise.")
        let noise = ["small_objects", "hands", "typing_writing", "body_sounds", "kitchen", "footsteps", "laughter", "impact"]
        for index in 0..<36 {
            let kind = noise[index % noise.count]
            let label: EvaluationLabel = switch kind {
            case "laughter", "impact": .optional
            case "hands", "kitchen", "footsteps": .ambient
            default: .irrelevant
            }
            scene.sound(kind, at: Double(index) * 0.3, duration: 0.5, quality: index % 3 == 0 ? .weak : .moderate,
                        label: label, name: kind, confirmDelay: 0.8, endAfter: 1.5)
        }
        scene.sound("dog", at: 2, duration: 5, label: .optional, name: "dog")
        scene.sound("beep", at: 3, duration: 4, label: .optional, name: "beep")
        scene.sound("phone", at: 4, duration: 5, label: .optional, name: "phone")
        scene.sound("thunder", at: 4.5, duration: 3, label: .optional, name: "thunder")
        scene.sound("shouting", at: 5, duration: 3, label: .optional, name: "shouting")
        scene.sound("door", at: 6, duration: 1, label: .important, name: "door knock")
        scene.sound("vehicle_horn", at: 7, duration: 1, label: .important, name: "horn")
        scene.sound("glass_breaking", at: 8, duration: 1, label: .important, name: "breaking glass")
        scene.quiet(until: 60)
        return scene.build()
    }

    // 15
    public static var modeComparison: AttentionScenario {
        var scene = ScenarioBuilder(id: "15-mode-comparison", title: "Quiet, Balanced and Sensitive compared",
                                    summary: "Five minutes with one of each kind of event from the policy table.")
        scene.sound("rain", at: 0, duration: 290, label: .ambient, name: "rain", endAfter: 3)
        scene.sound("wind", at: 12, duration: 60, label: .ambient, name: "wind", endAfter: 3)
        scene.sound("music", at: 20, duration: 50, label: .irrelevant, name: "music", endAfter: 3)
        scene.sound("dog", at: 80, duration: 8, label: .optional, name: "dog barking")
        scene.sound("door", at: 110, duration: 1, label: .important, name: "door knock")
        scene.sound("vehicle_horn", at: 140, duration: 1.5, label: .important, name: "car horn")
        scene.sound("siren", at: 170, duration: 15, label: .important, name: "emergency siren", endAfter: 5)
        scene.sound("glass_breaking", at: 200, duration: 1, label: .important, name: "glass breaking")
        scene.speech(at: 220, label: .optional, name: "ordinary speech") { speech in
            speech.final("did you see the game last night", at: 224, category: .casualConversation)
            speech.completed(at: 232)
        }
        scene.speech(at: 250, label: .important, name: "important speech") { speech in
            speech.final("watch out", at: 251.5, category: .warning)
            speech.summary("Watch Out", at: 252.3, category: .warning)
            speech.completed(at: 260)
        }
        scene.quiet(until: 330)
        return scene.build()
    }

    // 16
    public static var preferenceChanges: AttentionScenario {
        var scene = ScenarioBuilder(id: "16-preference-changes", title: "User preference changes",
                                    summary: "The mode, two category settings and speech attention change while sounds are active.")
        var preferences = AttentionPreferences.default
        scene.sound("rain", at: 0, duration: 170, label: .ambient, name: "rain", endAfter: 3)
        preferences.mode = .sensitive
        scene.preferences(preferences, at: 20)            // rain becomes visible
        preferences.set(.muted, for: .weather)
        scene.preferences(preferences, at: 30)            // rain is taken down
        scene.sound("dog", at: 50, duration: 4, label: .optional, name: "dog (Sensitive)")
        preferences.set(.muted, for: .animals)
        scene.preferences(preferences, at: 80)
        scene.sound("dog", at: 90, duration: 4, label: .irrelevant, name: "dog while animals are muted")
        scene.preferences(.default, at: 100)              // restore defaults
        scene.sound("door", at: 110, duration: 1, label: .important, name: "door knock (defaults)")
        preferences = .default
        preferences.speech = .off
        scene.preferences(preferences, at: 120)
        scene.speech(at: 125, label: .irrelevant, name: "warning while speech attention is off") { speech in
            speech.final("watch out", at: 126.5, category: .warning)
            speech.completed(at: 134)
        }
        preferences.speech = .standard
        preferences.set(.high, for: .animals)
        scene.preferences(preferences, at: 140)
        scene.sound("cat", at: 145, duration: 3, label: .optional, name: "cat while animals are set to High")
        scene.quiet(until: 220)
        return scene.build()
    }

    // 17
    public static var backgroundLifecycle: AttentionScenario {
        var scene = ScenarioBuilder(id: "17-background-lifecycle", title: "Background lifecycle transitions",
                                    summary: "The classifier stops reporting while a siren is active, the session is interrupted and restarted.")
        scene.sound("door", at: 2, duration: 1, label: .important, name: "door knock (foreground)")
        // App goes to the background at 12 s and the classifier stalls: the siren never ends.
        scene.sound("siren", at: 10, duration: 4, label: .important, name: "siren when the classifier stalls", ends: false)
        // An interruption ends the session at 60 s; listening resumes at 70 s.
        scene.sound("rain", at: 40, duration: 18, label: .ambient, name: "rain until the interruption", ends: false)
        scene.sessionEnded(at: 60)
        scene.sessionStarted(at: 70)
        // Locked screen with the classifier running (the A2 configuration): events arrive as usual.
        scene.sound("vehicle_horn", at: 75, duration: 1, label: .important, name: "horn after the restart")
        scene.sound("siren", at: 90, duration: 10, label: .important, name: "siren while locked", endAfter: 5)
        scene.quiet(until: 160)
        return scene.build()
    }

    // 18
    public static var unavailableModels: AttentionScenario {
        var scene = ScenarioBuilder(id: "18-unavailable-models", title: "Unavailable speech or language models",
                                    summary: "Speech without a transcriber, then transcripts without the language model.")
        scene.speech(at: 0, label: .optional, name: "speech, transcriber not supported",
                     transcription: .unsupportedDevice, model: .deviceNotEligible) { speech in
            speech.detected(at: 3)
            speech.completed(at: 9)
        }
        scene.speech(at: 150, label: .important, name: "warning, language model unavailable",
                     model: .deviceNotEligible) { speech in
            speech.final("watch out", at: 151.5)
            speech.completed(at: 160)
        }
        scene.speech(at: 300, label: .optional, name: "ordinary sentence, language model not ready",
                     model: .modelNotReady) { speech in
            speech.final("the meeting moved to room twelve", at: 304)
            speech.completed(at: 312)
        }
        scene.sound("speech", at: 450, duration: 6, label: .optional, name: "classifier's speech event only", endAfter: 3)
        scene.quiet(until: 520)
        return scene.build()
    }
}

/// Seeded pseudo-random numbers (SplitMix64), so the long scene is the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension ScenarioLibrary {
    /// A long generated scene for rates and stability: a mix of background sounds, handling
    /// noise, optional events, important events and immediate repeats, placed at random times
    /// from a fixed seed. The mix is invented; the rates it yields describe this script only.
    public static func soak(hours: Double = 1, seed: UInt64 = 20_261_010) -> AttentionScenario {
        var random = SeededGenerator(seed: seed)
        let length = hours * 3600
        var scene = ScenarioBuilder(id: "soak-\(Int(hours * 60))min-seed\(seed)",
                                    title: "Generated \(Int(hours * 60))-minute scene",
                                    summary: "Seeded random mix of ambient, irrelevant, optional, important and repeated events.")
        let ambient = ["rain", "wind", "road_vehicle", "appliance", "water_use", "crowd"]
        let irrelevant = ["small_objects", "typing_writing", "body_sounds", "clock", "insect", "music"]
        let optional = ["dog", "laughter", "beep", "phone", "footsteps", "thunder", "bird", "shouting"]
        let important = ["vehicle_horn", "siren", "door", "glass_breaking", "alarm", "screaming"]
        let sentences: [(String, SpeechSemanticCategory, String?)] = [
            ("did you see the game last night", .casualConversation, nil),
            ("can you pass me that book", .request, "Pass The Book"),
            ("the bus leaves at five", .announcement, "Bus Leaves At Five"),
            ("i think it might rain later", .casualConversation, nil),
            ("dinner is ready", .announcement, "Dinner Is Ready"),
        ]
        var lastImportant: [String: TimeInterval] = [:]
        var time = 5.0
        while time < length - 60 {
            let roll = Double.random(in: 0..<1, using: &random)
            switch roll {
            case ..<0.22:
                scene.sound(ambient.randomElement(using: &random)!, at: time,
                            duration: Double.random(in: 20...240, using: &random), label: .ambient, endAfter: 3)
            case ..<0.52:
                scene.sound(irrelevant.randomElement(using: &random)!, at: time,
                            duration: Double.random(in: 0.5...20, using: &random),
                            quality: Bool.random(using: &random) ? .weak : .moderate, label: .irrelevant)
            case ..<0.70:
                scene.sound(optional.randomElement(using: &random)!, at: time,
                            duration: Double.random(in: 1...12, using: &random), label: .optional)
            case ..<0.84:
                let sentence = sentences.randomElement(using: &random)!
                scene.speech(at: time, label: .optional, name: sentence.0) { speech in
                    speech.final(sentence.0, at: time + 3, category: sentence.1)
                    if let headline = sentence.2 { speech.summary(headline, at: time + 4, category: sentence.1) }
                    speech.completed(at: time + 11)
                }
            case ..<0.87:
                // A song with sung words: the classifier reports music, the recognizer hears words.
                scene.sound("music", at: time, duration: 30, label: .irrelevant, name: "song", endAfter: 3)
                scene.speech(at: time + 8, label: .irrelevant, name: "lyrics") { speech in
                    speech.final("oh watch out baby", at: time + 11, quality: .fair, relevance: .possiblyMusic)
                    speech.completed(at: time + 18)
                }
            case ..<0.89:
                if let last = lastImportant["speech"], time < last + 60 { break }
                scene.speech(at: time, label: .important, name: "spoken warning") { speech in
                    speech.final("look out", at: time + 1.5, category: .warning)
                    speech.completed(at: time + 9)
                }
                lastImportant["speech"] = time + 9
            default:
                let kind = important.randomElement(using: &random)!
                // An important event is scripted only when the same kind has been silent for a
                // minute, so that "independent occurrence" is true by construction.
                if let last = lastImportant[kind], time < last + 60 {
                    scene.sound(ambient.randomElement(using: &random)!, at: time,
                                duration: Double.random(in: 20...120, using: &random), label: .ambient, endAfter: 3)
                } else {
                    let isLong = kind == "siren" || kind == "alarm"
                    let duration = isLong ? Double.random(in: 5...25, using: &random) : 1
                    scene.sound(kind, at: time, duration: duration, label: .important, endAfter: isLong ? 5 : 2)
                    lastImportant[kind] = time + duration
                    // Half of the brief ones come back a few seconds later: the same thing again.
                    if !isLong, Bool.random(using: &random) {
                        let again = time + Double.random(in: 3...5, using: &random)
                        scene.sound(kind, at: again, duration: 1, label: .duplicate)
                        lastImportant[kind] = again + 1
                    }
                }
            }
            time += Double.random(in: 4...45, using: &random)
        }
        scene.quiet(until: length)
        return scene.build()
    }
}
