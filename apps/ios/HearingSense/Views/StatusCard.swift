import HearingSenseAudio
import SwiftUI

/// Listening status. Uses symbol + text + a "MIC ON" badge so state never depends on color.
struct StatusCard: View {
    let state: ListeningState
    let format: CaptureFormat?
    /// Debug builds: the session runs without the microphone (device test mode, synthetic capture).
    var isSynthetic = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.systemImage)
                    .font(.title)
                    .foregroundStyle(state.isCapturing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(minWidth: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(state.title)
                            .font(.headline)
                        Spacer(minLength: 8)
                        if state.isCapturing, isSynthetic {
                            Text("TEST · MIC OFF")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .overlay(Capsule().stroke(.secondary))
                                .accessibilityLabel("Test session, microphone off")
                        } else if state.isCapturing {
                            Text("MIC ON")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(.white)
                                .background(.red, in: Capsule())
                                .accessibilityLabel("Microphone on")
                        }
                    }
                    Text(state.isCapturing && isSynthetic
                        ? "Test session without the microphone: the audio session is not active and nothing is captured."
                        : state.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let format, state.isCapturing {
                        Text("Input format: \(format.summary)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(state.title)")
    }
}
