import Foundation

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case mock
    case openAI
    case deepSeek
    case anthropic
    case xAI
    case yandexGPT

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mock: "Mock (без сети)"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .anthropic: "Anthropic Claude"
        case .xAI: "xAI Grok"
        case .yandexGPT: "YandexGPT 5.1 Pro"
        }
    }

    var keychainAccount: String { "api-key.\(rawValue)" }
}

enum AnswerMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case concise
    case code
    case photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .concise: "Коротко"
        case .code: "Программирование"
        case .photo: "Фото-задача"
        }
    }
}

struct ConversationTurn: Codable, Hashable, Sendable {
    let role: String
    let text: String
}

struct AIRequest: Sendable {
    let id: UUID
    let question: String
    let context: [ConversationTurn]
    let mode: AnswerMode
    let imageJPEG: Data?
    let maxOutputTokens: Int

    init(
        id: UUID = UUID(),
        question: String,
        context: [ConversationTurn],
        mode: AnswerMode = .concise,
        imageJPEG: Data? = nil,
        maxOutputTokens: Int = 220
    ) {
        self.id = id
        self.question = question
        self.context = context
        self.mode = mode
        self.imageJPEG = imageJPEG
        self.maxOutputTokens = maxOutputTokens
    }
}

struct TokenUsage: Codable, Hashable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
}

enum AIStreamEvent: Sendable {
    case textDelta(String)
    case usage(TokenUsage)
    case completed
}

struct ProviderCapabilities: Sendable {
    let supportsText: Bool
    let supportsImages: Bool
    let supportsStreaming: Bool
}

enum AIProviderError: LocalizedError {
    case missingCredential(ProviderKind)
    case invalidConfiguration(String)
    case badResponse(Int, String)
    case unsupportedImage(ProviderKind)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            "Для \(provider.title) не сохранён ключ. Добавьте его в Настройках или включите Mock."
        case .invalidConfiguration(let detail): detail
        case .badResponse(let code, let detail): "API вернул \(code): \(detail)"
        case .unsupportedImage(let provider): "\(provider.title) не настроен для прямого анализа изображения."
        case .emptyResponse: "Провайдер завершил запрос без текста."
        }
    }
}

