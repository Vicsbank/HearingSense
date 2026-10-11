import Foundation

/// The complete confusion counts and the derived rates of one evaluation run (Window 6.1).
///
/// Definitions, fixed here so that every report uses the same ones:
/// - Positive item: expected `relevant`. Negative item: expected `irrelevant` or `repeat`
///   (a repetition must not alert a second time). `ambiguous` items are not scored.
/// - Prediction: positive when the engine *accepted* the utterance (a verified, novel, relevant
///   decision that would be handed to the attention engine). An `uncertain` verdict, which the
///   app keeps in its list without an alert, counts as negative.
/// - precision = TP / (TP + FP); recall = TP / (TP + FN);
///   false-positive rate = FP / (FP + TN); false-negative rate = FN / (FN + TP);
///   balanced accuracy = (recall + TN / (TN + FP)) / 2.
///
/// Window 6 reported "false alerts 11.6 %" as alerts on `irrelevant` items only (5 of 43),
/// leaving the 4 `repeat` items out of that denominator; with them it is 5 of 47. It is a
/// false-positive rate, not 1 − precision (which was 9.1 %, 5 of 55): the two numbers have
/// different denominators and do not contradict each other.
public struct SemanticConfusion: Sendable, Codable {
    public var truePositives = 0
    public var falsePositives = 0
    public var falseNegatives = 0
    public var trueNegatives = 0
    public var ambiguousAlerted = 0
    public var ambiguousUncertain = 0
    public var ambiguousSilent = 0

    /// Correct / total per group of categories.
    public var groups: [String: SemanticMetrics.Rate] = [:]
    public var byCategory: [String: SemanticMetrics.Rate] = [:]
    public var byProfile: [String: [String: Int]] = [:]
    public var stages: [String: Int] = [:]
    public var secondsP50: Double?
    public var secondsP95: Double?
    public var secondsP99: Double?
    public var modelSecondsP50: Double?
    public var modelSecondsP95: Double?
    public var modelSecondsP99: Double?
    public var outputTokensPerModelDecision: Double?
    public var modelDecisions = 0
    public var falsePositiveIDs: [String] = []
    public var falseNegativeIDs: [String] = []

    public var precision: SemanticMetrics.Rate { .init(hits: truePositives, total: truePositives + falsePositives) }
    public var recall: SemanticMetrics.Rate { .init(hits: truePositives, total: truePositives + falseNegatives) }
    public var falsePositiveRate: SemanticMetrics.Rate { .init(hits: falsePositives, total: falsePositives + trueNegatives) }
    public var falseNegativeRate: SemanticMetrics.Rate { .init(hits: falseNegatives, total: falseNegatives + truePositives) }
    public var specificity: SemanticMetrics.Rate { .init(hits: trueNegatives, total: falsePositives + trueNegatives) }
    public var f1: Double? {
        guard let p = precision.value, let r = recall.value, p + r > 0 else { return nil }
        return 2 * p * r / (p + r)
    }

    public var balancedAccuracy: Double? {
        guard let r = recall.value, let s = specificity.value else { return nil }
        return (r + s) / 2
    }

    /// Groups of categories that the brief asks about. An item belongs to every group that
    /// names its category (and its expected label, where the group is about one side only).
    static let groupDefinitions: [(name: String, categories: Set<String>, expected: SemanticDataset.Expected?)] = [
        ("implicit relevance recall", ["implicit", "causal"], .relevant),
        ("explicit relevance recall", ["obvious", "attention"], .relevant),
        ("negation accuracy", ["negation"], nil),
        ("hypothetical accuracy", ["hypothetical"], nil),
        ("personal relevance accuracy", ["third_person"], nil),
        ("past and quotation accuracy", ["past", "sarcasm_quote"], nil),
        ("idiom accuracy", ["idiom"], nil),
        ("recognition-error accuracy", ["asr_error"], nil),
        ("context (several sentences) accuracy", ["multi"], nil),
        ("unrelated talk accuracy", ["unrelated"], nil),
        ("repetition accuracy", ["repeated"], nil),
    ]

    public init(_ outcomes: [SemanticItemOutcome], dataset: SemanticDataset) {
        let byID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.id, $0) })
        func count(_ name: String, _ isCorrect: Bool, in table: inout [String: SemanticMetrics.Rate]) {
            var rate = table[name] ?? .init(hits: 0, total: 0)
            rate.total += 1
            if isCorrect { rate.hits += 1 }
            table[name] = rate
        }
        for item in dataset.items {
            guard let outcome = byID[item.id] else { continue }
            stages[outcome.stage ?? "-", default: 0] += 1
            let isCorrect: Bool
            switch item.expected {
            case .relevant:
                isCorrect = outcome.alerted
                if isCorrect { truePositives += 1 } else {
                    falseNegatives += 1
                    falseNegativeIDs.append(item.id)
                }
                if item.isImportant { count("important-event recall", isCorrect, in: &groups) }
                if item.isUrgent { count("short urgent instruction recall", isCorrect, in: &groups) }
            case .irrelevant, .repeat:
                isCorrect = !outcome.alerted
                if isCorrect { trueNegatives += 1 } else {
                    falsePositives += 1
                    falsePositiveIDs.append(item.id)
                }
            case .ambiguous:
                if outcome.alerted { ambiguousAlerted += 1 } else if outcome.verdict == "uncertain" { ambiguousUncertain += 1 } else {
                    ambiguousSilent += 1
                }
                continue
            }
            count(item.category, isCorrect, in: &byCategory)
            for group in Self.groupDefinitions where group.categories.contains(item.category) {
                if let expected = group.expected, expected != item.expected { continue }
                count(group.name, isCorrect, in: &groups)
            }
            let key = item.expected == .relevant ? (isCorrect ? "tp" : "fn") : (isCorrect ? "tn" : "fp")
            byProfile[item.profile, default: [:]][key, default: 0] += 1
        }
        func quantile(_ values: [Double], _ q: Double) -> Double? {
            let sorted = values.sorted()
            return sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int((Double(sorted.count) * q).rounded(.down)))]
        }
        let seconds = outcomes.map(\.seconds)
        (secondsP50, secondsP95, secondsP99) = (quantile(seconds, 0.5), quantile(seconds, 0.95), quantile(seconds, 0.99))
        let model = outcomes.map(\.modelSeconds).filter { $0 > 0 }
        (modelSecondsP50, modelSecondsP95, modelSecondsP99) = (quantile(model, 0.5), quantile(model, 0.95), quantile(model, 0.99))
        let tokens = outcomes.compactMap(\.outputTokens).filter { $0 > 0 }
        modelDecisions = model.count
        outputTokensPerModelDecision = tokens.isEmpty ? nil : Double(tokens.reduce(0, +)) / Double(tokens.count)
    }

    public var report: String {
        func seconds(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–" }
        var lines = [
            "  confusion            TP \(truePositives)  FP \(falsePositives)  FN \(falseNegatives)  TN \(trueNegatives)"
                + "  (ambiguous, not scored: \(ambiguousAlerted) alerted, \(ambiguousUncertain) uncertain, \(ambiguousSilent) silent)",
            "  precision            \(precision.text)",
            "  recall               \(recall.text)",
            "  F1                   \(f1.map { $0.formatted(.number.precision(.fractionLength(3))) } ?? "–")",
            "  false-positive rate  \(falsePositiveRate.text)",
            "  false-negative rate  \(falseNegativeRate.text)",
            "  balanced accuracy    \(balancedAccuracy.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) + " %" } ?? "–")",
        ]
        for name in ["important-event recall", "short urgent instruction recall"] + Self.groupDefinitions.map(\.name) {
            if let rate = groups[name] { lines.append("  " + name.padding(toLength: 38, withPad: " ", startingAt: 0) + rate.text) }
        }
        lines.append("  by profile           " + byProfile.sorted { $0.key < $1.key }.map { profile, counts in
            "\(profile) TP \(counts["tp"] ?? 0) FP \(counts["fp"] ?? 0) FN \(counts["fn"] ?? 0) TN \(counts["tn"] ?? 0)"
        }.joined(separator: "; "))
        lines.append("  decided at           " + stages.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        lines.append("  seconds per item     p50 \(seconds(secondsP50))  p95 \(seconds(secondsP95))  p99 \(seconds(secondsP99))"
            + "   model only: p50 \(seconds(modelSecondsP50))  p95 \(seconds(modelSecondsP95))  p99 \(seconds(modelSecondsP99))")
        lines.append("  output tokens        \(outputTokensPerModelDecision.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")"
            + " per model decision (\(modelDecisions) model decisions)")
        return lines.joined(separator: "\n")
    }
}
