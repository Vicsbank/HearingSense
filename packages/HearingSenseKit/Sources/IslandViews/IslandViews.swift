import HearingSenseDomain
import IslandPresentation
import SwiftUI

// The pieces of the Live Activity, shared by the widget extension (which places them in the
// Dynamic Island regions and on the Lock Screen) and the app (which previews them). They draw
// `IslandContent` and decide nothing.
//
// Presentations:
// - compact / minimal: icons only, for every mode.
// - expanded: text for attention episodes; while an ordinary sound or nothing is shown, the
//   latest speech summary of the last minutes, if there is one (marked with its age).
// - Lock Screen: icon-focused for every mode and priority; no event text, no speech text.

public enum IslandStyle {
    /// Colour by channel and priority. Never the only carrier of meaning: attention episodes
    /// also get a mark (`IslandPriorityMark`) and an accessibility label.
    public static func tint(for content: IslandContent) -> Color {
        switch content.mode {
        case .listening, .paused: .white.opacity(0.75)
        case .ambient: .mint
        case .attention: tint(for: content.priority ?? .normal)
        }
    }

    public static func tint(for priority: AttentionPriority) -> Color {
        switch priority {
        case .urgent: .red
        case .high: .orange
        case .normal: .yellow
        case .low, .ambient: .mint
        }
    }
}

/// The one icon of the current content.
public struct IslandIcon: View {
    let content: IslandContent
    var isStale: Bool

    public init(_ content: IslandContent, isStale: Bool = false) {
        self.content = content
        self.isStale = isStale
    }

    public var body: some View {
        Image(systemName: isStale ? IslandSymbol.stale : content.symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isStale ? Color.white.opacity(0.5) : IslandStyle.tint(for: content))
            .fontWeight(content.mode == .attention ? .bold : .medium)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(isStale ? "Hearing Sense is not updating" : content.spokenLabel)
    }
}

/// Priority as a mark, so that it does not depend on colour.
public struct IslandPriorityMark: View {
    let priority: AttentionPriority

    public init(_ priority: AttentionPriority) {
        self.priority = priority
    }

    public var body: some View {
        Image(systemName: priority == .urgent ? "exclamationmark.2" : priority == .high ? "exclamationmark" : "circle.fill")
            .font(priority >= .high ? .caption.weight(.heavy) : .system(size: 6))
            .foregroundStyle(IslandStyle.tint(for: priority))
            .accessibilityLabel("\(priority.displayName) priority")
    }
}

// MARK: - Compact and minimal (icons only)

/// Left of the camera. Listening and ordinary sounds: the app's glyph. Attention: the episode's icon.
public struct IslandCompactLeading: View {
    let content: IslandContent
    var isStale: Bool

    public init(_ content: IslandContent, isStale: Bool = false) {
        self.content = content
        self.isStale = isStale
    }

    public var body: some View {
        Group {
            if content.mode == .ambient, !isStale {
                Image(systemName: IslandSymbol.listening)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityLabel("Hearing Sense is listening")
            } else {
                IslandIcon(content, isStale: isStale)
            }
        }
        .font(.system(size: 15))
        .padding(.leading, 2)
    }
}

/// Right of the camera. Ordinary sound: its icon. Attention: the priority mark. Otherwise empty.
public struct IslandCompactTrailing: View {
    let content: IslandContent
    var isStale: Bool

    public init(_ content: IslandContent, isStale: Bool = false) {
        self.content = content
        self.isStale = isStale
    }

    public var body: some View {
        Group {
            if isStale {
                EmptyView()
            } else if content.mode == .ambient {
                IslandIcon(content).font(.system(size: 15))
            } else if content.mode == .attention, let priority = content.priority {
                IslandPriorityMark(priority)
            }
        }
        .padding(.trailing, 2)
    }
}

/// The single icon shown when another activity shares the island.
public struct IslandMinimal: View {
    let content: IslandContent
    var isStale: Bool

    public init(_ content: IslandContent, isStale: Bool = false) {
        self.content = content
        self.isStale = isStale
    }

    public var body: some View {
        IslandIcon(content, isStale: isStale).font(.system(size: 14))
    }
}

// MARK: - Expanded

public struct IslandExpandedLeading: View {
    let content: IslandContent
    var isStale: Bool

    public init(_ content: IslandContent, isStale: Bool = false) {
        self.content = content
        self.isStale = isStale
    }

    public var body: some View {
        IslandIcon(content, isStale: isStale)
            .font(.system(size: 26))
            .frame(width: 48, height: 48)
            .background(IslandStyle.tint(for: content).opacity(0.18), in: Circle())
            .padding(.leading, 4)
    }
}

public struct IslandExpandedTrailing: View {
    let content: IslandContent
    let sessionStart: Date

    public init(_ content: IslandContent, sessionStart: Date) {
        self.content = content
        self.sessionStart = sessionStart
    }

    public var body: some View {
        HStack(spacing: 6) {
            if content.mode == .attention, let priority = content.priority {
                IslandPriorityMark(priority)
            }
            // Counts up without any update from the app.
            Text(content.mode == .attention ? content.since : sessionStart, style: .timer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 48, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.trailing, 8)
    }
}

/// The text of the expanded presentation. Ordinary sounds get no text of their own: the
/// expanded island then says that the app is listening, or shows the latest speech summary.
public struct IslandExpandedCenter: View {
    let content: IslandContent
    var isStale: Bool

    public init(_ content: IslandContent, isStale: Bool = false) {
        self.content = content
        self.isStale = isStale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isStale {
                Text("Not updating").font(.headline)
                Text("Open Hearing Sense").font(.caption).foregroundStyle(.secondary)
            } else if content.mode == .attention, let headline = content.headline {
                headlineText(headline)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let caption = content.caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if content.mode != .paused, let recent = content.recentSummary {
                // The episode is over or gave way to an ordinary sound; its summary stays readable
                // for a short while. Speech-derived: hidden wherever the system redacts content.
                Text("“\(recent)”")
                    .privacySensitive()
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                recentCaption
            } else {
                Text(content.mode == .paused ? "Paused" : "Listening").font(.headline)
                Text("Hearing Sense").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Nearby speech · 40 sec ago": the age counts up without an update from the app.
    @ViewBuilder
    private var recentCaption: some View {
        Group {
            if let date = content.recentSummaryDate {
                Text("Nearby speech · \(Text(date, style: .relative)) ago")
            } else {
                Text("Nearby speech, a moment ago")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func headlineText(_ headline: String) -> some View {
        if content.headlineIsSpeech {
            // Speech-derived: hidden by the system wherever content is redacted for privacy.
            Text("“\(headline)”").privacySensitive()
        } else {
            Text(headline)
        }
    }
}

public struct IslandExpandedBottom: View {
    let content: IslandContent

    public init(_ content: IslandContent) {
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 8) {
            if content.mode == .attention {
                if content.isUncertain {
                    Label("Uncertain", systemImage: "questionmark.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if content.additionalCount > 0 {
                    Text("+\(content.additionalCount) more")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(content.additionalCount) more events")
                }
            }
            Spacer(minLength: 0)
            if content.mode == .attention, let ambient = content.ambientSymbolName {
                Image(systemName: ambient)
                    .font(.footnote)
                    .foregroundStyle(.mint)
                    .accessibilityLabel("Another sound in the background")
            }
            Image(systemName: IslandSymbol.listening)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Lock Screen

/// Icon-focused for every mode and priority: the current icon, the app's name and the session
/// timer. No event title and no speech text, whatever the priority.
public struct IslandLockScreenView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let content: IslandContent
    let sessionStart: Date
    var isStale: Bool

    public init(_ content: IslandContent, sessionStart: Date, isStale: Bool = false) {
        self.content = content
        self.sessionStart = sessionStart
        self.isStale = isStale
    }

    public var body: some View {
        HStack(spacing: 12) {
            IslandIcon(content, isStale: isStale)
                .font(.system(size: 28))
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hearing Sense").font(.subheadline.weight(.semibold))
                Text(isStale ? "Not updating" : content.mode == .paused ? "Paused" : "Listening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !isStale, content.mode == .attention, let priority = content.priority {
                IslandPriorityMark(priority)
            }
            if !isStale, content.mode != .paused {
                Text(sessionStart, style: .timer)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Always-On display: the system dims the activity; keep it calm there.
        .opacity(isLuminanceReduced ? 0.8 : 1)
    }
}
