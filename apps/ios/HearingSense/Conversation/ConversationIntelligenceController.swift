import ConversationUnderstanding
import HearingSenseAudio
import HearingSenseDomain
import IslandPresentation
import IslandViews
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

    /// `--hs-sample-history` (Debug builds): three invented summaries in a store that exists in
    /// memory only, for layout checks of History and of a summary's page.
    static let sampleHistoryArgument = "--hs-sample-history"

    /// Nothing is read from or written to storage: the demo, and the Window 7 self-test unless
    /// it is asked to check what is stored (`--hs-w7-persist`).
    static var usesMemoryOnly: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return isDemoRequested || arguments.contains(sampleHistoryArgument)
            || (arguments.contains("--hs-w7-selftest") && !arguments.contains("--hs-w7-persist"))
            || (arguments.contains("--hs-w9-selftest") && !arguments.contains("--hs-w9-persist"))
            || arguments.contains("--hs-w9-runtime-probe")
            || arguments.contains("--hs-w9-apple-draft-probe")
            || arguments.contains("--hs-w9-audit-synthetic-history")
            || arguments.contains("--hs-w9-install-cached-model")
        #else
        false
        #endif
    }



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
    /// Summaries the last check before storage refused (they repeated the speech word for word).
    private(set) var summariesNotSaved = 0
    private(set) var lastRecapSeconds: TimeInterval?
    /// Window 9: which engine wrote the latest summary (a name), and why Qwen was not used if it was not.
    private(set) var lastEngineLabel: String?
    private(set) var lastFallbackReason: String?

    // History
    private(set) var history: [ConversationRecord] = []
    private(set) var storageError: String?

    private(set) var isSessionActive = false
    /// "Continue" was pressed while there was no summary yet: follow as soon as one is ready.
    @ObservationIgnored private var continuesWhenReady = false
    private(set) var isTranscriptionOn = false

    /// Where a requested summary stands, for the Live Activity (its expanded presentation offers
    /// Summarize, Continue and Stop by this). nil during ordinary listening.
    @ObservationIgnored var onIslandState: ((IslandConversation?) -> Void)?
    /// The state of "Transcribe nearby speech" (Window 3), read whenever it matters.
    @ObservationIgnored var transcriptionProvider: () -> Bool = { false }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: SwiftDataConversationHistory?
    @ObservationIgnored private let recapEngine: ConversationRecapEngine
    /// Window 9: Qwen first, Apple's model as the fallback (nil for test summarizers).
    @ObservationIgnored private let coordinator: SummarizationCoordinator?
    /// The model is loaded for use soon (speech is buffered) and freed after a quiet time.
    @ObservationIgnored private var residencyTask: Task<Void, Never>?
    @ObservationIgnored private var modelPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var isModelResident = false
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
    init(defaults: UserDefaults = .standard, inMemory: Bool = ConversationIntelligenceController.usesMemoryOnly,
         summarizer: any ConversationSummarizing = SummarizationSetup.makeCoordinator())
    {
        self.defaults = defaults
        coordinator = summarizer as? SummarizationCoordinator
        let policy = ConversationBufferPolicy.standard
        buffer = RollingConversationBuffer(policy: policy)
        // The outer request must allow the coordinator's primary timeout AND fallback.
        // A 25 s outer timeout previously cancelled Qwen before its 40 s fallback threshold.
        var recapPolicy = ConversationRecapEngine.Policy()
        let routingPolicy = SummarizationSetup.routingPolicy
        recapPolicy.timeout = routingPolicy.primaryTimeout + routingPolicy.fallbackTimeout + 1
        #if targetEnvironment(simulator)
        recapPolicy.rewriteTimeout = recapPolicy.timeout
        #endif
        recapEngine = ConversationRecapEngine(summarizer: summarizer, policy: recapPolicy, bufferPolicy: policy)
        var opened: SwiftDataConversationHistory?
        var records: [ConversationRecord] = []
        var problem: String?
        do {
            let history = try SwiftDataConversationHistory(inMemory: inMemory)
            try history.completeInterrupted()
            #if DEBUG
            if inMemory, ProcessInfo.processInfo.arguments.contains(Self.sampleHistoryArgument) {
                for record in Self.sampleHistory { try history.save(record) }
            }
            #endif
            records = try history.all()
            opened = history
        } catch {
            problem = "The summary history could not be opened: \(error.localizedDescription)"
        }
        store = opened
        history = records
        storageError = problem
        Task { [weak self] in
            let isAvailable = await summarizer.isAvailable()
            self?.isLanguageModelAvailable = isAvailable
        }
    }

    #if DEBUG
    private static var sampleHistory: [ConversationRecord] {
        let now = Date.now
        return [
            // A fixed identifier, so that a check can open this page by its link
            // (`hearingsense://summary/00000000-0000-0000-0000-000000000001`).
            ConversationRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Lunch on Friday",
                               summary: "Maya and Jon agreed to meet for lunch on Friday at 12:30 at the noodle place on Fifth Street. "
                                   + "Jon will book a table for four and Maya brings the signed forms for the science fair.",
                               keyPoints: ["Lunch on Friday at 12:30, noodle place on Fifth Street.", "Jon books a table for four.",
                                           "Maya brings the signed science fair forms."],
                               caveats: ["The beginning of the conversation may be missing."],
                               createdAt: now.addingTimeInterval(-900), coveredFrom: now.addingTimeInterval(-1020),
                               coveredTo: now.addingTimeInterval(-900)),
            ConversationRecord(title: "Group report",
                               summary: "The group meets on Saturday at ten in study room 204 of the science building, because the library is closed on weekends. "
                                   + "The graphs should be finished by Friday night.",
                               keyPoints: ["Saturday at ten, science building, room 204.", "Graphs due Friday night."],
                               createdAt: now.addingTimeInterval(-86400 * 2)),
            ConversationRecord(title: "Bus change", summary: "The 14 bus leaves from the north stop this week because of road work.",
                               createdAt: now.addingTimeInterval(-86400 * 5)),
        ]
    }
    #endif

    deinit {
        workTask?.cancel()
        deadlineTask?.cancel()
        residencyTask?.cancel()
        modelPreparationTask?.cancel()
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
        releaseModel()
        log(.recognition, "Conversation: \(recapsMade) summary request(s), \(updatesMade) update(s) this launch")
    }

    /// The user switched "Transcribe nearby speech" (Window 3).
    func transcriptionChanged(isOn: Bool) {
        guard isOn != isTranscriptionOn else { return }
        isTranscriptionOn = isOn
        applyContextPermission()
        if !isOn { releaseModel() }
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
            prepareModelIfUseful()
        }
    }

    // MARK: - Model residency (Window 9)

    /// Speech is being buffered, so a summary may be asked for soon: load the model now, so that
    /// the first request does not wait for it. Loading starts only when enough was said for a
    /// summary, never without transcription, and the model is freed again after a quiet time
    /// (`scheduleModelRelease`).
    private func prepareModelIfUseful() {
        guard let coordinator, !isModelResident, isTranscriptionOn, bufferedWordCount >= ConversationBufferPolicy.standard.minimumWords
        else { return }
        isModelResident = true
        modelPreparationTask = Task {
            guard !Task.isCancelled else { return }
            await coordinator.prewarm()
        }
        scheduleModelRelease()
    }

    /// Frees the model's memory when no summary was asked for and no conversation is followed
    /// for a while (the next request reloads it).
    private func scheduleModelRelease() {
        residencyTask?.cancel()
        guard let coordinator, isModelResident else { return }
        residencyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.modelIdleSeconds))
            guard !Task.isCancelled, let self else { return }
            guard self.phase == .idle else { self.scheduleModelRelease(); return }
            await coordinator.releaseResources()
            self.isModelResident = false
            self.log(.recognition, "Summary model released after \(Int(Self.modelIdleSeconds)) s without a request")
        }
    }

    /// How long the model stays in memory without a request.
    static let modelIdleSeconds: TimeInterval = 180

    private func releaseModel() {
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        residencyTask?.cancel()
        residencyTask = nil
        isModelResident = false
        if let coordinator { Task { await coordinator.releaseResources() } }
    }

    #if DEBUG
    /// Engine metadata only; never a prompt or response.
    func summarizationAttempts() async -> [SummarizationCoordinator.Attempt] {
        await coordinator?.lastAttempts ?? []
    }
    #endif

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
        case (.continuing, _): return "Following the conversation. Its summary is kept up to date."
        default: return unavailableMessage ?? "No summary could be written."
        }
    }

    /// "Continue": keep following the conversation — live captions and a summary that grows.
    /// Following starts from a summary, so when there is none yet (the button is offered beside
    /// "Summary" from the start) one is written first and following begins when it is ready.
    func continueUnderstanding() {
        switch phase {
        case .summaryAvailable:
            run(machine.process(.continueSelected(at: .now)))
        case .idle:
            continuesWhenReady = true
            summarize()
            // Nothing could be started (not listening, transcription off).
            if phase == .idle { continuesWhenReady = false }
        case .preparing, .summarizing:
            continuesWhenReady = true
        case .continuing:
            break
        }
    }

    func stopUnderstanding() {
        continuesWhenReady = false
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
                    self.lastEngineLabel = recap.engineLabel
                    self.lastFallbackReason = recap.fallbackReason
                    if recap.engines.contains(where: { $0.kind == .qwen }) { self.isModelResident = true }
                    self.scheduleModelRelease()
                    self.log(.recognition, "Recap: \(recap.source.rawValue), engine \(recap.engineLabel ?? "none")"
                        + "\(recap.fallbackReason.map { " (fallback: \($0))" } ?? ""), \(excerpt.utterances.count) utterance(s), "
                        + "\(excerpt.wordCount) words, model \(Self.seconds(recap.modelSeconds)), "
                        + "\(recap.corrections.count) correction(s)" + Self.tally(recap.corrections))
                    self.run(self.machine.process(.recapReady(recap, at: .now)))
                    // "Continue" was pressed before there was a summary.
                    if self.continuesWhenReady {
                        self.continuesWhenReady = false
                        if self.phase == .summaryAvailable { self.run(self.machine.process(.continueSelected(at: .now))) }
                    }
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
                    if let updated {
                        self.updatesMade += 1
                        self.lastEngineLabel = updated.engineLabel
                        self.lastFallbackReason = updated.fallbackReason ?? self.lastFallbackReason
                    }
                    self.scheduleModelRelease()
                    if updated != nil {
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
        // The last check before anything is written, whatever path the text took: a text that
        // repeats too much of the words still held in memory is not a summary and is not stored.
        // An earlier saved version of this summary stays as it is.
        guard recapEngine.maySave(recap, transcript: recapTranscript) else {
            summariesNotSaved += 1
            storageError = "This summary repeated too much of what was said word for word, so it was not saved."
            log(.error, "A summary was not saved: it failed the word-for-word check before storage")
            return
        }
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
    ///
    /// The island gets a preview, not the summary: whole sentences chosen from the finished
    /// summary (`IslandSummaryPreview`), as many as fill three lines of 17-point text; the
    /// island shows no title of the model's. The full summary stays as it is, in `recap` and in History;
    /// "Open" leads to it (`recordID`).
    private func islandPreview(newestFirst: Bool) -> String? {
        guard let recap else { return nil }
        guard recap.isSummary else { return recap.summary }
        let preview = IslandSummaryPreview.body(summary: recap.summary, keyPoints: recap.keyPoints, newestFirst: newestFirst,
                                                fits: Self.fitsIslandPreview)
        return preview.isEmpty ? nil : preview
    }

    /// Whether `text` fills at most the preview's lines in the island's own font (body, at the
    /// user's text size up to the island's cap) and width.
    static func fitsIslandPreview(_ text: String) -> Bool {
        let preferred = UIApplication.shared.preferredContentSizeCategory
        let category = preferred > .extraLarge ? .extraLarge : preferred
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: IslandMetrics.previewWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        return Int((bounds.height / font.lineHeight).rounded()) <= IslandMetrics.previewLines
    }

    private func publishIslandState() {
        let state: IslandConversation? = switch status {
        case nil:
            nil
        case .preparingRecap, .summarizing:
            IslandConversation(phase: .summarizing, title: "Summarizing", since: statusSince)
        case .summarySaved, .summaryAvailable:
            IslandConversation(phase: .summaryReady, title: "Summary Ready", detail: islandPreview(newestFirst: false),
                               recordID: currentRecordID, since: statusSince)
        case .continuing:
            IslandConversation(phase: .following, title: "Following Conversation", detail: islandPreview(newestFirst: true),
                               recordID: currentRecordID, since: statusSince)
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

    /// " (copied_from_transcript ×2, unsupported_name ×1)": the names of the checks that removed
    /// something, never what they removed.
    static func tally(_ corrections: [String]) -> String {
        guard !corrections.isEmpty else { return "" }
        let counts = Dictionary(grouping: corrections, by: \.self).mapValues(\.count)
        return " (" + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + ")"
    }

    static func seconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " s"
    }

    static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return seconds % 60 == 0 ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" : "\(seconds) seconds"
    }

    /// Counts, states and timings. No utterance, no summary.
    func reportText() -> String {
        var engineLines: [String] = []
        if let coordinator {
            engineLines.append("Summary engines (Window 9): " + coordinator.identities.map(\.detail).joined(separator: " → fallback ")
                + " · last summary by \(lastEngineLabel ?? "–")" + (lastFallbackReason.map { " (fallback: \($0))" } ?? "")
                + " · model preparation requested: \(isModelResident ? "yes" : "no")")
            engineLines.append("Qwen execution backend: \(SummarizationSetup.backendDescription)")
        }
        return (engineLines + [
            "Conversation summaries (Window 7)",
            "Continuous semantic relevance inference: not part of this build · language model "
                + "\(isLanguageModelAvailable ? "available" : "not available") (used only for summaries the user asks for)",
            "Recent speech for summaries: \(isTranscriptionOn ? "kept in memory" : "not kept (transcription off)") · look-back \(Int(lookBack)) s · "
                + "buffered \(captions.count) utterance(s), \(bufferedWordCount) words, expired \(buffer.expiredUtterances)",
            "Phase: \(phase.rawValue) · summary requests \(recapsMade) · updates \(updatesMade) · refused before storage \(summariesNotSaved) · last summary model time "
                + "\(lastRecapSeconds.map(Self.seconds) ?? "–") · saved summaries \(history.count)",
        ]).joined(separator: "\n")
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
