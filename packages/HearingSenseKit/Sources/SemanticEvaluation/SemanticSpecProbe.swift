import Foundation
import FoundationModels
import SemanticAttention

/// Research harness (Window 6.3): one request per sentence, described by a small JSON file, so
/// that the instructions, the request and the form of the answer can be changed without
/// building anything. The raw answer of every request is kept with its time and token counts;
/// scoring is done outside (`tools/w63_score.py`).
///
/// Nothing here is used by the app.
public enum SemanticSpecProbe {
    public struct Spec: Codable, Sendable {
        public struct Field: Codable, Sendable {
            public var name: String
            /// An enumerated answer.
            public var values: [String]?
            /// A whole number between the two.
            public var range: [Int]?
            /// "bool" or "string" when neither of the above is given.
            public var type: String?
        }

        public var name: String
        public var instructions: String
        /// The request. `{goals}`: the numbered goals. `{about}`: what the listener wrote about
        /// themselves. `{context}`: the sentences said just before, quoted. `{sentence}`: the
        /// sentence, quoted. `{earlier}`: earlier alerts this one may repeat, quoted.
        /// `{first.<field>}`: a field of an earlier answer for the same sentence (`--from`).
        /// `{goal_text}`: the text of the goal that answer named. A line that begins with "?" is
        /// left out when one of its placeholders is empty.
        public var prompt: String
        /// Nil or empty: the answer is plain text.
        public var fields: [Field]?
        public var limit: Int?
        public var schemaInPrompt: Bool?
        /// The answer is the first field's value on its own (one enumerated string), not an
        /// object with fields: fewer tokens to write.
        public var bare: Bool?
        /// Text that does not change between sentences, read ahead of the request when the run
        /// is asked to prepare sessions (`{goals}` and `{about}` only).
        public var prefix: String?
    }

    public struct Answer: Codable, Sendable {
        public var id: String
        public var fields: [String: String]
        public var text: String?
        public var seconds: Double
        public var turn: Int
        public var inputTokens: Int?
        public var cachedTokens: Int?
        public var outputTokens: Int?
        public var failure: String?
    }

    public struct Options: Sendable {
        /// Requests one session answers before it is replaced.
        public var sessionTurns = 1
        /// Prepare each new session this long before it is asked; nil: not prepared.
        public var lead: TimeInterval?
        /// Earlier answers for the same sentences, by identifier.
        public var first: [String: [String: String]] = [:]
        public init() {}
    }

    static func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "'") + "\"" }

    static func fill(_ template: String, values: [String: String]) -> String {
        var lines: [String] = []
        for var line in template.components(separatedBy: "\n") {
            let optional = line.hasPrefix("?")
            if optional { line.removeFirst() }
            var missing = false
            for (key, value) in values where line.contains("{\(key)}") {
                if value.isEmpty { missing = true }
                line = line.replacingOccurrences(of: "{\(key)}", with: value)
            }
            if optional, missing { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func schema(for spec: Spec) throws -> GenerationSchema? {
        guard let fields = spec.fields, !fields.isEmpty else { return nil }
        if spec.bare == true, let values = fields[0].values {
            return try GenerationSchema(root: DynamicGenerationSchema(name: "Answer", anyOf: values), dependencies: [])
        }
        var dependencies: [DynamicGenerationSchema] = []
        var properties: [DynamicGenerationSchema.Property] = []
        for field in fields {
            if let values = field.values {
                let name = field.name.prefix(1).uppercased() + field.name.dropFirst()
                let choice = DynamicGenerationSchema(name: name, anyOf: values)
                dependencies.append(choice)
                properties.append(.init(name: field.name, schema: DynamicGenerationSchema(referenceTo: name)))
            } else if let range = field.range, range.count == 2 {
                properties.append(.init(name: field.name,
                                        schema: DynamicGenerationSchema(type: Int.self, guides: [.range(range[0] ... range[1])])))
            } else if field.type == "bool" {
                properties.append(.init(name: field.name, schema: DynamicGenerationSchema(type: Bool.self)))
            } else {
                properties.append(.init(name: field.name, schema: DynamicGenerationSchema(type: String.self)))
            }
        }
        let root = DynamicGenerationSchema(name: "Answer", properties: properties)
        return try GenerationSchema(root: root, dependencies: dependencies)
    }

    static func text(of content: GeneratedContent) -> String {
        if let text = try? content.value(String.self) { return text }
        if let number = try? content.value(Int.self) { return String(number) }
        if let flag = try? content.value(Bool.self) { return String(flag) }
        return content.jsonString
    }

    public static func run(_ dataset: SemanticDataset, spec: Spec, options: Options,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [Answer]
    {
        let schema = try schema(for: spec)
        var answers: [Answer] = []
        var session: LanguageModelSession?
        var sessionProfile = ""
        var turn = 0
        var asked: [String: [String]] = [:]
        let generation = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: spec.limit ?? 48)
        for (index, item) in dataset.items.enumerated() {
            let goals = SemanticDataset.goals(for: item.profile).map(\.goal)
            let first = options.first[item.id] ?? [:]
            var values: [String: String] = [
                "goals": goals.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n"),
                "about": SemanticDataset.about(for: item.profile),
                "context": item.context.map(quoted).joined(separator: " "),
                "sentence": quoted(item.text),
                "earlier": SemanticRepetition.candidates(for: item.text, among: asked[item.profile] ?? []).map(quoted)
                    .joined(separator: " "),
            ]
            for (key, value) in first { values["first.\(key)"] = value }
            if let number = Int(first["goal"] ?? ""), number >= 1, number <= goals.count {
                values["goal_text"] = goals[number - 1].text
            } else {
                values["goal_text"] = ""
            }
            asked[item.profile, default: []].append(item.text)
            if session == nil || sessionProfile != item.profile || turn >= options.sessionTurns {
                let new = LanguageModelSession(model: SystemLanguageModel.default, instructions: spec.instructions)
                if let lead = options.lead {
                    if let prefix = spec.prefix {
                        new.prewarm(promptPrefix: Prompt(fill(prefix, values: values)))
                    } else {
                        new.prewarm()
                    }
                    try? await Task.sleep(for: .seconds(lead))
                }
                session = new
                sessionProfile = item.profile
                turn = 0
            }
            turn += 1
            let prompt = fill(spec.prompt, values: values)
            var answer = Answer(id: item.id, fields: [:], seconds: 0, turn: turn)
            let started = Date()
            do {
                guard let session else { continue }
                if let schema {
                    let response = try await session.respond(to: prompt, schema: schema,
                                                             includeSchemaInPrompt: spec.schemaInPrompt ?? false, options: generation)
                    if spec.bare == true, let field = spec.fields?.first {
                        answer.fields[field.name] = text(of: response.content)
                    }
                    for field in spec.bare == true ? [] : spec.fields ?? [] {
                        if let value = try? response.content.value(GeneratedContent.self, forProperty: field.name) {
                            answer.fields[field.name] = text(of: value)
                        }
                    }
                    if #available(iOS 27.0, macOS 27.0, *) {
                        answer.inputTokens = response.usage.input.totalTokenCount
                        answer.cachedTokens = response.usage.input.cachedTokenCount
                        answer.outputTokens = response.usage.output.totalTokenCount
                    }
                } else {
                    let response = try await session.respond(to: prompt, options: generation)
                    answer.text = response.content
                    if #available(iOS 27.0, macOS 27.0, *) {
                        answer.inputTokens = response.usage.input.totalTokenCount
                        answer.cachedTokens = response.usage.input.cachedTokenCount
                        answer.outputTokens = response.usage.output.totalTokenCount
                    }
                }
            } catch {
                answer.failure = String(describing: type(of: error)) + "." + (Mirror(reflecting: error).children.first?.label ?? "")
                session = nil
            }
            answer.seconds = Date().timeIntervalSince(started)
            answers.append(answer)
            progress?(index + 1, dataset.items.count)
        }
        return answers
    }
}
