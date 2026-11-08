import Foundation
import HearingSenseDomain

/// What the Live Activity shows right now. This is the activity's content state, so it is
/// `Codable` and small; the widget extension draws it and decides nothing.
///
/// Two channels share it and never mix:
/// - `ambient` / `listening`: one icon, no text (ordinary sounds, or nothing recognized).
/// - `attention`: an episode the attention engine (Window 4) decided to present, with text for
///   the expanded Dynamic Island.
public struct IslandContent: Hashable, Sendable, Codable {
    public enum Mode: String, Hashable, Sendable, Codable {
        /// Listening, nothing to show: the app's own glyph.
        case listening
        /// An ordinary sound: its icon only.
        case ambient
        /// An attention episode: icon and, in the expanded presentation, text.
        case attention
        /// The microphone is off for now (interruption); the session is expected to resume.
        case paused
    }

    public var mode: Mode
    /// SF Symbol name of the one icon to draw.
    public var symbolName: String
    /// Accessibility label of the icon. Never drawn as text.
    public var spokenLabel: String
    /// `attention` only: the concise text of the expanded presentation ("Door or knock",
    /// or a speech summary when `headlineIsSpeech`).
    public var headline: String?
    /// `attention` only: a generic second line ("Nearby speech afterwards").
    public var caption: String?
    /// `headline` is derived from what people said. Views mark it privacy sensitive and the Lock
    /// Screen presentation never shows it.
    public var headlineIsSpeech: Bool
    /// `attention` only.
    public var priority: AttentionPriority?
    /// The classification or interpretation is uncertain: do not word it as a fact.
    public var isUncertain: Bool
    /// When the current item was first shown (session start while `listening`).
    public var since: Date
    /// `attention` only: the ordinary sound heard at the same time, as an icon.
    public var ambientSymbolName: String?
    /// `attention` only: further presented episodes behind the one shown.
    public var additionalCount: Int
    /// `ambient` / `listening` only: the latest speech summary that was presented a short while
    /// ago, so that a touch and hold can still read it after an ordinary sound took the icon
    /// back. Speech-derived: only the expanded presentation draws it, never the compact, minimal
    /// or Lock Screen ones, and it is absent while the iPhone is judged locked.
    public var recentSummary: String?
    /// When `recentSummary` was last presented as an episode.
    public var recentSummaryDate: Date?

    public init(mode: Mode, symbolName: String, spokenLabel: String, headline: String? = nil, caption: String? = nil,
                headlineIsSpeech: Bool = false, priority: AttentionPriority? = nil, isUncertain: Bool = false,
                since: Date, ambientSymbolName: String? = nil, additionalCount: Int = 0, recentSummary: String? = nil,
                recentSummaryDate: Date? = nil)
    {
        self.mode = mode
        self.symbolName = symbolName
        self.spokenLabel = spokenLabel
        self.headline = headline
        self.caption = caption
        self.headlineIsSpeech = headlineIsSpeech
        self.priority = priority
        self.isUncertain = isUncertain
        self.since = since
        self.ambientSymbolName = ambientSymbolName
        self.additionalCount = additionalCount
        self.recentSummary = recentSummary
        self.recentSummaryDate = recentSummaryDate
    }

    public static func listening(since: Date) -> IslandContent {
        IslandContent(mode: .listening, symbolName: IslandSymbol.listening, spokenLabel: "Hearing Sense is listening",
                      since: since)
    }

    public static func paused(since: Date) -> IslandContent {
        IslandContent(mode: .paused, symbolName: IslandSymbol.paused, spokenLabel: "Hearing Sense is paused", since: since)
    }
}

/// Symbols of the presentation itself (not of sounds).
public enum IslandSymbol {
    public static let listening = "ear"
    public static let paused = "pause.circle"
    /// The app stopped updating the activity (it was terminated, or the system ended the session).
    public static let stale = "ear.trianglebadge.exclamationmark"
    public static let brand = "ear.badge.waveform"

    public static var all: [String] { [listening, paused, stale, brand] }
}

/// The user's choices for the Live Activity. Stored by the app as JSON; a missing key falls back
/// to its default, so a stored value from an older build keeps working.
public struct IslandSettings: Hashable, Sendable, Codable {
    /// Show the Live Activity (Lock Screen and Dynamic Island) while listening.
    public var isEnabled: Bool
    /// Show the icon of ordinary sounds. Off: only the app's glyph and attention episodes.
    public var showsAmbientIcons: Bool
    /// Ask iOS to expand the Dynamic Island for important events — only while the iPhone is
    /// judged to be unlocked (see `AlertGate`). Off by default, because the lock state can only
    /// be estimated and an expansion request on a locked iPhone lights up the screen: the island
    /// then never expands by itself and the text is one long press away.
    public var expandsForImportantEvents: Bool
    /// Show validated speech summaries in the expanded Dynamic Island. They are never shown on
    /// the Lock Screen. Off: speech appears as "Nearby Speech" without text.
    public var showsSpeechSummaries: Bool
    /// Play the system alert sound with an expansion. Off: a silent sound file is used.
    public var playsAlertSound: Bool

    public init(isEnabled: Bool = true, showsAmbientIcons: Bool = true, expandsForImportantEvents: Bool = false,
                showsSpeechSummaries: Bool = true, playsAlertSound: Bool = false)
    {
        self.isEnabled = isEnabled
        self.showsAmbientIcons = showsAmbientIcons
        self.expandsForImportantEvents = expandsForImportantEvents
        self.showsSpeechSummaries = showsSpeechSummaries
        self.playsAlertSound = playsAlertSound
    }

    public static let `default` = IslandSettings()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, showsAmbientIcons, expandsForImportantEvents, showsSpeechSummaries, playsAlertSound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = IslandSettings.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
        showsAmbientIcons = try container.decodeIfPresent(Bool.self, forKey: .showsAmbientIcons) ?? fallback.showsAmbientIcons
        expandsForImportantEvents = try container.decodeIfPresent(Bool.self, forKey: .expandsForImportantEvents)
            ?? fallback.expandsForImportantEvents
        showsSpeechSummaries = try container.decodeIfPresent(Bool.self, forKey: .showsSpeechSummaries)
            ?? fallback.showsSpeechSummaries
        playsAlertSound = try container.decodeIfPresent(Bool.self, forKey: .playsAlertSound) ?? fallback.playsAlertSound
    }
}
