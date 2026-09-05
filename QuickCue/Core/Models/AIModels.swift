import Foundation

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
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
    case openAIResponses
    case anthropicMessages

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAIChatCompletions: "OpenAI Chat Completions"
        case .openAIResponses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic Messages"
        }
    }

    var endpointSuffix: String {
        switch self {
        case .openAIChatCompletions: "chat/completions"
        case .openAIResponses: "responses"
        case .anthropicMessages: "messages"
        }
    }

    var supportsModelDiscovery: Bool { self != .anthropicMessages }
}

enum CustomAuthScheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case bearer
    /// Preserves profiles created before B3a, which sent `Authorization: Api-Key …`.
    case apiKey
    case apiKeyHeader
    case xAPIKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bearer: "Bearer"
        case .apiKey: "Authorization: Api-Key (старый вариант)"
        case .apiKeyHeader: "Api-Key"
        case .xAPIKey: "x-api-key"
        }
    }

    func headers(credential: String) -> [String: String] {
        switch self {
        case .bearer: ["Authorization": "Bearer \(credential)"]
        case .apiKey: ["Authorization": "Api-Key \(credential)"]
        case .apiKeyHeader: ["Api-Key": credential]
        case .xAPIKey: ["x-api-key": credential]
        }
    }
}

enum ListeningNavigationPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case ask
    case continueWhileActive
    case stopOnTabChange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Спрашивать"
        case .continueWhileActive: "Продолжать"
        case .stopOnTabChange: "Останавливать"
        }
    }
}

enum AnswerTriggerPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .manual: "Вручную"
        }
    }
}

struct ModelProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var apiModelID: String
    var displayName: String
    var capabilities: ProviderModelCapabilities
    var selectionPolicy: ModelSelectionPolicy
    var inputRateRUB: Double
    var outputRateRUB: Double

    init(
        id: UUID = UUID(),
        apiModelID: String = "",
        displayName: String = "",
        capabilities: ProviderModelCapabilities = .unknown,
        selectionPolicy: ModelSelectionPolicy? = nil,
        inputRateRUB: Double = 0,
        outputRateRUB: Double = 0
    ) {
        self.id = id
        self.apiModelID = apiModelID
        self.displayName = displayName.isEmpty ? apiModelID : displayName
        self.capabilities = capabilities
        self.selectionPolicy = selectionPolicy ?? .explicit(apiModelID)
        self.inputRateRUB = inputRateRUB
        self.outputRateRUB = outputRateRUB
    }
}

struct ProviderCredentialReference: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var headerName: String
    var keychainAccount: String

    init(id: UUID = UUID(), headerName: String, keychainAccount: String) {
        self.id = id
        self.headerName = headerName
        self.keychainAccount = keychainAccount
    }
}

struct ProviderProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var baseURL: String
    var protocolKind: CustomProviderProtocol
    var authScheme: CustomAuthScheme
    var models: [ModelProfile]
    var selectedModelID: UUID?
    var credentialReferences: [ProviderCredentialReference]

    init(
        id: UUID = UUID(),
        displayName: String = "Новый провайдер",
        baseURL: String = "",
        protocolKind: CustomProviderProtocol = .openAIChatCompletions,
        authScheme: CustomAuthScheme = .bearer,
        modelName: String = "",
        inputRateRUB: Double = 0,
        outputRateRUB: Double = 0,
        models: [ModelProfile]? = nil,
        selectedModelID: UUID? = nil,
        credentialReferences: [ProviderCredentialReference] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.protocolKind = protocolKind
        self.authScheme = authScheme
        let initialModels = models ?? [ModelProfile(
            apiModelID: modelName,
            inputRateRUB: inputRateRUB,
            outputRateRUB: outputRateRUB
        )]
        self.models = initialModels
        self.selectedModelID = selectedModelID.flatMap { id in initialModels.contains(where: { $0.id == id }) ? id : nil }
            ?? initialModels.first?.id
        self.credentialReferences = credentialReferences
    }

    var selection: ProviderSelection { .custom(id) }
    var keychainAccount: String { "api-key.custom.\(id.uuidString.lowercased())" }

    func additionalSecretAccount(referenceID: UUID) -> String {
        "api-key.custom.\(id.uuidString.lowercased()).header.\(referenceID.uuidString.lowercased())"
    }

    var selectedModel: ModelProfile? {
        get {
            if let selectedModelID, let selected = models.first(where: { $0.id == selectedModelID }) { return selected }
            return models.first
        }
        set {
            guard let newValue else {
                selectedModelID = nil
                return
            }
            if let index = models.firstIndex(where: { $0.id == newValue.id }) { models[index] = newValue }
            else { models.append(newValue) }
            selectedModelID = newValue.id
        }
    }

    var modelName: String {
        get { selectedModel?.apiModelID ?? "" }
        set {
            if var selected = selectedModel {
                selected.apiModelID = newValue
                if selected.displayName.isEmpty { selected.displayName = newValue }
                selected.selectionPolicy = .explicit(newValue)
                self.selectedModel = selected
            } else {
                let model = ModelProfile(apiModelID: newValue)
                models = [model]
                selectedModelID = model.id
            }
        }
    }

    var inputRateRUB: Double {
        get { selectedModel?.inputRateRUB ?? 0 }
        set {
            guard var selected = selectedModel else { return }
            selected.inputRateRUB = newValue
            self.selectedModel = selected
        }
    }

    var outputRateRUB: Double {
        get { selectedModel?.outputRateRUB ?? 0 }
        set {
            guard var selected = selectedModel else { return }
            selected.outputRateRUB = newValue
            self.selectedModel = selected
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, baseURL, protocolKind, authScheme, models, selectedModelID, credentialReferences
        case modelName, inputRateRUB, outputRateRUB
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        protocolKind = try values.decode(CustomProviderProtocol.self, forKey: .protocolKind)
        authScheme = try values.decode(CustomAuthScheme.self, forKey: .authScheme)
        credentialReferences = try values.decodeIfPresent([ProviderCredentialReference].self, forKey: .credentialReferences) ?? []
        if let decodedModels = try values.decodeIfPresent([ModelProfile].self, forKey: .models), !decodedModels.isEmpty {
            models = decodedModels
            let requested = try values.decodeIfPresent(UUID.self, forKey: .selectedModelID)
            selectedModelID = requested.flatMap { id in decodedModels.contains(where: { $0.id == id }) ? id : nil }
                ?? decodedModels.first?.id
        } else {
            let legacyModel = try values.decodeIfPresent(String.self, forKey: .modelName) ?? ""
            let model = ModelProfile(
                apiModelID: legacyModel,
                inputRateRUB: try values.decodeIfPresent(Double.self, forKey: .inputRateRUB) ?? 0,
                outputRateRUB: try values.decodeIfPresent(Double.self, forKey: .outputRateRUB) ?? 0
            )
            models = [model]
            selectedModelID = model.id
        }
        var seenHeaders = Set<String>()
        for reference in credentialReferences {
            let expectedAccount = additionalSecretAccount(referenceID: reference.id)
            let normalized = try CustomSecretHeaderPolicy.normalized(reference.headerName)
            guard reference.keychainAccount == expectedAccount,
                  seenHeaders.insert(normalized.lowercased()).inserted else {
                throw DecodingError.dataCorruptedError(
                    forKey: .credentialReferences,
                    in: values,
                    debugDescription: "Invalid or duplicate credential reference"
                )
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(protocolKind, forKey: .protocolKind)
        try values.encode(authScheme, forKey: .authScheme)
        try values.encode(models, forKey: .models)
        try values.encodeIfPresent(selectedModelID, forKey: .selectedModelID)
        try values.encode(credentialReferences, forKey: .credentialReferences)
    }

}

/// Source-compatible name for the B3a code while persisted profiles use the B3b model.
typealias CustomProviderProfile = ProviderProfile

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
    var requestID: UUID? = nil
    var buildIdentity: BuildIdentity? = nil

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

