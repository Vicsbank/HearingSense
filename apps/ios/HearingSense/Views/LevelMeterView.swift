import HearingSenseAudio
import SwiftUI

/// Live microphone level. Every value shown comes from `LevelMeter` measurements of real
/// captured buffers; when not capturing the meter is empty rather than animated.
struct LevelMeterView: View {
    let level: AudioLevel
    let history: [Float]
    let capacity: Int
    let isActive: Bool

    private let range: ClosedRange<Float> = -80 ... 0

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Microphone level", systemImage: "waveform")
                        .font(.headline)
                    Spacer()
                    Text(isActive ? "\(Int(level.rmsDBFS.rounded())) dBFS" : "—")
                        .font(.body.monospacedDigit())
                }

                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        if isActive {
                            Capsule()
                                .fill(.tint)
                                .frame(width: width * CGFloat(level.normalizedRMS(range: range)))
                            Rectangle()
                                .fill(.primary)
                                .frame(width: 2)
                                .offset(x: max(0, width * CGFloat(level.normalizedPeak(range: range)) - 2))
                        }
                    }
                }
                .frame(height: 14)

                LevelHistoryGraph(values: history, capacity: capacity, range: range)
                    .frame(height: 64)
                    .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                Text(isActive
                     ? "RMS level of live microphone buffers (bar), peak (line), last ~10 seconds (graph). Scale −80 to 0 dBFS."
                     : "Start listening to see the live microphone level.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(isActive ? "\(Int(level.rmsDBFS.rounded())) decibels relative to full scale" : "Microphone off")
    }
}

private struct LevelHistoryGraph: View {
    let values: [Float]
    let capacity: Int
    let range: ClosedRange<Float>

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, capacity > 1 else { return }
            let step = size.width / CGFloat(capacity - 1)
            let offset = capacity - values.count  // newest sample at the right edge
            var path = Path()
            for (index, value) in values.enumerated() {
                let normalized = AudioLevel(rmsDBFS: value, peakDBFS: value).normalizedRMS(range: range)
                let point = CGPoint(x: CGFloat(index + offset) * step,
                                    y: size.height * (1 - CGFloat(normalized)))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .style(.tint), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }
}
