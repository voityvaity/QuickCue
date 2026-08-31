import Foundation
import SwiftData

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

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        question: String,
        answer: String = "",
        provider: ProviderKind,
        modelName: String,
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
