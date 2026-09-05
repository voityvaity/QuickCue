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
        honorMockMode: Bool = true,
        snapshotCredentials: Bool = false
    ) -> any AIProvider {
        let selection: ProviderSelection = honorMockMode && settings.mockMode
            ? .builtIn(.mock)
            : requested
        let kind = selection.kind
        let model = settings.modelName(for: selection)
        let account = settings.customProvider(for: selection)?.keychainAccount ?? kind.keychainAccount
        let reader: CredentialReader
        if snapshotCredentials, kind != .mock {
            reader = Self.snapshotCredential(account: account, from: secretStore)
        } else {
            reader = { [secretStore] in try secretStore.read(account: account) }
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
            return CustomOpenAIProvider(
                profile: profile,
                credential: reader,
                additionalHeaders: Self.secretHeaders(
                    for: profile,
                    from: secretStore,
                    snapshot: snapshotCredentials
                )
            )
        }
    }

    func provider(
        _ requested: ProviderKind,
        honorMockMode: Bool = true
    ) -> any AIProvider {
        provider(.builtIn(requested), honorMockMode: honorMockMode)
    }

    /// Queue a key and endpoint as one configuration. A later key edit must not
    /// send the new secret to the endpoint captured by an older queued request.
    static func snapshotCredential(account: String, from store: SecretStore) -> CredentialReader {
        let snapshot = Result { try store.read(account: account) }
        return { try snapshot.get() }
    }

    static func secretHeaders(
        for profile: CustomProviderProfile,
        from store: SecretStore,
        snapshot: Bool
    ) -> SecretHeadersReader {
        let load: @Sendable () throws -> [String: String] = {
            var headers: [String: String] = [:]
            for reference in profile.credentialReferences {
                guard reference.keychainAccount == profile.additionalSecretAccount(referenceID: reference.id) else {
                    throw AIProviderError.invalidConfiguration("Повреждена ссылка на секретный заголовок.")
                }
                let name = try CustomSecretHeaderPolicy.normalized(reference.headerName)
                guard headers.keys.allSatisfy({ $0.caseInsensitiveCompare(name) != .orderedSame }),
                      let value = try store.read(account: reference.keychainAccount), !value.isEmpty else {
                    throw AIProviderError.invalidConfiguration("Добавьте значение для секретного заголовка \(name).")
                }
                headers[name] = value
            }
            return headers
        }
        guard snapshot else { return load }
        let captured = Result { try load() }
        return { try captured.get() }
    }
}

