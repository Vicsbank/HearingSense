import HearingSenseAudio
import SwiftUI

/// In-memory event log (permission, session, route, interruption, capture events).
/// Holds no audio and no transcripts; cleared when the app quits.
struct DiagnosticLogView: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        List {
            if controller.log.entries.isEmpty {
                Text("No events yet.").foregroundStyle(.secondary)
            }
            ForEach(controller.log.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.kind.rawValue.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(entry.kind == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                        Spacer()
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Event Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: controller.diagnosticsReport()) {
                    Label("Share report", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    controller.clearLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(controller.log.entries.isEmpty)
            }
        }
    }
}
