import Foundation
import SwiftData

enum ConversationSpeaker: String, Codable, CaseIterable, Sendable {
    case me
    case partner
    case unknown
    case assistant

    var title: String {
        switch self {
        case .me: "Вы"
        case .partner: "Собеседник"
        case .unknown: "Не определён"
        case .assistant: "QuickCue"
        }
    }
}

enum ConversationMessageKind: String, Codable, Sendable {
    case speech
    case answer
    case photo
    case error
}

typealias SessionRecord = QuickCueSchemaV7.SessionRecord
typealias TranscriptRecord = QuickCueSchemaV7.TranscriptRecord
typealias AnswerRecord = QuickCueSchemaV7.AnswerRecord
typealias PhotoRecord = QuickCueSchemaV7.PhotoRecord
typealias UsageRecord = QuickCueSchemaV7.UsageRecord
typealias ConversationMessageRecord = QuickCueSchemaV7.ConversationMessageRecord
typealias CandidateProfile = QuickCueSchemaV7.CandidateProfile
typealias JobProfile = QuickCueSchemaV7.JobProfile
typealias AttachmentRecord = QuickCueSchemaV7.AttachmentRecord
typealias ContextProfile = QuickCueSchemaV7.ContextProfile
typealias SessionContextSnapshot = QuickCueSchemaV7.SessionContextSnapshot
typealias PracticeQuestionRecord = QuickCueSchemaV8.PracticeQuestionRecord
typealias PracticeSessionRecord = QuickCueSchemaV9.PracticeSessionRecord
typealias PracticeTurnRecord = QuickCueSchemaV9.PracticeTurnRecord
typealias PracticeFeedbackRecord = QuickCueSchemaV9.PracticeFeedbackRecord

enum QuickCueSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [SessionRecord.self, TranscriptRecord.self, AnswerRecord.self, PhotoRecord.self, UsageRecord.self, ConversationMessageRecord.self] }

    @Model
    final class SessionRecord {
        @Attribute(.unique) var id: UUID
        var startedAt: Date
        var endedAt: Date?
        var title: String
        var providerRaw: String
        var questionCount: Int
        var photoCount: Int
        var estimatedCostRUB: Double

        init(id: UUID = UUID(), startedAt: Date = .now, title: String, provider: ProviderKind) {
            self.id = id
            self.startedAt = startedAt
            self.title = title
            self.providerRaw = provider.rawValue
            self.questionCount = 0
            self.photoCount = 0
            self.estimatedCostRUB = 0
        }
    }

    @Model
    final class TranscriptRecord {
        @Attribute(.unique) var id: UUID
        var sessionID: UUID
        var createdAt: Date
        var text: String
        var confidence: Double
        var isQuestion: Bool

        init(sessionID: UUID, text: String, confidence: Double = 0, isQuestion: Bool = false) {
            self.id = UUID()
            self.sessionID = sessionID
            self.createdAt = .now
            self.text = text
            self.confidence = confidence
            self.isQuestion = isQuestion
        }
    }

    @Model
    final class AnswerRecord {
        @Attribute(.unique) var id: UUID
        var sessionID: UUID
        var createdAt: Date
        var question: String
        var answer: String
        var providerRaw: String
        var modelName: String
        var firstTokenMilliseconds: Int
        var totalMilliseconds: Int
        var inputTokens: Int
        var outputTokens: Int
        var feedback: Int
        var requestKindRaw: String = "concise"
        var statusRaw: String = "completed"
        var errorMessage: String?
        var promptSnapshot: String?
        var promptVersion: String?

        init(
            id: UUID = UUID(),
            sessionID: UUID,
            question: String,
            answer: String = "",
            provider: ProviderKind,
            modelName: String,
            requestKind: AnswerMode = .concise,
            status: AnswerStatus = .completed,
            firstTokenMilliseconds: Int = 0,
            totalMilliseconds: Int = 0
        ) {
            self.id = id
            self.sessionID = sessionID
            self.createdAt = .now
            self.question = question
            self.answer = answer
            self.providerRaw = provider.rawValue
            self.modelName = modelName
            self.firstTokenMilliseconds = firstTokenMilliseconds
            self.totalMilliseconds = totalMilliseconds
            self.inputTokens = 0
            self.outputTokens = 0
            self.feedback = 0
            self.requestKindRaw = requestKind.rawValue
            self.statusRaw = status.rawValue
            self.errorMessage = nil
        }
    }

    @Model
    final class ConversationMessageRecord {
        @Attribute(.unique) var id: UUID
        var sessionID: UUID
        var createdAt: Date
        var speakerRaw: String
        var kindRaw: String
        var text: String
        var statusRaw: String
        var confidence: Double
        var photoRelativePath: String?
        var answerID: UUID?

        init(
            sessionID: UUID,
            speaker: ConversationSpeaker,
            kind: ConversationMessageKind,
            text: String,
            status: AnswerStatus = .completed,
            confidence: Double = 0,
            photoRelativePath: String? = nil,
            answerID: UUID? = nil
        ) {
            self.id = UUID()
            self.sessionID = sessionID
            self.createdAt = .now
            self.speakerRaw = speaker.rawValue
            self.kindRaw = kind.rawValue
            self.text = text
            self.statusRaw = status.rawValue
            self.confidence = confidence
            self.photoRelativePath = photoRelativePath
            self.answerID = answerID
        }
    }

    @Model
    final class PhotoRecord {
        @Attribute(.unique) var id: UUID
        var sessionID: UUID?
        var createdAt: Date
        var relativePath: String
        var recognizedText: String
        var answerID: UUID?

        init(sessionID: UUID?, relativePath: String, recognizedText: String = "", answerID: UUID? = nil) {
            self.id = UUID()
            self.sessionID = sessionID
            self.createdAt = .now
            self.relativePath = relativePath
            self.recognizedText = recognizedText
            self.answerID = answerID
        }
    }

    @Model
    final class UsageRecord {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var sessionID: UUID
        var providerRaw: String
        var requestKind: String
        var inputTokens: Int
        var outputTokens: Int
        var estimatedCostRUB: Double
        var requestID: UUID?
        var attemptID: UUID?
        var providerSelectionRaw: String?
        var modelName: String?
        var outcomeRaw: String?
        var usageSourceRaw: String?
        var costSourceRaw: String?
        var errorCode: String?
        var durationMilliseconds: Int?

        init(sessionID: UUID, provider: ProviderKind, requestKind: String) {
            self.id = UUID()
            self.createdAt = .now
            self.sessionID = sessionID
            self.providerRaw = provider.rawValue
            self.requestKind = requestKind
            self.inputTokens = 0
            self.outputTokens = 0
            self.estimatedCostRUB = 0
        }
    }
}

enum QuickCueMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [QuickCueSchemaV1.self, QuickCueSchemaV2.self, QuickCueSchemaV3.self, QuickCueSchemaV4.self, QuickCueSchemaV5.self, QuickCueSchemaV6.self, QuickCueSchemaV7.self, QuickCueSchemaV8.self, QuickCueSchemaV9.self]
    }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: QuickCueSchemaV1.self, toVersion: QuickCueSchemaV2.self),
            .lightweight(fromVersion: QuickCueSchemaV2.self, toVersion: QuickCueSchemaV3.self),
            .lightweight(fromVersion: QuickCueSchemaV3.self, toVersion: QuickCueSchemaV4.self),
            .lightweight(fromVersion: QuickCueSchemaV4.self, toVersion: QuickCueSchemaV5.self),
            .lightweight(fromVersion: QuickCueSchemaV5.self, toVersion: QuickCueSchemaV6.self),
            .lightweight(fromVersion: QuickCueSchemaV6.self, toVersion: QuickCueSchemaV7.self),
            .lightweight(fromVersion: QuickCueSchemaV7.self, toVersion: QuickCueSchemaV8.self),
            .lightweight(fromVersion: QuickCueSchemaV8.self, toVersion: QuickCueSchemaV9.self),
        ]
    }
}
