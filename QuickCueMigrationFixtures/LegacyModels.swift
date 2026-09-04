import Foundation
import SwiftData

// Frozen persisted shape of the original unversioned v0.3 app (commit 1de0370).
// Top-level names intentionally match that release. A separate test-only module
// lets tests write a real legacy database without referencing a VersionedSchema.
// Initializers use raw strings to avoid a dependency on the current app model API.

@Model
public final class SessionRecord {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String
    public var providerRaw: String
    public var questionCount: Int
    public var photoCount: Int
    public var estimatedCostRUB: Double

    public init(id: UUID, title: String) {
        self.id = id
        self.startedAt = Date(timeIntervalSince1970: 1_780_000_000)
        self.title = title
        self.providerRaw = "openAI"
        self.questionCount = 1
        self.photoCount = 1
        self.estimatedCostRUB = 0.25
    }
}

@Model
public final class TranscriptRecord {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    public var text: String
    public var confidence: Double
    public var isQuestion: Bool

    public init(id: UUID, sessionID: UUID, text: String) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = .now
        self.text = text
        self.confidence = 0.92
        self.isQuestion = true
    }
}

@Model
public final class AnswerRecord {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    public var question: String
    public var answer: String
    public var providerRaw: String
    public var modelName: String
    public var firstTokenMilliseconds: Int
    public var totalMilliseconds: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var feedback: Int
    public var requestKindRaw: String = "concise"
    public var statusRaw: String = "completed"
    public var errorMessage: String?

    public init(id: UUID, sessionID: UUID, question: String, answer: String) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = .now
        self.question = question
        self.answer = answer
        self.providerRaw = "openAI"
        self.modelName = "legacy-model"
        self.firstTokenMilliseconds = 520
        self.totalMilliseconds = 1_700
        self.inputTokens = 100
        self.outputTokens = 50
        self.feedback = 1
        self.errorMessage = nil
    }
}

@Model
public final class ConversationMessageRecord {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    public var speakerRaw: String
    public var kindRaw: String
    public var text: String
    public var statusRaw: String
    public var confidence: Double
    public var photoRelativePath: String?
    public var answerID: UUID?

    public init(id: UUID, sessionID: UUID, answerID: UUID, text: String) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = .now
        self.speakerRaw = "assistant"
        self.kindRaw = "answer"
        self.text = text
        self.statusRaw = "completed"
        self.confidence = 1
        self.photoRelativePath = nil
        self.answerID = answerID
    }
}

@Model
public final class PhotoRecord {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID?
    public var createdAt: Date
    public var relativePath: String
    public var recognizedText: String
    public var answerID: UUID?

    public init(id: UUID, sessionID: UUID, answerID: UUID, relativePath: String) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = .now
        self.relativePath = relativePath
        self.recognizedText = "print(42)"
        self.answerID = answerID
    }
}

@Model
public final class UsageRecord {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var sessionID: UUID
    public var providerRaw: String
    public var requestKind: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var estimatedCostRUB: Double

    public init(id: UUID, sessionID: UUID) {
        self.id = id
        self.createdAt = .now
        self.sessionID = sessionID
        self.providerRaw = "openAI"
        self.requestKind = "concise"
        self.inputTokens = 100
        self.outputTokens = 50
        self.estimatedCostRUB = 0.25
    }
}
