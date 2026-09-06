import Foundation
import SwiftData

/// Stages 19–21 add scheduling and reversible deletion metadata. All earlier
/// schemas remain frozen migration inputs.
enum QuickCueSchemaV10: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(10, 0, 0) }
    static var models: [any PersistentModel.Type] {
        QuickCueSchemaV9.models + [InterviewEventRecord.self, DeletedItemRecord.self]
    }

    @Model
    final class InterviewEventRecord {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var company: String
        var role: String
        var scheduledAt: Date
        var timeZoneIdentifier: String
        var meetingURL: String?
        var notes: String
        var jobID: UUID?
        var preparationPlanID: UUID?
        var calendarEventIdentifier: String?
        var calendarScheduledAt: Date?
        var notificationIdentifier: String?

        init(
            id: UUID = UUID(),
            company: String,
            role: String,
            scheduledAt: Date,
            timeZoneIdentifier: String
        ) {
            self.id = id
            self.createdAt = .now
            self.updatedAt = .now
            self.company = company
            self.role = role
            self.scheduledAt = scheduledAt
            self.timeZoneIdentifier = timeZoneIdentifier
            self.notes = ""
        }
    }

    /// A tombstone hides an item while its original records remain intact.
    /// Explicit restore removes the tombstone; explicit purge removes both.
    @Model
    final class DeletedItemRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var originalID: UUID
        var kindRaw: String
        var title: String
        var deletedAt: Date
        var purgeAfter: Date

        init(
            id: UUID = UUID(),
            originalID: UUID,
            kindRaw: String,
            title: String,
            deletedAt: Date = .now,
            purgeAfter: Date
        ) {
            self.id = id
            self.originalID = originalID
            self.kindRaw = kindRaw
            self.title = title
            self.deletedAt = deletedAt
            self.purgeAfter = purgeAfter
        }
    }
}
