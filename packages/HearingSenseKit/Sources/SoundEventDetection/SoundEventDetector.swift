import Foundation
import HearingSenseDomain

/// Turns classifier windows into confirmed acoustic events.
///
/// Pipeline per window: confidence filter (per-kind thresholds) → per-kind aggregation (best
/// label score among the kind's labels) → candidate confirmation (k hits within a look-back, or
/// one very strong window) → hysteresis while active (lower sustain threshold) → end after a
/// kind-specific timeout without evidence.
///
/// Deterministic: time comes only from the frames' audio clock and wall-clock fields, never
/// from the system clock, so recorded or synthetic frame sequences replay identically.
/// Not thread-safe; owned by one serial context (`SoundRecognitionEngine`'s worker or a test).
public struct SoundEventDetector: Sendable {
    public struct Statistics: Hashable, Sendable {
        public var windows = 0
        public var candidatesStarted = 0
        /// Candidates that expired without meeting their rule (suppressed noise).
        public var candidatesRejected = 0
        public var eventsConfirmed = 0
        public var eventsEnded = 0

        public init() {}
    }

    public struct Output: Hashable, Sendable {
        public var updates: [AcousticEventUpdate]
        public var status: EnvironmentStatus
        public var candidates: [AcousticEventCandidate]
    }

    public let taxonomy: SoundTaxonomy
    public let policy: DetectionPolicy
    public private(set) var statistics = Statistics()
    private var tracks: [String: Track] = [:]

    public init(taxonomy: SoundTaxonomy = .appleV1, policy: DetectionPolicy = .standard) {
        self.taxonomy = taxonomy
        self.policy = policy
    }

    public var activeEvents: [ConfirmedAcousticEvent] {
        tracks.values.compactMap(\.event).sorted(by: Self.presentationOrder)
    }

    public var candidates: [AcousticEventCandidate] {
        tracks.values.filter { $0.event == nil }.map { $0.candidate() }.sorted { $0.kind.id < $1.kind.id }
    }

    // MARK: - Processing

    public mutating func process(_ frame: ClassificationFrame) -> Output {
        statistics.windows += 1
        let observations = observe(frame)
        var updates: [AcousticEventUpdate] = []

        for kindID in Set(tracks.keys).union(observations.keys).sorted() {
            let observation = observations[kindID]
            if var track = tracks[kindID] {
                let update = track.event == nil
                    ? advanceCandidate(&track, with: observation, frame: frame)
                    : advanceActive(&track, with: observation, frame: frame)
                if let update { updates.append(update) }
                if track.isFinished {
                    tracks[kindID] = nil
                } else {
                    tracks[kindID] = track
                }
            } else if let observation, observation.bestScore >= observation.rule.enterScore {
                var track = Track(definition: observation.definition, rule: observation.rule, frame: frame)
                statistics.candidatesStarted += 1
                track.recordHit(observation, threshold: observation.rule.enterScore, frame: frame)
                if track.meetsConfirmation(bestScore: observation.bestScore) {
                    updates.append(confirm(&track, frame: frame))
                }
                tracks[kindID] = track
            }
        }

        return Output(updates: updates, status: status(for: frame), candidates: candidates)
    }

    /// Ends every active event and discards candidates (listening stopped or interrupted).
    public mutating func finish(at date: Date) -> [AcousticEventUpdate] {
        var updates: [AcousticEventUpdate] = []
        for kindID in tracks.keys.sorted() {
            guard var event = tracks[kindID]?.event else { continue }
            event.phase = .ended
            event.endedDate = date
            statistics.eventsEnded += 1
            updates.append(.ended(event))
        }
        statistics.candidatesRejected += tracks.values.filter { $0.event == nil }.count
        tracks.removeAll()
        return updates
    }

    // MARK: - Steps

    /// Confidence filter + aggregation: for each kind, the best score among its labels in this
    /// window, keeping only labels at or above the kind's sustain threshold (the lowest
    /// threshold any rule uses). Non-event labels (`silence`) and labels suppressed by a
    /// competing kind (`DetectionPolicy.suppressions`) are skipped.
    private func observe(_ frame: ClassificationFrame) -> [String: Observation] {
        var kindScores: [String: Double] = [:]
        for prediction in frame.predictions {
            let kindID = taxonomy.definition(for: prediction.label).kind.id
            kindScores[kindID] = max(kindScores[kindID] ?? 0, prediction.score.rawValue)
        }
        var result: [String: Observation] = [:]
        for prediction in frame.predictions {
            let definition = taxonomy.definition(for: prediction.label)
            guard definition.producesEvents else { continue }
            let suppressed = policy.suppressions.contains {
                $0.label == prediction.label && (kindScores[$0.competingKind] ?? 0) >= $0.minimumCompetingScore
            }
            guard !suppressed else { continue }
            let rule = policy.rule(for: definition)
            guard prediction.score.rawValue >= rule.sustainScore else { continue }
            result[definition.kind.id, default: Observation(definition: definition, rule: rule)]
                .add(prediction)
        }
        return result
    }

    private mutating func advanceCandidate(_ track: inout Track, with observation: Observation?,
                                           frame: ClassificationFrame) -> AcousticEventUpdate?
    {
        track.observedWindows += 1
        let rule = track.rule
        if let observation, observation.bestScore >= rule.enterScore {
            track.recordHit(observation, threshold: rule.enterScore, frame: frame)
        }
        track.pruneHits(before: frame.audioTime.end - rule.confirmWithin)
        let bestScore = observation?.bestScore ?? 0
        let hitThisWindow = track.lastSupported == frame.audioTime.end
        if hitThisWindow, track.meetsConfirmation(bestScore: bestScore) {
            return confirm(&track, frame: frame)
        }
        if frame.audioTime.end - track.lastSupported > rule.confirmWithin {
            statistics.candidatesRejected += 1
            track.isFinished = true
        }
        return nil
    }

    private mutating func advanceActive(_ track: inout Track, with observation: Observation?,
                                        frame: ClassificationFrame) -> AcousticEventUpdate?
    {
        track.observedWindows += 1
        let rule = track.rule
        var supported = false
        if let observation, observation.bestScore >= rule.sustainScore {
            track.recordHit(observation, threshold: rule.sustainScore, frame: frame)
            supported = true
        }
        guard var event = track.event else { return nil }

        if frame.audioTime.end - track.lastSupported >= rule.endAfter {
            event.phase = .ended
            event.endedDate = frame.producedAt
            event.evidence = track.evidence
            track.event = event
            track.isFinished = true
            statistics.eventsEnded += 1
            return .ended(event)
        }
        guard supported else { return nil }

        let primary = track.primaryLabel
        let quality = EventQuality.assess(track.evidence)
        let changed = primary != track.publishedPrimary || quality != track.publishedQuality
        let due = frame.audioTime.end - track.publishedAudioTime >= policy.updateInterval
        event.primaryLabel = primary
        event.audioLastObserved = track.lastSupported
        event.lastObservedDate = frame.producedAt
        event.evidence = track.evidence
        event.quality = quality
        event.phase = .ongoing
        track.event = event
        guard changed || due else { return nil }
        track.markPublished(event, at: frame.audioTime.end)
        return .updated(event)
    }

    private mutating func confirm(_ track: inout Track, frame: ClassificationFrame) -> AcousticEventUpdate {
        let anchor = frame.capturedAt ?? frame.producedAt
        let startDate = anchor.addingTimeInterval(track.firstDetected - frame.audioTime.end)
        let event = ConfirmedAcousticEvent(
            kind: track.definition.kind, source: .soundClassifier(frame.model), primaryLabel: track.primaryLabel,
            phase: .confirmed, audioStart: track.firstDetected, audioConfirmed: frame.audioTime.end,
            audioLastObserved: track.lastSupported, startDate: startDate, confirmedDate: frame.producedAt,
            lastObservedDate: frame.producedAt, evidence: track.evidence,
            quality: EventQuality.assess(track.evidence))
        track.event = event
        track.markPublished(event, at: frame.audioTime.end)
        statistics.eventsConfirmed += 1
        return .started(event)
    }

    private func status(for frame: ClassificationFrame) -> EnvironmentStatus {
        let active = activeEvents
        if !active.isEmpty { return .recognized(active) }
        let silenceOnTop = frame.top.map { $0.label == taxonomy.silenceLabel && $0.score.rawValue >= 0.5 } ?? false
        let belowQuiet = frame.inputLevel.map { $0.rmsDBFS < policy.quietThresholdDBFS } ?? false
        if silenceOnTop || belowQuiet { return .quiet }
        if let top = frame.predictions.first(where: {
            $0.label != taxonomy.silenceLabel && $0.score.rawValue >= policy.displayFloor
        }) {
            return .uncertain(top)
        }
        return .unclassified
    }

    /// Most recently observed first; ties by category then kind.
    static func presentationOrder(_ a: ConfirmedAcousticEvent, _ b: ConfirmedAcousticEvent) -> Bool {
        if a.audioLastObserved != b.audioLastObserved { return a.audioLastObserved > b.audioLastObserved }
        if a.category != b.category { return a.category.rawValue < b.category.rawValue }
        return a.kind.id < b.kind.id
    }
}

// MARK: - Internal state

/// One window's evidence for one kind.
private struct Observation {
    let definition: SoundKindDefinition
    let rule: ConfirmationRule
    var labelScores: [SoundLabel: Double] = [:]
    var bestScore: Double = 0

    init(definition: SoundKindDefinition, rule: ConfirmationRule) {
        self.definition = definition
        self.rule = rule
    }

    mutating func add(_ prediction: RawSoundPrediction) {
        labelScores[prediction.label] = max(labelScores[prediction.label] ?? 0, prediction.score.rawValue)
        bestScore = max(bestScore, prediction.score.rawValue)
    }
}

/// A candidate (event == nil) or an active event for one kind.
private struct Track {
    let definition: SoundKindDefinition
    let rule: ConfirmationRule
    let firstDetected: TimeInterval
    var lastSupported: TimeInterval
    var hitEnds: [TimeInterval] = []
    var observedWindows = 0
    var supportingWindows = 0
    var peakScore = 0.0
    var scoreSum = 0.0
    var labels: [SoundLabel: LabelEvidence] = [:]
    var event: ConfirmedAcousticEvent?
    var publishedPrimary: SoundLabel?
    var publishedQuality: EventQuality?
    var publishedAudioTime: TimeInterval = 0
    var isFinished = false

    init(definition: SoundKindDefinition, rule: ConfirmationRule, frame: ClassificationFrame) {
        self.definition = definition
        self.rule = rule
        firstDetected = frame.audioTime.start
        lastSupported = frame.audioTime.end
        observedWindows = 1
    }

    mutating func recordHit(_ observation: Observation, threshold: Double, frame: ClassificationFrame) {
        let end = frame.audioTime.end
        hitEnds.append(end)
        lastSupported = end
        supportingWindows += 1
        peakScore = max(peakScore, observation.bestScore)
        scoreSum += observation.bestScore
        for (label, score) in observation.labelScores where score >= threshold {
            var entry = labels[label] ?? LabelEvidence(label: label, windowCount: 0, peakScore: .zero, scoreSum: 0)
            entry.windowCount += 1
            entry.scoreSum += score
            entry.peakScore = max(entry.peakScore, ClassifierScore(score))
            labels[label] = entry
        }
    }

    /// Small tolerance so a look-back of exactly k hops includes the window k hops ago despite
    /// floating-point rounding of window end times.
    mutating func pruneHits(before limit: TimeInterval) {
        hitEnds.removeAll { $0 < limit - 1e-6 }
    }

    func meetsConfirmation(bestScore: Double) -> Bool {
        if let instant = rule.instantConfirmScore, bestScore >= instant { return true }
        return hitEnds.count >= rule.requiredHits
    }

    var evidence: EventEvidence {
        let sorted = labels.values.sorted {
            if $0.scoreSum != $1.scoreSum { return $0.scoreSum > $1.scoreSum }
            return $0.label < $1.label
        }
        return EventEvidence(supportingWindows: supportingWindows, observedWindows: observedWindows,
                             peakScore: ClassifierScore(peakScore), scoreSum: scoreSum, labels: sorted)
    }

    var primaryLabel: SoundLabel {
        evidence.labels.first?.label ?? definition.labels.first ?? SoundLabel(definition.kind.id)
    }

    mutating func markPublished(_ event: ConfirmedAcousticEvent, at audioTime: TimeInterval) {
        publishedPrimary = event.primaryLabel
        publishedQuality = event.quality
        publishedAudioTime = audioTime
    }

    func candidate() -> AcousticEventCandidate {
        AcousticEventCandidate(kind: definition.kind, primaryLabel: primaryLabel, firstDetected: firstDetected,
                               lastDetected: lastSupported, evidence: evidence, recentHits: hitEnds.count,
                               requiredHits: rule.requiredHits)
    }
}
