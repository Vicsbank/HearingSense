import HearingSenseAudio
import HearingSenseDomain
import Observation
import SoundEventDetection
import SwiftUI

/// The acoustic scene of a listening session (Window 7): "Traffic nearby", "Music playing",
/// "Quiet surroundings". Secondary information beside the individual sound's icon.
///
/// It reads the confirmed sound events the recognition pipeline already publishes and nothing
/// else: no audio, no language model, no location. Main-actor isolated and owned by
/// `ListeningController`. Event-driven: one pending timer for the tracker's next look, and none
/// at all once a quiet scene has settled.
@Observable
final class SceneAwarenessController {
    private(set) var estimate: AcousticSceneEstimate?
    private(set) var statistics = AcousticSceneTracker.Statistics()

    /// The scene changed (nil: the session ended).
    @ObservationIgnored var onChange: ((AcousticSceneEstimate?) -> Void)?

    @ObservationIgnored private var tracker = AcousticSceneTracker()
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var log: (DiagnosticEventLog.Kind, String) -> Void = { _, _ in }

    deinit {
        deadlineTask?.cancel()
    }

    func setLogger(_ logger: @escaping (DiagnosticEventLog.Kind, String) -> Void) {
        log = logger
    }

    func sessionWillStart() {
        process(.sessionStarted(at: .now))
    }

    func sessionDidEnd() {
        guard estimate != nil || tracker.nextDeadline != nil else { return }
        process(.sessionEnded(at: .now))
        estimate = nil
        onChange?(nil)
    }

    func receive(_ update: AcousticEventUpdate) {
        process(.sound(update))
    }

    private func process(_ input: AcousticSceneInput) {
        if let change = tracker.process(input) {
            estimate = change
            log(.recognition, "Scene: \(change.scene.rawValue) (share \(change.confidence.formatted(.percent.precision(.fractionLength(0)))))")
            onChange?(change)
        }
        statistics = tracker.statistics
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = tracker.nextDeadline else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled, let self else { return }
            self.process(.tick(at: max(.now, deadline)))
        }
    }

    /// Counts and the current scene. No audio, no text.
    func reportText() -> String {
        "Acoustic scene (Window 7): \(estimate?.scene.rawValue ?? "none") · changes \(statistics.changes), "
            + "evaluations \(statistics.evaluations), candidates abandoned \(statistics.candidatesAbandoned), "
            + "sound inputs \(statistics.soundInputs)"
    }
}
