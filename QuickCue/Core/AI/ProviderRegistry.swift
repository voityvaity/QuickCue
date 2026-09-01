import Foundation

@MainActor
struct ProviderRegistry {
    private let settings: AppSettings
    private let secretStore: SecretStore

    init(settings: AppSettings, secretStore: SecretStore = KeychainStore()) {
        self.settings = settings
        self.secretStore = secretStore
    }

    func provider(
        _ requested: ProviderKind,
        honorMockMode: Bool = true
    ) -> any AIProvider {
        let kind: ProviderKind = honorMockMode && settings.mockMode ? .mock : requested
        let model = settings.modelName(for: kind)
        let reader: CredentialReader = { [secretStore] in
            try secretStore.read(account: kind.keychainAccount)
        }

        switch kind {
        case .mock:
            return MockAIProvider()

        case .openAI:
            return OpenAIProvider(
                modelName: model,
                credential: reader
            )

        case .deepSeek:
            return DeepSeekProvider(
                modelName: model,
                credential: reader
            )
        
        case .anthropic:
            return AnthropicProvider(
                modelName: model,
                credential: reader
            )
        
        case .xAI:
            return XAIProvider(
                modelName: model,
                credential: reader
            )
        
        case .yandexGPT:
            return YandexGPTProvider(
                modelName: model,
                folderID: settings.yandexFolderID,
                credential: reader
            )
        }
    }
}

