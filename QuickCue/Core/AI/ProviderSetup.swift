import Combine
import Foundation

struct ProviderPreset: Identifiable, Sendable {
    let kind: ProviderKind
    let summary: String
    let destinationHost: String
    let requiresFolderID: Bool

    var id: String { kind.rawValue }

    static let builtIn: [Self] = [
        .init(kind: .deepSeek, summary: "Быстрые короткие ответы", destinationHost: "api.deepseek.com", requiresFolderID: false),
        .init(kind: .openAI, summary: "Текст и фотографии", destinationHost: "api.openai.com", requiresFolderID: false),
        .init(kind: .anthropic, summary: "Claude: текст и фотографии", destinationHost: "api.anthropic.com", requiresFolderID: false),
        .init(kind: .xAI, summary: "Grok: потоковые ответы", destinationHost: "api.x.ai", requiresFolderID: false),
        .init(kind: .yandexGPT, summary: "Yandex Cloud AI Studio", destinationHost: "ai.api.cloud.yandex.net", requiresFolderID: true),
    ]

    static func preset(for kind: ProviderKind) -> Self? {
        builtIn.first { $0.kind == kind }
    }
}

enum ProviderSetupState: Equatable {
    case editing
    case needsAdditionalFields
    case discovering
    case testing
    case connected(ProviderConnectionReport)
    case failed(String)
}

/// Non-secret recovery record. The candidate itself stays in Keychain.
struct ProviderSetupActivation: Codable, Equatable, Sendable {
    let selection: ProviderSelection
    let modelName: String
    let yandexFolderID: String?
    let candidateAccount: String
    let report: ProviderConnectionReport
    var modelSelectionPolicy: ModelSelectionPolicy? = nil
    var credentialCopied = false

    var isValid: Bool {
        selection.customID == nil
            && selection.kind != .mock
            && selection.kind != .custom
            && candidateAccount.hasPrefix("api-key.setup.")
            && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (selection.kind != .yandexGPT
                || !(yandexFolderID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && report.state == .verified
            && report.modelName == modelName
            && (modelSelectionPolicy == nil || modelSelectionPolicy?.resolvedExplicitModel == nil
                || modelSelectionPolicy?.resolvedExplicitModel == modelName)
    }
}

@MainActor
struct ProviderSetupRecoveryStore {
    private static let markerKey = "settings.providerSetup.pendingActivation.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func begin(_ activation: ProviderSetupActivation) throws {
        guard activation.isValid else { throw ProviderSetupError.invalidActivation }
        var prepared = activation
        prepared.credentialCopied = false
        defaults.set(try JSONEncoder().encode(prepared), forKey: Self.markerKey)
    }

    func complete(
        _ activation: ProviderSetupActivation,
        settings: AppSettings,
        secretStore: SecretStore
    ) throws {
        guard activation.isValid,
              var pending = pendingActivation(),
              pending.isSameOperation(as: activation) else {
            throw ProviderSetupError.invalidActivation
        }
        let targetAccount = pending.selection.kind.keychainAccount
        if pending.credentialCopied {
            guard try secretStore.read(account: targetAccount) != nil else {
                throw ProviderSetupError.missingCandidate
            }
        } else {
            guard let candidate = try secretStore.read(account: pending.candidateAccount),
                  !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderSetupError.missingCandidate
            }
            try secretStore.save(candidate, account: targetAccount)
            pending.credentialCopied = true
            defaults.set(try JSONEncoder().encode(pending), forKey: Self.markerKey)
        }

        settings.activateVerifiedProvider(
            pending.selection,
            modelName: pending.modelName,
            yandexFolderID: pending.yandexFolderID,
            report: pending.report,
            modelSelectionPolicy: pending.modelSelectionPolicy
        )
        defaults.removeObject(forKey: Self.markerKey)
        try? secretStore.delete(account: pending.candidateAccount)
    }

    func recoverIfNeeded(settings: AppSettings, secretStore: SecretStore) {
        guard let data = defaults.data(forKey: Self.markerKey) else { return }
        guard let activation = try? JSONDecoder().decode(ProviderSetupActivation.self, from: data),
              activation.isValid else {
            defaults.removeObject(forKey: Self.markerKey)
            return
        }
        // Leave a valid marker in place when Keychain is temporarily
        // unavailable. The next launch retries the same idempotent completion.
        try? complete(activation, settings: settings, secretStore: secretStore)
    }

    func hasPendingActivation(candidateAccount: String) -> Bool {
        guard let activation = pendingActivation() else { return false }
        return activation.candidateAccount == candidateAccount
    }

    private func pendingActivation() -> ProviderSetupActivation? {
        guard let data = defaults.data(forKey: Self.markerKey) else { return nil }
        return try? JSONDecoder().decode(ProviderSetupActivation.self, from: data)
    }
}

private extension ProviderSetupActivation {
    func isSameOperation(as other: Self) -> Bool {
        selection == other.selection
            && modelName == other.modelName
            && yandexFolderID == other.yandexFolderID
            && candidateAccount == other.candidateAccount
            && report == other.report
            && modelSelectionPolicy == other.modelSelectionPolicy
    }
}

private extension ModelSelectionPolicy {
    var resolvedExplicitModel: String? {
        if case .explicit(let model) = self {
            return model.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

enum ProviderSetupError: LocalizedError {
    case missingCandidate
    case invalidActivation

    var errorDescription: String? {
        switch self {
        case .missingCandidate: "Временный ключ не найден. Введите или сфотографируйте его ещё раз."
        case .invalidActivation: "Не удалось безопасно завершить настройку провайдера."
        }
    }
}

@MainActor
final class ProviderSetupCoordinator: ObservableObject {
    typealias Verifier = @MainActor (any AIProvider, UUID) async throws -> ProviderConnectionChecker.Result
    typealias MetadataLoader = @MainActor (
        ProviderSelection,
        CustomProviderProfile?,
        CredentialReader
    ) async throws -> MetadataResult

    @Published private(set) var selectedProvider: ProviderKind = .deepSeek
    @Published private(set) var state: ProviderSetupState = .editing
    @Published private(set) var credentialLength = 0
    @Published private(set) var resolvedModelName = ""
    @Published private(set) var metadataStatus: ProviderMetadataStatus = .notRequested
    @Published var yandexFolderID = "" {
        didSet {
            guard oldValue != yandexFolderID else { return }
            revision = UUID()
            state = .editing
        }
    }

    // Swift rejects covariant `Self` in a class stored-property initializer,
    // including for final classes. Use the concrete type at this boundary.
    private(set) var candidateAccount = ProviderSetupCoordinator.makeCandidateAccount()

    private let settings: AppSettings
    private let secretStore: SecretStore
    private let recoveryStore: ProviderSetupRecoveryStore
    private let verifier: Verifier
    private let metadataLoader: MetadataLoader
    private let metadataCache: ProviderMetadataCache
    private var revision = UUID()
    private var connectionTask: Task<Void, Never>?
    private var activeOperationRevision: UUID?

    init(
        settings: AppSettings,
        secretStore: SecretStore = KeychainStore(),
        defaults: UserDefaults = .standard,
        verifier: @escaping Verifier = { provider, requestID in
            try await ProviderConnectionChecker.verify(provider: provider, requestID: requestID)
        },
        metadataLoader: MetadataLoader? = nil
    ) {
        self.settings = settings
        self.secretStore = secretStore
        self.recoveryStore = ProviderSetupRecoveryStore(defaults: defaults)
        self.verifier = verifier
        let metadataClient = ProviderMetadataClient()
        self.metadataLoader = metadataLoader ?? { selection, profile, credential in
            try await metadataClient.metadata(for: selection, customProfile: profile, credential: credential)
        }
        self.metadataCache = ProviderMetadataCache(defaults: defaults)
        self.yandexFolderID = settings.yandexFolderID
        self.recoveryStore.recoverIfNeeded(settings: settings, secretStore: secretStore)
        self.yandexFolderID = settings.yandexFolderID
        self.resolvedModelName = settings.modelName(for: selectedProvider)
    }

    var preset: ProviderPreset { ProviderPreset.preset(for: selectedProvider)! }
    var canConnect: Bool {
        credentialLength > 0
            && !isBusy
            && (!preset.requiresFolderID || !trimmedFolderID.isEmpty)
    }
    var modelName: String { resolvedModelName }
    var isBusy: Bool {
        state == .discovering || state == .testing
    }

    func select(_ provider: ProviderKind) {
        guard !isBusy,
              ProviderPreset.preset(for: provider) != nil,
              provider != selectedProvider else { return }
        discardCandidate()
        selectedProvider = provider
        candidateAccount = Self.makeCandidateAccount()
        credentialLength = 0
        yandexFolderID = provider == .yandexGPT ? settings.yandexFolderID : ""
        resolvedModelName = settings.modelName(for: provider)
        metadataStatus = .notRequested
        revision = UUID()
        state = .editing
    }

    /// KeyEditor reports only the opaque Keychain account, never the secret.
    func candidateStored(account: String) {
        guard account == candidateAccount else { return }
        do {
            credentialLength = try secretStore.read(account: account)?.count ?? 0
        } catch {
            credentialLength = 0
            state = .failed("credential_storage")
            return
        }
        revision = UUID()
        state = .editing
    }

    func connect() {
        guard !isBusy, connectionTask == nil else { return }
        guard credentialLength > 0 else {
            state = .failed("credential_missing")
            return
        }
        if preset.requiresFolderID, trimmedFolderID.isEmpty {
            state = .needsAdditionalFields
            return
        }

        let operationRevision = revision
        let selection = ProviderSelection.builtIn(selectedProvider)
        let initialModel = settings.modelName(for: selection)
        let selectionPolicy = settings.modelSelectionPolicy(for: selection)
        guard !initialModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("model_or_endpoint")
            return
        }
        let folderID = selectedProvider == .yandexGPT ? trimmedFolderID : nil
        let requestID = UUID()
        let account = candidateAccount
        let reader = ProviderRegistry.snapshotCredential(account: account, from: secretStore)
        state = shouldDiscover(selection: selection, policy: selectionPolicy) ? .discovering : .testing
        activeOperationRevision = operationRevision
        connectionTask = Task { [weak self] in
            await self?.performConnection(
                operationRevision: operationRevision,
                selection: selection,
                initialModel: initialModel,
                selectionPolicy: selectionPolicy,
                folderID: folderID,
                requestID: requestID,
                account: account,
                credential: reader
            )
        }
    }

    func waitForConnection() async {
        let task = connectionTask
        await task?.value
    }

    private func performConnection(
        operationRevision: UUID,
        selection: ProviderSelection,
        initialModel: String,
        selectionPolicy: ModelSelectionPolicy,
        folderID: String?,
        requestID: UUID,
        account: String,
        credential: @escaping CredentialReader
    ) async {
        defer {
            if activeOperationRevision == operationRevision {
                connectionTask = nil
                activeOperationRevision = nil
            }
        }
        do {
            let model = try await resolveModel(
                initialModel: initialModel,
                selection: selection,
                policy: selectionPolicy,
                credential: credential
            )
            try Task.checkCancellation()
            guard revision == operationRevision, account == candidateAccount else {
                if isBusy { state = .editing }
                return
            }
            resolvedModelName = model
            state = .testing
            let provider = makeProvider(
                kind: selection.kind,
                modelName: model,
                folderID: folderID,
                credential: credential
            )
            let result = try await verifier(provider, requestID)
            try Task.checkCancellation()
            guard revision == operationRevision, account == candidateAccount else {
                if state == .testing { state = .editing }
                return
            }
            let report = ProviderConnectionReport(
                state: .verified,
                modelName: model,
                checkedAt: .now,
                firstTokenMilliseconds: result.firstTokenMilliseconds,
                totalMilliseconds: result.totalMilliseconds,
                errorCategory: nil,
                requestID: requestID,
                buildIdentity: .current
            )
            let activation = ProviderSetupActivation(
                selection: selection,
                modelName: model,
                yandexFolderID: folderID,
                candidateAccount: account,
                report: report,
                modelSelectionPolicy: selectionPolicy
            )
            try recoveryStore.begin(activation)
            try recoveryStore.complete(activation, settings: settings, secretStore: secretStore)
            credentialLength = 0
            state = .connected(report)
        } catch is CancellationError {
            if revision == operationRevision { state = .editing }
        } catch {
            guard revision == operationRevision else { return }
            state = .failed(error is ProviderSetupError ? "setup_commit" : ProviderFailure.category(for: error))
        }
    }

    func cancel() {
        connectionTask?.cancel()
        revision = UUID()
        if !recoveryStore.hasPendingActivation(candidateAccount: candidateAccount) {
            discardCandidate()
        }
        credentialLength = 0
        if case .connected = state {
            return
        } else {
            state = .editing
        }
    }

    private func shouldDiscover(selection: ProviderSelection, policy: ModelSelectionPolicy) -> Bool {
        guard case .recommended = policy else { return false }
        return ProviderMetadataClient.supportsDiscovery(for: selection)
    }

    private func resolveModel(
        initialModel: String,
        selection: ProviderSelection,
        policy: ModelSelectionPolicy,
        credential: @escaping CredentialReader
    ) async throws -> String {
        if case .explicit(let explicitModel) = policy {
            metadataStatus = .explicit
            return explicitModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard ProviderMetadataClient.supportsDiscovery(for: selection) else {
            metadataStatus = .unsupported
            return initialModel
        }
        if let cached = metadataCache.freshSnapshot(for: selection) {
            if let selected = ProviderModelSelector.select(from: cached, policy: policy, provider: selection.kind) {
                metadataStatus = .cached
                return selected
            }
            metadataStatus = .noRecommendedModel
            return initialModel
        }

        let result = try await metadataLoader(selection, nil, credential)
        switch result {
        case .available(let snapshot):
            metadataCache.save(snapshot, for: selection)
            guard let selected = ProviderModelSelector.select(from: snapshot, policy: policy, provider: selection.kind) else {
                metadataStatus = .noRecommendedModel
                return initialModel
            }
            metadataStatus = .discovered
            return selected
        case .unsupported:
            metadataStatus = .unsupported
            return initialModel
        case .unavailable(let reason):
            metadataStatus = .unavailable(reason)
            return initialModel
        }
    }

    private var trimmedFolderID: String {
        yandexFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func discardCandidate() {
        try? secretStore.delete(account: candidateAccount)
    }

    private func makeProvider(
        kind: ProviderKind,
        modelName: String,
        folderID: String?,
        credential: @escaping CredentialReader
    ) -> any AIProvider {
        return switch kind {
        case .openAI: OpenAIProvider(modelName: modelName, credential: credential)
        case .deepSeek: DeepSeekProvider(modelName: modelName, credential: credential)
        case .anthropic: AnthropicProvider(modelName: modelName, credential: credential)
        case .xAI: XAIProvider(modelName: modelName, credential: credential)
        case .yandexGPT: YandexGPTProvider(modelName: modelName, folderID: folderID ?? "", credential: credential)
        case .mock, .custom: MockAIProvider()
        }
    }

    private static func makeCandidateAccount() -> String {
        "api-key.setup.\(UUID().uuidString.lowercased())"
    }
}
