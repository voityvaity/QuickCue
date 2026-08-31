import Foundation

@MainActor
struct ProviderRegistry {
    private let settings: AppSettings
    private let secretStore: SecretStore

    init(settings: AppSettings, secretStore: SecretStore = KeychainStore()) {
        self.settings = settings
        self.secretStore = secretStore
    }

    func provider(_ requested: ProviderKind) -> any AIProvider {
        let kind: ProviderKind = settings.mockMode ? .mock : requested
        let model = settings.modelName(for: kind)
        let reader: CredentialReader = { [secretStore] in
            try secretStore.read(account: kind.keychainAccount)
        }

        switch kind {
        case .mock: MockAIProvider()
        case .openAI: OpenAIProvider(modelName: model, credential: reader)
        case .deepSeek: DeepSeekProvider(modelName: model, credential: reader)
        case .anthropic: AnthropicProvider(modelName: model, credential: reader)
        case .xAI: XAIProvider(modelName: model, credential: reader)
        case .yandexGPT:
            YandexGPTProvider(modelName: model, folderID: settings.yandexFolderID, credential: reader)
        }
    }
}

