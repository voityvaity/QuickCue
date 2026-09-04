import Foundation

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case mock
    case openAI
    case deepSeek
    case anthropic
    case xAI
    case yandexGPT
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mock: "Mock (без сети)"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .anthropic: "Anthropic Claude"
        case .xAI: "xAI Grok"
        case .yandexGPT: "YandexGPT 5 Pro"
        case .custom: "Свой API"
        }
    }

    var keychainAccount: String { "api-key.\(rawValue)" }
}

struct ProviderSelection: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    var kind: ProviderKind {
        if customID != nil { return .custom }
        return ProviderKind(rawValue: rawValue) ?? .custom
    }

    var customID: UUID? {
        guard rawValue.hasPrefix("custom:") else { return nil }
        return UUID(uuidString: String(rawValue.dropFirst("custom:".count)))
    }

    static func builtIn(_ kind: ProviderKind) -> Self {
        Self(rawValue: kind.rawValue)
    }

    static func custom(_ id: UUID) -> Self {
        Self(rawValue: "custom:\(id.uuidString.lowercased())")
    }
}

enum CustomProviderProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAIChatCompletions

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAIChatCompletions: "OpenAI Chat Completions"
        }
    }
}

enum CustomAuthScheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case bearer
    case apiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bearer: "Bearer"
        case .apiKey: "Api-Key"
        }
    }
}

struct CustomProviderProfile: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var baseURL: String
    var protocolKind: CustomProviderProtocol
    var authScheme: CustomAuthScheme
    var modelName: String
    var inputRateRUB: Double
    var outputRateRUB: Double

    init(
        id: UUID = UUID(),
        displayName: String = "Новый провайдер",
        baseURL: String = "",
        protocolKind: CustomProviderProtocol = .openAIChatCompletions,
        authScheme: CustomAuthScheme = .bearer,
        modelName: String = "",
        inputRateRUB: Double = 0,
        outputRateRUB: Double = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.protocolKind = protocolKind
        self.authScheme = authScheme
        self.modelName = modelName
        self.inputRateRUB = inputRateRUB
        self.outputRateRUB = outputRateRUB
    }

    var selection: ProviderSelection { .custom(id) }
    var keychainAccount: String { "api-key.custom.\(id.uuidString.lowercased())" }

}

enum ProviderConnectionState: String, Codable, Sendable {
    case unconfigured
    case unverified
    case verified
    case failed
}

struct ProviderConnectionReport: Codable, Equatable, Sendable {
    var state: ProviderConnectionState
    var modelName: String
    var checkedAt: Date?
    var firstTokenMilliseconds: Int?
    var totalMilliseconds: Int?
    var errorCategory: String?

    static let unconfigured = Self(
        state: .unconfigured,
        modelName: "",
        checkedAt: nil,
        firstTokenMilliseconds: nil,
        totalMilliseconds: nil,
        errorCategory: nil
    )
}

enum AppAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    case light
    case system

    var id: String { rawValue }
    var title: String { self == .light ? "Светлое" : "Как в системе" }
}

enum PromptProfileKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case live
    case conversation
    case photo

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Эфир"
        case .conversation: "Диалог"
        case .photo: "Код и фото"
        }
    }
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

enum AnswerStatus: String, Codable, Sendable {
    case queued
    case thinking
    case streaming
    case completed
    case failed
    case cancelled
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
    let systemPrompt: String

    init(
        id: UUID = UUID(),
        question: String,
        context: [ConversationTurn],
        mode: AnswerMode = .concise,
        imageJPEG: Data? = nil,
        maxOutputTokens: Int = 220,
        systemPrompt: String = PromptFactory.defaultConciseSystem
    ) {
        self.id = id
        self.question = question
        self.context = context
        self.mode = mode
        self.imageJPEG = imageJPEG
        self.maxOutputTokens = maxOutputTokens
        self.systemPrompt = systemPrompt
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
    case incompleteResponse

    var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            "Для \(provider.title) не сохранён ключ. Добавьте его в Настройках или включите Mock."
        case .invalidConfiguration(let detail): detail
        case .badResponse(let code, _): ProviderFailure.message(forHTTPStatus: code)
        case .unsupportedImage(let provider): "\(provider.title) не настроен для прямого анализа изображения."
        case .emptyResponse: "Провайдер завершил запрос без текста."
        case .incompleteResponse: "Ответ оборвался до подтверждения завершения. Частичный текст сохранён — можно повторить запрос."
        }
    }
}

