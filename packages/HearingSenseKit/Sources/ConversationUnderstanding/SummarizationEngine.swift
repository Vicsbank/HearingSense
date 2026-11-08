import Foundation

/// Which model wrote a summary, exactly (Window 9). Stored with every recap so that a summary
/// from the Apple fallback is never reported as one from Qwen, and the diagnostics can name the
/// checkpoint, revision and quantization that produced a result.
public struct SummarizationEngineIdentity: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case qwen
        case appleFoundationModels
    }

    public var kind: Kind
    /// "mlx-community/Qwen3.5-4B-MLX-4bit", or "AFM 3 Core" style name for the system model.
    public var modelID: String
    /// Checkpoint revision (the snapshot hash for a downloaded checkpoint); "system" for Apple's model.
    public var revision: String
    /// "4-bit affine, group 64", or "system".
    public var quantization: String
    /// "mlx-swift-lm 3.32.3 / mlx-swift 0.32.3", or "FoundationModels".
    public var runtime: String

    public init(kind: Kind, modelID: String, revision: String, quantization: String, runtime: String) {
        self.kind = kind
        self.modelID = modelID
        self.revision = revision
        self.quantization = quantization
        self.runtime = runtime
    }

    public static let appleFoundationModels = SummarizationEngineIdentity(
        kind: .appleFoundationModels, modelID: "SystemLanguageModel.default", revision: "system", quantization: "system",
        runtime: "FoundationModels")

    /// A few words for a screen or a log line.
    public var label: String {
        switch kind {
        case .qwen: "Qwen (\(modelID.split(separator: "/").last.map(String.init) ?? modelID))"
        case .appleFoundationModels: "Apple on-device model"
        }
    }

    /// Everything, for the diagnostics report. Model and runtime names only: nothing of any speech.
    public var detail: String {
        "\(kind.rawValue): \(modelID) @ \(revision) · \(quantization) · \(runtime)"
    }
}

/// A language model that can write recaps, with its identity. Production engines:
/// `QwenSummarizationEngine` (the primary, on-device through MLX) and
/// `AppleFoundationSummarizationEngine` (the fallback).
public protocol SummarizationEngine: ConversationSummarizing {
    var identity: SummarizationEngineIdentity { get }
    /// Why the engine cannot be used right now (a code, never speech text); nil when it can.
    func unavailabilityReason() async -> String?
    /// Frees memory held for fast starts (weights, caches). The engine reloads on the next request.
    func releaseResources() async
}

extension SummarizationEngine {
    public func unavailabilityReason() async -> String? { await isAvailable() ? nil : "unavailable" }
    public func releaseResources() async {}
}

/// Writes summaries with the preferred engine and falls back to the other one when the preferred
/// engine cannot do it (unavailable, failed to start, failed while writing, ran out of time or
/// memory). Never retries without limit: an engine that failed is left alone for `cooldown`.
///
/// Which engine wrote each draft is put into `RecapDraft.engine`; the fallback's drafts say so.
public actor SummarizationCoordinator: ConversationSummarizing {
    public struct Policy: Hashable, Sendable {
        /// Time the preferred engine gets for one request before the fallback is asked.
        public var primaryTimeout: TimeInterval = 40
        /// Time the fallback gets (the caller's own limit applies on top).
        public var fallbackTimeout: TimeInterval = 25
        /// Failures in a row after which the preferred engine is left alone for `cooldown`.
        public var failuresBeforeCooldown = 2
        /// How long a failing engine is skipped. After that one new attempt is made.
        public var cooldown: TimeInterval = 300
        public init() {}
    }

    /// One request's outcome, for diagnostics (names and times only).
    public struct Attempt: Hashable, Sendable {
        public var engine: SummarizationEngineIdentity
        public var seconds: TimeInterval
        /// nil: it wrote the draft.
        public var failure: String?
    }

    private let primary: (any SummarizationEngine)?
    private let fallback: any SummarizationEngine
    private let policy: Policy
    private let gate = SummaryExecutionGate()
    private var isForeground = true
    private var lifecycleRevision = 0
    private var consecutivePrimaryFailures = 0
    private var primarySkippedUntil: Date?
    public private(set) var lastAttempts: [Attempt] = []
    /// The engine that wrote the latest draft.
    public private(set) var lastEngine: SummarizationEngineIdentity?

    public init(primary: (any SummarizationEngine)?, fallback: any SummarizationEngine, policy: Policy = Policy()) {
        self.primary = primary
        self.fallback = fallback
        self.policy = policy
    }

    public nonisolated var identities: [SummarizationEngineIdentity] {
        [primary?.identity, fallback.identity].compactMap(\.self)
    }

    public func isAvailable() async -> Bool {
        guard isForeground else { return false }
        if await primaryUsable() { return true }
        return await fallback.isAvailable()
    }

    public func prewarm() async {
        guard isForeground else { return }
        let engine = await primaryUsable() ? primary : fallback
        try? await gate.perform { await engine?.prewarm() }
    }

    public func setForeground(_ foreground: Bool, revision: Int? = nil) {
        if let revision {
            guard revision >= lifecycleRevision else { return }
            lifecycleRevision = revision
        }
        isForeground = foreground
    }

    public func releaseResources() async {
        let primary = self.primary, fallback = self.fallback
        try? await gate.perform {
            await primary?.releaseResources()
            await fallback.releaseResources()
        }
    }

    // MARK: ConversationSummarizing

    public func recap(transcript: String, notes: [String]) async throws -> RecapDraft {
        try await run { engine in try await engine.recap(transcript: transcript, notes: notes) }
    }

    public func update(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft {
        try await run { engine in try await engine.update(previous: previous, newTranscript: newTranscript) }
    }

    public func rewrite(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft {
        try await run { engine in try await engine.rewrite(previous: previous, newTranscript: newTranscript) }
    }

    public func restate(_ statement: String) async throws -> String {
        // Same engine as the draft when possible; failures here are not worth a second engine.
        let engine: any SummarizationEngine = lastEngine?.kind == .qwen ? (primary ?? fallback) : fallback
        return try await gate.perform { try await engine.restate(statement) }
    }

    public func restate(_ statement: String, using identity: SummarizationEngineIdentity?) async throws -> String {
        let engine = engine(for: identity)
        guard isForeground else { throw CancellationError() }
        return try await gate.perform { try await engine.restate(statement) }
    }

    public func evidence(for statements: [String], in lines: [String], using identity: SummarizationEngineIdentity?) async throws -> [StatementEvidence]? {
        let engine = engine(for: identity)
        guard isForeground else { throw CancellationError() }
        return try await gate.perform { try await engine.evidence(for: statements, in: lines) }
    }

    private func engine(for identity: SummarizationEngineIdentity?) -> any SummarizationEngine {
        if let primary, primary.identity == identity { return primary }
        return fallback
    }

    public func evidence(for statements: [String], in lines: [String]) async throws -> [StatementEvidence]? {
        let engine: any SummarizationEngine = lastEngine?.kind == .qwen ? (primary ?? fallback) : fallback
        return try await gate.perform { try await engine.evidence(for: statements, in: lines) }
    }

    public func isGrounded(_ statement: String, in transcript: String) async throws -> Bool? {
        let engine: any SummarizationEngine = lastEngine?.kind == .qwen ? (primary ?? fallback) : fallback
        return try await gate.perform { try await engine.isGrounded(statement, in: transcript) }
    }

    // MARK: Routing

    private func primaryUsable() async -> Bool {
        guard let primary else { return false }
        if let until = primarySkippedUntil {
            if until > Date() { return false }
            primarySkippedUntil = nil
            consecutivePrimaryFailures = 0
        }
        return await primary.isAvailable()
    }

    private func notePrimaryFailure() {
        consecutivePrimaryFailures += 1
        if consecutivePrimaryFailures >= policy.failuresBeforeCooldown {
            primarySkippedUntil = Date().addingTimeInterval(policy.cooldown)
        }
    }

    private func run(_ operation: @escaping @Sendable (any SummarizationEngine) async throws -> RecapDraft) async throws -> RecapDraft {
        try Task.checkCancellation()
        guard isForeground else { throw CancellationError() }
        var attempts: [Attempt] = []
        defer { lastAttempts = attempts }
        let request = SummaryRequest.current
        request?.record(.availability)
        if let primary, await primaryUsable() {
            let stageBudget = request?.budget(maximum: policy.primaryTimeout, reservingChecks: true) ?? policy.primaryTimeout
            guard stageBudget > 0 else { throw CancellationError() }
            let started = Date()
            do {
                request?.record(.primary)
                let gate = self.gate
                request?.record(.queue)
                var draft = try await Self.withTimeout(stageBudget) {
                    try await gate.perform {
                        try request?.check()
                        request?.record(.queue, .completed, duration: Date().timeIntervalSince(started))
                        request?.record(.primary)
                        return try await operation(primary)
                    }
                }
                try request?.check()
                consecutivePrimaryFailures = 0
                draft.engine = primary.identity
                lastEngine = primary.identity
                attempts.append(Attempt(engine: primary.identity, seconds: Date().timeIntervalSince(started), failure: nil))
                request?.record(.primary, .completed, duration: Date().timeIntervalSince(started))
                return draft
            } catch is CancellationError where Task.isCancelled {
                throw CancellationError()
            } catch {
                notePrimaryFailure()
                request?.record(.primary, .failed, duration: Date().timeIntervalSince(started))
                attempts.append(Attempt(engine: primary.identity, seconds: Date().timeIntervalSince(started),
                                            failure: Self.failureCode(error)))
            }
        } else if let primary {
            attempts.append(Attempt(engine: primary.identity, seconds: 0,
                                        failure: (await primary.unavailabilityReason()) ?? "skipped_after_failures"))
        }
        // The fallback.
        try Task.checkCancellation()
        let fallback = self.fallback
        guard await fallback.isAvailable() else { throw RecapError.modelFailure("no_engine_available") }
        let fallbackBudget = request?.budget(maximum: policy.fallbackTimeout, reservingChecks: true) ?? policy.fallbackTimeout
        guard fallbackBudget > 0 else { throw CancellationError() }
        let started = Date()
        do {
            guard isForeground else { throw CancellationError() }
            request?.record(.fallback)
            let gate = self.gate
            var draft = try await Self.withTimeout(fallbackBudget) {
                try await gate.perform {
                    try request?.check()
                    return try await operation(fallback)
                }
            }
            try request?.check()
            draft.engine = fallback.identity
            if let first = attempts.first, let failure = first.failure { draft.fallbackReason = failure }
            lastEngine = fallback.identity
            attempts.append(Attempt(engine: fallback.identity, seconds: Date().timeIntervalSince(started), failure: nil))
            request?.record(.fallback, .completed, duration: Date().timeIntervalSince(started))
            return draft
        } catch {
            attempts.append(Attempt(engine: fallback.identity, seconds: Date().timeIntervalSince(started),
                                        failure: Self.failureCode(error)))
            throw error
        }
    }

    /// A short code for an error: its type, never its text (errors can quote the prompt).
    static func failureCode(_ error: Error) -> String {
        if error is CancellationError { return "timeout" }
        if case RecapError.modelFailure(let kind) = error { return "failure_" + kind }
        return "failure_" + String(describing: type(of: error))
    }

    private static func withTimeout<Value: Sendable>(_ seconds: TimeInterval,
                                                     _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value
    {
        try await SummaryDeadline.run(seconds: seconds, operation: operation)
    }
}
