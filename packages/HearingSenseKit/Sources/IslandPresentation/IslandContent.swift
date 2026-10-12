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
    // Window 7 adds two things beside the channels: the state of a summary the user asked for
    // (`conversation`), which decides the controls of the expanded presentation, and the
    // acoustic scene (`sceneTitle`), a secondary line of text.

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
    /// A summary the user asked for, or a conversation the user chose to keep following; nil
    /// during ordinary listening. Never set by the app on its own.
    public var conversation: IslandConversation?
    /// "Traffic nearby": the acoustic scene, in generic words. Drawn in the expanded
    /// presentation only.
    public var sceneTitle: String?

    public init(mode: Mode, symbolName: String, spokenLabel: String, headline: String? = nil, caption: String? = nil,
                headlineIsSpeech: Bool = false, priority: AttentionPriority? = nil, isUncertain: Bool = false,
                since: Date, ambientSymbolName: String? = nil, additionalCount: Int = 0, recentSummary: String? = nil,
                recentSummaryDate: Date? = nil, conversation: IslandConversation? = nil, sceneTitle: String? = nil)
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
        self.conversation = conversation
        self.sceneTitle = sceneTitle
    }

    public static func listening(since: Date) -> IslandContent {
        IslandContent(mode: .listening, symbolName: IslandSymbol.listening, spokenLabel: "Hearing Sense is listening",
                      since: since)
    }

    public static func paused(since: Date) -> IslandContent {
        IslandContent(mode: .paused, symbolName: IslandSymbol.paused, spokenLabel: "Hearing Sense is paused", since: since)
    }
}

/// Where a summary the user asked for stands, as the Live Activity shows it (Window 7).
///
/// It exists only between the user's request ("Summarize" in the expanded Dynamic Island or in
/// the app) and the end of what followed from it. The expanded presentation offers its controls
/// by `phase`: Summarize during ordinary listening, Continue when a summary is ready, Stop while
/// a conversation is followed.
public struct IslandConversation: Hashable, Sendable, Codable {
    public enum Phase: String, Hashable, Sendable, Codable {
        /// The summary of the last two minutes is being written.
        case summarizing
        /// The summary is saved; "Continue" is on offer.
        case summaryReady
        /// The user chose to keep following: captions in the app, a summary that grows.
        case following
        /// A short message: nothing to summarize, transcription off, stopped.
        case notice
    }

    public var phase: Phase
    /// Generic words, safe on the Lock Screen ("Summary ready").
    public var title: String
    /// Speech-derived text (the summary). The pipeline removes it while the iPhone is judged
    /// locked or summaries are not to be shown; views mark it privacy sensitive.
    public var detail: String?
    /// A second line in generic words ("Past speech cannot be recovered"). Never speech-derived.
    public var message: String?
    public var since: Date

    public init(phase: Phase, title: String, detail: String? = nil, message: String? = nil, since: Date) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.message = message
        self.since = since
    }

    public var symbolName: String {
        switch phase {
        case .summarizing: "ellipsis.bubble"
        case .summaryReady: "text.bubble"
        case .following: "captions.bubble"
        case .notice: "exclamationmark.bubble"
        }
    }

    /// The compact presentation marks it (a small bubble beside the sound's icon).
    public var isActive: Bool { phase != .notice }

    public static var symbolNames: [String] { ["ellipsis.bubble", "text.bubble", "captions.bubble", "exclamationmark.bubble"] }
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
    /// "Prominent alerts": ask iOS to present a verified highest-priority acoustic event
    /// prominently (on an iPhone with a Dynamic Island: to expand it). On by default since the
    /// decision of 2026-10-11. While the iPhone is not judged unlocked the request is only made
    /// with `alertsWhileLocked` (see `AlertGate`). iOS decides whether anything is shown.
    public var expandsForImportantEvents: Bool
    /// The user's explicit opt-in to prominent alerts while the iPhone is locked, or while the
    /// app cannot tell: such an alert can light up the locked screen and, with
    /// `playsAlertSound`, play a sound. Off by default. Never applies to summaries.
    public var alertsWhileLocked: Bool
    /// Show validated speech summaries in the expanded Dynamic Island. They are never shown on
    /// the Lock Screen. Off: speech appears as "Nearby Speech" without text.
    public var showsSpeechSummaries: Bool
    /// Play the system alert sound with an expansion. Off: a silent sound file is used.
    public var playsAlertSound: Bool
    /// Ask iOS to expand the Dynamic Island when a summary the user asked for is ready — like
    /// `expandsForImportantEvents`, only while the iPhone is judged unlocked. On by default: the
    /// user asked for the summary seconds earlier.
    public var expandsForSummaries: Bool

    public init(isEnabled: Bool = true, showsAmbientIcons: Bool = true, expandsForImportantEvents: Bool = true,
                showsSpeechSummaries: Bool = true, playsAlertSound: Bool = false, expandsForSummaries: Bool = true,
                alertsWhileLocked: Bool = false)
    {
        self.isEnabled = isEnabled
        self.showsAmbientIcons = showsAmbientIcons
        self.expandsForImportantEvents = expandsForImportantEvents
        self.showsSpeechSummaries = showsSpeechSummaries
        self.playsAlertSound = playsAlertSound
        self.expandsForSummaries = expandsForSummaries
        self.alertsWhileLocked = alertsWhileLocked
    }

    public static let `default` = IslandSettings()

    /// Settings stored before the decision of 2026-10-11 (key `island.settings.v1`), carried
    /// over once. "Prominent alerts" takes its new default: the stored value was the old
    /// default (off) or a choice made under the old rule, and the two cannot be told apart. The
    /// opt-in for the locked iPhone starts off. Everything else is kept.
    public static func migrated(fromVersion1 data: Data) -> IslandSettings {
        var settings = (try? JSONDecoder().decode(IslandSettings.self, from: data)) ?? .default
        settings.expandsForImportantEvents = IslandSettings.default.expandsForImportantEvents
        settings.alertsWhileLocked = false
        return settings
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, showsAmbientIcons, expandsForImportantEvents, showsSpeechSummaries, playsAlertSound, expandsForSummaries
        case alertsWhileLocked
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
        expandsForSummaries = try container.decodeIfPresent(Bool.self, forKey: .expandsForSummaries) ?? fallback.expandsForSummaries
        alertsWhileLocked = try container.decodeIfPresent(Bool.self, forKey: .alertsWhileLocked) ?? fallback.alertsWhileLocked
    }
}
