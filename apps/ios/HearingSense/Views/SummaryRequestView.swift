import SwiftUI
import ConversationUnderstanding

/// A request has a page before it has a saved record. No empty History rows are inserted.
struct SummaryRequestView: View {
    @Environment(ListeningController.self) private var controller
    let requestID: UUID
    @State private var savedID: UUID?

    var body: some View {
        let conversation = controller.conversation
        Group {
            if let id = savedID ?? conversation.requestRecords[requestID] {
                ConversationRecordView(id: id)
            } else {
                Form {
                    Section {
                        if conversation.isSummaryWorking, conversation.summaryRequestID == requestID {
                            HStack {
                                ProgressView()
                                Text(conversation.summaryStage).accessibilityIdentifier("summary.progress")
                            }
                            if let started = conversation.summaryStartedAt {
                                HStack {
                                    Text("Elapsed")
                                    Text(started, style: .timer).monospacedDigit()
                                }.foregroundStyle(.secondary)
                            }
                        } else {
                            Label(conversation.requestNotices[requestID] ?? "This summary is no longer available.",
                                  systemImage: "info.circle")
                                .accessibilityIdentifier("summary.notice")
                        }
                        if let error = conversation.storageError {
                            Label(error, systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                        }
                    }
                    if let recap = conversation.recap {
                        Section { Text(conversation.isSummaryWorking ? "Last completed summary" : "Summary") .font(.headline) }
                        SummarySections(title: recap.title, summary: recap.summary,
                                        keyPoints: recap.keyPoints, caveats: recap.caveats)
                    }
                    Section {
                        ConversationButtons(conversation: conversation) { }
                        NavigationLink("Live captions") { ConversationLiveView() }
                    }
                }
                .navigationTitle("Summary")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onChange(of: conversation.requestRecords[requestID], initial: true) { _, id in
            if let id { savedID = id }
        }
    }
}

/// The same full summary is read from a pending request and from History.
struct SummarySections: View {
    let title: String
    let summary: String
    let keyPoints: [String]
    let caveats: [String]
    var savedAt: Date? = nil
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: HSSpacing.xs) {
                Text(title).font(.title2.bold())
                Text(summary).font(.body).textSelection(.enabled)
                    .accessibilityIdentifier("summary.body")
                    #if DEBUG
                    // Fixed-fixture UI acceptance measures save-to-visible latency without
                    // exporting text or adding a diagnostic control to the screen.
                    .accessibilityValue(Window9StabilitySelfTest.arguments.contains("--hs-w9-ui-fixture")
                        ? savedAt.map { String($0.timeIntervalSince1970) } ?? "" : "")
                    #endif
            }
            .padding(.vertical, HSSpacing.xxs)
        }
        if !keyPoints.isEmpty {
            Section("Key Points") { ForEach(keyPoints, id: \.self) { Text($0).textSelection(.enabled) } }
        }
        if !caveats.isEmpty {
            Section("Notes") { ForEach(caveats, id: \.self) { Label($0, systemImage: "info.circle") } }
        }
    }
}
