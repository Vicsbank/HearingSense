import Foundation

/// A bounded, in-memory log of audio lifecycle events for device testing.
///
/// Privacy: entries hold only state and routing metadata. Never log audio samples,
/// recognized speech or transcripts here. The log is not persisted.
public struct DiagnosticEventLog: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case lifecycle, permission, session, route, interruption, capture, error
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: Int
        public let date: Date
        public let kind: Kind
        public let message: String
    }

    public let capacity: Int
    /// Oldest first.
    public private(set) var entries: [Entry] = []
    private var nextID = 0

    public init(capacity: Int = 300) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func append(_ kind: Kind, _ message: String, date: Date = .now) {
        entries.append(Entry(id: nextID, date: date, kind: kind, message: message))
        nextID += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    public func exportText() -> String {
        entries.map { entry in
            let time = entry.date.formatted(.iso8601.time(includingFractionalSeconds: true))
            return "\(time) [\(entry.kind.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
