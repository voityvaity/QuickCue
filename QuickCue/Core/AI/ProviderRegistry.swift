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
        _ requested: ProviderSelection,
        honorMockMode: Bool = true
    ) -> any AIProvider {
        let selection: ProviderSelection = honorMockMode && settings.mockMode
            ? .builtIn(.mock)
            : requested
        let kind = selection.kind
        let model = settings.modelName(for: selection)
        let account = settings.customProvider(for: selection)?.keychainAccount ?? kind.keychainAccount
        let reader: CredentialReader = { [secretStore] in
            try secretStore.read(account: account)
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

        case .custom:
            let profile = settings.customProvider(for: selection) ?? CustomProviderProfile(
                id: selection.customID ?? UUID(),
                displayName: "Удалённый провайдер"
            )
            return CustomOpenAIProvider(profile: profile, credential: reader)
        }
    }

    func provider(
        _ requested: ProviderKind,
        honorMockMode: Bool = true
    ) -> any AIProvider {
        provider(.builtIn(requested), honorMockMode: honorMockMode)
    }
}

