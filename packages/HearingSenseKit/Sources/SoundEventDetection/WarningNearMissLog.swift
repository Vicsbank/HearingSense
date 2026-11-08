import Foundation
import HearingSenseDomain

/// Keeps what the classifier reported for warning sounds that were *not* confirmed as an event:
/// label, score, number of windows, time, the label that scored highest at the same moment and
/// the input level. No audio and nothing derived from speech.
///
/// Why it exists: in the Window 5 retest a siren clip was not recognized, and nothing was kept
/// that could say why — a miss leaves no confirmed event, and scores were not logged. With this
/// log a miss can be read afterwards as "the label never appeared", "it appeared below the
/// confirmation rule" or "another label won".
///
/// A value type without a clock: times come from the frames. Bounded.
public struct WarningNearMissLog: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var kindID: String
        /// The kind's label with the highest score in the run.
        public var label: SoundLabel
        public var peak: Double
        /// Windows in which a label of the kind was at or above the floor.
        public var windows: Int
        public var first: Date
        public var last: Date
        /// The classifier's top label in the peak window, if it was another one.
        public var competingLabel: SoundLabel?
        public var competingScore: Double?
        public var inputRMSDBFS: Float?
        /// The detector confirmed an event of this kind during the run (then it is not a miss).
        public var wasConfirmed: Bool
    }

    /// Kinds that warn, or that the attention engine treats as important.
    public static let standardKindIDs: Set<String> = ["siren", "alarm", "vehicle_horn", "reverse_beeps", "bicycle_bell",
                                                      "glass_breaking", "bang", "screaming", "door"]

    public let kindIDs: Set<String>
    /// Scores below this are not noted.
    public let floor: Double
    /// A run ends when its kind was not seen for this long.
    public let gap: TimeInterval
    public let capacity: Int
    public private(set) var closed: [Entry] = []
    public private(set) var confirmedRuns = 0
    private var open: [String: Entry] = [:]

    public init(kindIDs: Set<String> = WarningNearMissLog.standardKindIDs, floor: Double = 0.15, gap: TimeInterval = 3,
                capacity: Int = 60)
    {
        self.kindIDs = kindIDs
        self.floor = floor
        self.gap = gap
        self.capacity = capacity
    }

    /// - Parameter confirmedKindIDs: kinds with a confirmed event that is active right now.
    public mutating func note(_ frame: ClassificationFrame, taxonomy: SoundTaxonomy, confirmedKindIDs: Set<String>) {
        let now = frame.producedAt
        var best: [String: RawSoundPrediction] = [:]
        for prediction in frame.predictions where prediction.score.rawValue >= floor {
            let kindID = taxonomy.definition(for: prediction.label).kind.id
            guard kindIDs.contains(kindID) else { continue }
            if let current = best[kindID], current.score >= prediction.score { continue }
            best[kindID] = prediction
        }
        for (kindID, prediction) in best {
            var entry = open[kindID] ?? Entry(kindID: kindID, label: prediction.label, peak: 0, windows: 0, first: now,
                                             last: now, competingLabel: nil, competingScore: nil, inputRMSDBFS: nil,
                                             wasConfirmed: false)
            entry.windows += 1
            entry.last = now
            if prediction.score.rawValue > entry.peak {
                entry.peak = prediction.score.rawValue
                entry.label = prediction.label
                entry.inputRMSDBFS = frame.inputLevel?.rmsDBFS
                if let top = frame.top, top.label != prediction.label {
                    entry.competingLabel = top.label
                    entry.competingScore = top.score.rawValue
                } else {
                    entry.competingLabel = nil
                    entry.competingScore = nil
                }
            }
            open[kindID] = entry
        }
        for kindID in confirmedKindIDs where open[kindID] != nil { open[kindID]?.wasConfirmed = true }
        for (kindID, entry) in open where now.timeIntervalSince(entry.last) > gap { close(kindID) }
    }

    /// Listening stopped: runs in progress are finished.
    public mutating func endSession() {
        for kindID in open.keys.sorted() { close(kindID) }
    }

    private mutating func close(_ kindID: String) {
        guard let entry = open.removeValue(forKey: kindID) else { return }
        if entry.wasConfirmed {
            confirmedRuns += 1
        } else {
            closed.append(entry)
            if closed.count > capacity { closed.removeFirst(closed.count - capacity) }
        }
    }

    /// Unconfirmed runs, oldest first, including the ones still in progress.
    public var misses: [Entry] {
        (closed + open.values.filter { !$0.wasConfirmed }).sorted { $0.first != $1.first ? $0.first < $1.first : $0.kindID < $1.kindID }
    }

    public func reportLines() -> [String] {
        let score = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        var lines = ["Warning-sound candidates that were not confirmed (score ≥ \(floor.formatted(score)); labels, scores "
            + "and times only, oldest first; \(confirmedRuns) further runs were confirmed):"]
        if misses.isEmpty { lines.append("  none") }
        for entry in misses {
            let time = entry.first.formatted(.iso8601.time(includingFractionalSeconds: true))
            let seconds = entry.last.timeIntervalSince(entry.first).formatted(.number.precision(.fractionLength(1)))
            let competing = entry.competingLabel.map { ", top label then \($0) \((entry.competingScore ?? 0).formatted(score))" } ?? ", it was the top label"
            let level = entry.inputRMSDBFS.map { ", input \(Int($0.rounded())) dBFS" } ?? ""
            lines.append("  \(time) \(entry.kindID) [\(entry.label)] peak \(entry.peak.formatted(score)), \(entry.windows) window(s) "
                + "over \(seconds) s\(competing)\(level)")
        }
        return lines
    }
}
