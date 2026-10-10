import Attention
import AttentionReplay
import HearingSenseDomain
import SwiftUI

/// What the attention engine currently wants shown, and the mode switch. The in-app view of
/// what Window 5 presents outside the app (`LiveActivityCard`, the Live Activity).
struct AttentionCard: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let attention = controller.attention
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Attention", systemImage: "bell.badge")
                    .font(.headline)
                Picker("Attention mode", selection: Binding(get: { attention.preferences.mode },
                                                            set: { attention.setMode($0) })) {
                    ForEach(AttentionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Changes how readily sounds and speech are brought to your attention.")
                Text(attention.preferences.mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                if attention.presented.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nothing needs attention").font(.title3.weight(.semibold))
                        Text("Important sounds and relevant speech appear here. Ambient sound, music and repeats stay quiet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 64, alignment: .top)
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(attention.presented.prefix(4)) { event in
                        AttentionEventRow(event: event, showsPrivateDetail: true)
                    }
                    if attention.presented.count > 4 {
                        Text("and \(attention.presented.count - 4) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                NavigationLink {
                    AttentionSettingsView()
                } label: {
                    Label("Attention settings", systemImage: "slider.horizontal.3").font(.subheadline)
                }
                NavigationLink {
                    AttentionDebugView()
                } label: {
                    Label("Attention decisions (debug)", systemImage: "list.bullet.rectangle").font(.subheadline)
                }
            }
        }
    }
}

/// Priority as symbol + text, so it never depends on color alone.
struct PriorityBadge: View {
    let priority: AttentionPriority

    var body: some View {
        Label(priority.displayName, systemImage: symbol)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(priority >= .high ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(priority == .urgent ? AnyShapeStyle(.red) : priority == .high ? AnyShapeStyle(.orange)
                : AnyShapeStyle(.quaternary), in: Capsule())
            .accessibilityLabel("\(priority.displayName) priority")
    }

    private var symbol: String {
        switch priority {
        case .urgent: "exclamationmark.2"
        case .high: "exclamationmark"
        case .normal: "circle.fill"
        case .low: "circle"
        case .ambient: "minus"
        }
    }
}

struct AttentionEventRow: View {
    let event: AttentionEvent
    /// Speech-derived text is shown inside the app only.
    var showsPrivateDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.symbolName)
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.isUncertain ? "\(event.title) (uncertain)" : event.title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = event.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if showsPrivateDetail, let detail = event.privateContent {
                    Text("“\(detail.text)”")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(event.reasons.map(\.rawValue).joined(separator: " · "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                PriorityBadge(priority: event.priority)
                Text(event.lifecycle.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings

/// Mode, speech attention and one setting per category. Everything applies at once and is
/// stored on this iPhone.
struct AttentionSettingsView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let attention = controller.attention
        Form {
            Section {
                Picker("Mode", selection: Binding(get: { attention.preferences.mode }, set: { attention.setMode($0) })) {
                    ForEach(AttentionMode.allCases, id: \.self) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                            Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Attention mode")
            }

            Section {
                Picker("Nearby speech", selection: Binding(get: { attention.preferences.speech },
                                                           set: { attention.setSpeechAttention($0) })) {
                    ForEach(SpeechAttention.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Speech")
            } footer: {
                Text("This only decides when speech is brought to your attention. Transcription has its own switch "
                    + "(“Transcribe nearby speech”) and is never turned on from here; while it is off, speech is "
                    + "shown as “Nearby Speech” without text.")
            }

            Section {
                ForEach(AttentionCategory.allCases.filter { $0 != .speech }, id: \.self) { category in
                    Picker(selection: Binding(get: { attention.preferences.setting(for: category) },
                                              set: { attention.setSetting($0, for: category) })) {
                        ForEach(CategorySetting.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    } label: {
                        Label(category.displayName, systemImage: category.systemImage)
                    }
                }
            } header: {
                Text("Sound categories")
            } footer: {
                Text("Automatic follows the mode. Muted never shows the category. Low, Normal and High fix its "
                    + "priority in every mode. Muting sirens, alarms or horns means they will not be shown.")
            }

            Section {
                Button("Restore default settings", role: .destructive) { attention.restoreDefaults() }
                    .disabled(attention.preferences.isDefault)
            } footer: {
                Text("Hearing Sense is an awareness aid, not a safety or emergency alert system.")
            }
        }
        .navigationTitle("Attention settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Debug

/// The engine's state and its recent decisions with their reason codes, plus synthetic event
/// injection (no microphone). Metadata only, except the in-memory summary of a shown episode.
struct AttentionDebugView: View {
    @Environment(ListeningController.self) private var controller
    @State private var scenarioID = ScenarioLibrary.all[0].id

    var body: some View {
        let attention = controller.attention
        List {
            Section("State") {
                LabeledContent("Mode", value: attention.preferences.mode.displayName)
                LabeledContent("Speech attention", value: attention.preferences.speech.displayName)
                LabeledContent("Presentation budget", value: "\(attention.budgetUsed) of \(attention.budgetLimit) used")
                LabeledContent("Decisions", value: AttentionAction.allCases
                    .map { "\($0.rawValue.prefix(3)) \(attention.statistics.count($0))" }.joined(separator: " · "))
                LabeledContent("Episodes", value: "\(attention.statistics.episodesCreated) created · max "
                    + "\(attention.statistics.maximumEpisodes) at once")
                LabeledContent("Decision time", value: "\(attention.processing.meanMicroseconds.formatted(.number.precision(.fractionLength(0)))) µs mean · "
                    + "\(attention.processing.maximumMicroseconds.formatted(.number.precision(.fractionLength(0)))) µs max")
            }
            .font(.subheadline)

            Section {
                Text("Synthetic events go through the same engine as real ones. They do not use the microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Self.quickSounds, id: \.kind) { item in
                    Button("\(item.title)") { attention.inject(ScenarioLibrary.singleSound(item.kind, duration: item.duration)) }
                }
                ForEach(ScenarioLibrary.InjectedSpeech.allCases, id: \.self) { speech in
                    Button(speech.title) { attention.inject(ScenarioLibrary.singleSpeech(speech)) }
                }
                Picker("Scene", selection: $scenarioID) {
                    ForEach(ScenarioLibrary.all) { Text($0.title).tag($0.id) }
                }
                Button("Play scene in real time") {
                    if let scenario = ScenarioLibrary.scenario(id: scenarioID) { attention.inject(scenario) }
                }
                if attention.isInjecting {
                    Button("Stop injection", role: .destructive) { attention.stopInjection() }
                }
            } header: {
                Text("Inject synthetic events")
            }

            Section("Active events (\(attention.presented.count))") {
                if attention.presented.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(attention.presented) { AttentionEventRow(event: $0, showsPrivateDetail: true) }
            }

            Section("Fusion results (\(attention.statistics.fusions) so far)") {
                let fused = (attention.presented + attention.tracked).filter(\.isFused)
                if fused.isEmpty { Text("No episode currently groups a sound with speech.").foregroundStyle(.secondary) }
                ForEach(fused) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(event.id.description) \(event.title)").font(.subheadline.weight(.semibold))
                        ForEach(Array(event.sources.enumerated()), id: \.offset) { _, source in
                            Text("\(source.firstObserved.formatted(.dateTime.hour().minute().second())) \(Self.describe(source))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text("Grouped by closeness in time only.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Tracked, not shown (\(attention.tracked.count))") {
                if attention.tracked.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(attention.tracked) { event in
                    AttentionEventRow(event: event)
                        .opacity(attention.deferred.contains(event.id) ? 1 : 0.7)
                }
            }

            Section("Cooldowns (\(attention.cooldowns.count))") {
                if attention.cooldowns.isEmpty { Text("None running").foregroundStyle(.secondary) }
                ForEach(attention.cooldowns) { cooldown in
                    LabeledContent(cooldown.id) {
                        Text("until \(cooldown.until.formatted(.dateTime.hour().minute().second()))")
                    }
                    .font(.subheadline.monospaced())
                }
            }

            Section("Decisions (\(attention.decisions.count), newest first)") {
                if attention.decisions.isEmpty { Text("No decisions yet").foregroundStyle(.secondary) }
                ForEach(attention.decisions.prefix(100)) { DecisionRow(decision: $0) }
            }
        }
        .navigationTitle("Attention decisions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: attention.reportText()) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share attention report")
            Button("Clear") { attention.clearDecisionLog() }
        }
    }

    private static let quickSounds: [(kind: String, title: String, duration: TimeInterval)] = [
        ("vehicle_horn", "Car horn", 1), ("siren", "Emergency siren (15 s)", 15), ("door", "Door knock", 1),
        ("glass_breaking", "Glass breaking", 1), ("alarm", "Alarm (30 s)", 30), ("dog", "Dog barking (8 s)", 8),
        ("rain", "Rain (60 s)", 60), ("music", "Music (60 s)", 60),
    ]

    private static func describe(_ record: AttentionSourceRecord) -> String {
        switch record.source {
        case .sound(_, let kindID): "sound \(kindID)" + (record.isActive ? " (active)" : "")
        case .speech: "speech" + (record.isActive ? " (active)" : "")
        }
    }
}

private struct DecisionRow: View {
    let decision: AttentionDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(decision.action.rawValue)
                    .font(.caption.weight(.bold).monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Text("\(decision.event.id.description) \(decision.event.title)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(decision.event.priority.description).font(.caption)
            }
            Text(decision.reasons.map(\.rawValue).joined(separator: " · "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(decision.decidedAt.formatted(.dateTime.hour().minute().second())) ← \(decision.trigger.summary)"
                + (decision.intent.map { " → \($0.action.rawValue) / \($0.interruption.rawValue)" } ?? ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
