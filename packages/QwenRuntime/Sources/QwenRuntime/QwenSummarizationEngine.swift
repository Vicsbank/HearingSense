import ConversationUnderstanding
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
#if os(iOS) && !targetEnvironment(simulator)
import os
#endif

/// Qwen3.5-4B (MLX, 4-bit) as a summarization engine (Window 9). Runs fully on the device through
/// mlx-swift-lm; nothing is sent anywhere. The weights are read from a local directory (see
/// `QwenModelLocator`); this type never downloads.
///
/// One loaded model is reused for every request (`container`); each request uses a fresh chat
/// session, because a summary of different speech must not see an earlier request's tokens. The
/// model is greedy (temperature 0) and has its thinking switched off. Generation runs on the
/// MLX/Swift-concurrency executors, never on the main thread.
public actor QwenSummarizationEngine: SummarizationEngine {
    public struct Metrics: Hashable, Sendable {
        public var loadSeconds: TimeInterval = 0
        public var promptTokens = 0
        public var generatedTokens = 0
        public var promptSeconds: TimeInterval = 0
        public var generateSeconds: TimeInterval = 0
        public var totalSeconds: TimeInterval = 0
        /// MLX's own count of bytes in use / at peak after the request.
        public var activeBytes = 0
        public var peakBytes = 0
        public var tokensPerSecond: Double { generateSeconds > 0 ? Double(generatedTokens) / generateSeconds : 0 }
    }

    public nonisolated let identity: SummarizationEngineIdentity
    private let modelDirectory: URL
    private let maxRecapTokens: Int
    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?
    private var loadFailure: String?
    public private(set) var lastMetrics = Metrics()
    public private(set) var loadSeconds: TimeInterval?

    /// - Parameter maxRecapTokens: generation limit for a full recap.
    public init(modelDirectory: URL, maxRecapTokens: Int = 700) {
        self.modelDirectory = modelDirectory
        self.maxRecapTokens = maxRecapTokens
        self.identity = QwenModelLocator.identity(of: modelDirectory)
    }

    // MARK: SummarizationEngine

    public func isAvailable() async -> Bool { await unavailabilityReason() == nil }

    public func unavailabilityReason() async -> String? {
        // The pinned local runtime uses its real CPU allocator/ops in Simulator.
        // Only the adapter's CPU backend is allowed to execute Simulator requests.
        #if targetEnvironment(simulator)
        guard Device.defaultDevice().deviceType == .cpu else { return "qwen_simulator_backend_misconfigured" }
        #endif
        if let loadFailure { return loadFailure }
        #if os(iOS) && !targetEnvironment(simulator)
        // A jetsam kill cannot be caught for fallback. Refuse a fresh load when iOS says
        // the app lacks headroom for the measured 3.03 GB MLX peak plus process overhead.
        // Do not apply the cold-load budget to an already resident/shared load.
        if container == nil, loading == nil, os_proc_available_memory() < 3_600_000_000 {
            return "qwen_insufficient_memory_budget"
        }
        #endif
        return QwenModelLocator.problem(with: modelDirectory)
    }

    public nonisolated static var executionBackend: String {
        Device.defaultDevice().deviceType == .cpu ? "cpu" : "metal"
    }

    public func releaseResources() async {
        loading?.cancel()
        loading = nil
        container = nil
        MLX.Memory.clearCache()
    }

    public func prewarm() async {
        _ = try? await ensureLoaded()
    }

    /// Loads the weights (once). Concurrent callers share one load.
    @discardableResult
    func ensureLoaded() async throws -> ModelContainer {
        if let container { return container }
        if let loading { return try await loading.value }
        if let problem = await unavailabilityReason() { throw RecapError.modelFailure(problem) }
        #if os(iOS) && !targetEnvironment(simulator)
        // Retaining the default multi-GB allocator cache exceeds iPhone process budgets.
        // Bound reusable buffers; active model tensors remain governed by MLX/iOS.
        MLX.Memory.cacheLimit = 64 * 1024 * 1024
        MLX.Memory.clearCache()
        #endif
        let directory = modelDirectory
        let task = Task<ModelContainer, Error> {
            try await loadModelContainer(from: directory, using: HubTokenizerLoader())
        }
        loading = task
        let started = Date()
        do {
            let loaded = try await task.value
            try Task.checkCancellation()
            guard !task.isCancelled else { throw CancellationError() }
            container = loaded
            loading = nil
            loadSeconds = Date().timeIntervalSince(started)
            return loaded
        } catch {
            loading = nil
            if error is CancellationError { throw CancellationError() }
            // Remembered: an engine that cannot load is not asked again until the app restarts.
            loadFailure = "qwen_load_failed_" + String(describing: type(of: error))
            throw RecapError.modelFailure(loadFailure ?? "qwen_load_failed")
        }
    }

    // MARK: ConversationSummarizing

    public func recap(transcript: String, notes: [String]) async throws -> RecapDraft {
        let answer = try await generate(instructions: OpenModelRecapProtocol.recapInstructions,
                                        prompt: OpenModelRecapProtocol.recapMessage(transcript: transcript, notes: notes),
                                        maxTokens: maxRecapTokens)
        guard let parsed = OpenModelRecapProtocol.parseRecap(answer) else { throw RecapError.modelFailure("qwen_unreadable_answer") }
        return parsed.draft
    }

    public func update(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft {
        let answer = try await generate(instructions: OpenModelRecapProtocol.updateInstructions,
                                        prompt: OpenModelRecapProtocol.updateMessage(previous: previous, newTranscript: newTranscript),
                                        maxTokens: 350)
        guard var parsed = OpenModelRecapProtocol.parseRecap(answer, fallbackTitle: previous.title) else {
            throw RecapError.modelFailure("qwen_unreadable_answer")
        }
        // The addition only; `ConversationRecapEngine` merges it with the earlier recap.
        parsed.draft.title = previous.title
        parsed.draft.outdated = parsed.outdated
        return parsed.draft
    }

    public func rewrite(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft {
        let answer = try await generate(instructions: OpenModelRecapProtocol.rewriteInstructions,
                                        prompt: OpenModelRecapProtocol.rewriteMessage(previous: previous, newTranscript: newTranscript),
                                        maxTokens: maxRecapTokens)
        guard var parsed = OpenModelRecapProtocol.parseRecap(answer, fallbackTitle: previous.title) else {
            throw RecapError.modelFailure("qwen_unreadable_answer")
        }
        parsed.draft.title = previous.title
        return parsed.draft
    }

    public func restate(_ statement: String) async throws -> String {
        let answer = try await generate(instructions: OpenModelRecapProtocol.restateInstructions,
                                        prompt: "Sentence:\n" + statement, maxTokens: 90)
        guard let sentence = OpenModelRecapProtocol.parseSentence(answer) else { throw RecapError.modelFailure("qwen_unreadable_answer") }
        return sentence
    }

    public func evidence(for statements: [String], in lines: [String]) async throws -> [StatementEvidence]? {
        guard !statements.isEmpty else { return [] }
        let answer = try await generate(instructions: OpenModelRecapProtocol.verifyInstructions,
                                        prompt: OpenModelRecapProtocol.verifyMessage(statements: statements, lines: lines),
                                        maxTokens: 30 + statements.count * 28)
        return OpenModelRecapProtocol.parseVerdicts(answer, count: statements.count)
    }

    // MARK: Generation

    private func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        let container = try await ensureLoaded()
        let started = Date()
        var parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        #if targetEnvironment(simulator)
        // Bound a CPU prefill forward so cancellation is checked between smaller chunks.
        parameters.prefill = PrefillParameters(stepSize: 64)
        #endif
        let session = ChatSession(
            container, instructions: instructions,
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false])
        var text = ""
        var metrics = Metrics(loadSeconds: loadSeconds ?? 0)
        do {
            for try await event in session.streamDetails(to: prompt) {
                try Task.checkCancellation()
                switch event {
                case .chunk(let piece): text += piece
                case .info(let info):
                    metrics.promptTokens = info.promptTokenCount
                    metrics.generatedTokens = info.generationTokenCount
                    metrics.promptSeconds = info.promptTime
                    metrics.generateSeconds = info.generateTime
                default: break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The kind only: errors can quote the prompt, which holds the transcript.
            throw RecapError.modelFailure("qwen_generation_" + String(describing: type(of: error)))
        }
        metrics.totalSeconds = Date().timeIntervalSince(started)
        metrics.activeBytes = MLX.Memory.activeMemory
        metrics.peakBytes = MLX.Memory.peakMemory
        lastMetrics = metrics
        return text
    }
}

/// Reads the tokenizer (and its chat template) from the model directory with swift-transformers.
struct HubTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int]
    {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
