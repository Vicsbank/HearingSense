import Foundation
import HearingSenseDomain

/// Decides which confirmed sounds and speech events deserve the user's attention.
///
/// A deterministic state machine over value types: the same inputs in the same order give the
/// same decisions. It reads no clock (every input carries its time), performs no I/O, calls no
/// model, and depends only on `HearingSenseDomain`, so it runs unchanged in the app (foreground
/// or background), in tests and in the replay tool.
///
/// Flow per input: advance time (stale sources, expirations, deferred presentations) → attach
/// the input to an episode (existing, rejoined, fused or new) → assess the episode's priority
/// with reason codes → schedule (`AttentionAction`) → emit an `AttentionDecision`, with a
/// `AttentionPresentationIntent` whenever something shown changes.
///
/// All state is bounded: `AttentionConfiguration.maximumEpisodes` episodes, a bounded number of
/// sources per episode, one memory entry per sound kind.
public struct AttentionEngine: Sendable {
    static let speechKey = AttentionConfiguration.speechKindID

    public let configuration: AttentionConfiguration
    public private(set) var preferences: AttentionPreferences
    public private(set) var statistics = AttentionStatistics()

    private var clock: Date?
    private var nextEpisode = 1
    private var nextDecision = 1
    private var episodes: [AttentionEventID: Episode] = [:]
    private var soundIndex: [AcousticEventID: AttentionEventID] = [:]
    private var speechIndex: [SpeechEventID: AttentionEventID] = [:]
    private var memory: [String: KindMemory] = [:]
    /// Times of recent presentations below `high` (the presentation budget).
    private var recentShows: [Date] = []
    /// Window 6: statements presented as goal matches a short while ago (their signatures only).
    private var goalMemory: [(signature: SemanticSignature, date: Date)] = []
    private var output: [AttentionDecision] = []

    public init(configuration: AttentionConfiguration = .standard, preferences: AttentionPreferences = .default) {
        self.configuration = configuration
        self.preferences = preferences
    }

    // MARK: - State

    private struct SoundState: Hashable, Sendable {
        var kind: SoundEventKind
        var quality: EventQuality
        var supportingWindows: Int
        var started: Date
        var lastObserved: Date
        var ended: Date?
    }

    private enum Pending: Hashable, Sendable {
        /// A conditional sound or ordinary speech that is not sustained yet.
        case condition
        /// Waiting for the presentation budget.
        case budget(since: Date)
        /// A content update held back by the update interval.
        case update
    }

    private struct Episode: Sendable {
        var event: AttentionEvent
        /// The sound this episode is about; nil when it is led by speech.
        var leadKind: SoundEventKind?
        var sounds: [AcousticEventID: SoundState] = [:]
        var speechID: SpeechEventID?
        var speech: SpeechFacts?
        var speechFirstObserved: Date?
        var speechLastObserved: Date?
        var speechEnded: Date?
        /// Once speech in this episode looked like a warning, later ordinary sentences of the
        /// same conversation do not lower it.
        var importantFloor: AttentionPriority?
        /// Window 6: the episode is a goal match from the semantic engine (no sound, no
        /// conversation attached).
        var semantic: SemanticAttentionSignal?
        var occurrenceDates: [Date] = []
        var lastUpdate: Date?
        var peakPresented = AttentionPriority.ambient
        var presentedContent: AttentionPrivateContent?
        var presentedSignature: SemanticSignature?
        var presentedTier: SpeechAssessment.Tier?
        /// The summary revision last reported as a rewording, so it is reported once.
        var cosmeticRevision: Int?
        var pending: Pending?
        /// When the last source ended; nil while one is active.
        var allEnded: Date?
        /// The presentation of this id is over, but its sources are still followed so that they
        /// do not alert again.
        var isTracker = false
        var lastAction: AttentionAction?
    }

    private struct KindMemory: Sendable {
        /// The latest episode created for this kind (a recurrence may join it).
        var episode: AttentionEventID?
        var lastPresented: Date?
        var lastPresentedBy: AttentionEventID?
    }

    private struct Assessment {
        var priority = AttentionPriority.ambient
        var reasons: [AttentionReason] = []
        var conditionPending = false
        var category = AttentionCategory.other
        var kindID: String?
        var title = ""
        var subtitle: String?
        var isUncertain = false
        var content: AttentionPrivateContent?
        var signature: SemanticSignature?
        var speechTier: SpeechAssessment.Tier?
        var cooldownKey: String?
        var cooldown: TimeInterval = 0
        /// Overrides the category's symbol.
        var symbolName: String?
        /// Warning signals are held back neither by a cooldown nor by the presentation budget.
        var bypassesCooldown = false
    }

    private enum ContentChange {
        case none, added, removed, cosmetic, refined
        case critical(negation: Bool)
    }

    private var tuning: ModeTuning { configuration.tuning[preferences.mode] }
    private var now: Date { clock ?? .distantPast }

    // MARK: - Input

    /// Applies one input and returns the decisions it caused, in order.
    @discardableResult
    public mutating func process(_ input: AttentionInput) -> [AttentionDecision] {
        statistics.inputs += 1
        output.removeAll(keepingCapacity: true)
        advance(to: max(input.date, clock ?? input.date))
        switch input {
        case .sessionStarted:
            endSession(reason: .sessionEnded)
            memory.removeAll()
            recentShows.removeAll()
        case .sessionEnded:
            endSession(reason: .sessionEnded)
        case .sound(let update):
            statistics.soundInputs += 1
            handle(update)
        case .speech(let result):
            statistics.speechInputs += 1
            handle(result)
        case .semantic(let signal):
            statistics.semanticInputs += 1
            handle(signal)
        case .preferences(let updated, _):
            apply(updated)
        case .speechDataCleared:
            clearSpeech()
        case .tick:
            break
        }
        purge()
        statistics.maximumEpisodes = max(statistics.maximumEpisodes, episodes.count)
        statistics.maximumDeferred = max(statistics.maximumDeferred, episodes.values.count { $0.pending != nil })
        return output
    }

    /// The next time at which something changes without a new input (an expiration, a deferred
    /// presentation, a stale source). The host sends `.tick` then; nil when nothing is pending.
    public var nextDeadline: Date? {
        var deadlines: [Date] = []
        for episode in episodes.values {
            for state in episode.sounds.values where state.ended == nil {
                deadlines.append(state.lastObserved.addingTimeInterval(configuration.soundStaleAfter))
            }
            if episode.speechID != nil, episode.speechEnded == nil, let last = episode.speechLastObserved {
                deadlines.append(last.addingTimeInterval(configuration.speech.staleAfter))
            }
            if episode.event.isPresented, let expires = episode.event.expiresAt { deadlines.append(expires) }
            switch episode.pending {
            case .budget(let since):
                deadlines.append(since.addingTimeInterval(configuration.maximumDeferral))
                if let ended = episode.allEnded { deadlines.append(ended.addingTimeInterval(configuration.deferredGrace)) }
                if let oldest = recentShows.first { deadlines.append(oldest.addingTimeInterval(tuning.budgetWindow)) }
            case .update:
                if let last = episode.lastUpdate { deadlines.append(last.addingTimeInterval(tuning.minimumUpdateInterval)) }
            case .condition:
                if episode.leadKind == nil, let first = episode.speechFirstObserved {
                    deadlines.append(first.addingTimeInterval(configuration.speech.sustainedAfter))
                }
            case nil:
                break
            }
        }
        return deadlines.filter { $0 > now }.min()
    }

    /// Current state for display and diagnostics.
    public var snapshot: AttentionSnapshot {
        let all = episodes.keys.sorted().compactMap { episodes[$0] }
        let presented = all.filter(\.event.isPresented).map(\.event).sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        let scale = tuning.cooldownScale
        var cooldowns: [AttentionCooldown] = []
        for key in memory.keys.sorted() {
            guard let last = memory[key]?.lastPresented else { continue }
            let duration = key == Self.speechKey ? configuration.speech.cooldown
                : (configuration.kinds[key].flatMap { configuration.profiles[$0.profile] }?.cooldown ?? 0)
            let until = last.addingTimeInterval(duration * scale)
            if until > now { cooldowns.append(AttentionCooldown(id: key, until: until)) }
        }
        return AttentionSnapshot(date: now, mode: preferences.mode, presented: presented,
                                 tracked: all.filter { !$0.event.isPresented }.map(\.event),
                                 deferred: all.filter { $0.pending != nil }.map(\.event.id),
                                 cooldowns: cooldowns, budgetUsed: budgetUsed, budgetLimit: tuning.presentationBudget,
                                 statistics: statistics)
    }

    // MARK: - Time

    private mutating func advance(to date: Date) {
        clock = date
        let budgetWindow = tuning.budgetWindow
        recentShows.removeAll { date.timeIntervalSince($0) >= budgetWindow }

        for id in episodes.keys.sorted() {
            guard var episode = episodes[id] else { continue }
            // Sources that stopped reporting (classifier stalled, session interrupted).
            var stale = false
            for key in episode.sounds.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                guard var state = episode.sounds[key], state.ended == nil,
                      date.timeIntervalSince(state.lastObserved) >= configuration.soundStaleAfter else { continue }
                state.ended = date
                episode.sounds[key] = state
                markEnded(.sound(id: key, kindID: state.kind.id), in: &episode, at: date)
                stale = true
            }
            if let speechID = episode.speechID, episode.speechEnded == nil, let last = episode.speechLastObserved,
               date.timeIntervalSince(last) >= configuration.speech.staleAfter
            {
                episode.speechEnded = date
                markEnded(.speech(id: speechID), in: &episode, at: date)
                stale = true
            }
            if stale {
                statistics.staleSources += 1
                episodes[id] = episode
                resolveIfEnded(id, trigger: .timer, reason: .sourceStale)
            }
        }

        for id in episodes.keys.sorted() {
            guard let episode = episodes[id] else { continue }
            if episode.event.isPresented, let expires = episode.event.expiresAt, date >= expires {
                endPresentation(id, reasons: [episode.allEnded != nil ? .sourceEnded : .presentationTimeout],
                                trigger: .timer)
            }
        }

        // Deferred presentations: most important first, then oldest.
        let waiting = episodes.values.filter { $0.pending != nil }.sorted {
            $0.event.priority != $1.event.priority ? $0.event.priority > $1.event.priority : $0.event.id < $1.event.id
        }.map(\.event.id)
        for id in waiting {
            guard var episode = episodes[id], let pending = episode.pending else { continue }
            switch pending {
            case .budget(let since):
                let tooOld = date.timeIntervalSince(since) >= configuration.maximumDeferral
                let gone = episode.allEnded.map { date.timeIntervalSince($0) >= configuration.deferredGrace } ?? false
                if tooOld || gone {
                    episode.pending = nil
                    episode.isTracker = true
                    episode.event.lifecycle = .expired
                    episodes[id] = episode
                    emit(.expire, id, reasons: [.deferredExpired, gone ? .sourceEnded : .rateLimited], trigger: .timer)
                } else if budgetUsed < tuning.presentationBudget {
                    evaluate(id, trigger: .timer, announce: false)
                }
            case .update:
                guard let last = episode.lastUpdate, date.timeIntervalSince(last) >= tuning.minimumUpdateInterval else { break }
                episode.pending = nil
                episode.lastUpdate = nil
                episodes[id] = episode
                evaluate(id, trigger: .timer, announce: false)
            case .condition:
                if episode.leadKind == nil { evaluate(id, trigger: .timer, announce: false) }
            }
        }

        purge()
    }

    /// Forgets episodes that are neither shown nor waiting and whose sources all ended.
    private mutating func purge() {
        for id in episodes.keys.sorted() {
            guard let episode = episodes[id], !episode.event.isPresented, episode.pending == nil,
                  episode.allEnded != nil else { continue }
            remove(id)
        }
    }

    private var budgetUsed: Int { recentShows.count }

    // MARK: - Sound

    private mutating func handle(_ update: AcousticEventUpdate) {
        let event = update.event
        let trigger = AttentionTrigger.sound(kindID: event.kind.id, phase: event.phase)
        let isEnd: Bool = if case .ended = update { true } else { false }

        if let id = soundIndex[event.id], var episode = episodes[id] {
            var state = episode.sounds[event.id] ?? soundState(event)
            state.quality = max(state.quality, event.quality)
            state.supportingWindows = max(state.supportingWindows, event.evidence.supportingWindows)
            state.lastObserved = max(state.lastObserved, event.lastObservedDate)
            if isEnd { state.ended = now }
            episode.sounds[event.id] = state
            let source = AttentionSourceRecord.Source.sound(id: event.id, kindID: event.kind.id)
            if isEnd {
                markEnded(source, in: &episode, at: now)
            } else if let index = episode.event.sources.firstIndex(where: { $0.source == source }) {
                episode.event.sources[index].lastObserved = state.lastObserved
            }
            episodes[id] = episode
            if isEnd {
                resolveIfEnded(id, trigger: trigger, reason: .sourceEnded)
                // An end can still change what is shown (a speech-led episode losing its sound).
                if episodes[id]?.allEnded == nil { evaluate(id, trigger: trigger, announce: false) }
            } else {
                evaluate(id, trigger: trigger, announce: true)
            }
            return
        }
        guard !isEnd else { return }  // the end of an event this engine never saw

        if event.kind.id == Self.speechKey {
            attachSpeechSound(event, trigger: trigger)
            return
        }

        let profile = configuration.profile(for: event.kind)
        // The same kind again, while its episode is still alive: one episode, one more occurrence.
        if let id = memory[event.kind.id]?.episode, var episode = episodes[id], episode.leadKind?.id == event.kind.id,
           episode.allEnded.map({ now.timeIntervalSince($0) <= profile.rejoinWindow }) ?? true
        {
            attach(event, to: &episode)
            episode.event.occurrences += 1
            episode.occurrenceDates.append(event.startDate)
            if episode.occurrenceDates.count > configuration.maximumOccurrencesRemembered {
                episode.occurrenceDates.removeFirst(episode.occurrenceDates.count - configuration.maximumOccurrencesRemembered)
            }
            reopen(&episode)
            episodes[id] = episode
            soundIndex[event.id] = id
            statistics.rejoins += 1
            evaluate(id, trigger: trigger, extra: [.repeatedEvent, .continuationOfRecent], structural: true, announce: true)
            return
        }

        let assignment = configuration.assignment(for: event.kind)
        var episode = newEpisode(category: assignment.category, kindID: event.kind.id, title: event.kind.displayName)
        episode.leadKind = event.kind
        episode.occurrenceDates = [event.startDate]
        attach(event, to: &episode)
        let id = episode.event.id
        episodes[id] = episode
        soundIndex[event.id] = id
        memory[event.kind.id, default: KindMemory()].episode = id
        absorbPrecedingSpeech(into: id, soundStart: event.startDate)
        evaluate(id, trigger: trigger, announce: true)
        enforceCapacity(keeping: id)
    }

    /// The sound classifier's own `speech` event: evidence for a speech episode, never a second one.
    private mutating func attachSpeechSound(_ event: ConfirmedAcousticEvent, trigger: AttentionTrigger) {
        let candidates = episodes.values.filter { $0.speech != nil && !$0.isTracker }
            .filter { $0.allEnded.map { now.timeIntervalSince($0) <= configuration.speech.rejoinWindow } ?? true }
            .sorted { $0.event.id > $1.event.id }
        if var episode = candidates.first {
            let id = episode.event.id
            attach(event, to: &episode)
            reopen(&episode)
            episodes[id] = episode
            soundIndex[event.id] = id
            evaluate(id, trigger: trigger, announce: false)
            return
        }
        // No speech pipeline result (yet): a generic speech episode from the classifier alone.
        var episode = newEpisode(category: .speech, kindID: nil, title: SpeechAssessment.ordinaryTitle)
        episode.speech = .soundOnly
        episode.speechFirstObserved = now
        attach(event, to: &episode)
        let id = episode.event.id
        episodes[id] = episode
        soundIndex[event.id] = id
        if !fuseSpeechEpisode(id, trigger: trigger) {
            evaluate(id, trigger: trigger, announce: true)
            enforceCapacity(keeping: id)
        }
    }

    private func soundState(_ event: ConfirmedAcousticEvent) -> SoundState {
        SoundState(kind: event.kind, quality: event.quality, supportingWindows: event.evidence.supportingWindows,
                   started: event.startDate, lastObserved: event.lastObservedDate, ended: nil)
    }

    private mutating func attach(_ event: ConfirmedAcousticEvent, to episode: inout Episode) {
        episode.sounds[event.id] = soundState(event)
        episode.event.sources.append(AttentionSourceRecord(source: .sound(id: event.id, kindID: event.kind.id),
                                                           firstObserved: event.startDate,
                                                           lastObserved: event.lastObservedDate))
        trimSources(&episode)
    }

    /// Keeps the source list bounded: the oldest ended sources go first.
    private mutating func trimSources(_ episode: inout Episode) {
        while episode.event.sources.count > configuration.maximumSourcesPerEpisode {
            let index = episode.event.sources.firstIndex { !$0.isActive } ?? 0
            let removed = episode.event.sources.remove(at: index)
            if case .sound(let id, _) = removed.source {
                episode.sounds[id] = nil
                soundIndex[id] = nil
            }
        }
    }

    private func markEnded(_ source: AttentionSourceRecord.Source, in episode: inout Episode, at date: Date) {
        guard let index = episode.event.sources.firstIndex(where: { $0.source == source }) else { return }
        episode.event.sources[index].ended = date
    }

    /// A source came back while the episode was resolved.
    private func reopen(_ episode: inout Episode) {
        guard episode.allEnded != nil else { return }
        episode.allEnded = nil
        if episode.event.lifecycle == .resolved {
            episode.event.lifecycle = .updated
            if episode.event.isPresented { episode.event.expiresAt = now.addingTimeInterval(lifetime(of: episode)) }
        }
    }

    // MARK: - Speech

    private mutating func handle(_ result: SpeechSemanticResult) {
        let facts = SpeechFacts(result, policy: configuration.speech)
        let trigger = AttentionTrigger.speech(state: result.state, level: result.level.rawValue,
                                              summaryRevision: result.summaryRevision)
        if let id = speechIndex[result.id], var episode = episodes[id] {
            let unchanged = episode.speech == facts
            episode.speech = facts
            episode.speechLastObserved = now
            noteImportance(of: facts, in: &episode)
            let source = AttentionSourceRecord.Source.speech(id: result.id)
            if let index = episode.event.sources.firstIndex(where: { $0.source == source }) {
                episode.event.sources[index].lastObserved = now
            }
            if result.state.isTerminal, episode.speechEnded == nil {
                episode.speechEnded = now
                markEnded(source, in: &episode, at: now)
            }
            episodes[id] = episode
            if unchanged, episode.pending != .condition {
                statistics.speechProgressIgnored += 1
            } else {
                evaluate(id, trigger: trigger, announce: false)
            }
            resolveIfEnded(id, trigger: trigger, reason: .sourceEnded)
            return
        }
        guard !result.state.isTerminal else { return }  // a conversation this engine never saw

        // A speech episode that has no conversation attached (classifier only), or whose
        // conversation just ended: the same stretch of speech goes on.
        let open = episodes.values.filter { $0.speech != nil && !$0.isTracker }
            .filter { $0.speechID == nil || $0.speechEnded != nil }
            .filter { $0.allEnded.map { now.timeIntervalSince($0) <= configuration.speech.rejoinWindow } ?? true }
            .sorted { $0.event.id > $1.event.id }
        if var episode = open.first {
            let id = episode.event.id
            let continues = episode.speechID != nil
            attachSpeech(result, facts: facts, to: &episode, keepFirstObserved: true)
            reopen(&episode)
            episodes[id] = episode
            speechIndex[result.id] = id
            if continues { statistics.rejoins += 1 }
            evaluate(id, trigger: trigger, extra: continues ? [.continuationOfRecent] : [], announce: false)
            return
        }

        var episode = newEpisode(category: .speech, kindID: nil, title: SpeechAssessment.ordinaryTitle)
        attachSpeech(result, facts: facts, to: &episode, keepFirstObserved: false)
        let id = episode.event.id
        episodes[id] = episode
        speechIndex[result.id] = id
        if !fuseSpeechEpisode(id, trigger: trigger) {
            evaluate(id, trigger: trigger, announce: true)
            enforceCapacity(keeping: id)
        }
    }

    // MARK: - Goal matches (Window 6)

    public static let goalMatchTitle = "Matches Your Goal"
    public static let goalMatchKindID = "goal_match"
    public static let goalMatchSymbol = "star.bubble"
    /// Shown in place of a headline that could not be verified against what was said.
    public static let goalMatchFallbackText = "Open Hearing Sense to read what was said"

    /// A goal match is an episode of its own: it has no source that goes on, so it is shown for
    /// the lifetime of its priority and then removed. The semantic engine decided that the
    /// statement matters; here it is checked against preferences, repetition and the budget.
    private mutating func handle(_ signal: SemanticAttentionSignal) {
        let signature = SemanticSignature(text: signal.statement, isNegated: false)
        let date = now, window = configuration.speech.goalRepeatWindow
        let similarity = configuration.speech.sameMeaningSimilarity
        goalMemory.removeAll { date.timeIntervalSince($0.date) > window }
        let isRepeat = goalMemory.contains {
            $0.signature.change(to: signature, sameMeaningSimilarity: similarity) == .cosmetic
        }
        var episode = newEpisode(category: .speech, kindID: Self.goalMatchKindID, title: Self.goalMatchTitle)
        episode.semantic = signal
        let id = episode.event.id
        episodes[id] = episode
        if isRepeat {
            statistics.semanticRepeats += 1
            emit(.suppress, id, reasons: [.goalMatch, .repeatedStatement, .recentlySeen], trigger: .semantic)
        } else {
            evaluate(id, trigger: .semantic, announce: true)
            if episodes[id]?.event.isPresented == true || episodes[id]?.pending != nil {
                goalMemory.append((signature, now))
            }
        }
        // Nothing keeps going: once its presentation is over (or if it was never shown) the
        // episode is forgotten.
        if var stored = episodes[id] {
            stored.allEnded = now
            episodes[id] = stored
        }
        enforceCapacity(keeping: id)
    }

    private mutating func attachSpeech(_ result: SpeechSemanticResult, facts: SpeechFacts, to episode: inout Episode,
                                       keepFirstObserved: Bool)
    {
        episode.speechID = result.id
        episode.speech = facts
        if !keepFirstObserved || episode.speechFirstObserved == nil { episode.speechFirstObserved = now }
        episode.speechLastObserved = now
        episode.speechEnded = nil
        noteImportance(of: facts, in: &episode)
        episode.event.sources.append(AttentionSourceRecord(source: .speech(id: result.id), firstObserved: now,
                                                           lastObserved: now))
        trimSources(&episode)
    }

    private func noteImportance(of facts: SpeechFacts, in episode: inout Episode) {
        let assessment = SpeechAssessment.assess(facts, preferences: preferences)
        if assessment.tier == .important {
            episode.importantFloor = max(episode.importantFloor ?? .ambient, assessment.priority)
        }
    }

    // MARK: - Temporal fusion

    /// Moves a new speech-led episode into a presented episode it closely follows (a knock, a
    /// ringing phone). Proximity only: nothing here says the two are related.
    private mutating func fuseSpeechEpisode(_ id: AttentionEventID, trigger: AttentionTrigger) -> Bool {
        guard let speechEpisode = episodes[id], let facts = speechEpisode.speech,
              SpeechAssessment.assess(facts, preferences: preferences).tier != .irrelevant,
              let observed = speechEpisode.speechFirstObserved else { return false }
        let anchors = episodes.values.filter { anchor in
            guard anchor.event.id != id, anchor.event.isPresented, !anchor.isTracker, anchor.speech == nil,
                  let kind = anchor.leadKind, canFuse(anchor: configuration.assignment(for: kind).category),
                  let start = anchor.sounds.values.map(\.started).min(),
                  let last = anchor.sounds.values.map(\.lastObserved).max() else { return false }
            return observed >= start.addingTimeInterval(-configuration.fusionOnsetTolerance)
                && observed.timeIntervalSince(last) <= configuration.fusionWindow
        }.sorted { $0.event.id > $1.event.id }
        guard let anchor = anchors.first else { return false }
        merge(speechFrom: id, into: anchor.event.id, trigger: trigger)
        return true
    }

    /// The reverse order of arrival: the sound is confirmed a moment after speech that began
    /// after the sound started was first reported.
    private mutating func absorbPrecedingSpeech(into id: AttentionEventID, soundStart: Date) {
        guard let anchor = episodes[id], let kind = anchor.leadKind,
              canFuse(anchor: configuration.assignment(for: kind).category) else { return }
        let assessment = assess(anchor)
        guard assessment.priority >= tuning.surfaceThreshold, assessment.priority > .ambient else { return }
        let followers = episodes.values.filter { candidate in
            guard candidate.event.id != id, candidate.leadKind == nil, !candidate.isTracker, candidate.allEnded == nil,
                  let facts = candidate.speech, let observed = candidate.speechFirstObserved,
                  SpeechAssessment.assess(facts, preferences: preferences).tier != .irrelevant else { return false }
            return observed >= soundStart.addingTimeInterval(-configuration.fusionOnsetTolerance)
        }.sorted { $0.event.id > $1.event.id }
        guard let follower = followers.first else { return }
        merge(speechFrom: follower.event.id, into: id, trigger: .sound(kindID: kind.id, phase: .confirmed),
              evaluates: false)
    }

    private func canFuse(anchor category: AttentionCategory) -> Bool {
        configuration.fusionAffinities.contains { $0.anchor == category && $0.follower == .speech }
    }

    private mutating func merge(speechFrom sourceID: AttentionEventID, into targetID: AttentionEventID,
                                trigger: AttentionTrigger, evaluates: Bool = true)
    {
        guard let source = episodes[sourceID], var target = episodes[targetID] else { return }
        if source.event.isPresented {
            endPresentation(sourceID, reasons: [.temporalFusion, .mergedIntoEpisode], trigger: trigger, removes: false)
        }
        target.speechID = source.speechID
        target.speech = source.speech
        target.speechFirstObserved = source.speechFirstObserved
        target.speechLastObserved = source.speechLastObserved
        target.speechEnded = source.speechEnded
        target.importantFloor = source.importantFloor
        for (key, state) in source.sounds { target.sounds[key] = state }
        target.event.sources.append(contentsOf: source.event.sources)
        target.event.sources.sort { $0.firstObserved < $1.firstObserved }
        reopen(&target)
        trimSources(&target)
        episodes[targetID] = target
        episodes[sourceID] = nil
        for (key, value) in soundIndex where value == sourceID { soundIndex[key] = targetID }
        for (key, value) in speechIndex where value == sourceID { speechIndex[key] = targetID }
        statistics.fusions += 1
        if evaluates { evaluate(targetID, trigger: trigger, extra: [.temporalFusion], structural: true, announce: true) }
    }

    // MARK: - Priority assessment

    /// The episode's priority and how it was reached. Uses the ordinal evidence quality from
    /// Window 2 only to gate (`urgent` needs more than weak evidence, a conditional sound needs
    /// sustained evidence); a higher classifier score never raises importance.
    private func assess(_ episode: Episode) -> Assessment {
        var result = Assessment()
        let mode = preferences.mode

        if let signal = episode.semantic {
            result.category = .speech
            result.kindID = Self.goalMatchKindID
            result.title = Self.goalMatchTitle
            result.symbolName = Self.goalMatchSymbol
            result.isUncertain = signal.isUncertain
            if preferences.speech == .off || preferences.setting(for: .speech) == .muted {
                result.reasons = [.goalMatch, preferences.speech == .off ? .speechAttentionOff : .userMuted]
                return result
            }
            // The user asked for this in their own words: it is presented in every mode. Only an
            // urgent statement interrupts; an uncertain one never does.
            result.priority = signal.urgency == .high && !signal.isUncertain ? .high
                : max(.normal, tuning.surfaceThreshold)
            result.reasons = [.goalMatch, .relevantSpeech]
            if signal.urgency == .high { result.reasons.append(.importantSpeech) }
            result.speechTier = .informative
            // Always something to read: the island presents speech only when it has text (Window
            // 5's rule), and a match whose headline failed the checks must still be noticed.
            let text = signal.headline.isEmpty ? Self.goalMatchFallbackText : signal.headline
            result.content = AttentionPrivateContent(text: text, summaryRevision: 1, isNegated: false, isQuestion: false)
            result.signature = SemanticSignature(text: text, isNegated: false)
            return result
        }

        var speech: SpeechAssessment?
        var isMusicAmbiguous = false
        if let facts = episode.speech {
            var assessment = SpeechAssessment.assess(facts, preferences: preferences)
            if assessment.tier == .ordinary, facts.relevance == nil, isMusicActive {
                // Voice-like sound while music is playing, and the speech pipeline has not said
                // yet whether it is speech or singing: not presented as speech until it has.
                assessment.priority = .ambient
                assessment.isConditional = false
                assessment.reasons += [.musicContext, .musicAmbiguity]
                assessment.isUncertain = true
                isMusicAmbiguous = true
            } else if assessment.tier != .irrelevant {
                if assessment.isConditional {
                    let sustained = facts.utteranceCount > 0 || episode.sounds.values.contains { $0.supportingWindows >= 3 }
                        || (episode.speechFirstObserved.map { now.timeIntervalSince($0) >= configuration.speech.sustainedAfter } ?? false)
                    if sustained {
                        assessment.priority = .normal
                        assessment.reasons.append(.conditionMet)
                    } else {
                        assessment.reasons.append(.conditionPending)
                    }
                    assessment.isConditional = !sustained
                }
                if let floor = episode.importantFloor, assessment.priority < floor {
                    assessment.priority = floor
                    assessment.tier = .important
                    assessment.title = SpeechAssessment.warningTitle
                    if !assessment.reasons.contains(.importantSpeech) { assessment.reasons.append(.importantSpeech) }
                }
            }
            speech = assessment
        }

        guard let kind = episode.leadKind else {
            guard let speech else { return result }
            result.priority = speech.priority
            result.reasons = speech.reasons
            result.conditionPending = speech.isConditional
            result.category = .speech
            result.title = speech.title
            result.isUncertain = speech.isUncertain
            result.content = speech.privateContent
            result.signature = speech.signature
            result.speechTier = speech.tier
            if speech.tier == .ordinary {
                result.cooldownKey = Self.speechKey
                result.cooldown = configuration.speech.cooldown
            }
            return result
        }

        let assignment = configuration.assignment(for: kind)
        let profile = configuration.profile(for: kind)
        let setting = preferences.setting(for: assignment.category)
        let states = episode.sounds.values.filter { $0.kind.id == kind.id }
        let quality = states.map(\.quality).max() ?? .weak
        let windows = states.reduce(0) { $0 + $1.supportingWindows }
        result.category = assignment.category
        result.kindID = kind.id
        result.title = kind.displayName
        result.cooldownKey = kind.id
        result.cooldown = profile.cooldown

        if setting == .muted {
            result.reasons = [.userMuted]
        } else {
            var priority = setting.fixedPriority ?? profile.base[mode]
            if setting.fixedPriority != nil {
                result.reasons.append(.userPriorityOverride)
            } else if assignment.category == .music, priority == .ambient {
                result.reasons += [.musicContext, .lowRelevance]
            } else if profile.isMinor {
                result.reasons += [.minorSound, .lowRelevance]
            } else if priority == .ambient {
                result.reasons.append(.ambientSound)
            } else if profile.isSafetyRelevant {
                if priority == .urgent { result.reasons.append(.urgentSignal) }
                result.reasons.append(.safetyRelevant)
            } else {
                result.reasons.append(.categoryDefault)
            }

            if priority > .ambient {
                switch quality {
                case .weak:
                    // A warning signal on thin evidence is still shown, one level lower, and
                    // rises when the evidence does.
                    if priority == .urgent { priority = .high }
                    result.reasons.append(.weakEvidence)
                    result.isUncertain = true
                case .strong:
                    result.reasons.append(.strongEvidence)
                case .moderate:
                    break
                }
            }
            if setting == .automatic, profile.conditional[mode], priority == .low {
                if quality >= .moderate, windows >= 3 {
                    priority = .normal
                    result.reasons += [.conditionMet, .persistentSound]
                } else {
                    result.conditionPending = true
                    result.reasons.append(.conditionPending)
                }
            }
            if priority > .ambient, let rule = profile.escalation {
                var raise = false
                if let duration = rule.afterDuration, let first = states.map(\.started).min(),
                   let last = states.map(\.lastObserved).max(), last.timeIntervalSince(first) >= duration
                {
                    raise = true
                    if !result.reasons.contains(.persistentSound) { result.reasons.append(.persistentSound) }
                }
                if let count = rule.afterOccurrences,
                   episode.occurrenceDates.count(where: { now.timeIntervalSince($0) <= rule.occurrenceWindow }) >= count
                {
                    raise = true
                    result.reasons.append(.repeatedEvent)
                }
                if raise {
                    let raised = priority.shifted(by: 1, limit: max(rule.limit, priority))
                    if raised > priority {
                        priority = raised
                        result.reasons.append(.escalated)
                        result.conditionPending = false
                    }
                }
            }
            result.priority = priority
            result.bypassesCooldown = profile.isSafetyRelevant || priority == .urgent
        }

        var subtitle: [String] = []
        if episode.event.occurrences > 1 { subtitle.append("Repeated \(episode.event.occurrences) times") }
        if let speech, speech.tier != .irrelevant, !isMusicAmbiguous, result.priority > .ambient {
            // Wording states the order in time and nothing more.
            subtitle.append(speech.tier == .important ? "Possible spoken warning afterwards" : "Nearby speech afterwards")
            if speech.priority > result.priority { result.priority = speech.priority }
            result.reasons.append(.temporalFusion)
            result.reasons += speech.reasons.filter { $0 != .conditionPending && $0 != .conditionMet }
            result.isUncertain = result.isUncertain || speech.isUncertain
            result.content = speech.privateContent
            result.signature = speech.signature
            result.speechTier = speech.tier
            result.conditionPending = false
        }
        result.subtitle = subtitle.isEmpty ? nil : subtitle.joined(separator: " · ")
        return result
    }

    /// A confirmed music event is going on.
    private var isMusicActive: Bool {
        episodes.values.contains { episode in
            guard episode.allEnded == nil, let kind = episode.leadKind else { return false }
            return configuration.assignment(for: kind).category == .music
        }
    }

    private func contentChange(from episode: Episode, to assessment: Assessment) -> ContentChange {
        switch (episode.presentedContent, assessment.content) {
        case (nil, nil): return .none
        case (nil, .some): return .added
        case (.some, nil): return .removed
        case (.some(let old), .some(let new)):
            if old.text == new.text { return .none }
            guard let before = episode.presentedSignature, let after = assessment.signature else { return .refined }
            switch before.change(to: after, sameMeaningSimilarity: configuration.speech.sameMeaningSimilarity) {
            case .cosmetic: return .cosmetic
            case .refined: return .refined
            case .critical(let negation): return .critical(negation: negation)
            }
        }
    }

    // MARK: - Scheduling

    /// Re-assesses one episode and decides what to do about it.
    ///
    /// - Parameters:
    ///   - structural: a source was added (fusion, a repeated occurrence).
    ///   - announce: emit a decision even when nothing changes (true for sound inputs, so every
    ///     confirmed sound has an explanation; false for speech progress and timers).
    private mutating func evaluate(_ id: AttentionEventID, trigger: AttentionTrigger, extra: [AttentionReason] = [],
                                   structural: Bool = false, announce: Bool)
    {
        guard var episode = episodes[id] else { return }
        let assessment = assess(episode)
        let previous = episode.event
        var reasons = assessment.reasons + extra
        let isEligible = assessment.priority >= tuning.surfaceThreshold && assessment.priority > .ambient
        let change = contentChange(from: episode, to: assessment)

        episode.event.category = assessment.category
        episode.event.kindID = assessment.kindID
        episode.event.symbolName = assessment.symbolName ?? assessment.category.systemImage
        episode.event.title = assessment.title
        episode.event.subtitle = assessment.subtitle
        episode.event.priority = assessment.priority
        episode.event.isUncertain = assessment.isUncertain

        // Presented: update, hold back, or take down.
        if episode.event.isPresented {
            guard isEligible else {
                episode.pending = nil
                episode.peakPresented = .ambient  // may be presented again if it becomes eligible
                episodes[id] = episode
                if assessment.priority > .ambient { reasons.append(.belowModeThreshold) }
                endPresentation(id, reasons: reasons, trigger: trigger, action: .suppress)
                return
            }
            let priorityRose = assessment.priority > previous.priority
            // Speech that now looks like a warning must be noticed even when the episode was
            // already at that priority (a knock followed by "Watch out!").
            let becameImportant = assessment.speechTier == .important && episode.presentedTier != .important
            var isCritical = priorityRose || becameImportant
            switch change {
            case .critical(let negation):
                isCritical = true
                reasons += negation ? [.meaningChanged, .negationChanged] : [.meaningChanged, .detailChanged]
            case .added: reasons.append(.summaryAdded)
            case .refined: reasons.append(.meaningChanged)
            case .cosmetic, .none, .removed: break
            }
            if priorityRose {
                if !reasons.contains(.escalated) { reasons.append(.escalated) }
                statistics.escalations += 1
            }
            let visible = structural || previous.title != assessment.title || previous.subtitle != assessment.subtitle
                || previous.priority != assessment.priority || previous.isUncertain != assessment.isUncertain
            let contentChanged: Bool = switch change {
            case .added, .removed, .refined, .critical: true
            case .none, .cosmetic: false
            }

            if !isCritical, !visible, !contentChanged {
                episodes[id] = episode
                if case .cosmetic = change {
                    // Same statement in other words: keep what is shown.
                    let revision = assessment.content?.summaryRevision
                    if revision != episode.cosmeticRevision {
                        episode.cosmeticRevision = revision
                        episodes[id] = episode
                        emit(.suppress, id, reasons: reasons + [.cosmeticRevision], trigger: trigger)
                    }
                } else if announce {
                    emit(.suppress, id, reasons: reasons + [.ongoingEvent, .duplicate], trigger: trigger)
                }
                return
            }
            let isRefinementOnly: Bool = if case .refined = change { !isCritical && !visible } else { false }
            if isRefinementOnly, let last = episode.lastUpdate,
               now.timeIntervalSince(last) < tuning.minimumUpdateInterval
            {
                let alreadyWaiting = episode.pending == .update
                episode.pending = .update
                episodes[id] = episode
                if !alreadyWaiting { emit(.defer, id, reasons: reasons + [.updateRateLimited], trigger: trigger) }
                return
            }
            episode.pending = nil
            episode.lastUpdate = now
            episode.peakPresented = max(episode.peakPresented, assessment.priority)
            episode.presentedContent = assessment.content
            episode.presentedSignature = assessment.signature
            episode.presentedTier = assessment.speechTier
            episode.event.privateContent = assessment.content
            if episode.event.lifecycle != .resolved { episode.event.lifecycle = .updated }
            let interruption: PresentationInterruption
            if isCritical {
                interruption = priorityRose ? Self.interruption(for: assessment.priority)
                    : (assessment.priority >= .high ? .active : .passive)
                // An alerting change restarts the presentation's lifetime.
                if episode.allEnded == nil { episode.event.expiresAt = now.addingTimeInterval(lifetime(of: episode)) }
            } else {
                // New content (a late summary, a joined source) appears quietly.
                interruption = .none
            }
            episodes[id] = episode
            emit(.update, id, reasons: reasons, trigger: trigger, intent: (.update, interruption))
            return
        }

        // Not presented, and this id's presentation is already over.
        if episode.isTracker {
            let hasNewContent: Bool = switch change {
            case .added, .refined, .critical: (assessment.speechTier ?? .irrelevant) >= .informative
            case .none, .removed, .cosmetic: false
            }
            guard isEligible, assessment.priority > episode.peakPresented || hasNewContent else {
                episodes[id] = episode
                if announce { emit(.suppress, id, reasons: reasons + [.ongoingEvent], trigger: trigger) }
                return
            }
            // More important than what was shown, or something new was said: a new episode that
            // takes over the sources.
            if assessment.priority > episode.peakPresented, episode.peakPresented > .ambient { reasons.append(.escalated) }
            let successor = respawn(id)
            evaluate(successor, trigger: trigger, extra: extra + reasons.filter { $0 == .escalated }, announce: true)
            return
        }

        guard isEligible else {
            if assessment.conditionPending {
                let alreadyWaiting = episode.pending == .condition
                episode.pending = .condition
                episodes[id] = episode
                if !alreadyWaiting { emit(.defer, id, reasons: reasons, trigger: trigger) }
            } else {
                if episode.pending == .condition { episode.pending = nil }
                episodes[id] = episode
                if assessment.priority > .ambient { reasons.append(.belowModeThreshold) }
                // Without `announce`, only a new explanation is worth a decision (speech that
                // turned out to be lyrics), not every revision of the same one.
                if announce || episode.lastAction != .suppress || Set(reasons) != Set(episode.event.reasons) {
                    emit(.suppress, id, reasons: reasons, trigger: trigger)
                }
            }
            return
        }
        // Nothing is presented for sources that already ended, unless it was waiting its turn.
        if episode.allEnded != nil, episode.pending == nil {
            episodes[id] = episode
            return
        }

        if let key = assessment.cooldownKey, assessment.cooldown > 0, let entry = memory[key],
           entry.lastPresentedBy != id, let last = entry.lastPresented,
           now.timeIntervalSince(last) < assessment.cooldown * tuning.cooldownScale
        {
            if assessment.bypassesCooldown {
                reasons.append(.cooldownBypassed)
            } else {
                // Decided once: a sound that began during its cooldown does not appear later just
                // because the cooldown ran out. Only a higher priority brings it up.
                episode.pending = nil
                episode.isTracker = true
                episode.peakPresented = assessment.priority
                episodes[id] = episode
                emit(.suppress, id, reasons: reasons + [.cooldownActive, .recentlySeen], trigger: trigger)
                return
            }
        }

        if assessment.priority >= .high || assessment.bypassesCooldown {
            if budgetUsed >= tuning.presentationBudget { reasons.append(.rateLimitBypassed) }
        } else if budgetUsed >= tuning.presentationBudget {
            let alreadyWaiting: Bool = if case .budget = episode.pending { true } else { false }
            if !alreadyWaiting { episode.pending = .budget(since: now) }
            episodes[id] = episode
            if !alreadyWaiting { emit(.defer, id, reasons: reasons + [.rateLimited], trigger: trigger) }
            return
        }

        // SHOW
        if case .budget = episode.pending { reasons.append(.deferredReleased) }
        if episode.event.occurrences == 1, !reasons.contains(.continuationOfRecent) { reasons.append(.newEvent) }
        episode.pending = nil
        episode.lastUpdate = now
        episode.peakPresented = assessment.priority
        episode.presentedContent = assessment.content
        episode.presentedSignature = assessment.signature
        episode.presentedTier = assessment.speechTier
        episode.event.privateContent = assessment.content
        episode.event.isPresented = true
        if assessment.priority < .high, !assessment.bypassesCooldown { recentShows.append(now) }
        if let key = assessment.cooldownKey ?? (episode.leadKind == nil ? Self.speechKey : nil) {
            memory[key, default: KindMemory()].lastPresented = now
            memory[key]?.lastPresentedBy = id
        }
        if episode.allEnded != nil {
            episode.event.lifecycle = .resolved
            episode.event.expiresAt = now.addingTimeInterval(linger(of: episode))
        } else {
            episode.event.lifecycle = .active
            episode.event.expiresAt = now.addingTimeInterval(lifetime(of: episode))
        }
        episodes[id] = episode
        emit(.show, id, reasons: reasons, trigger: trigger,
             intent: (.present, Self.interruption(for: assessment.priority)))
    }

    private static func interruption(for priority: AttentionPriority) -> PresentationInterruption {
        switch priority {
        case .ambient, .low: .none
        case .normal: .passive
        case .high: .active
        case .urgent: .timeSensitive
        }
    }

    /// Longest presentation while the source keeps going. Long enough for a duration-based
    /// escalation to happen while the episode is still shown.
    private func lifetime(of episode: Episode) -> TimeInterval {
        var lifetime = configuration.lifetime(for: episode.event.priority)
        if let kind = episode.leadKind, let duration = configuration.profile(for: kind).escalation?.afterDuration {
            lifetime = max(lifetime, duration + 15)
        }
        return lifetime
    }

    /// How long a resolved episode stays shown: at least `resolveLinger`, and for sounds that
    /// come back in bursts (knocks, horns) as long as a recurrence would still join it.
    private func linger(of episode: Episode) -> TimeInterval {
        let rejoin = episode.leadKind.map { configuration.profile(for: $0).rejoinWindow } ?? configuration.speech.rejoinWindow
        return min(max(configuration.resolveLinger, rejoin), 20)
    }

    private mutating func resolveIfEnded(_ id: AttentionEventID, trigger: AttentionTrigger, reason: AttentionReason) {
        guard var episode = episodes[id], episode.allEnded == nil,
              episode.sounds.values.allSatisfy({ $0.ended != nil }),
              episode.speechID == nil || episode.speechEnded != nil,
              !(episode.sounds.isEmpty && episode.speechID == nil) else { return }
        episode.allEnded = now
        if episode.event.isPresented {
            episode.pending = nil
            episode.event.lifecycle = .resolved
            episode.event.expiresAt = now.addingTimeInterval(linger(of: episode))
            episodes[id] = episode
            emit(.resolve, id, reasons: [reason], trigger: trigger, intent: (.dismiss, .none))
        } else if episode.pending == .condition {
            episode.pending = nil
            episode.event.lifecycle = .expired
            episodes[id] = episode
            emit(.expire, id, reasons: [.deferredExpired, reason], trigger: trigger)
        } else {
            if !episode.isTracker { episode.event.lifecycle = .resolved }
            episodes[id] = episode
        }
    }

    /// Ends the presentation of an episode. The episode stays as a tracker while a source is
    /// active, so the same ongoing sound does not alert again under this id.
    private mutating func endPresentation(_ id: AttentionEventID, reasons: [AttentionReason], trigger: AttentionTrigger,
                                          action: AttentionAction = .expire, removes: Bool = true)
    {
        guard var episode = episodes[id] else { return }
        let wasPresented = episode.event.isPresented
        episode.event.isPresented = false
        episode.event.expiresAt = now
        episode.event.lifecycle = .expired
        episode.isTracker = true
        episode.pending = nil
        episodes[id] = episode
        emit(action, id, reasons: reasons, trigger: trigger, intent: wasPresented ? (.dismiss, .none) : nil)
        if removes, episode.allEnded != nil { remove(id) }
    }

    /// Hands a tracker's sources to a new episode id (the old id is final).
    private mutating func respawn(_ id: AttentionEventID) -> AttentionEventID {
        guard var episode = episodes[id] else { return id }
        let successor = AttentionEventID(rawValue: nextEpisode)
        nextEpisode += 1
        statistics.episodesCreated += 1
        var event = episode.event
        event = AttentionEvent(id: successor, category: event.category, kindID: event.kindID, title: event.title,
                               subtitle: event.subtitle, symbolName: event.symbolName, priority: event.priority,
                               createdAt: now, updatedAt: now, sources: event.sources, occurrences: event.occurrences)
        episode.event = event
        episode.isTracker = false
        episode.pending = nil
        episode.lastUpdate = nil
        episode.lastAction = nil
        episode.peakPresented = .ambient
        episode.presentedContent = nil
        episode.presentedSignature = nil
        episode.presentedTier = nil
        episodes[id] = nil
        episodes[successor] = episode
        for (key, value) in soundIndex where value == id { soundIndex[key] = successor }
        for (key, value) in speechIndex where value == id { speechIndex[key] = successor }
        for (key, value) in memory {
            if value.episode == id { memory[key]?.episode = successor }
            if value.lastPresentedBy == id { memory[key]?.lastPresentedBy = successor }
        }
        return successor
    }

    private mutating func newEpisode(category: AttentionCategory, kindID: String?, title: String) -> Episode {
        let id = AttentionEventID(rawValue: nextEpisode)
        nextEpisode += 1
        statistics.episodesCreated += 1
        return Episode(event: AttentionEvent(id: id, category: category, kindID: kindID, title: title,
                                             symbolName: category.systemImage, priority: .ambient, createdAt: now,
                                             updatedAt: now))
    }

    private mutating func remove(_ id: AttentionEventID) {
        episodes[id] = nil
        for (key, value) in soundIndex where value == id { soundIndex[key] = nil }
        for (key, value) in speechIndex where value == id { speechIndex[key] = nil }
        for (key, value) in memory where value.episode == id { memory[key]?.episode = nil }
    }

    /// Drops the least important, oldest episode when the table is full: untracked ones first.
    private mutating func enforceCapacity(keeping kept: AttentionEventID) {
        while episodes.count > configuration.maximumEpisodes {
            let candidates = episodes.values.filter { $0.event.id != kept }.sorted {
                if $0.event.isPresented != $1.event.isPresented { return !$0.event.isPresented }
                if $0.event.priority != $1.event.priority { return $0.event.priority < $1.event.priority }
                return $0.event.id < $1.event.id
            }
            guard let victim = candidates.first else { return }
            statistics.evictions += 1
            if victim.event.isPresented {
                endPresentation(victim.event.id, reasons: [.capacityEvicted], trigger: .timer, removes: false)
            }
            remove(victim.event.id)
        }
    }

    // MARK: - Preferences and session

    private mutating func apply(_ updated: AttentionPreferences) {
        guard updated != preferences else { return }
        preferences = updated
        for id in episodes.keys.sorted() {
            guard var episode = episodes[id] else { continue }
            // The floor was set under the old preferences; recompute it from the current facts.
            episode.importantFloor = nil
            if let facts = episode.speech { noteImportance(of: facts, in: &episode) }
            // A presentation ended by a preference may come back when the preference does.
            if episode.isTracker, episode.peakPresented == .ambient, episode.allEnded == nil {
                episodes[id] = episode
                let successor = respawn(id)
                evaluate(successor, trigger: .preferences, extra: [.preferencesChanged], announce: false)
                continue
            }
            episodes[id] = episode
            evaluate(id, trigger: .preferences, extra: [.preferencesChanged], announce: false)
        }
    }

    /// Drops every speech source and all speech-derived text (the user switched transcription
    /// off, so the speech pipeline discarded its events and will not finish them).
    private mutating func clearSpeech() {
        goalMemory.removeAll()
        for id in episodes.keys.sorted() {
            guard var episode = episodes[id], episode.speech != nil || episode.semantic != nil else { continue }
            if episode.leadKind == nil {
                if episode.event.isPresented || episode.pending != nil {
                    endPresentation(id, reasons: [.speechDataCleared], trigger: .session, removes: false)
                }
                remove(id)
                continue
            }
            // A sound with speech attached keeps the sound.
            for source in episode.event.sources {
                if case .sound(let soundID, let kindID) = source.source, kindID == Self.speechKey {
                    episode.sounds[soundID] = nil
                    soundIndex[soundID] = nil
                }
            }
            episode.event.sources.removeAll { record in
                if case .sound(_, let kindID) = record.source { return kindID == Self.speechKey }
                return true
            }
            if let speechID = episode.speechID { speechIndex[speechID] = nil }
            episode.speechID = nil
            episode.speech = nil
            episode.speechFirstObserved = nil
            episode.speechLastObserved = nil
            episode.speechEnded = nil
            episode.importantFloor = nil
            episode.event.privateContent = nil
            episodes[id] = episode
            evaluate(id, trigger: .session, extra: [.speechDataCleared], structural: true, announce: false)
            resolveIfEnded(id, trigger: .session, reason: .sourceEnded)
        }
    }

    private mutating func endSession(reason: AttentionReason) {
        for id in episodes.keys.sorted() {
            guard let episode = episodes[id] else { continue }
            if episode.event.isPresented || episode.pending != nil {
                endPresentation(id, reasons: [reason], trigger: .session, removes: false)
            }
            remove(id)
        }
        goalMemory.removeAll()
        soundIndex.removeAll()
        speechIndex.removeAll()
    }

    // MARK: - Output

    private mutating func emit(_ action: AttentionAction, _ id: AttentionEventID, reasons: [AttentionReason],
                               trigger: AttentionTrigger,
                               intent: (action: PresentationAction, interruption: PresentationInterruption)? = nil)
    {
        guard var episode = episodes[id] else { return }
        var unique: [AttentionReason] = []
        for reason in reasons where !unique.contains(reason) { unique.append(reason) }
        // A shown episode keeps the reasons it was shown or updated with; "still going on" is
        // an explanation of the decision, not of the episode.
        if !(action == .suppress && episode.event.isPresented) { episode.event.reasons = unique }
        episode.lastAction = action
        if intent != nil {
            episode.event.revision += episode.event.revision == 1 && action == .show ? 0 : 1
            episode.event.updatedAt = now
        }
        episodes[id] = episode
        let presentation = intent.map {
            AttentionPresentationIntent(event: episode.event, action: $0.action, interruption: $0.interruption, timestamp: now,
                               expiresAt: episode.event.expiresAt, reasons: unique)
        }
        statistics.decisions[action, default: 0] += 1
        output.append(AttentionDecision(id: nextDecision, action: action, event: episode.event, intent: presentation,
                                        reasons: unique, decidedAt: now, trigger: trigger))
        nextDecision += 1
    }
}
