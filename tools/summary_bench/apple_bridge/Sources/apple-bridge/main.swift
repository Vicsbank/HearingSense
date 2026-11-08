import Foundation
import FoundationModels

// Reads one JSON request per line on standard input and writes one JSON answer per line.
// On device only: SystemLanguageModel.default, never PrivateCloudComputeLanguageModel.
// A fresh session per request (each decision stands alone), greedy sampling.

struct Field: Decodable {
    var name: String
    var type: String
    var values: [String]?
    var description: String?
    var maxCount: Int?
}

struct SchemaSpec: Decodable { var fields: [Field] }

struct Request: Decodable {
    var command: String
    var instructions: String?
    var prompt: String?
    var limit: Int?
    var prewarm: Bool?
    var schema: SchemaSpec?
}

func write(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func schema(for spec: SchemaSpec) throws -> GenerationSchema {
    var dependencies: [DynamicGenerationSchema] = []
    var properties: [DynamicGenerationSchema.Property] = []
    for field in spec.fields {
        if let values = field.values {
            let name = field.name.prefix(1).uppercased() + field.name.dropFirst()
            dependencies.append(DynamicGenerationSchema(name: name, anyOf: values))
            properties.append(.init(name: field.name, schema: DynamicGenerationSchema(referenceTo: name)))
        } else if field.type == "bool" {
            properties.append(.init(name: field.name, description: field.description, schema: DynamicGenerationSchema(type: Bool.self)))
        } else if field.type == "string_array" {
            properties.append(.init(name: field.name, description: field.description,
                                    schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), maximumElements: field.maxCount)))
        } else {
            properties.append(.init(name: field.name, description: field.description, schema: DynamicGenerationSchema(type: String.self)))
        }
    }
    return try GenerationSchema(root: DynamicGenerationSchema(name: "Answer", properties: properties), dependencies: dependencies)
}

// The session for the next request, created and prepared while nothing else runs (what an app that
// expects more speech would do).
var prepared: (instructions: String, session: LanguageModelSession)?

func session(for instructions: String) -> LanguageModelSession {
    if let ready = prepared, ready.instructions == instructions {
        prepared = nil
        return ready.session
    }
    return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
}

func generate(_ request: Request) async -> [String: Any] {
    let instructions = request.instructions ?? ""
    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.limit ?? 40)
    let current = session(for: instructions)
    var answer: [String: Any] = [:]
    let started = Date()
    do {
        var first: TimeInterval?
        if let spec = request.schema {
            // As in the app's `respond(generating:)`, the schema is part of the prompt.
            let stream = current.streamResponse(to: request.prompt ?? "", schema: try schema(for: spec),
                                                includeSchemaInPrompt: true, options: options)
            for try await snapshot in stream {
                if first == nil { first = Date().timeIntervalSince(started) }
                answer["text"] = snapshot.rawContent.jsonString
                answer["input_tokens"] = snapshot.usage.input.totalTokenCount
                answer["cached_tokens"] = snapshot.usage.input.cachedTokenCount
                answer["output_tokens"] = snapshot.usage.output.totalTokenCount
            }
        } else {
            let stream = current.streamResponse(to: request.prompt ?? "", options: options)
            for try await snapshot in stream {
                if first == nil { first = Date().timeIntervalSince(started) }
                answer["text"] = snapshot.content
                answer["input_tokens"] = snapshot.usage.input.totalTokenCount
                answer["cached_tokens"] = snapshot.usage.input.cachedTokenCount
                answer["output_tokens"] = snapshot.usage.output.totalTokenCount
            }
        }
        if let first { answer["first_seconds"] = first }
    } catch {
        // The kind of error only: model errors can quote the prompt.
        answer["error"] = String(describing: type(of: error)) + "." + (Mirror(reflecting: error).children.first?.label ?? "")
    }
    answer["seconds"] = Date().timeIntervalSince(started)
    if request.prewarm == true {
        let next = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        next.prewarm()
        prepared = (instructions, next)
    }
    return answer
}

while let line = readLine(strippingNewline: true) {
    guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else {
        write(["error": "bad request"])
        continue
    }
    switch request.command {
    case "info":
        let model = SystemLanguageModel.default
        write(["variant": model.variant.displayName, "context_size": model.contextSize,
               "available": model.isAvailable, "os": ProcessInfo.processInfo.operatingSystemVersionString])
    case "generate":
        write(await generate(request))
    default:
        write(["error": "unknown command"])
    }
}
