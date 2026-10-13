import Foundation
import Testing
@testable import SummaryPostprocessing

/// Dump of the statements the postprocessor removes from units the judge found fully supported
/// (and of the unsupported units it keeps), for reading. Synthetic data. Runs only when
/// HS_DUMP_PATH is set: HS_DUMP_PATH=/some/file swift test --filter CorpusDiagnosticsTests
@Suite struct CorpusDiagnosticsTests {
    @Test func dumpDisagreements() throws {
        guard let path = ProcessInfo.processInfo.environment["HS_DUMP_PATH"] else { return }
        let url = try #require(CorpusRegressionTests.corpusURL())
        let conversations = try JSONDecoder().decode([CorpusRegressionTests.Conversation].self, from: Data(contentsOf: url))
        let only = ProcessInfo.processInfo.environment["HS_DUMP_MODEL"]
        let processor = SummaryPostprocessor()
        var out = ""
        for conversation in conversations {
            for summary in conversation.summaries where only == nil || "\(summary.model)/\(summary.config)".contains(only!) {
                let a = summary.units.filter { $0.u.hasPrefix("a") }, k = summary.units.filter { $0.u.hasPrefix("k") }
                let draft = DraftText(title: "", summary: a.map(\.text).joined(separator: "\n"), keyPoints: k.map(\.text))
                let output = processor.process(draft, transcriptLines: conversation.transcript)
                var counts = a.map { SummaryText.sentences(in: $0.text).count }
                counts += k.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1 }
                guard counts.reduce(0, +) == output.reports.count else { continue }
                var position = 0
                for (unit, count) in zip(a + k, counts) {
                    let reports = Array(output.reports[position ..< position + count]); position += count
                    for report in reports where report.verdict == .unsupported || report.verdict == .copied {
                        if unit.unsupported == 0 && unit.claims > 0 {
                            out += "FALSE-DELETE \(conversation.id)/\(summary.model)/\(summary.config)/\(unit.u) [\(report.reason)]\n  S: \(report.text)\n"
                            for line in report.evidenceLines.prefix(3) where conversation.transcript.indices.contains(line) {
                                out += "  E\(line): \(conversation.transcript[line])\n"
                            }
                            if report.evidenceLines.isEmpty { out += "  (no evidence line)\n" }
                        }
                    }
                    if unit.unsupported > 0, reports.allSatisfy({ $0.verdict == .supported }) {
                        out += "MISSED \(conversation.id)/\(summary.model)/\(summary.config)/\(unit.u) judge-note: \(unit.claims)/\(unit.unsupported)\n  S: \(reports.map(\.text).joined(separator: " "))\n"
                    }
                }
            }
        }
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
