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
            report: pending.report
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

    @Published private(set) var selectedProvider: ProviderKind = .deepSeek
    @Published private(set) var state: ProviderSetupState = .editing
    @Published private(set) var credentialLength = 0
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
    private var revision = UUID()
    private var connectionTask: Task<Void, Never>?
    private var activeOperationRevision: UUID?

    init(
        settings: AppSettings,
        secretStore: SecretStore = KeychainStore(),
        defaults: UserDefaults = .standard,
        verifier: @escaping Verifier = { provider, requestID in
            try await ProviderConnectionChecker.verify(provider: provider, requestID: requestID)
        }
    ) {
        self.settings = settings
        self.secretStore = secretStore
        self.recoveryStore = ProviderSetupRecoveryStore(defaults: defaults)
        self.verifier = verifier
        self.yandexFolderID = settings.yandexFolderID
        self.recoveryStore.recoverIfNeeded(settings: settings, secretStore: secretStore)
        self.yandexFolderID = settings.yandexFolderID
    }

    var preset: ProviderPreset { ProviderPreset.preset(for: selectedProvider)! }
    var canConnect: Bool {
        credentialLength > 0
            && state != .testing
            && (!preset.requiresFolderID || !trimmedFolderID.isEmpty)
    }
    var modelName: String { settings.modelName(for: selectedProvider) }

    func select(_ provider: ProviderKind) {
        guard state != .testing,
              ProviderPreset.preset(for: provider) != nil,
              provider != selectedProvider else { return }
        discardCandidate()
        selectedProvider = provider
        candidateAccount = Self.makeCandidateAccount()
        credentialLength = 0
        yandexFolderID = provider == .yandexGPT ? settings.yandexFolderID : ""
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
        guard state != .testing, connectionTask == nil else { return }
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
        let model = modelName
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("model_or_endpoint")
            return
        }
        let folderID = selectedProvider == .yandexGPT ? trimmedFolderID : nil
        let requestID = UUID()
        let account = candidateAccount
        let reader = ProviderRegistry.snapshotCredential(account: account, from: secretStore)
        let provider = makeProvider(kind: selectedProvider, modelName: model, folderID: folderID, credential: reader)
        state = .testing
        activeOperationRevision = operationRevision
        connectionTask = Task { [weak self] in
            await self?.performConnection(
                provider: provider,
                operationRevision: operationRevision,
                selection: selection,
                model: model,
                folderID: folderID,
                requestID: requestID,
                account: account
            )
        }
    }

    func waitForConnection() async {
        let task = connectionTask
        await task?.value
    }

    private func performConnection(
        provider: any AIProvider,
        operationRevision: UUID,
        selection: ProviderSelection,
        model: String,
        folderID: String?,
        requestID: UUID,
        account: String
    ) async {
        defer {
            if activeOperationRevision == operationRevision {
                connectionTask = nil
                activeOperationRevision = nil
            }
        }
        do {
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
                report: report
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
