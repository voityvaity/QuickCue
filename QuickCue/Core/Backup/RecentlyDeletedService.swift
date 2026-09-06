import Foundation
import SwiftData

@MainActor
enum RecentlyDeletedService {
    static let retentionDays = 30

    static func moveSessions(
        _ sessions: [SessionRecord],
        existingTombstones: [DeletedItemRecord],
        context: ModelContext,
        now: Date = .now
    ) throws {
        let existing = Set(existingTombstones.map(\.originalID))
        let purgeAfter = Calendar(identifier: .gregorian).date(byAdding: .day, value: retentionDays, to: now)
            ?? now.addingTimeInterval(TimeInterval(retentionDays * 86_400))
        for session in sessions where !existing.contains(session.id) {
            context.insert(DeletedItemRecord(
                originalID: session.id,
                kindRaw: "session",
                title: session.title.isEmpty ? "Сессия" : session.title,
                deletedAt: now,
                purgeAfter: purgeAfter
            ))
        }
        try context.save()
    }

    static func restore(_ item: DeletedItemRecord, context: ModelContext) throws {
        context.delete(item)
        try context.save()
    }

    static func purgeExpired(context: ModelContext, now: Date = .now) throws {
        let expired = try context.fetch(FetchDescriptor<DeletedItemRecord>()).filter { $0.purgeAfter <= now }
        for item in expired { try purge(item, context: context) }
    }

    static func purge(_ item: DeletedItemRecord, context: ModelContext) throws {
        guard item.kindRaw == "session" else { throw UserBackupError.invalidPayload }
        let sessionID = item.originalID
        let photos = try context.fetch(FetchDescriptor<PhotoRecord>()).filter { $0.sessionID == sessionID }
        for photo in photos { try PhotoStore().delete(relativePath: photo.relativePath) }
        photos.forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<ConversationMessageRecord>()).filter { $0.sessionID == sessionID }.forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<AnswerRecord>()).filter { $0.sessionID == sessionID }.forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<TranscriptRecord>()).filter { $0.sessionID == sessionID }.forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<UsageRecord>()).filter { $0.sessionID == sessionID }.forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<SessionContextSnapshot>()).filter { $0.sessionID == sessionID }.forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<SessionRecord>()).filter { $0.id == sessionID }.forEach { context.delete($0) }
        context.delete(item)
        try context.save()
    }
}
