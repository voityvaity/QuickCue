import Foundation
import SwiftData

/// Stages 16–18 add durable practice attempts, feedback and full interview summaries.
/// V7 and V8 stay frozen migration inputs.
enum QuickCueSchemaV9: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(9, 0, 0) }
    static var models: [any PersistentModel.Type] {
        QuickCueSchemaV8.models + [
            PracticeSessionRecord.self,
            PracticeTurnRecord.self,
            PracticeFeedbackRecord.self,
        ]
    }

    @Model
    final class PracticeSessionRecord {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var endedAt: Date?
        var modeRaw: String
        var statusRaw: String
        var interviewerRoleRaw: String
        var difficultyRaw: String
        var requestedRounds: Int
        var completedRounds: Int
        var maxDurationSeconds: Int
        var questionIDsData: Data
        var jobID: UUID?
        var jobRevision: Int?
        var jobTitle: String?
        var jobSnapshotText: String?
        var promptVersion: String
        var rubricVersion: String
        var providerRaw: String?
        var modelName: String?
        var summaryText: String
        var nextExercisesData: Data
        var safeErrorCategory: String?
        var isCompanySimulation: Bool

        init(
            id: UUID = UUID(),
            mode: PracticeMode,
            interviewerRole: PracticeInterviewerRole,
            difficulty: PracticeDifficulty,
            requestedRounds: Int,
            maxDurationSeconds: Int,
            questionIDs: [UUID]
        ) {
            self.id = id
            self.createdAt = .now
            self.updatedAt = .now
            self.modeRaw = mode.rawValue
            self.statusRaw = PracticeSessionStatus.active.rawValue
            self.interviewerRoleRaw = interviewerRole.rawValue
            self.difficultyRaw = difficulty.rawValue
            self.requestedRounds = requestedRounds
            self.completedRounds = 0
            self.maxDurationSeconds = maxDurationSeconds
            self.questionIDsData = (try? JSONEncoder().encode(questionIDs)) ?? Data("[]".utf8)
            self.promptVersion = PracticePrompt.version
            self.rubricVersion = PracticeRubric.version
            self.summaryText = ""
            self.nextExercisesData = Data("[]".utf8)
            self.isCompanySimulation = false
        }
    }

    @Model
    final class PracticeTurnRecord {
        @Attribute(.unique) var id: UUID
        var sessionID: UUID
        var questionID: UUID
        var createdAt: Date
        var answeredAt: Date?
        var orderIndex: Int
        var questionText: String
        var topic: String
        var typeRaw: String
        var difficultyRaw: String
        var statusRaw: String
        var answerText: String
        var answerRevision: Int
        var followUpQuestion: String?
        var followUpAnswer: String?
        var requestID: UUID?
        var providerRaw: String?
        var modelName: String?
        var promptVersion: String
        var rubricVersion: String

        init(
            id: UUID = UUID(),
            sessionID: UUID,
            question: PracticeQuestionRecord,
            orderIndex: Int
        ) {
            self.id = id
            self.sessionID = sessionID
            self.questionID = question.id
            self.createdAt = .now
            self.orderIndex = orderIndex
            self.questionText = question.text
            self.topic = question.topic
            self.typeRaw = question.typeRaw
            self.difficultyRaw = question.difficultyRaw
            self.statusRaw = PracticeTurnStatus.asking.rawValue
            self.answerText = ""
            self.answerRevision = 1
            self.promptVersion = PracticePrompt.version
            self.rubricVersion = PracticeRubric.version
        }
    }

    @Model
    final class PracticeFeedbackRecord {
        @Attribute(.unique) var id: UUID
        var sessionID: UUID
        var turnID: UUID
        var createdAt: Date
        var answerRevision: Int
        var statusRaw: String
        var rubricVersion: String
        var promptVersion: String
        var providerRaw: String?
        var modelName: String?
        var requestID: UUID
        var evidenceFragment: String
        var strengthsData: Data
        var improvementsData: Data
        var exampleAnswer: String
        var followUpQuestion: String?
        var accuracyScore: Int?
        var completenessScore: Int?
        var structureScore: Int?
        var examplesScore: Int?
        var safeErrorCategory: String?
        var isStale: Bool

        init(
            id: UUID = UUID(),
            sessionID: UUID,
            turnID: UUID,
            answerRevision: Int,
            requestID: UUID
        ) {
            self.id = id
            self.sessionID = sessionID
            self.turnID = turnID
            self.createdAt = .now
            self.answerRevision = answerRevision
            self.statusRaw = PracticeFeedbackStatus.queued.rawValue
            self.rubricVersion = PracticeRubric.version
            self.promptVersion = PracticePrompt.version
            self.requestID = requestID
            self.evidenceFragment = ""
            self.strengthsData = Data("[]".utf8)
            self.improvementsData = Data("[]".utf8)
            self.exampleAnswer = ""
            self.isStale = false
        }
    }
}
