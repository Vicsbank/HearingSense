import Foundation

/// User-facing semantic category of a sound. Derived from the real label inventory of Apple's
/// built-in classifier (see docs/research/SOUND_CATEGORY_MAPPING.md for the rationale and the
/// complete label table). A category says *what kind* of sound it is, not how important it is;
/// importance is the Attention Priority Engine's job (Window 4).
public enum SoundCategory: String, CaseIterable, Hashable, Sendable, Codable {
    /// Linguistic speech: talking, whispering, shouting, conversation.
    case speech
    /// Devices and signals whose purpose is to warn: sirens, alarms, horns, reversing beeps.
    case alerts
    /// Vehicles and engines.
    case transportation
    /// Doors, knocking, phones, kitchen, water, appliances and tools.
    case household
    /// Bangs, explosions, gunshots, breaking glass, thuds.
    case impacts
    /// Non-speech human sounds: laughter, crying, coughing, footsteps, clapping, sports.
    case humanActivity
    case animals
    /// Music, instruments and singing.
    case music
    /// Wind, rain, thunder, water bodies and fire.
    case weatherNature
    /// Crowds, cheering, applause.
    case crowd
    /// Anything else, including microphone wind noise and labels this app version does not know.
    case other

    public var displayName: String {
        switch self {
        case .speech: "Speech"
        case .alerts: "Alerts & sirens"
        case .transportation: "Transportation"
        case .household: "Home & devices"
        case .impacts: "Bangs & impacts"
        case .humanActivity: "Human sounds"
        case .animals: "Animals"
        case .music: "Music"
        case .weatherNature: "Weather & nature"
        case .crowd: "Crowd"
        case .other: "Other"
        }
    }

    /// SF Symbol name for presentation layers.
    public var systemImage: String {
        switch self {
        case .speech: "person.wave.2"
        case .alerts: "light.beacon.max"
        case .transportation: "car"
        case .household: "house"
        case .impacts: "burst"
        case .humanActivity: "figure.walk"
        case .animals: "pawprint"
        case .music: "music.note"
        case .weatherNature: "cloud.rain"
        case .crowd: "person.3"
        case .other: "waveform"
        }
    }
}

/// A trackable kind of sound event: one or more classifier labels that describe the same
/// real-world source (e.g. `dog`, `dog_bark`, `dog_growl` → kind `dog`). The temporal detector
/// tracks one event per kind at a time, so fluctuating synonymous labels form one event.
public struct SoundEventKind: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    /// Stable machine-readable identifier, e.g. `dog`, `siren`, `speech`.
    public let id: String
    public let displayName: String
    public let category: SoundCategory

    public init(id: String, displayName: String, category: SoundCategory) {
        self.id = id
        self.displayName = displayName
        self.category = category
    }

    public var description: String { id }
}
