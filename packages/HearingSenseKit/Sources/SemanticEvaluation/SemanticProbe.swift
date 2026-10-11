import Foundation
import FoundationModels
import SemanticAttention

/// Research harness (Window 6.2): asks the language model directly, outside the engine, so one
/// variable at a time can be changed — the instructions, the form of the answer, how long a
/// session is kept, the order of the sentences — and the raw answer of every request is kept
/// together with its place in the session and its token counts.
///
/// Nothing here is used by the app.
public enum SemanticProbe {
    /// The form of the first answer.
    public enum Form: String, Sendable, CaseIterable {
        /// kind, goal, verdict (the Window 6.1 answer).
        case kindGoalVerdict
        /// kind, goal.
        case kindGoal
        /// goal, kind.
        case goalKind
        /// topic, kind: what the sentence is about (a goal or one of several everyday subjects).
        case aboutKind
        /// kind, goal with the kinds renamed to one short word each and a kind for being spoken to.
        case kindGoal2
        /// who, kind, goal.
        case whoKindGoal
        /// kind, goal, tell (true or false): a cheaper last word than the verdict.
        case kindGoalTell
        case kind2GoalTell
        /// The renamed kinds with the Window 6.1 verdict.
        case kind2GoalVerdict
        /// The Window 6.1 answer in two steps: the kind alone, and the goal and the verdict in a
        /// second request to the same session only when the kind is one that can alert.
        case lazy
    }

    public struct Variant: Sendable {
        public var name: String
        public var instructions: String
        public var form: Form
        public var limit: Int

        public init(name: String, instructions: String, form: Form, limit: Int = 32) {
            self.name = name
            self.instructions = instructions
            self.form = form
            self.limit = limit
        }
    }

    public struct Answer: Codable, Sendable {
        public var id: String
        public var kind: String
        public var goal: Int
        public var verdict: String
        /// 1 for the first request of a session.
        public var turn: Int
        public var seconds: Double
        public var inputTokens: Int?
        public var cachedTokens: Int?
        public var outputTokens: Int?
        public var failure: String?
        /// The check on a positive answer, when one was run.
        public var check: String?
        public var checkSeconds: Double?

        /// What the engine's verifier would let through as an alert.
        public func isPositive(goalCount: Int) -> Bool {
            goal >= 1 && goal <= goalCount && ["relevant", "urgent"].contains(verdict)
                && ["change", "request", "warning", "address"].contains(kind)
        }
    }

    public struct Options: Sendable {
        /// Requests one session answers before it is replaced.
        public var sessionTurns = 1
        /// Repeat the answer's form and the goals in every request of a kept session.
        /// `omitsSchema`: never put the form in the request (the instructions describe it).
        public var omitsSchema = false
        public var repeatsSchema = false
        public var repeatsGoals = false
        /// Nil: file order. Otherwise the items of each profile are shuffled with this seed.
        public var seed: UInt64?
        /// Before every item, in the item's own new session, ask about this many sentences of
        /// the same profile that should stay silent (chosen with `seed`): what a session looks
        /// like that is kept while everyday talk goes by.
        public var silentBefore = 0

        public init() {}
    }

    /// The items in the order they are asked: profile by profile, shuffled within a profile when
    /// a seed is given.
    public static func ordered(_ dataset: SemanticDataset, seed: UInt64?) -> [SemanticDataset.Item] {
        guard let seed else { return dataset.items }
        var generator = SplitMix(state: seed)
        var profiles: [String] = []
        for item in dataset.items where !profiles.contains(item.profile) { profiles.append(item.profile) }
        return profiles.flatMap { profile in
            dataset.items.filter { $0.profile == profile }.shuffled(using: &generator)
        }
    }

    public static func run(_ dataset: SemanticDataset, variant: Variant, options: Options,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Answer]
    {
        var answers: [Answer] = []
        var session: LanguageModelSession?
        var sessionProfile = ""
        var turn = 0
        let items = ordered(dataset, seed: options.silentBefore > 0 ? nil : options.seed)
        var generator = SplitMix(state: options.seed ?? 1)
        for (index, item) in items.enumerated() {
            let goals = SemanticDataset.goals(for: item.profile).map(\.goal)
            if options.silentBefore > 0 {
                // A session of its own that has first answered for a few silent sentences.
                let silent = dataset.items.filter {
                    $0.profile == item.profile && $0.expected == .irrelevant && $0.id != item.id && $0.context.isEmpty
                }.shuffled(using: &generator).prefix(options.silentBefore)
                let warmed = LanguageModelSession(model: SystemLanguageModel.default, instructions: variant.instructions)
                var scratch = Answer(id: "", kind: "", goal: 0, verdict: "", turn: 0, seconds: 0)
                for (place, other) in silent.enumerated() {
                    try? await ask(warmed, prompt(other.text, context: [], goals: place == 0 || options.repeatsGoals ? goals : []),
                                   variant: variant, includesSchema: !options.omitsSchema && place == 0,
                                   goalCount: goals.count, into: &scratch)
                }
                session = warmed
                sessionProfile = item.profile
                turn = silent.count
            } else if session == nil || sessionProfile != item.profile || turn >= options.sessionTurns {
                session = LanguageModelSession(model: SystemLanguageModel.default, instructions: variant.instructions)
                sessionProfile = item.profile
                turn = 0
            }
            turn += 1
            let isFirst = turn == 1
            let prompt = prompt(item.text, context: item.context, goals: isFirst || options.repeatsGoals ? goals : [])
            let started = Date()
            var answer = Answer(id: item.id, kind: "", goal: 0, verdict: "", turn: turn, seconds: 0)
            do {
                guard let session else { continue }
                try await ask(session, prompt, variant: variant, includesSchema: !options.omitsSchema && (isFirst || options.repeatsSchema),
                              goalCount: goals.count, into: &answer)
            } catch {
                answer.failure = String(describing: type(of: error))
                session = nil
            }
            answer.seconds = Date().timeIntervalSince(started)
            answers.append(answer)
            progress?(index + 1, items.count)
        }
        return answers
    }

    static func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "'") + "\"" }

    static func prompt(_ text: String, context: [String], goals: [AttentionGoal]) -> String {
        var lines: [String] = []
        if !goals.isEmpty {
            lines.append("The listener's goals:")
            lines += goals.enumerated().map { "\($0.offset + 1). \($0.element.text)" }
        }
        if !context.isEmpty {
            lines.append("Said just before, for context only: " + context.map(quoted).joined(separator: " "))
        }
        lines.append("Utterance: " + quoted(text))
        return lines.joined(separator: "\n")
    }

    static func ask(_ session: LanguageModelSession, _ prompt: String, variant: Variant, includesSchema: Bool,
                    goalCount: Int, into answer: inout Answer) async throws
    {
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: variant.limit)
        @available(iOS 27.0, macOS 27.0, *)
        func record(_ usage: LanguageModelSession.Usage) {
            answer.inputTokens = usage.input.totalTokenCount
            answer.cachedTokens = usage.input.cachedTokenCount
            answer.outputTokens = usage.output.totalTokenCount
        }
        switch variant.form {
        case .kindGoalVerdict:
            let response = try await session.respond(to: prompt, generating: ProbeKindGoalVerdict.self,
                                                     includeSchemaInPrompt: includesSchema, options: options)
            (answer.kind, answer.goal, answer.verdict) = (response.content.kind.rawValue, response.content.goal,
                                                          response.content.verdict.rawValue)
            if #available(iOS 27.0, macOS 27.0, *) { record(response.usage) }
        case .kindGoal:
            let response = try await session.respond(to: prompt, generating: ProbeKindGoal.self,
                                                     includeSchemaInPrompt: includesSchema, options: options)
            (answer.kind, answer.goal) = (response.content.kind.rawValue, response.content.goal)
            answer.verdict = response.content.goal > 0 ? "relevant" : "irrelevant"
            if #available(iOS 27.0, macOS 27.0, *) { record(response.usage) }
        case .goalKind:
            let response = try await session.respond(to: prompt, generating: ProbeGoalKind.self,
                                                     includeSchemaInPrompt: includesSchema, options: options)
            (answer.kind, answer.goal) = (response.content.kind.rawValue, response.content.goal)
            answer.verdict = response.content.goal > 0 ? "relevant" : "irrelevant"
            if #available(iOS 27.0, macOS 27.0, *) { record(response.usage) }
        case .kindGoal2:
            let response = try await session.respond(to: prompt, generating: ProbeKindGoal2.self,
                                                     includeSchemaInPrompt: includesSchema, options: options)
            (answer.kind, answer.goal) = (response.content.kind.rawValue, response.content.goal)
            answer.verdict = response.content.goal > 0 ? "relevant" : "irrelevant"
            if #available(iOS 27.0, macOS 27.0, *) { record(response.usage) }
        case .kindGoalTell:
            let response = try await session.respond(to: prompt, generating: ProbeKindGoalTell.self,
                                                     includeSchemaInPrompt: includesSchema, options: options)
            (answer.kind, answer.goal) = (response.content.kind.rawValue, response.content.goal)
            answer.verdict = response.content.tell ? "relevant" : "irrelevant"
            if #available(iOS 27.0, macOS 27.0, *) { record(response.usage) }
        case .kind2GoalTell:
            let response = try await session.respond(to: prompt, generating: ProbeKind2GoalTell.self,
                                                     includeSchemaInPrompt: includesSchema, options: options)
            (answer.kind, answer.goal) = (response.content.kind.rawValue, response.content.goal)
            answer.verdict = response.content.tell ? "relevant" : "irrelevant"
            if #available(iOS 27.0, macOS 27.0, *) { record(response.usage) }
        case .kind2GoalVerdict:
            let response = try await session.respond(to: prompt, generating: ProbeKind2GoalVerdict.self,
                                                     includeSchemaInPrompt: includesSchema, options: options)
            (answer.kind, answer.goal, answer.verdict) = (response.content.kind.rawValue, response.content.goal,
                                                          response.content.verdict.rawValue)
            if #available(iOS 27.0, macOS 27.0, *) { record(response.usage) }
        case .lazy:
            let first = try await session.respond(to: prompt, generating: ProbeKindOnly.self,
                                                  includeSchemaInPrompt: includesSchema, options: options)
            answer.kind = first.content.kind.rawValue
            (answer.goal, answer.verdict) = (0, "irrelevant")
            if #available(iOS 27.0, macOS 27.0, *) { record(first.usage) }
            if ["change", "request", "warning"].contains(answer.kind) {
                let second = try await session.respond(to: "Now the goal and the verdict for that sentence.",
                                                       generating: ProbeGoalVerdict.self,
                                                       includeSchemaInPrompt: includesSchema, options: options)
                (answer.goal, answer.verdict) = (second.content.goal, second.content.verdict.rawValue)
                if #available(iOS 27.0, macOS 27.0, *) {
                    answer.outputTokens = (answer.outputTokens ?? 0) + second.usage.output.totalTokenCount
                }
                answer.check = "two-requests"
            }
        case .whoKindGoal:
            let response = try await session.respond(to: prompt, generating: ProbeWhoKindGoal.self,
                                                     includeSchemaInPrompt: includesSchema, options: options)
            (answer.kind, answer.goal) = (response.content.kind.rawValue, response.content.goal)
            if response.content.who == .others { answer.kind = "others" }
            answer.verdict = response.content.goal > 0 ? "relevant" : "irrelevant"
            if #available(iOS 27.0, macOS 27.0, *) { record(response.usage) }
        case .aboutKind:
            let response = try await session.respond(to: prompt, generating: ProbeAboutKind.self,
                                                     includeSchemaInPrompt: includesSchema, options: options)
            (answer.kind, answer.goal) = (response.content.kind.rawValue, response.content.about.goal)
            answer.verdict = answer.goal > 0 ? "relevant" : "irrelevant"
            if answer.goal == 0 { answer.check = response.content.about.rawValue }
            if #available(iOS 27.0, macOS 27.0, *) { record(response.usage) }
        }
    }

    // MARK: - Checks on a positive answer

    /// A second request about a sentence that the first answer called relevant.
    public struct Check: Sendable {
        public var name: String
        public var instructions: String
        /// Builds the request from the sentence, its context, the goals and the number of the
        /// goal it was matched to.
        public var prompt: @Sendable (_ text: String, _ context: [String], _ goals: [String], _ goal: Int) -> String
        /// Also check answers of kind warning.
        public var checksWarnings = false
        /// With these instructions the check is also told which earlier alerts the sentence
        /// may repeat (see `SemanticRepetition`), when there are any.
        public var instructionsWithEarlier: String?
        /// Answers that keep the alert.
        public var keeps: Set<String>
        public var form: CheckForm

        public init(name: String, instructions: String, form: CheckForm, keeps: Set<String>,
                    checksWarnings: Bool = false, prompt: @escaping @Sendable (String, [String], [String], Int) -> String)
        {
            self.name = name
            self.instructions = instructions
            self.form = form
            self.keeps = keeps
            self.checksWarnings = checksWarnings
            self.prompt = prompt
        }
    }

    public enum CheckForm: String, Sendable {
        /// hereAndNow, someoneElse, past, story, wish, nothingChanges (Window 6.1).
        case about
        /// One of four ways a sentence can stand to a goal.
        case link
        /// yes or no.
        case yesNo
        /// forListener, someoneElse, past, story, wish, nothingChanges, offTopic.
        case role
        /// listener or someoneElse.
        case who
        /// The number of the goal the sentence is about, 0 for none ("0" or "goal").
        case topic
    }

    /// Runs a check on every positive answer and records what it said.
    public static func check(_ answers: [Answer], dataset: SemanticDataset, check: Check,
                             progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Answer]
    {
        var answers = answers
        let items = Dictionary(uniqueKeysWithValues: dataset.items.map { ($0.id, $0) })
        let positives = answers.indices.filter { index in
            guard let item = items[answers[index].id] else { return false }
            return answers[index].isPositive(goalCount: SemanticDataset.goals(for: item.profile).count)
        }
        var alerted: [String: [String]] = [:]
        for (done, index) in positives.enumerated() {
            guard let item = items[answers[index].id] else { continue }
            let goals = SemanticDataset.goals(for: item.profile)
            let earlier = check.instructionsWithEarlier == nil ? []
                : SemanticRepetition.candidates(for: item.text, among: alerted[item.profile] ?? [])
            alerted[item.profile, default: []].append(item.text)
            let session = LanguageModelSession(model: SystemLanguageModel.default,
                                               instructions: earlier.isEmpty ? check.instructions
                                                   : check.instructionsWithEarlier ?? check.instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16)
            var prompt = check.prompt(item.text, item.context, goals.map(\.goal.text), answers[index].goal)
            if !earlier.isEmpty {
                prompt = "Already said a moment ago: " + earlier.map(quoted).joined(separator: " ") + "\n" + prompt
            }
            let started = Date()
            do {
                switch check.form {
                case .about:
                    let about = try await session.respond(to: prompt, generating: ProbeAbout.self, options: options)
                        .content.about
                    // Without earlier statements there is nothing it could repeat.
                    answers[index].check = about == .saidBefore && earlier.isEmpty ? "hereAndNow" : about.rawValue
                    if !earlier.isEmpty { answers[index].check? += "+earlier" }
                case .link:
                    answers[index].check = try await session.respond(to: prompt, generating: ProbeLink.self, options: options)
                        .content.link.rawValue
                case .role:
                    answers[index].check = try await session.respond(to: prompt, generating: ProbeRole.self, options: options)
                        .content.what.rawValue
                case .topic:
                    let goal = try await session.respond(to: prompt, generating: ProbeTopicAnswer.self, options: options).content.goal
                    answers[index].check = goal == 0 ? "none" : goal == answers[index].goal ? "same" : "another"
                case .who:
                    answers[index].check = try await session.respond(to: prompt, generating: ProbeWhoAnswer.self, options: options)
                        .content.who.rawValue
                case .yesNo:
                    answers[index].check = try await session.respond(to: prompt, generating: ProbeYesNo.self, options: options)
                        .content.answer.rawValue
                }
            } catch {
                answers[index].check = "failed"
            }
            answers[index].checkSeconds = Date().timeIntervalSince(started)
            progress?(done + 1, positives.count)
        }
        return answers
    }

    // MARK: - Scoring

    public struct Score: Codable, Sendable {
        public var truePositives = 0, falsePositives = 0, falseNegatives = 0, trueNegatives = 0
        public var ambiguousAlerted = 0, ambiguousTotal = 0, failures = 0
        public var falsePositiveIDs: [String] = []
        public var falseNegativeIDs: [String] = []
        /// Alerts and requests by the request's place in its session.
        public var alertsByTurn: [Int: Int] = [:]
        public var falseAlertsByTurn: [Int: Int] = [:]
        public var negativesByTurn: [Int: Int] = [:]
        public var requestsByTurn: [Int: Int] = [:]
        public var meanSeconds = 0.0
        public var meanOutputTokens = 0.0

        public var precision: Double { Double(truePositives) / Double(max(1, truePositives + falsePositives)) }
        public var recall: Double { Double(truePositives) / Double(max(1, truePositives + falseNegatives)) }

        public var line: String {
            func percent(_ value: Double) -> String { (value * 100).formatted(.number.precision(.fractionLength(1))) }
            return "TP \(truePositives) FP \(falsePositives) FN \(falseNegatives) TN \(trueNegatives)  P \(percent(precision)) "
                + "R \(percent(recall))  ambiguous alerted \(ambiguousAlerted)/\(ambiguousTotal)  failed \(failures)  "
                + "mean \(meanSeconds.formatted(.number.precision(.fractionLength(2)))) s, "
                + "\(meanOutputTokens.formatted(.number.precision(.fractionLength(1)))) tokens out"
        }
    }

    /// Scores raw answers. Repetitions are left out: recognising them is the engine's work, not
    /// the model's. With `keeps`, an alert also needs a check answer from that set.
    public static func score(_ answers: [Answer], dataset: SemanticDataset, keeps: Set<String>? = nil,
                             checksWarnings: Bool = false) -> Score
    {
        var score = Score()
        let items = Dictionary(uniqueKeysWithValues: dataset.items.map { ($0.id, $0) })
        var seconds: [Double] = [], tokens: [Double] = []
        for answer in answers {
            guard let item = items[answer.id] else { continue }
            if answer.failure != nil { score.failures += 1 }
            seconds.append(answer.seconds)
            if let count = answer.outputTokens { tokens.append(Double(count)) }
            var alerted = answer.isPositive(goalCount: SemanticDataset.goals(for: item.profile).count)
            if alerted, let keeps, checksWarnings || answer.kind != "warning", let check = answer.check {
                alerted = keeps.contains(check)
            }
            score.requestsByTurn[answer.turn, default: 0] += 1
            switch item.expected {
            case .relevant:
                if alerted { score.truePositives += 1 } else {
                    score.falseNegatives += 1
                    score.falseNegativeIDs.append(item.id)
                }
            case .irrelevant:
                score.negativesByTurn[answer.turn, default: 0] += 1
                if alerted {
                    score.falsePositives += 1
                    score.falsePositiveIDs.append(item.id)
                    score.falseAlertsByTurn[answer.turn, default: 0] += 1
                } else {
                    score.trueNegatives += 1
                }
            case .ambiguous:
                score.ambiguousTotal += 1
                if alerted { score.ambiguousAlerted += 1 }
            case .repeat:
                continue
            }
            if alerted { score.alertsByTurn[answer.turn, default: 0] += 1 }
        }
        score.meanSeconds = seconds.isEmpty ? 0 : seconds.reduce(0, +) / Double(seconds.count)
        score.meanOutputTokens = tokens.isEmpty ? 0 : tokens.reduce(0, +) / Double(tokens.count)
        return score
    }
}

/// A small seeded generator, so a shuffled order can be repeated.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Generable
enum ProbeKind: String {
    case others, past, reported, hypothetical, noChange, warning, request, change, other
}

@Generable
enum ProbeVerdict: String {
    case irrelevant, uncertain, relevant, urgent
}

@Generable(description: "Whether one overheard sentence matters for one of the listener's goals")
struct ProbeKindGoalVerdict {
    var kind: ProbeKind
    @Guide(description: "Number of the one goal this matters for, 0 for none", .range(0 ... 6))
    var goal: Int
    var verdict: ProbeVerdict
}

@Generable(description: "Whether one overheard sentence matters for one of the listener's goals")
struct ProbeKindGoal {
    var kind: ProbeKind
    @Guide(description: "Number of the one goal this matters for, 0 for none", .range(0 ... 6))
    var goal: Int
}

@Generable(description: "Whether one overheard sentence matters for one of the listener's goals")
struct ProbeGoalKind {
    @Guide(description: "Number of the one goal this matters for, 0 for none", .range(0 ... 6))
    var goal: Int
    var kind: ProbeKind
}

@Generable
enum ProbeTopic: String {
    case otherPeople, smallTalk, nothing, goal1, goal2, goal3, goal4, goal5, goal6

    var goal: Int {
        switch self {
        case .goal1: 1
        case .goal2: 2
        case .goal3: 3
        case .goal4: 4
        case .goal5: 5
        case .goal6: 6
        case .otherPeople, .smallTalk, .nothing: 0
        }
    }
}

@Generable(description: "What one overheard sentence is about and what kind of sentence it is")
struct ProbeAboutKind {
    var about: ProbeTopic
    var kind: ProbeKind2
}

@Generable
enum ProbeAboutValue: String {
    case hereAndNow, someoneElse, past, story, wish, nothingChanges, saidBefore
}

@Generable
struct ProbeAbout {
    var about: ProbeAboutValue
}

@Generable
enum ProbeLinkValue: String {
    case direct, consequence, sameWordsOnly, unrelated
}

@Generable
struct ProbeLink {
    var link: ProbeLinkValue
}

@Generable
enum ProbeYesNoValue: String {
    case yes, no
}

@Generable
struct ProbeYesNo {
    var answer: ProbeYesNoValue
}

@Generable
enum ProbeKind2: String {
    case others, past, story, wish, same, warning, address, change, other
}

@Generable
enum ProbeWho: String {
    case listener, others
}

@Generable(description: "Whether one overheard sentence matters for one of the listener's goals")
struct ProbeKindGoal2 {
    var kind: ProbeKind2
    @Guide(description: "Number of the one goal this matters for, 0 for none", .range(0 ... 6))
    var goal: Int
}

@Generable(description: "Whether one overheard sentence matters for one of the listener's goals")
struct ProbeWhoKindGoal {
    var who: ProbeWho
    var kind: ProbeKind2
    @Guide(description: "Number of the one goal this matters for, 0 for none", .range(0 ... 6))
    var goal: Int
}

@Generable
enum ProbeRoleValue: String {
    case forListener, someoneElse, past, story, wish, nothingChanges, offTopic
}

@Generable
struct ProbeRole {
    var what: ProbeRoleValue
}

@Generable(description: "Whether one overheard sentence matters for one of the listener's goals")
struct ProbeKindGoalTell {
    var kind: ProbeKind
    @Guide(description: "Number of the one goal this matters for, 0 for none", .range(0 ... 6))
    var goal: Int
    @Guide(description: "true only if the listener should be told about this sentence now")
    var tell: Bool
}

@Generable(description: "Whether one overheard sentence matters for one of the listener's goals")
struct ProbeKind2GoalTell {
    var kind: ProbeKind2
    @Guide(description: "Number of the one goal this matters for, 0 for none", .range(0 ... 6))
    var goal: Int
    @Guide(description: "true only if the listener should be told about this sentence now")
    var tell: Bool
}

@Generable(description: "Whether one overheard sentence matters for one of the listener's goals")
struct ProbeKind2GoalVerdict {
    var kind: ProbeKind2
    @Guide(description: "Number of the one goal this matters for, 0 for none", .range(0 ... 6))
    var goal: Int
    var verdict: ProbeVerdict
}

@Generable
struct ProbeWhoAnswer {
    var who: ProbeWho
}

@Generable(description: "What kind of sentence one overheard sentence is")
struct ProbeKindOnly {
    var kind: ProbeKind
}

@Generable(description: "Whether the sentence matters for one of the listener's goals")
struct ProbeGoalVerdict {
    @Guide(description: "Number of the one goal this matters for, 0 for none", .range(0 ... 6))
    var goal: Int
    var verdict: ProbeVerdict
}

@Generable
struct ProbeTopicAnswer {
    @Guide(description: "Number of the goal the sentence is about, 0 for none", .range(0 ... 6))
    var goal: Int
}
