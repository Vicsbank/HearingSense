import Foundation

/// A summary the user asked for, as it is kept in the app's history (Window 6).
///
/// It holds the summary and nothing else of the conversation: no audio and no transcript.
public struct ConversationRecord: Identifiable, Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        /// The user is still following this conversation; the summary may be extended.
        case continuing
        case completed
    }

    public var id: UUID
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var caveats: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var status: Status
    /// The user changed the title or the text. Their wording is never overwritten afterwards.
    public var isUserEdited: Bool
    /// The time span of the speech the summary covers.
    public var coveredFrom: Date?
    public var coveredTo: Date?
    /// False when no summary could be written (too little speech, or no language model).
    public var isSummary: Bool

    public init(id: UUID = UUID(), title: String, summary: String, keyPoints: [String] = [], caveats: [String] = [],
                createdAt: Date, updatedAt: Date? = nil, status: Status = .completed, isUserEdited: Bool = false,
                coveredFrom: Date? = nil, coveredTo: Date? = nil, isSummary: Bool = true)
    {
        self.id = id
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.caveats = caveats
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.status = status
        self.isUserEdited = isUserEdited
        self.coveredFrom = coveredFrom
        self.coveredTo = coveredTo
        self.isSummary = isSummary
    }

    public init(recap: ConversationRecap, id: UUID = UUID(), at date: Date, status: Status) {
        self.init(id: id, title: recap.title, summary: recap.summary, keyPoints: recap.keyPoints, caveats: recap.caveats,
                  createdAt: date, status: status, coveredFrom: recap.coveredFrom, coveredTo: recap.coveredTo,
                  isSummary: recap.isSummary)
    }

    /// Takes over a newer recap of the same session. Once the user has edited the record, their
    /// title and text stay; only new key points are added below them.
    public mutating func apply(_ recap: ConversationRecap, at date: Date, status: Status) {
        if isUserEdited {
            for point in recap.keyPoints where !keyPoints.contains(point) { keyPoints.append(point) }
        } else {
            title = recap.title
            summary = recap.summary
            keyPoints = recap.keyPoints
            isSummary = recap.isSummary
        }
        caveats = recap.caveats
        coveredFrom = coveredFrom ?? recap.coveredFrom
        coveredTo = recap.coveredTo ?? coveredTo
        updatedAt = date
        self.status = status
    }

    public mutating func edit(title: String, summary: String, at date: Date) {
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newTitle != self.title || newSummary != self.summary else { return }
        self.title = newTitle.isEmpty ? ConversationRecapEngine.untitled : newTitle
        self.summary = newSummary
        isUserEdited = true
        updatedAt = date
    }

    /// Everything that can be searched and copied.
    public var fullText: String {
        var parts = [title, summary]
        if !keyPoints.isEmpty { parts.append(keyPoints.map { "• " + $0 }.joined(separator: "\n")) }
        if !caveats.isEmpty { parts.append(caveats.map { "Note: " + $0 }.joined(separator: "\n")) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Lower-cased and without diacritics, for search.
    public var searchText: String { Self.fold(fullText) }

    /// True when every word of the query occurs somewhere in the record.
    public func matches(_ query: String) -> Bool {
        let terms = Self.fold(query).split(whereSeparator: \.isWhitespace)
        let text = searchText
        return terms.allSatisfy { text.contains($0) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Where requested summaries are kept. The app's implementation stores them on the device only
/// (SwiftData, file protection); tests use `InMemoryConversationHistory`.
public protocol ConversationHistoryStoring {
    /// Newest first.
    func all() throws -> [ConversationRecord]
    func record(_ id: UUID) throws -> ConversationRecord?
    /// Inserts, or replaces the record with the same id.
    func save(_ record: ConversationRecord) throws
    func delete(_ id: UUID) throws
    func deleteAll() throws
}

extension ConversationHistoryStoring {
    public func search(_ query: String) throws -> [ConversationRecord] {
        let records = try all()
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? records : records.filter { $0.matches(query) }
    }

    /// Records left in `continuing` by a session that ended without finalizing (the app was
    /// terminated): they are completed the next time the store is opened.
    public func completeInterrupted(at date: Date) throws {
        for var record in try all() where record.status == .continuing {
            record.status = .completed
            try save(record)
        }
    }
}

public final class InMemoryConversationHistory: ConversationHistoryStoring {
    private var records: [UUID: ConversationRecord] = [:]

    public init() {}

    public func all() -> [ConversationRecord] { records.values.sorted { $0.createdAt > $1.createdAt } }
    public func record(_ id: UUID) -> ConversationRecord? { records[id] }
    public func save(_ record: ConversationRecord) { records[record.id] = record }
    public func delete(_ id: UUID) { records[id] = nil }
    public func deleteAll() { records.removeAll() }
}
