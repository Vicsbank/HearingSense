import ConversationUnderstanding
import Foundation
import SwiftData

/// One saved summary (Window 6). SwiftData model behind `ConversationRecord`.
///
/// Only what the user asked to keep: the summary, its key points and its dates. No audio, no
/// transcript.
@Model
final class StoredConversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var summary: String
    var keyPoints: [String]
    var caveats: [String]
    var createdAt: Date
    var updatedAt: Date
    var isContinuing: Bool
    var isUserEdited: Bool
    var coveredFrom: Date?
    var coveredTo: Date?
    var isSummary: Bool
    /// Folded text of the record, so that a search does not have to rebuild it.
    var searchText: String

    init(_ record: ConversationRecord) {
        id = record.id
        title = record.title
        summary = record.summary
        keyPoints = record.keyPoints
        caveats = record.caveats
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        isContinuing = record.status == .continuing
        isUserEdited = record.isUserEdited
        coveredFrom = record.coveredFrom
        coveredTo = record.coveredTo
        isSummary = record.isSummary
        searchText = record.searchText
    }

    func update(from record: ConversationRecord) {
        title = record.title
        summary = record.summary
        keyPoints = record.keyPoints
        caveats = record.caveats
        updatedAt = record.updatedAt
        isContinuing = record.status == .continuing
        isUserEdited = record.isUserEdited
        coveredFrom = record.coveredFrom
        coveredTo = record.coveredTo
        isSummary = record.isSummary
        searchText = record.searchText
    }

    var record: ConversationRecord {
        ConversationRecord(id: id, title: title, summary: summary, keyPoints: keyPoints, caveats: caveats,
                           createdAt: createdAt, updatedAt: updatedAt, status: isContinuing ? .continuing : .completed,
                           isUserEdited: isUserEdited, coveredFrom: coveredFrom, coveredTo: coveredTo, isSummary: isSummary)
    }
}

/// Where the app keeps what the user asked it to keep: saved summaries (SwiftData), in one
/// folder of Application Support.
///
/// - On this iPhone only: no CloudKit, and the folder is excluded from iCloud and computer backups.
/// - Data protection `completeUntilFirstUserAuthentication`: encrypted at rest and unreadable
///   until the first unlock after a restart, but writable afterwards while the phone is locked,
///   because a continued session updates its summary in the pocket.
enum ConversationStorage {
    static let folderName = "ConversationIntelligence"

    static func folder() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                               create: true)
        var folder = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }
}

/// Main-actor isolated (app default), so it does not adopt the package's non-isolated
/// `ConversationHistoryStoring`; it offers the same operations.
final class SwiftDataConversationHistory {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// - Parameter inMemory: for previews and UI checks without touching the device's store.
    init(inMemory: Bool = false) throws {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let url = try ConversationStorage.folder().appendingPathComponent("history.store")
            configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: StoredConversation.self, configurations: configuration)
    }

    func all() throws -> [ConversationRecord] {
        let descriptor = FetchDescriptor<StoredConversation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor).map(\.record)
    }

    private func stored(_ id: UUID) throws -> StoredConversation? {
        var descriptor = FetchDescriptor<StoredConversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func record(_ id: UUID) throws -> ConversationRecord? {
        try stored(id)?.record
    }

    func save(_ record: ConversationRecord) throws {
        if let existing = try stored(record.id) {
            existing.update(from: record)
        } else {
            context.insert(StoredConversation(record))
        }
        try context.save()
    }

    func delete(_ id: UUID) throws {
        guard let existing = try stored(id) else { return }
        context.delete(existing)
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: StoredConversation.self)
        try context.save()
    }

    func search(_ query: String) throws -> [ConversationRecord] {
        let records = try all()
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? records : records.filter { $0.matches(query) }
    }

    /// Records left in `continuing` by a session that never finalized (the app was terminated).
    func completeInterrupted() throws {
        for var record in try all() where record.status == .continuing {
            record.status = .completed
            try save(record)
        }
    }
}
