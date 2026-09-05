import Foundation
import SwiftData

/// Current schema. V1 and V2 are frozen migration inputs and must never be edited.
enum QuickCueSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [SessionRecord.self, TranscriptRecord.self, AnswerRecord.self, PhotoRecord.self, UsageRecord.self, ConversationMessageRecord.self]
    }

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
            id: UUID = UUID(), sessionID: UUID, question: String, answer: String = "",
            provider: ProviderKind, modelName: String, requestKind: AnswerMode = .concise,
            status: AnswerStatus = .completed, firstTokenMilliseconds: Int = 0,
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
            sessionID: UUID, speaker: ConversationSpeaker, kind: ConversationMessageKind,
            text: String, status: AnswerStatus = .completed, confidence: Double = 0,
            photoRelativePath: String? = nil, answerID: UUID? = nil
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
        /// Nil means setup/connection work that is intentionally outside conversation history.
        var sessionID: UUID?
        var providerRaw: String
        var requestKind: String
        var inputTokens: Int
        var outputTokens: Int
        /// Known RUB subtotal only. Read `costSourceRaw` before presenting it as a total.
        var estimatedCostRUB: Double
        var requestID: UUID?
        var attemptID: UUID?
        var providerSelectionRaw: String?
        var modelName: String?
        var outcomeRaw: String?
        /// reported / estimated / unknown
        var usageSourceRaw: String?
        /// api_reported / calculated / unknown / free_mock / not_sent
        var costSourceRaw: String?
        var errorCode: String?
        var durationMilliseconds: Int?
        var cachedInputTokens: Int?
        var providerReportedCost: Double?
        var costCurrencyCode: String?
        var pricingSnapshotDate: Date?
        var pricingModelName: String?

        init(sessionID: UUID?, provider: ProviderKind, requestKind: String) {
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
