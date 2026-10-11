import Foundation
import SemanticAttention

/// The engine generations compared in the reports, each with its own reasoner and queue.
struct EngineSetup {
    var name: String
    var reasoner: FoundationModelRelevanceReasoner
    var configuration: SemanticAttentionEngine.Configuration

    /// --config window6 | window6_1 | window6_2 | window6_3 (default), with for the last two:
    /// --reuse <turns>  --steps | --no-steps  --order oldest  --no-confirm  --no-repetition  --max-wait <s>
    /// and for window6_3: --no-audience  --no-name  --no-cutoff  --no-joined
    static func named(_ name: String?, arguments: [String], option: (String) -> String?) -> EngineSetup? {
        let name = name ?? "window6_3"
        switch name {
        case "window6":
            return EngineSetup(name: "Window 6", reasoner: FoundationModelRelevanceReasoner(style: .window6),
                               configuration: .window6)
        case "window6_1", "optimized":
            return EngineSetup(name: "Window 6.1", reasoner: .window6_1, configuration: .window6_1)
        case "window6_2", "window6_3":
            let isCurrent = name == "window6_3"
            var reuse = FoundationModelRelevanceReasoner.currentReuse
            if let turns = option("--reuse").flatMap({ Int($0) }) { reuse.maximumTurns = max(1, turns) }
            if arguments.contains("--no-restate") { reuse.restatesGoals = false }
            let steps = arguments.contains("--steps") ? true
                : arguments.contains("--no-steps") ? false : FoundationModelRelevanceReasoner.currentAsksKindFirstWhenBusy
            var configuration = isCurrent ? SemanticAttentionEngine.Configuration.standard : .window6_2
            if arguments.contains("--no-audience") { configuration.usesAudienceCues = false }
            if arguments.contains("--no-name") { configuration.alertsWhenCalledByName = false }
            if arguments.contains("--no-cutoff") { configuration.holdsBackCutOffSentences = false }
            if arguments.contains("--no-word") { configuration.takesSpeakersAtTheirWord = false }
            if arguments.contains("--context-always") { configuration.givesContextOnlyToLeaningSentences = false }
            if arguments.contains("--context-leaning") { configuration.givesContextOnlyToLeaningSentences = true }
            let joined = isCurrent && !arguments.contains("--no-joined")
            if option("--order") == "oldest" { configuration.servingOrder = .oldestFirst }
            if arguments.contains("--no-confirm") { configuration.confirmsRelevant = false }
            if arguments.contains("--no-repetition") { configuration.asksAboutRepetition = false }
            if let wait = option("--max-wait").flatMap({ Double($0) }) { configuration.maximumWait = wait }
            var label = isCurrent ? "Window 6.3" : "Window 6.2"
            if isCurrent, !configuration.usesAudienceCues { label += ", no audience cues" }
            if isCurrent, !configuration.alertsWhenCalledByName { label += ", no alert on the name alone" }
            if isCurrent, !configuration.holdsBackCutOffSentences { label += ", cut-off sentences not held back" }
            if isCurrent, !joined { label += ", second look without the sentence before" }
            if !configuration.givesContextOnlyToLeaningSentences { label += ", context given to every sentence" }
            label += reuse.maximumTurns > 1 ? ", session reused up to \(reuse.maximumTurns) while sentences wait" : ", a session per sentence"
            if steps { label += ", kind first when no session is prepared" }
            if !configuration.confirmsRelevant { label += ", no second look" }
            if configuration.servingOrder == .oldestFirst { label += ", oldest first" }
            return EngineSetup(name: label,
                               reasoner: FoundationModelRelevanceReasoner(style: .staged, reuse: reuse, asksKindFirstWhenBusy: steps,
                                                                          readsLeaningSentencesWithContext: joined),
                               configuration: configuration)
        default:
            return nil
        }
    }
}
