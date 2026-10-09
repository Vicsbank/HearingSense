import CoreMedia
import Foundation
import HearingSenseDomain
import SoundAnalysis

/// What Apple's built-in classifier reports about itself on the running OS. Used to verify the
/// label inventory on each platform (reproducible: same API on macOS, Simulator and iPhone).
public struct SoundClassifierCatalog: Hashable, Sendable {
    public var labels: [SoundLabel]
    public var defaultWindowDuration: TimeInterval
    public var defaultOverlapFactor: Double
    public var windowConstraint: String

    /// Queries `SNClassifySoundRequest(classifierIdentifier: .version1)`. Labels are kept in the
    /// order the framework returns them.
    public static func load() throws -> SoundClassifierCatalog {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let constraint: String
        switch request.windowDurationConstraint {
        case .enumeratedDurations(let durations):
            constraint = "enumerated " + durations.map { "\($0.seconds)" }.joined(separator: ", ")
        case .durationRange(let range):
            constraint = "range \(range.start.seconds) … \(range.end.seconds) s"
        @unknown default:
            constraint = "unknown"
        }
        return SoundClassifierCatalog(labels: request.knownClassifications.map(SoundLabel.init(rawValue:)),
                                      defaultWindowDuration: request.windowDuration.seconds,
                                      defaultOverlapFactor: request.overlapFactor,
                                      windowConstraint: constraint)
    }

    /// Plain-text inventory in the format of docs/research/sound_analysis_labels_v1_*.txt,
    /// extended with the taxonomy mapping of each label.
    public func reportText(platform: String, taxonomy: SoundTaxonomy = .appleV1) -> String {
        let coverage = taxonomy.coverage(of: labels)
        var lines = [
            "# Apple SoundAnalysis built-in classifier (SNClassifierIdentifier.version1)",
            "# Enumerated with SNClassifySoundRequest.knownClassifications on \(Date.now.formatted(.iso8601.year().month().day()))",
            "# Platform: \(platform)",
            "# count=\(labels.count)",
            "# defaultWindow=\(defaultWindowDuration)s overlap=\(defaultOverlapFactor)",
            "# constraint=\(windowConstraint)",
            "# taxonomy: \(coverage.isExactMatch ? "exact match" : "differs") "
                + "(not in taxonomy: \(coverage.notInTaxonomy.count), not reported: \(coverage.notReportedByClassifier.count))",
        ]
        if !coverage.notInTaxonomy.isEmpty {
            lines.append("# not in taxonomy: " + coverage.notInTaxonomy.map(\.rawValue).joined(separator: " "))
        }
        if !coverage.notReportedByClassifier.isEmpty {
            lines.append("# in taxonomy but not reported: "
                + coverage.notReportedByClassifier.map(\.rawValue).joined(separator: " "))
        }
        lines.append("# columns: label<TAB>kind<TAB>category")
        for label in labels {
            let definition = taxonomy.definition(for: label)
            lines.append("\(label.rawValue)\t\(definition.kind.id)\t\(definition.kind.category.rawValue)")
        }
        return lines.joined(separator: "\n")
    }
}
