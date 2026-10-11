import Foundation

/// Icons the app draws itself (Window 6), for sounds SF Symbols has no telling picture of.
///
/// The raw value travels wherever an SF Symbol name does (`IslandContent.symbolName`,
/// `AmbientIcon.symbolName`); the prefix tells the two apart. The drawing lives in IslandViews
/// (`SoundSymbolImage`), so this module stays free of SwiftUI.
public enum CustomSoundGlyph: String, CaseIterable, Hashable, Sendable {
    case cough = "hs.cough"
    case sneeze = "hs.sneeze"
    case snore = "hs.snore"
    case laugh = "hs.laugh"
    case cry = "hs.cry"
    case scream = "hs.scream"
    case whistle = "hs.whistle"
    case knock = "hs.knock"
    case glassBreak = "hs.glass.break"

    public static let prefix = "hs."

    public init?(symbolName: String) {
        guard symbolName.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue: symbolName)
    }

    /// What the drawing shows, for the coverage report and the debug gallery.
    public var visualDescription: String {
        switch self {
        case .cough: "Head with an open mouth and short cough marks"
        case .sneeze: "Head with an open mouth and a spray of droplets"
        case .snore: "Sleeping face with Z marks"
        case .laugh: "Laughing face with closed eyes and an open mouth"
        case .cry: "Crying face with tears"
        case .scream: "Face with wide eyes and a wide open mouth"
        case .whistle: "Face with pursed lips and a musical note"
        case .knock: "Door with impact marks"
        case .glassBreak: "Pane of glass with cracks"
        }
    }
}
