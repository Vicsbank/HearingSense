import Foundation

/// A coarse description of the surroundings, derived from which sounds were recognized over the
/// last minute (Window 7). Secondary information: the individual sound's icon stays the primary
/// presentation. It describes sounds, never a place: "Traffic nearby" is not "you are on a road".
public enum AcousticScene: String, CaseIterable, Hashable, Sendable, Codable {
    /// Hardly any recognized sound.
    case quiet
    /// Household and device sounds dominate (kitchen, appliances, typing).
    case indoor
    /// Speech, laughter or a crowd dominate.
    case conversation
    /// Vehicles, horns, sirens.
    case traffic
    /// Wind, rain, water, birds, insects.
    case nature
    case music
    /// Several kinds of sound at once, none dominating.
    case mixed

    /// Lock-screen-safe words for the expanded Dynamic Island and the app.
    public var title: String {
        switch self {
        case .quiet: "Quiet surroundings"
        case .indoor: "Indoor sounds"
        case .conversation: "Conversation nearby"
        case .traffic: "Traffic nearby"
        case .nature: "Nature sounds"
        case .music: "Music playing"
        case .mixed: "Mixed sounds"
        }
    }

    public var symbolName: String {
        switch self {
        case .quiet: "moon.zzz"
        case .indoor: "house"
        case .conversation: "bubble.left.and.bubble.right"
        case .traffic: "car.2"
        case .nature: "leaf"
        case .music: "music.note"
        case .mixed: "waveform"
        }
    }
}

/// The current scene with how much of the recent evidence supports it.
public struct AcousticSceneEstimate: Hashable, Sendable, Codable {
    public var scene: AcousticScene
    /// 0…1: the scene's share of the recent evidence (for `quiet`: how little evidence there is).
    public var confidence: Double
    public var since: Date

    public init(scene: AcousticScene, confidence: Double, since: Date) {
        self.scene = scene
        self.confidence = confidence
        self.since = since
    }
}
