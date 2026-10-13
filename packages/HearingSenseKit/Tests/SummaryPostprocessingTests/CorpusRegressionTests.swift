import Foundation
import Testing
@testable import SummaryPostprocessing

/// Regression over `data/summary_regression/en_judged_v1.json`: 44 synthetic English
/// conversations, 264 model summaries whose statements a blinded judge marked supported or not.
///
/// This corpus was read while the module was written (and in the model benchmark before it):
/// the numbers below are a regression check, not a held-out result.
///
/// Each summary becomes one draft: its "a" units are the summary (one paragraph each), its "k"
/// units the key points. A unit counts as removed when any of its statements was removed for what
/// it says (unsupported, or a copy without a restatement); as flagged when a statement was kept
/// but listed as uncertain. Statements dropped as duplicates or filler lose no information and
/// are counted apart. Only ids and counts are printed (synthetic data, but the habit holds).
@Suite struct CorpusRegressionTests {
    struct Conversation: Decodable {
        let id: String
        let transcript: [String]
        let summaries: [Summary]
    }

    struct Summary: Decodable {
        let model: String
        let config: String
        let units: [Unit]
    }

    struct Unit: Decodable {
        let u: String
        let text: String
        let claims: Int
        let unsupported: Int
    }

    struct Tally {
        var legitimate = 0
        var legitimateRemoved = 0
        var legitimateDroppedAsRepeat = 0
        var legitimateFlagged = 0
        var unsupported = 0
        var unsupportedRemoved = 0
        var unsupportedFlagged = 0
        var unsupportedDroppedAsRepeat = 0

        mutating func add(_ other: Tally) {
            legitimate += other.legitimate
            legitimateRemoved += other.legitimateRemoved
            legitimateDroppedAsRepeat += other.legitimateDroppedAsRepeat
            legitimateFlagged += other.legitimateFlagged
            unsupported += other.unsupported
            unsupportedRemoved += other.unsupportedRemoved
            unsupportedFlagged += other.unsupportedFlagged
            unsupportedDroppedAsRepeat += other.unsupportedDroppedAsRepeat
        }

        var legitimateDeletion: Double { legitimate == 0 ? 0 : Double(legitimateRemoved) / Double(legitimate) }
        var unsupportedCaught: Double { unsupported == 0 ? 0 : Double(unsupportedRemoved + unsupportedFlagged) / Double(unsupported) }

        func line(_ name: String) -> String {
            func percent(_ part: Int, _ whole: Int) -> String {
                whole == 0 ? "-" : String(format: "%.1f%%", 100 * Double(part) / Double(whole))
            }
            return "\(name): supported units \(legitimate), removed \(percent(legitimateRemoved, legitimate)), "
                + "dropped as repeat/filler \(percent(legitimateDroppedAsRepeat, legitimate)), flagged \(percent(legitimateFlagged, legitimate)) | "
                + "units with unsupported claims \(unsupported), removed \(percent(unsupportedRemoved, unsupported)), "
                + "flagged \(percent(unsupportedFlagged, unsupported)), caught \(percent(unsupportedRemoved + unsupportedFlagged, unsupported)), "
                + "dropped as repeat/filler \(percent(unsupportedDroppedAsRepeat, unsupported))"
        }
    }

    static func corpusURL() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = directory.appendingPathComponent("data/summary_regression/en_judged_v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test func judgedSummariesKeepTheirSupportedStatements() throws {
        let url = try #require(Self.corpusURL(), "data/summary_regression/en_judged_v1.json not found above \(#filePath)")
        let conversations = try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: url))
        #expect(conversations.count == 44)

        let postprocessor = SummaryPostprocessor()
        var tallies: [String: Tally] = [:]
        var order: [String] = []
        var removalReasons: [String: Int] = [:]
        var removedIds: [String] = []
        var summaries = 0

        for conversation in conversations {
            for summary in conversation.summaries {
                summaries += 1
                let summaryUnits = summary.units.filter { $0.u.hasPrefix("a") }
                let pointUnits = summary.units.filter { $0.u.hasPrefix("k") }
                let draft = DraftText(title: "", summary: summaryUnits.map(\.text).joined(separator: "\n"), keyPoints: pointUnits.map(\.text))
                let output = postprocessor.process(draft, transcriptLines: conversation.transcript)

                // Statements per unit, in the order the postprocessor reports them.
                var counts = summaryUnits.map { SummaryText.sentences(in: $0.text).count }
                counts += pointUnits.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1 }
                let units = summaryUnits + pointUnits
                guard counts.reduce(0, +) == output.reports.count else {
                    Issue.record("statement count mismatch in \(conversation.id) \(summary.model)/\(summary.config)")
                    continue
                }
                let key = "\(summary.model)/\(summary.config)"
                if tallies[key] == nil { order.append(key) }
                var tally = tallies[key] ?? Tally()
                var position = 0
                for (unit, count) in zip(units, counts) {
                    let reports = Array(output.reports[position ..< position + count])
                    position += count
                    guard !reports.isEmpty else { continue }
                    let removed = reports.contains { $0.verdict == .unsupported || $0.verdict == .copied }
                    let repeatOnly = !removed && reports.allSatisfy { $0.verdict == .duplicate || $0.verdict == .filler }
                    let flagged = !removed && reports.contains { $0.verdict == .uncertain }
                    if unit.unsupported == 0 {
                        guard unit.claims > 0 else { continue }
                        tally.legitimate += 1
                        if removed {
                            tally.legitimateRemoved += 1
                            removedIds.append("\(conversation.id)/\(key)/\(unit.u)")
                            for report in reports where report.verdict == .unsupported || report.verdict == .copied {
                                removalReasons[report.reason, default: 0] += 1
                            }
                        }
                        if repeatOnly { tally.legitimateDroppedAsRepeat += 1 }
                        if flagged { tally.legitimateFlagged += 1 }
                    } else {
                        tally.unsupported += 1
                        if removed { tally.unsupportedRemoved += 1 }
                        if flagged { tally.unsupportedFlagged += 1 }
                        if repeatOnly { tally.unsupportedDroppedAsRepeat += 1 }
                    }
                }
                tallies[key] = tally
            }
        }

        var total = Tally()
        print("W9 corpus regression (seen data, not held out): \(summaries) summaries")
        for key in order.sorted() {
            let tally = tallies[key] ?? Tally()
            print("  " + tally.line(key))
            total.add(tally)
        }
        print("  " + total.line("all"))
        print("  removal reasons on supported units: "
            + removalReasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        print("  supported units removed: " + removedIds.joined(separator: " "))

        #expect(summaries == 264)
        // Conservative floors only (see the design note): few supported statements lost, and at
        // least a fifth of the unsupported ones removed or flagged.
        #expect(total.legitimateDeletion <= 0.08)
        #expect(total.unsupportedCaught >= 0.2)
    }
}
