import Foundation
import SwiftData

/// Stage 15 adds the local question bank without changing any released V7 model.
enum QuickCueSchemaV8: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }
    static var models: [any PersistentModel.Type] {
        QuickCueSchemaV7.models + [PracticeQuestionRecord.self]
    }

    @Model
    final class PracticeQuestionRecord {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var text: String
        var topic: String
        var roleRaw: String
        var difficultyRaw: String
        var typeRaw: String
        var provenanceRaw: String
        var sourceLabel: String
        var isFavorite: Bool
        var attemptCount: Int
        var isCustom: Bool
        var isArchived: Bool

        init(
            id: UUID = UUID(),
            text: String,
            topic: String,
            role: PracticeQuestionRole,
            difficulty: PracticeDifficulty,
            type: PracticeQuestionType,
            provenance: PracticeQuestionProvenance,
            sourceLabel: String
        ) {
            self.id = id
            self.createdAt = .now
            self.updatedAt = .now
            self.text = text
            self.topic = topic
            self.roleRaw = role.rawValue
            self.difficultyRaw = difficulty.rawValue
            self.typeRaw = type.rawValue
            self.provenanceRaw = provenance.rawValue
            self.sourceLabel = sourceLabel
            self.isFavorite = false
            self.attemptCount = 0
            self.isCustom = provenance != .editorial
            self.isArchived = false
        }
    }
}
