import Foundation
import SemanticAttention

/// The engine generations compared in the reports, each with its own reasoner and queue.
struct EngineSetup {
    var name: String
    var reasoner: FoundationModelRelevanceReasoner
    var configuration: SemanticAttentionEngine.Configuration

    /// --config window6 | window6_1 | window6_2 (default), with for window6_2:
    /// --reuse <turns>  --steps | --no-steps  --order oldest  --no-confirm  --no-repetition  --max-wait <s>
    static func named(_ name: String?, arguments: [String], option: (String) -> String?) -> EngineSetup? {
        switch name ?? "window6_2" {
        case "window6":
            return EngineSetup(name: "Window 6", reasoner: FoundationModelRelevanceReasoner(style: .window6),
                               configuration: .window6)
        case "window6_1", "optimized":
            return EngineSetup(name: "Window 6.1", reasoner: .window6_1, configuration: .window6_1)
        case "window6_2":
            var reuse = FoundationModelRelevanceReasoner.currentReuse
            if let turns = option("--reuse").flatMap({ Int($0) }) { reuse.maximumTurns = max(1, turns) }
            if arguments.contains("--no-restate") { reuse.restatesGoals = false }
            let steps = arguments.contains("--steps") ? true
                : arguments.contains("--no-steps") ? false : FoundationModelRelevanceReasoner.currentAsksInSteps
            var configuration = SemanticAttentionEngine.Configuration.standard
            if option("--order") == "oldest" { configuration.servingOrder = .oldestFirst }
            if arguments.contains("--no-confirm") { configuration.confirmsRelevant = false }
            if arguments.contains("--no-repetition") { configuration.asksAboutRepetition = false }
            if let wait = option("--max-wait").flatMap({ Double($0) }) { configuration.maximumWait = wait }
            var label = "Window 6.2"
            label += reuse.maximumTurns > 1 ? ", session reused up to \(reuse.maximumTurns) while sentences wait" : ", a session per sentence"
            if steps { label += ", kind first" }
            if !configuration.confirmsRelevant { label += ", no second look" }
            if configuration.servingOrder == .oldestFirst { label += ", oldest first" }
            return EngineSetup(name: label,
                               reasoner: FoundationModelRelevanceReasoner(style: .staged, reuse: reuse, asksInSteps: steps),
                               configuration: configuration)
        default:
            return nil
        }
    }
}
