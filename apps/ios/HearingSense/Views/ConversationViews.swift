import ConversationUnderstanding
import SwiftUI

// The recap and the live conversation screen, the saved
// history, and what the app tells the user about speech data.

/// The card on the main screen.
struct ConversationCard: View {
    @Environment(ListeningController.self) private var controller
    @State private var navigation = ConversationNavigation.shared

    var body: some View {
        let conversation = controller.conversation
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Conversation", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.headline)

                Text(Self.explanation(conversation, isTranscribing: controller.speech.isTranscriptionEnabled))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ConversationButtons(conversation: conversation) { navigation.showsConversation = true }

                if let message = conversation.unavailableMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let error = conversation.storageError {
                    Label(error, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Divider()
                NavigationLink {
                    ConversationLiveView()
                } label: {
                    LabeledContent {
                        Text(conversation.status?.title ?? "")
                    } label: {
                        Label("Recap and live captions", systemImage: "captions.bubble").font(.subheadline)
                    }
                }
                NavigationLink {
                    ConversationHistoryView()
                } label: {
                    LabeledContent {
                        Text("\(conversation.history.count)")
                    } label: {
                        Label("Saved summaries", systemImage: "clock.arrow.circlepath").font(.subheadline)
                    }
                }
                NavigationLink {
                    ConversationPrivacyView()
                } label: {
                    Label("Speech data and privacy", systemImage: "hand.raised").font(.subheadline)
                }
            }
        }
        .navigationDestination(isPresented: $navigation.showsConversation) {
            ConversationLiveView()
        }
        .onChange(of: controller.speech.isTranscriptionEnabled, initial: true) { _, isOn in
            conversation.transcriptionChanged(isOn: isOn)
        }
    }

    private static func explanation(_ conversation: ConversationIntelligenceController, isTranscribing: Bool) -> String {
        if !isTranscribing {
            return "Speech near you is shown as an icon only. Turn on “Transcribe nearby speech” to be able to ask for a summary. Speech from before it is on cannot be recovered."
        }
        switch conversation.phase {
        case .idle:
            return "Nothing is summarized by itself. Press Summarize, here or in the Dynamic Island (touch and hold it), for a summary of the last two minutes."
        case .preparing, .summarizing:
            return "Writing the summary…"
        case .summaryAvailable:
            return "The summary is saved. You can keep following the conversation."
        case .continuing:
            return "Following the conversation: live captions, and a summary that grows."
        }
    }
}

/// Summarize, Continue and Stop: three separate controls, the same ones the expanded Dynamic
/// Island offers. None of them starts or stops listening.
struct ConversationButtons: View {
    let conversation: ConversationIntelligenceController
    var onSummarize: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch conversation.phase {
            case .idle:
                Button {
                    conversation.summarize()
                    if conversation.phase != .idle { onSummarize() }
                } label: {
                    Label("Summarize Last 2 Minutes", systemImage: "text.bubble").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!conversation.isSessionActive)
                .accessibilityIdentifier("conversation.summarize")
                .accessibilityHint("Writes a summary of what was transcribed in the last two minutes and saves it.")
            case .preparing, .summarizing:
                Label("Writing the summary…", systemImage: "ellipsis.bubble")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)
            case .summaryAvailable:
                Button {
                    conversation.continueUnderstanding()
                } label: {
                    Label("Continue Understanding", systemImage: "captions.bubble").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("conversation.continue")
                .accessibilityHint("Keeps showing live captions and extends the saved summary.")
                Button {
                    conversation.summarize()
                } label: {
                    Label("Summarize Again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            case .continuing:
                Button(role: .destructive) {
                    conversation.stopUnderstanding()
                } label: {
                    Label("Stop Understanding", systemImage: "stop.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("conversation.stop")
                .accessibilityHint("Finishes the saved summary and deletes the temporary captions. Hearing Sense keeps listening for sounds.")
            }
        }
        .controlSize(.large)
    }
}

// MARK: - Live conversation

/// The recap and the live captions, full screen: large adjustable text, high contrast, final and
/// tentative speech told apart, the summary in its own section, timestamps, VoiceOver labels.
struct ConversationLiveView: View {
    @Environment(ListeningController.self) private var controller
    @AppStorage("conversation.captionSize") private var captionSize = 26.0
    @AppStorage("conversation.highContrast") private var highContrast = true
    @State private var showsTextSettings = false

    private var foreground: Color { highContrast ? .white : .primary }
    private var background: Color { highContrast ? .black : Color(.systemBackground) }
    private var dimmed: Color { highContrast ? Color(white: 0.72) : .secondary }

    var body: some View {
        let conversation = controller.conversation
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statusLine(conversation)
                    summarySection(conversation)
                    captionSection(conversation)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation.captions.count) { _, _ in
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: conversation.tentativeCaption) { _, _ in
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
        .background(background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { controls(conversation) }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsTextSettings = true
                } label: {
                    Label("Text size and contrast", systemImage: "textformat.size")
                }
            }
        }
        .sheet(isPresented: $showsTextSettings) {
            textSettings.presentationDetents([.height(260)])
        }
        .toolbarColorScheme(highContrast ? .dark : nil, for: .navigationBar)
    }

    private func statusLine(_ conversation: ConversationIntelligenceController) -> some View {
        HStack(spacing: 10) {
            Image(systemName: conversation.status?.symbolName ?? (conversation.canSummarize ? "ear" : "ear.trianglebadge.exclamationmark"))
                .accessibilityHidden(true)
            Text(Self.statusText(conversation))
            if conversation.phase == .preparing || conversation.phase == .summarizing {
                ProgressView().tint(foreground)
            }
        }
        .font(.system(size: max(captionSize * 0.62, 15), weight: .semibold))
        .foregroundStyle(dimmed)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func summarySection(_ conversation: ConversationIntelligenceController) -> some View {
        if let recap = conversation.recap {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Summary", detail: Self.span(recap.coveredFrom, recap.coveredTo))
                Text(recap.title)
                    .font(.system(size: captionSize * 1.05, weight: .bold))
                    .foregroundStyle(foreground)
                Text(recap.summary)
                    .font(.system(size: captionSize))
                    .foregroundStyle(foreground)
                    .textSelection(.enabled)
                ForEach(recap.keyPoints, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").accessibilityHidden(true)
                        Text(point)
                    }
                    .font(.system(size: captionSize * 0.92))
                    .foregroundStyle(foreground)
                }
                ForEach(recap.caveats, id: \.self) { caveat in
                    Label(caveat, systemImage: "info.circle")
                        .font(.system(size: max(captionSize * 0.7, 15)))
                        .foregroundStyle(dimmed)
                }
                if !recap.isSummary {
                    Label("No summary was written; nothing but this note is saved.", systemImage: "exclamationmark.bubble")
                        .font(.system(size: max(captionSize * 0.7, 15)))
                        .foregroundStyle(dimmed)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((highContrast ? Color(white: 0.14) : Color(.secondarySystemBackground)), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Summary")
        }
    }

    @ViewBuilder
    private func captionSection(_ conversation: ConversationIntelligenceController) -> some View {
        sectionHeader(conversation.phase == .continuing ? "Live captions" : "Recent speech (temporary)",
                      detail: conversation.isTranscriptionOn ? "kept \(ConversationIntelligenceController.describe(conversation.lookBack)), never saved" : nil)
        if conversation.captions.isEmpty, conversation.tentativeCaption == nil {
            Text(conversation.canSummarize ? "Nothing has been said yet." : Self.unavailableText(conversation))
                .font(.system(size: captionSize * 0.85))
                .foregroundStyle(dimmed)
        }
        ForEach(conversation.captions) { caption in
            VStack(alignment: .leading, spacing: 4) {
                Text(caption.start, format: .dateTime.hour().minute().second())
                    .font(.system(size: max(captionSize * 0.55, 14), weight: .medium).monospacedDigit())
                    .foregroundStyle(dimmed)
                Text(caption.text)
                    .font(.system(size: captionSize))
                    .foregroundStyle(foreground)
                    .textSelection(.enabled)
                if caption.isLowQuality {
                    Label("Hard to recognize", systemImage: "questionmark.circle")
                        .font(.system(size: max(captionSize * 0.55, 14)))
                        .foregroundStyle(dimmed)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(caption.text). \(caption.isLowQuality ? "Hard to recognize. " : "")Said at \(caption.start.formatted(date: .omitted, time: .standard))")
        }
        if let tentative = conversation.tentativeCaption {
            // Not final: lighter, italic, and marked in words, not by colour alone.
            VStack(alignment: .leading, spacing: 4) {
                Label("Still listening — may change", systemImage: "ellipsis")
                    .font(.system(size: max(captionSize * 0.55, 14), weight: .medium))
                    .foregroundStyle(dimmed)
                Text(tentative + " …")
                    .font(.system(size: captionSize).italic())
                    .foregroundStyle(dimmed)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Not final yet: \(tentative)")
        }
    }

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: max(captionSize * 0.55, 14), weight: .bold))
                .foregroundStyle(dimmed)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.system(size: max(captionSize * 0.5, 13))).foregroundStyle(dimmed)
            }
        }
    }

    private func controls(_ conversation: ConversationIntelligenceController) -> some View {
        ConversationButtons(conversation: conversation) {}
            .padding()
            .background(highContrast ? AnyShapeStyle(Color(white: 0.1)) : AnyShapeStyle(.bar))
    }

    private var textSettings: some View {
        Form {
            Section("Text size") {
                HStack {
                    Image(systemName: "textformat.size.smaller").accessibilityHidden(true)
                    Slider(value: $captionSize, in: 18 ... 48, step: 2) {
                        Text("Caption text size")
                    }
                    .accessibilityValue("\(Int(captionSize)) points")
                    Image(systemName: "textformat.size.larger").accessibilityHidden(true)
                }
                Text("Sample caption").font(.system(size: captionSize))
            }
            Section {
                Toggle("High contrast (white on black)", isOn: $highContrast)
            }
        }
    }

    private static func statusText(_ conversation: ConversationIntelligenceController) -> String {
        if let status = conversation.status { return status.title }
        if !conversation.canSummarize { return "Summaries unavailable" }
        return conversation.phase == .summaryAvailable ? "Summary saved" : "Listening"
    }

    private static func unavailableText(_ conversation: ConversationIntelligenceController) -> String {
        if !conversation.isSessionActive { return "Hearing Sense is not listening." }
        return "“Transcribe nearby speech” is off, so there is no text to show. Speech from before it is turned on cannot be recovered."
    }

    private static func span(_ from: Date?, _ to: Date?) -> String? {
        guard let from, let to else { return nil }
        return "\(from.formatted(date: .omitted, time: .shortened)) – \(to.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - History

struct ConversationHistoryView: View {
    @Environment(ListeningController.self) private var controller
    @State private var query = ""
    @State private var confirmsDeleteAll = false

    var body: some View {
        let conversation = controller.conversation
        let records = conversation.search(query)
        List {
            if records.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No saved summaries" : "No results",
                                       systemImage: query.isEmpty ? "text.bubble" : "magnifyingglass",
                                       description: Text(query.isEmpty
                                           ? "Summaries you ask for are saved here, on this iPhone only."
                                           : "No saved summary contains “\(query)”."))
            }
            ForEach(records) { record in
                NavigationLink {
                    ConversationRecordView(id: record.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(record.title).font(.headline)
                            if record.status == .continuing {
                                Text("Continuing").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.tint.opacity(0.2), in: Capsule())
                            }
                        }
                        Text(record.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        Text(record.createdAt, format: .dateTime.weekday().day().month().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .onDelete { offsets in
                conversation.delete(Set(offsets.map { records[$0].id }))
            }
        }
        .searchable(text: $query, prompt: "Search summaries")
        .navigationTitle("Saved summaries")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete All", role: .destructive) { confirmsDeleteAll = true }
                    .disabled(conversation.history.isEmpty)
            }
        }
        .confirmationDialog("Delete every saved summary?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
            Button("Delete All Summaries", role: .destructive) { conversation.deleteAllHistory() }
        } message: {
            Text("This cannot be undone.")
        }
        .onAppear { conversation.refreshHistory() }
    }
}

struct ConversationRecordView: View {
    @Environment(ListeningController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var isEditing = false
    @State private var title = ""
    @State private var summary = ""
    @State private var didCopy = false

    var body: some View {
        let conversation = controller.conversation
        Group {
            if let record = conversation.record(id) {
                Form {
                    if isEditing {
                        Section("Title") { TextField("Title", text: $title) }
                        Section("Summary") { TextEditor(text: $summary).frame(minHeight: 220) }
                    } else {
                        Section {
                            Text(record.title).font(.title3.bold())
                            Text(record.summary).textSelection(.enabled)
                        }
                        if !record.keyPoints.isEmpty {
                            Section("Key points") {
                                ForEach(record.keyPoints, id: \.self) { Text($0).textSelection(.enabled) }
                            }
                        }
                        if !record.caveats.isEmpty {
                            Section("Notes") {
                                ForEach(record.caveats, id: \.self) { Label($0, systemImage: "info.circle") }
                            }
                        }
                        Section {
                            LabeledContent("Created", value: record.createdAt.formatted(date: .abbreviated, time: .standard))
                            LabeledContent("Updated", value: record.updatedAt.formatted(date: .abbreviated, time: .standard))
                            if let from = record.coveredFrom, let to = record.coveredTo {
                                LabeledContent("Speech from", value: "\(from.formatted(date: .omitted, time: .standard)) – \(to.formatted(date: .omitted, time: .standard))")
                            }
                            LabeledContent("Status", value: record.status == .continuing ? "Continuing" : "Completed")
                            if record.isUserEdited { LabeledContent("Edited", value: "By you") }
                        }
                        Section {
                            Button {
                                UIPasteboard.general.string = record.fullText
                                didCopy = true
                            } label: {
                                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                conversation.delete([id])
                                dismiss()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isEditing ? "Done" : "Edit") {
                            if isEditing {
                                conversation.edit(id, title: title, summary: summary)
                            } else {
                                title = record.title
                                summary = record.summary
                            }
                            isEditing.toggle()
                        }
                    }
                }
            } else {
                ContentUnavailableView("Summary deleted", systemImage: "trash")
            }
        }
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
/// The newest saved summary, for `--hs-screen summary`.
struct NewestConversationRecordView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        if let id = controller.conversation.history.first?.id {
            ConversationRecordView(id: id)
        } else {
            ContentUnavailableView("No saved summaries yet", systemImage: "text.bubble")
        }
    }
}
#endif

// MARK: - Privacy

/// What is processed, what is kept for how long, what is saved, and how to turn it off.
struct ConversationPrivacyView: View {
    @Environment(ListeningController.self) private var controller
    @State private var confirmsDeleteAll = false

    var body: some View {
        let conversation = controller.conversation
        let speech = controller.speech
        Form {
            Section {
                LabeledContent("Microphone", value: controller.state.isCapturing ? "On (listening)" : "Off")
                LabeledContent("Sound recognition", value: controller.state.isCapturing ? "On" : "Off")
                Toggle("Transcribe nearby speech", isOn: Binding(get: { speech.isTranscriptionEnabled },
                                                               set: { speech.setTranscriptionEnabled($0) }))
            } header: {
                Text("What is running")
            } footer: {
                Text("Recognizing sounds does not include transcribing speech: that is a separate switch, and it is off until you turn it on. Everything is processed on this iPhone. Nothing is uploaded.")
            }

            Section {
                LabeledContent("Kept for a summary", value: speech.isTranscriptionEnabled ? "The last 2 minutes" : "Nothing")
                LabeledContent("Held right now", value: "\(conversation.captions.count) sentences, \(conversation.bufferedWordCount) words")
                Button("Clear Recent Speech Now", role: .destructive) { conversation.speechDataCleared() }
                    .disabled(conversation.captions.isEmpty && conversation.tentativeCaption == nil)
            } header: {
                Text("Temporary")
            } footer: {
                Text("Needed for a summary you ask for. While “Transcribe nearby speech” is on, transcribed sentences stay in memory for two minutes and are then deleted. They are never written to storage, and they are deleted at once when you switch transcription off, stop listening or stop following a conversation. Nothing is summarized unless you press Summarize.")
            }

            Section {
                LabeledContent("Saved summaries", value: "\(conversation.history.count)")
                Button("Delete All Saved Summaries", role: .destructive) { confirmsDeleteAll = true }
                    .disabled(conversation.history.isEmpty)
            } header: {
                Text("Saved")
            } footer: {
                Text("Only summaries you ask for are saved: the summary text and its dates, on this iPhone, excluded from backups. No audio and no transcript is saved.")
            }

            Section("Other people") {
                Text("Recaps and captions put other people's words into text. Tell the people you are talking with, and follow the rules that apply where you are. Do not use them where conversations must stay confidential.")
                Text("Hearing Sense is an awareness aid. It can miss or misunderstand speech and sounds. It is not an emergency or safety system and does not replace hearing assistance.")
            }
        }
        .navigationTitle("Speech data and privacy")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete every saved summary?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
            Button("Delete All Summaries", role: .destructive) { conversation.deleteAllHistory() }
        } message: {
            Text("This cannot be undone.")
        }
    }
}
