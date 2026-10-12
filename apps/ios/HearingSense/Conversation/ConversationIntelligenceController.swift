import ConversationUnderstanding
import HearingSenseAudio
import HearingSenseDomain
import IslandPresentation
import Observation
import SwiftUI

/// Conversation summaries in the app (Window 7; built on Window 6): the two-minute summary the
/// user asks for, continued understanding with live captions, and the saved history.
///
/// Main-actor isolated (app default) and owned by `ListeningController`, so it keeps working in
/// the background. It adds no microphone path: it reads the finalized utterances the Window 3
/// speech pipeline already produces.
///
/// The language model runs only when the user asks: for a summary, and for the updates of a
/// conversation the user chose to keep following. Nothing here judges what is said while the
/// user has not asked (the personal semantic attention of Windows 6–6.3 is not part of the
/// product; its code stays in the `SemanticAttention` package module and on its branches).
///
/// What is stored on the device: the summaries the user asked for. Log lines and reports hold
/// counts, states and timings only.
@Observable
final class ConversationIntelligenceController {
    /// A summary covers what was transcribed in the last two minutes. Not a setting.
    static let lookBack: TimeInterval = ConversationBufferPolicy.standard.lookBack

    /// `--hs-conversation-demo` (Debug builds): a scripted conversation instead of the microphone,
    /// with nothing read from or written to the device's storage. See `runDemo`.
    static var isDemoRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--hs-conversation-demo")
        #else
        false
        #endif
    }

    /// For App Intents, which have no reference to the app's object graph.
    private(set) static weak var shared: ConversationIntelligenceController?


    private(set) var isLanguageModelAvailable = false

    // Recap and continued understanding
    private(set) var phase = ConversationPhase.idle
    private(set) var status: ConversationStatus?
    private(set) var recap: ConversationRecap?
    private(set) var currentRecordID: UUID?
    private(set) var captions: [BufferedUtterance] = []
    private(set) var tentativeCaption: String?
    private(set) var unavailableMessage: String?
    private(set) var continuedSince: Date?
    private(set) var recapsMade = 0
    private(set) var updatesMade = 0
    private(set) var lastRecapSeconds: TimeInterval?

    // History
    private(set) var history: [ConversationRecord] = []
    private(set) var storageError: String?

    private(set) var isSessionActive = false
    private(set) var isTranscriptionOn = false

    /// Where a requested summary stands, for the Live Activity (its expanded presentation offers
    /// Summarize, Continue and Stop by this). nil during ordinary listening.
    @ObservationIgnored var onIslandState: ((IslandConversation?) -> Void)?
    /// The state of "Transcribe nearby speech" (Window 3), read whenever it matters.
    @ObservationIgnored var transcriptionProvider: () -> Bool = { false }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: SwiftDataConversationHistory?
    @ObservationIgnored private let recapEngine: ConversationRecapEngine
    @ObservationIgnored private var buffer: RollingConversationBuffer
    @ObservationIgnored private var machine = ConversationSessionMachine(policy: .product)
    @ObservationIgnored private var islandState: IslandConversation?
    @ObservationIgnored private var statusSince = Date.now
    @ObservationIgnored private var unavailableTitle: String?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var lastUtteranceIndex: [SpeechEventID: Int] = [:]
    /// The words the saved recap was written from, kept only while the session is followed so
    /// that an update can be checked against them. Cleared with the temporary context.
    @ObservationIgnored private var recapTranscript = ""
    @ObservationIgnored private var log: (DiagnosticEventLog.Kind, String) -> Void = { _, _ in }

    /// - Parameter inMemory: no files are read or written (UI checks, previews).
    init(defaults: UserDefaults = .standard, inMemory: Bool = ConversationIntelligenceController.isDemoRequested,
         summarizer: any ConversationSummarizing = FoundationModelRecapSummarizer())
    {
        self.defaults = defaults
        let policy = ConversationBufferPolicy.standard
        buffer = RollingConversationBuffer(policy: policy)
        recapEngine = ConversationRecapEngine(summarizer: summarizer, bufferPolicy: policy)
        var opened: SwiftDataConversationHistory?
        var records: [ConversationRecord] = []
        var problem: String?
        do {
            let history = try SwiftDataConversationHistory(inMemory: inMemory)
            try history.completeInterrupted()
            records = try history.all()
            opened = history
        } catch {
            problem = "The summary history could not be opened: \(error.localizedDescription)"
        }
        store = opened
        history = records
        storageError = problem
        Self.shared = self
        Task { [weak self] in
            let isAvailable = await summarizer.isAvailable()
            self?.isLanguageModelAvailable = isAvailable
        }
    }

    deinit {
        workTask?.cancel()
        deadlineTask?.cancel()
    }

    func setLogger(_ logger: @escaping (DiagnosticEventLog.Kind, String) -> Void) {
        log = logger
    }

    // MARK: - Lifecycle (called by ListeningController)

    func sessionWillStart(isTranscriptionOn: Bool) {
        isSessionActive = true
        self.isTranscriptionOn = isTranscriptionOn
        lastUtteranceIndex.removeAll()
        machine.setListening(true)
        machine.setContextAllowed(isTranscriptionOn)
        if isTranscriptionOn { buffer.begin(at: .now) }
    }

    /// Capture stopped: a continued session is finalized and every temporary text is deleted.
    func sessionDidEnd() {
        guard isSessionActive else { return }
        isSessionActive = false
        run(machine.process(.listeningStopped(at: .now)))
        clearTemporaryText()
        log(.recognition, "Conversation: \(recapsMade) summary request(s), \(updatesMade) update(s) this launch")
    }

    /// The user switched "Transcribe nearby speech" (Window 3).
    func transcriptionChanged(isOn: Bool) {
        guard isOn != isTranscriptionOn else { return }
        isTranscriptionOn = isOn
        applyContextPermission()
    }

    /// The speech pipeline discarded its events (transcription off, or "Clear speech data").
    func speechDataCleared() {
        isTranscriptionOn = transcriptionProvider()
        run(machine.process(.contextRevoked(at: .now)))
        machine.setContextAllowed(isTranscriptionOn)
        clearTemporaryText()
        if isSessionActive, isTranscriptionOn { buffer.begin(at: .now) }
    }

    // MARK: - Input from the speech pipeline

    func receive(_ result: SpeechSemanticResult) {
        guard isSessionActive else { return }
        transcriptionChanged(isOn: transcriptionProvider())
        let now = Date.now
        let keeps = isTranscriptionOn
        if keeps {
            buffer.setTentative(result.volatileText)
            tentativeCaption = buffer.tentative
        }
        let last = lastUtteranceIndex[result.id] ?? -1
        for utterance in result.recentUtterances where utterance.index > last && !utterance.isPossiblyMusic {
            lastUtteranceIndex[result.id] = utterance.index
            if keeps {
                buffer.append(BufferedUtterance(text: utterance.text, start: utterance.startDate, end: utterance.endDate,
                                                isLowQuality: utterance.quality == .poor), now: now)
                run(machine.process(.utterance(meaningfulWords: MeaningfulWords.count(in: utterance.text), end: now)))
            }
        }
        if result.state.isTerminal {
            lastUtteranceIndex[result.id] = nil
            // Speech was detected and nothing could be transcribed: a recap says so.
            if keeps, result.utteranceCount == 0, result.transcriptionAvailability.isUsable {
                buffer.noteMissingSpeech(from: result.startDate, to: result.updatedDate, now: now)
            }
        }
        if keeps {
            buffer.prune(now: now)
            captions = buffer.utterances
            scheduleDeadline()
        }
    }

    // MARK: - Settings

    private func applyContextPermission() {
        if isTranscriptionOn {
            machine.setContextAllowed(true)
            if isSessionActive, buffer.collectingSince == nil { buffer.begin(at: .now) }
        } else {
            run(machine.process(.contextRevoked(at: .now)))
            clearTemporaryText()
        }
    }

    // MARK: - Recap and continued understanding

    /// "Summarize" (the expanded Dynamic Island, or the button in the app): a summary of what was
    /// transcribed in the last two minutes. Only ever called for something the user pressed.
    /// It stops nothing: while a summary is being written or a conversation is followed it does
    /// nothing. Returns a generic sentence (never speech text).
    @discardableResult
    func summarize() -> String {
        unavailableMessage = nil
        unavailableTitle = nil
        transcriptionChanged(isOn: transcriptionProvider())
        let before = phase
        run(machine.process(.summarizeRequested(at: .now)))
        switch (before, phase) {
        case (_, .preparing), (_, .summarizing):
            return before == phase ? "A summary is already being written." : "Writing a summary of the last two minutes."
        case (.continuing, _): return "Following the conversation. Stop it first to ask for a new summary."
        default: return unavailableMessage ?? "No summary could be written."
        }
    }

    func continueUnderstanding() {
        run(machine.process(.continueSelected(at: .now)))
    }

    func stopUnderstanding() {
        run(machine.process(.stopSelected(at: .now)))
    }

    var lookBack: TimeInterval { Self.lookBack }
    /// A summary can be asked for: listening, and speech is being transcribed.
    var canSummarize: Bool { isSessionActive && isTranscriptionOn }
    var bufferedWordCount: Int { captions.reduce(0) { $0 + $1.wordCount } }

    private func run(_ effects: [ConversationEffect]) {
        for effect in effects {
            switch effect {
            case .generateRecap:
                let excerpt = buffer.excerpt(now: .now)
                recapTranscript = recapEngine.transcript(of: excerpt)
                run(machine.process(.excerptReady(at: .now)))
                workTask?.cancel()
                workTask = Task { [recapEngine] in
                    let recap = await recapEngine.recap(excerpt)
                    guard !Task.isCancelled else { return }
                    self.recapsMade += 1
                    self.lastRecapSeconds = recap.modelSeconds
                    self.log(.recognition, "Recap: \(recap.source.rawValue), \(excerpt.utterances.count) utterance(s), "
                        + "\(excerpt.wordCount) words, model \(Self.seconds(recap.modelSeconds)), "
                        + "\(recap.corrections.count) correction(s)")
                    self.run(self.machine.process(.recapReady(recap, at: .now)))
                }
            case .cancelWork:
                workTask?.cancel()
                workTask = nil
            case .save(let recap, let isContinuing):
                self.recap = recap
                save(recap, status: isContinuing ? .continuing : .completed)
            case .requestUpdate(let since):
                guard let recap else {
                    run(machine.process(.updateFinished(nil, at: .now)))
                    break
                }
                let new = buffer.utterances(after: since)
                let earlier = recapTranscript
                workTask = Task { [recapEngine] in
                    let updated = await recapEngine.update(recap, earlierTranscript: earlier, new: new)
                    guard !Task.isCancelled else { return }
                    if updated != nil {
                        self.updatesMade += 1
                        // Kept only as long as the session is followed; bounded.
                        self.recapTranscript = String((earlier + "\n" + new.map(\.text).joined(separator: "\n")).suffix(8000))
                    }
                    self.log(.recognition, "Recap update: \(updated == nil ? "nothing new" : "extended") from \(new.count) utterance(s)")
                    self.run(self.machine.process(.updateFinished(updated, at: .now)))
                }
            case .finalize:
                if let recap { save(recap, status: .completed) }
                currentRecordID = nil
            case .clearTemporaryContext:
                clearTemporaryText()
                if isSessionActive, isTranscriptionOn { buffer.begin(at: .now) }
            case .status(let newStatus, _):
                if newStatus != status { statusSince = .now }
                status = newStatus
            case .unavailable(let reason):
                unavailableMessage = reason.message
                unavailableTitle = reason.title
            case .noSummary(let note):
                // The engine's own explanation ("too little was said", "the model is not
                // available"): shown, never saved, and never a summary.
                recap = nil
                unavailableMessage = note.summary
                unavailableTitle = "No summary"
                log(.recognition, "Summary request ended without a summary (\(note.source.rawValue))")
            }
        }
        phase = machine.phase
        continuedSince = machine.continuedSince
        publishIslandState()
        scheduleDeadline()
    }

    private func save(_ recap: ConversationRecap, status: ConversationRecord.Status) {
        guard let store else { return }
        do {
            let now = Date.now
            if let id = currentRecordID, var record = try store.record(id) {
                record.apply(recap, at: now, status: status)
                try store.save(record)
            } else {
                let record = ConversationRecord(recap: recap, at: now, status: status)
                currentRecordID = record.id
                try store.save(record)
            }
            history = try store.all()
            storageError = nil
        } catch {
            storageError = "The summary could not be saved: \(error.localizedDescription)"
            log(.error, "Saving a summary failed: \(type(of: error))")
        }
    }

    /// Deletes every temporary speech text this controller holds.
    private func clearTemporaryText() {
        buffer.clear()
        captions = []
        tentativeCaption = nil
        recapTranscript = ""
        lastUtteranceIndex.removeAll()
        if phase == .idle { recap = nil }
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let deadline = [machine.nextDeadline, buffer.nextExpiry].compactMap(\.self).min() else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0) + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.buffer.prune(now: .now)
            self.captions = self.buffer.utterances
            self.run(self.machine.process(.tick(at: .now)))
        }
    }

    // MARK: - Dynamic Island

    /// Titles and messages are generic and safe on the Lock Screen. The summary's own text is
    /// `detail`: the Live Activity pipeline shows it only in the expanded presentation, only
    /// while "Show speech summaries" is on, and never while the iPhone is judged locked.
    private func publishIslandState() {
        let state: IslandConversation? = switch status {
        case nil:
            nil
        case .preparingRecap, .summarizing:
            IslandConversation(phase: .summarizing, title: "Summarizing", since: statusSince)
        case .summarySaved, .summaryAvailable:
            IslandConversation(phase: .summaryReady, title: "Summary ready", detail: recap?.summary, since: statusSince)
        case .continuing:
            IslandConversation(phase: .following, title: "Following the conversation", detail: recap?.summary, since: statusSince)
        case .stopped:
            IslandConversation(phase: .notice, title: "Stopped following", message: "The summary is saved. Still listening for sounds.",
                               since: statusSince)
        case .unavailable:
            IslandConversation(phase: .notice, title: unavailableTitle ?? "No summary",
                               message: unavailableTitle == RecapUnavailableReason.contextNotAllowed.title
                                   ? "Past speech cannot be recovered. Turn it on in Hearing Sense."
                                   : "Open Hearing Sense for details.",
                               since: statusSince)
        }
        guard state != islandState else { return }
        islandState = state
        onIslandState?(state)
    }

    // MARK: - History

    func refreshHistory() {
        guard let store else { return }
        history = (try? store.all()) ?? history
    }

    func search(_ query: String) -> [ConversationRecord] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? history : history.filter { $0.matches(query) }
    }

    func record(_ id: UUID) -> ConversationRecord? {
        history.first { $0.id == id }
    }

    func edit(_ id: UUID, title: String, summary: String) {
        guard let store, var record = try? store.record(id) else { return }
        record.edit(title: title, summary: summary, at: .now)
        try? store.save(record)
        refreshHistory()
    }

    func delete(_ ids: Set<UUID>) {
        guard let store else { return }
        for id in ids {
            try? store.delete(id)
            if id == currentRecordID { currentRecordID = nil }
        }
        refreshHistory()
    }

    /// Deletes every saved summary.
    func deleteAllHistory() {
        try? store?.deleteAll()
        currentRecordID = nil
        refreshHistory()
        log(.recognition, "All saved summaries deleted by the user")
    }

    // MARK: - Reports

    static func seconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " s"
    }

    static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return seconds % 60 == 0 ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" : "\(seconds) seconds"
    }

    /// Counts, states and timings. No utterance, no summary.
    func reportText() -> String {
        [
            "Conversation summaries (Window 7)",
            "Continuous semantic relevance inference: not part of this build · language model "
                + "\(isLanguageModelAvailable ? "available" : "not available") (used only for summaries the user asks for)",
            "Recent speech for summaries: \(isTranscriptionOn ? "kept in memory" : "not kept (transcription off)") · look-back \(Int(lookBack)) s · "
                + "buffered \(captions.count) utterance(s), \(bufferedWordCount) words, expired \(buffer.expiredUtterances)",
            "Phase: \(phase.rawValue) · summary requests \(recapsMade) · updates \(updatesMade) · last summary model time "
                + "\(lastRecapSeconds.map(Self.seconds) ?? "–") · saved summaries \(history.count)",
        ].joined(separator: "\n")
    }
}

#if DEBUG
// MARK: - Demo without a microphone

extension ConversationIntelligenceController {
    /// Synthetic sentences, written for this project. Not a real conversation.
    private static let demoFirstPart = [
        "So for the chemistry project, are we still meeting on Thursday?",
        "No, Thursday doesn't work, the library closes at five that day.",
        "What about Saturday morning then, around ten?",
        "Saturday at ten works, but not at the library, it's closed on weekends.",
        "We could use the study room in the science building, room 204.",
        "By the way, the exam has been postponed until Friday.",
        "I have the data on my laptop, but the graphs are not finished.",
        "Then please finish the graphs by Friday night so we can write the report on Saturday.",
    ]
    private static let demoLaterPart = [
        "One more thing, the report is due next Wednesday, not Monday.",
        "And the teacher said it has to be at least six pages.",
        "Fine, then let's split it, three pages each.",
    ]

    /// Plays a scripted conversation through the same path as transcribed speech: the buffer,
    /// the recap engine runs for real (with the on-device language
    /// model where it exists); only the microphone and the recognizer are replaced. The
    /// opt-in is switched on for this launch only and nothing is stored.
    func runDemo() {
        guard Self.isDemoRequested, !isSessionActive else { return }
        log(.lifecycle, "Conversation demo (synthetic sentences, microphone off, nothing stored)")
        transcriptionProvider = { true }
        sessionWillStart(isTranscriptionOn: true)
        Task {
            let id = SpeechEventID()
            var index = 0
            @MainActor func say(_ text: String) async {
                let now = Date.now
                var result = SpeechSemanticResult(
                    id: id, state: .transcribing, audioTime: AudioTimeRange(start: 0, end: Double(index + 1) * 4),
                    startDate: now, updatedDate: now,
                    transcript: SpeechTranscript(text: text, language: "en-US", isFinal: true, quality: .unknown,
                                                 audioTime: AudioTimeRange(start: Double(index) * 4, end: Double(index + 1) * 4)),
                    utteranceCount: index + 1, transcriptionAvailability: .available, modelAvailability: .available)
                result.recentUtterances = [SpeechUtterance(index: index, text: text, startDate: now.addingTimeInterval(-3),
                                                           endDate: now, quality: .good)]
                index += 1
                receive(result)
                try? await Task.sleep(for: .seconds(1.6))
            }
            try? await Task.sleep(for: .seconds(1))
            for line in Self.demoFirstPart { await say(line) }
            summarize()
            // Wait for the recap, then keep following.
            for _ in 0 ..< 60 where phase != .summaryAvailable { try? await Task.sleep(for: .seconds(0.5)) }
            try? await Task.sleep(for: .seconds(2))
            continueUnderstanding()
            for line in Self.demoLaterPart { await say(line) }
            var tentative = SpeechSemanticResult(
                id: id, state: .transcribing, audioTime: AudioTimeRange(start: 0, end: 60), startDate: .now, updatedDate: .now,
                transcript: SpeechTranscript(text: "and I will bring", language: "en-US", isFinal: false, quality: .unknown,
                                             audioTime: AudioTimeRange(start: 56, end: 60)),
                utteranceCount: index, transcriptionAvailability: .available, modelAvailability: .available)
            tentative.volatileText = "and I will bring the"
            receive(tentative)
        }
    }
}
#endif
