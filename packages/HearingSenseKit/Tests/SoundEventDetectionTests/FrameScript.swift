import Foundation
import HearingSenseDomain
@testable import SoundEventDetection

/// Builds synthetic classifier frames for deterministic detector tests. Test-only: production
/// code never fabricates predictions.
struct FrameScript {
    var window: TimeInterval = 1.5
    var hop: TimeInterval = 0.75
    var origin = Date(timeIntervalSince1970: 1_000_000)
    private(set) var sequence = 0

    /// Window `index` covers [index·hop, index·hop + window] on the audio clock.
    mutating func frame(_ scores: [SoundLabel: Double], rmsDBFS: Float? = -30) -> ClassificationFrame {
        let range = AudioTimeRange(start: Double(sequence) * hop, duration: window)
        let produced = origin.addingTimeInterval(range.end + 0.05)
        let predictions = scores.map {
            RawSoundPrediction(label: $0.key, score: ClassifierScore($0.value), audioTime: range,
                               producedAt: produced, model: .appleSoundClassifierV1)
        }
        defer { sequence += 1 }
        return ClassificationFrame(sequence: sequence, audioTime: range, producedAt: produced,
                                   capturedAt: origin.addingTimeInterval(range.end), model: .appleSoundClassifierV1,
                                   predictions: predictions,
                                   inputLevel: rmsDBFS.map { WindowInputLevel(rmsDBFS: $0, peakDBFS: $0 + 10) })
    }
}

extension SoundEventDetector {
    /// Runs a script and returns all updates, in order.
    mutating func run(_ script: inout FrameScript, _ windows: [[SoundLabel: Double]]) -> [AcousticEventUpdate] {
        windows.flatMap { process(script.frame($0)).updates }
    }
}

extension AcousticEventUpdate {
    var summary: String {
        switch self {
        case .started(let event): "started \(event.kind.id)"
        case .updated(let event): "updated \(event.kind.id)"
        case .ended(let event): "ended \(event.kind.id)"
        }
    }
}

/// Repository paths relative to this file (tests run from the package directory or Xcode).
enum RepositoryPaths {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SoundEventDetectionTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // HearingSenseKit
        .deletingLastPathComponent()  // packages
        .deletingLastPathComponent()  // repository root

    static let macOSLabelInventory = root.appending(path: "docs/research/sound_analysis_labels_v1_macos27.txt")
    static let speechSample = root.appending(path: "data/test_signals/speech_en.aiff")
}
