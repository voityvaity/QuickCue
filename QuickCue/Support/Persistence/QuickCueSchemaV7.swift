import Foundation
import SwiftData

/// Stage 11 schema. Earlier schemas are frozen migration inputs.
enum QuickCueSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            SessionRecord.self, TranscriptRecord.self, AnswerRecord.self, PhotoRecord.self,
            UsageRecord.self, ConversationMessageRecord.self, CandidateProfile.self,
            JobProfile.self, AttachmentRecord.self, ContextProfile.self, SessionContextSnapshot.self,
        ]
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
        var contextSnapshotID: UUID?
        var contextTitle: String?

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
        var revision: Int = 1
        var speechEngineRaw: String?
        var endpointDelayMilliseconds: Int?
        var finalizationMilliseconds: Int?

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
        var responseStyleRaw: String?
        var sourceTranscriptID: UUID?
        var sourceMessageID: UUID?
        var questionRevision: Int = 1
        var parentAnswerID: UUID?
        var isStale: Bool = false
        var isFavorite: Bool = false
        var contextSnapshotID: UUID?
        var queueWaitMilliseconds: Int?
        var speechEngineRaw: String?
        var speechEndpointDelayMilliseconds: Int?
        var speechFinalizationMilliseconds: Int?

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
        var transcriptID: UUID?
        var revision: Int = 1
        var speakerSourceRaw: String?
        var speakerConfidence: Double?
        var speakerManuallyLocked: Bool = false
        var diarizationLabelRaw: String?

        init(
            sessionID: UUID, speaker: ConversationSpeaker, kind: ConversationMessageKind,
            text: String, status: AnswerStatus = .completed, confidence: Double = 0,
            photoRelativePath: String? = nil, answerID: UUID? = nil, transcriptID: UUID? = nil
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
            self.transcriptID = transcriptID
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
        var sessionID: UUID?
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

    @Model
    final class CandidateProfile {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var title: String
        var revision: Int
        var experience: String
        var projects: String
        var education: String
        var skills: String
        var achievements: String
        var language: String
        var level: String
        var isDefault: Bool

        init(id: UUID = UUID(), title: String) {
            self.id = id
            self.createdAt = .now
            self.updatedAt = .now
            self.title = title
            self.revision = 1
            self.experience = ""
            self.projects = ""
            self.education = ""
            self.skills = ""
            self.achievements = ""
            self.language = ""
            self.level = ""
            self.isDefault = false
        }
    }

    @Model
    final class JobProfile {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var title: String
        var revision: Int
        var company: String
        var role: String
        var vacancyText: String
        var topics: String
        var notes: String

        init(id: UUID = UUID(), title: String) {
            self.id = id
            self.createdAt = .now
            self.updatedAt = .now
            self.title = title
            self.revision = 1
            self.company = ""
            self.role = ""
            self.vacancyText = ""
            self.topics = ""
            self.notes = ""
        }
    }

    @Model
    final class AttachmentRecord {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var title: String
        var revision: Int
        var kindRaw: String
        var statusRaw: String
        var extractedText: String
        var sourceFilename: String?
        var sourceByteCount: Int
        var importWasTruncated: Bool

        init(
            id: UUID = UUID(), title: String, kindRaw: String, extractedText: String,
            sourceFilename: String? = nil, sourceByteCount: Int = 0,
            importWasTruncated: Bool = false
        ) {
            self.id = id
            self.createdAt = .now
            self.updatedAt = .now
            self.title = title
            self.revision = 1
            self.kindRaw = kindRaw
            self.statusRaw = "ready"
            self.extractedText = extractedText
            self.sourceFilename = sourceFilename
            self.sourceByteCount = sourceByteCount
            self.importWasTruncated = importWasTruncated
        }
    }

    @Model
    final class ContextProfile {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var title: String
        var scenario: String
        var revision: Int
        var candidateProfileID: UUID?
        var jobProfileID: UUID?
        var selectedAttachmentIDsData: Data

        init(id: UUID = UUID(), title: String) {
            self.id = id
            self.createdAt = .now
            self.updatedAt = .now
            self.title = title
            self.scenario = ""
            self.revision = 1
            self.selectedAttachmentIDsData = Data("[]".utf8)
        }
    }

    @Model
    final class SessionContextSnapshot {
        @Attribute(.unique) var id: UUID
        var sessionID: UUID
        var createdAt: Date
        var contextProfileID: UUID
        var contextProfileRevision: Int
        var candidateProfileID: UUID?
        var candidateRevision: Int?
        var jobProfileID: UUID?
        var jobRevision: Int?
        var attachmentRevisionsData: Data
        var title: String
        var text: String
        var wasTruncated: Bool
        var originalCharacterCount: Int

        init(
            id: UUID = UUID(), sessionID: UUID, contextProfileID: UUID,
            contextProfileRevision: Int, title: String, text: String
        ) {
            self.id = id
            self.sessionID = sessionID
            self.createdAt = .now
            self.contextProfileID = contextProfileID
            self.contextProfileRevision = contextProfileRevision
            self.attachmentRevisionsData = Data("{}".utf8)
            self.title = title
            self.text = text
            self.wasTruncated = false
            self.originalCharacterCount = text.count
        }
    }
}



