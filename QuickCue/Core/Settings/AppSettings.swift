import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let mockMode = "settings.mockMode"
        static let primaryProvider = "settings.primaryProvider"
        static let fallbackProvider = "settings.fallbackProvider"
        static let fallbackDelay = "settings.fallbackDelay"
        static let latencyFallbackEnabled = "settings.latencyFallbackEnabled"
        static let monthlyBudget = "settings.monthlyBudget"
        static let sessionQuestionLimit = "settings.sessionQuestionLimit"
        static let sessionPhotoLimit = "settings.sessionPhotoLimit"
        static let contextMinutes = "settings.contextMinutes"
        static let yandexFolderID = "settings.yandexFolderID"
        static let customModels = "settings.customModels"
        static let recommendedModels = "settings.recommendedModels.v1"
        static let inputRates = "settings.inputRates"
        static let outputRates = "settings.outputRates"
        static let systemPrompt = "settings.systemPrompt"
        static let conversationPrompt = "settings.conversationPrompt"
        static let photoPrompt = "settings.photoPrompt"
        static let promptConfigurations = "settings.promptConfigurations.v2"
        static let answerTextSize = "settings.answerTextSize"
        static let highlightKeywords = "settings.highlightKeywords"
        static let hasSeenQuickTips = "settings.hasSeenQuickTips"
        static let selectedContextProfileID = "settings.selectedContextProfileID"
        static let appearance = "settings.appearance"
        static let connectionReports = "settings.connectionReports.v1"
        static let customProviders = "settings.customProviders.v1"
        static let providerProfiles = "settings.providerProfiles.v2"
        static let providerProfilesRecovery = "settings.providerProfiles.recovery.v2"
        static let listeningNavigationPolicy = "settings.listeningNavigationPolicy"
        static let answerTriggerPolicy = "settings.answerTriggerPolicy"
        static let bleRemoteEnabled = "settings.bleRemoteEnabled"
        static let bleRemoteServiceUUID = "settings.bleRemoteServiceUUID"
        static let bleRemoteCharacteristicUUID = "settings.bleRemoteCharacteristicUUID"
    }

    private let defaults: UserDefaults
    private var configurationRevisions: [String: Int] = [:]

    @Published var mockMode: Bool { didSet { defaults.set(mockMode, forKey: Key.mockMode) } }
    @Published var primaryProvider: ProviderSelection {
        didSet { defaults.set(primaryProvider.rawValue, forKey: Key.primaryProvider) }
    }
    @Published var fallbackProvider: ProviderSelection {
        didSet { defaults.set(fallbackProvider.rawValue, forKey: Key.fallbackProvider) }
    }
    @Published var fallbackDelaySeconds: Double { didSet { defaults.set(fallbackDelaySeconds, forKey: Key.fallbackDelay) } }
    @Published var latencyFallbackEnabled: Bool { didSet { defaults.set(latencyFallbackEnabled, forKey: Key.latencyFallbackEnabled) } }
    @Published var monthlyBudgetRUB: Double { didSet { defaults.set(monthlyBudgetRUB, forKey: Key.monthlyBudget) } }
    @Published var sessionQuestionLimit: Int { didSet { defaults.set(sessionQuestionLimit, forKey: Key.sessionQuestionLimit) } }
    @Published var sessionPhotoLimit: Int { didSet { defaults.set(sessionPhotoLimit, forKey: Key.sessionPhotoLimit) } }
    @Published var contextMinutes: Int { didSet { defaults.set(contextMinutes, forKey: Key.contextMinutes) } }
    @Published var yandexFolderID: String {
        didSet {
            defaults.set(yandexFolderID, forKey: Key.yandexFolderID)
            if oldValue != yandexFolderID { markConnectionUnverified(.builtIn(.yandexGPT)) }
        }
    }
    @Published var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: Key.systemPrompt) } }
    @Published var conversationPrompt: String { didSet { defaults.set(conversationPrompt, forKey: Key.conversationPrompt) } }
    @Published var photoPrompt: String { didSet { defaults.set(photoPrompt, forKey: Key.photoPrompt) } }
    @Published private(set) var promptConfigurations: [String: PromptConfiguration] {
        didSet { persistPromptConfigurations() }
    }
    @Published var answerTextSize: AnswerTextSize {
        didSet { defaults.set(answerTextSize.rawValue, forKey: Key.answerTextSize) }
    }
    @Published var highlightKeywords: Bool {
        didSet { defaults.set(highlightKeywords, forKey: Key.highlightKeywords) }
    }
    @Published var hasSeenQuickTips: Bool {
        didSet { defaults.set(hasSeenQuickTips, forKey: Key.hasSeenQuickTips) }
    }
    @Published var selectedContextProfileID: UUID? {
        didSet {
            if let selectedContextProfileID {
                defaults.set(selectedContextProfileID.uuidString, forKey: Key.selectedContextProfileID)
            } else {
                defaults.removeObject(forKey: Key.selectedContextProfileID)
            }
        }
    }
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    @Published var listeningNavigationPolicy: ListeningNavigationPolicy {
        didSet { defaults.set(listeningNavigationPolicy.rawValue, forKey: Key.listeningNavigationPolicy) }
    }
    @Published var answerTriggerPolicy: AnswerTriggerPolicy {
        didSet { defaults.set(answerTriggerPolicy.rawValue, forKey: Key.answerTriggerPolicy) }
    }
    @Published var bleRemoteEnabled: Bool {
        didSet { defaults.set(bleRemoteEnabled, forKey: Key.bleRemoteEnabled) }
    }
    @Published var bleRemoteServiceUUID: String {
        didSet { defaults.set(bleRemoteServiceUUID, forKey: Key.bleRemoteServiceUUID) }
    }
    @Published var bleRemoteCharacteristicUUID: String {
        didSet { defaults.set(bleRemoteCharacteristicUUID, forKey: Key.bleRemoteCharacteristicUUID) }
    }
    @Published private(set) var connectionReports: [String: ProviderConnectionReport] {
        didSet { persistConnectionReports() }
    }
    @Published private(set) var customProviders: [CustomProviderProfile] {
        didSet { persistCustomProviders() }
    }
    @Published private(set) var corruptProviderProfileCount: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let isExistingInstallation = defaults.object(forKey: Key.mockMode) != nil
            || defaults.object(forKey: Key.primaryProvider) != nil
        let decodedCustomProviders: [CustomProviderProfile]
        let corruptProviderProfileCount: Int
        let profileData = defaults.data(forKey: Key.providerProfiles)
            ?? defaults.data(forKey: Key.customProviders)
        if let data = profileData,
           let decoded = try? JSONDecoder().decode([FailableDecodable<CustomProviderProfile>].self, from: data) {
            decodedCustomProviders = decoded.compactMap(\.value)
            corruptProviderProfileCount = decoded.filter { $0.value == nil }.count
            if corruptProviderProfileCount > 0,
               defaults.data(forKey: Key.providerProfilesRecovery) == nil {
                defaults.set(data, forKey: Key.providerProfilesRecovery)
            }
        } else {
            decodedCustomProviders = []
            corruptProviderProfileCount = profileData == nil ? 0 : 1
            if let profileData, defaults.data(forKey: Key.providerProfilesRecovery) == nil {
                defaults.set(profileData, forKey: Key.providerProfilesRecovery)
            }
        }
        let decodedConnectionReports: [String: ProviderConnectionReport]
        if let data = defaults.data(forKey: Key.connectionReports),
           let decoded = try? JSONDecoder().decode([String: ProviderConnectionReport].self, from: data) {
            decodedConnectionReports = decoded
        } else {
            decodedConnectionReports = [:]
        }
        let decodedPromptConfigurations: [String: PromptConfiguration]
        if let data = defaults.data(forKey: Key.promptConfigurations),
           let decoded = try? JSONDecoder().decode([String: PromptConfiguration].self, from: data) {
            decodedPromptConfigurations = decoded
        } else {
            decodedPromptConfigurations = [:]
        }

        mockMode = (defaults.object(forKey: Key.mockMode) as? Bool) ?? true
        primaryProvider = ProviderSelection(
            rawValue: defaults.string(forKey: Key.primaryProvider) ?? ProviderKind.openAI.rawValue
        )
        fallbackProvider = ProviderSelection(
            rawValue: defaults.string(forKey: Key.fallbackProvider) ?? ProviderKind.yandexGPT.rawValue
        )
        fallbackDelaySeconds = (defaults.object(forKey: Key.fallbackDelay) as? Double) ?? 1.7
        latencyFallbackEnabled = (defaults.object(forKey: Key.latencyFallbackEnabled) as? Bool) ?? isExistingInstallation
        monthlyBudgetRUB = (defaults.object(forKey: Key.monthlyBudget) as? Double) ?? 2_000
        sessionQuestionLimit = (defaults.object(forKey: Key.sessionQuestionLimit) as? Int) ?? 150
        sessionPhotoLimit = (defaults.object(forKey: Key.sessionPhotoLimit) as? Int) ?? 30
        contextMinutes = (defaults.object(forKey: Key.contextMinutes) as? Int) ?? 5
        yandexFolderID = defaults.string(forKey: Key.yandexFolderID) ?? ""
        systemPrompt = defaults.string(forKey: Key.systemPrompt) ?? PromptFactory.defaultConciseSystem
        // Preserve the shipped shared prompt until per-mode editors are introduced.
        conversationPrompt = defaults.string(forKey: Key.conversationPrompt) ?? ""
        photoPrompt = defaults.string(forKey: Key.photoPrompt) ?? ""
        promptConfigurations = decodedPromptConfigurations
        answerTextSize = AnswerTextSize(rawValue: defaults.string(forKey: Key.answerTextSize) ?? "") ?? .standard
        highlightKeywords = (defaults.object(forKey: Key.highlightKeywords) as? Bool) ?? false
        hasSeenQuickTips = (defaults.object(forKey: Key.hasSeenQuickTips) as? Bool) ?? false
        selectedContextProfileID = defaults.string(forKey: Key.selectedContextProfileID).flatMap(UUID.init(uuidString:))
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .light
        listeningNavigationPolicy = ListeningNavigationPolicy(
            rawValue: defaults.string(forKey: Key.listeningNavigationPolicy) ?? ""
        ) ?? .ask
        answerTriggerPolicy = AnswerTriggerPolicy(
            rawValue: defaults.string(forKey: Key.answerTriggerPolicy) ?? ""
        ) ?? .automatic
        bleRemoteEnabled = (defaults.object(forKey: Key.bleRemoteEnabled) as? Bool) ?? false
        bleRemoteServiceUUID = defaults.string(forKey: Key.bleRemoteServiceUUID) ?? ""
        bleRemoteCharacteristicUUID = defaults.string(forKey: Key.bleRemoteCharacteristicUUID) ?? ""
        connectionReports = decodedConnectionReports
        customProviders = decodedCustomProviders
        self.corruptProviderProfileCount = corruptProviderProfileCount

        // One-way settings migration. The legacy payload stays untouched as a recovery source;
        // profile UUIDs keep pointing to the same Keychain accounts.
        if defaults.data(forKey: Key.providerProfiles) == nil,
           let migrated = try? JSONEncoder().encode(decodedCustomProviders) {
            defaults.set(migrated, forKey: Key.providerProfiles)
        }

        if !contains(primaryProvider) { primaryProvider = .builtIn(.openAI) }
        if !contains(fallbackProvider) { fallbackProvider = .builtIn(.yandexGPT) }
    }

    var availableProviders: [ProviderSelection] {
        let builtIns = ProviderKind.allCases
            .filter { $0 != .mock && $0 != .custom }
            .map(ProviderSelection.builtIn)
        return builtIns + customProviders.map(\.selection)
    }

    func contains(_ selection: ProviderSelection) -> Bool {
        if let id = selection.customID { return customProviders.contains { $0.id == id } }
        return selection.kind != .mock && selection.kind != .custom
    }

    func customProvider(for selection: ProviderSelection) -> CustomProviderProfile? {
        guard let id = selection.customID else { return nil }
        return customProviders.first { $0.id == id }
    }

    func addCustomProvider(_ profile: CustomProviderProfile = .init()) {
        customProviders.append(profile)
    }

    func createCustomProvider(_ profile: CustomProviderProfile) {
        guard !customProviders.contains(where: { $0.id == profile.id }) else {
            updateCustomProvider(profile)
            return
        }
        customProviders.append(profile)
    }

    func updateCustomProvider(_ profile: CustomProviderProfile) {
        guard let index = customProviders.firstIndex(where: { $0.id == profile.id }) else { return }
        let old = customProviders[index]
        customProviders[index] = profile
        if old.baseURL != profile.baseURL || old.modelName != profile.modelName
            || old.protocolKind != profile.protocolKind || old.authScheme != profile.authScheme
            || old.credentialReferences != profile.credentialReferences {
            markConnectionUnverified(profile.selection)
        }
    }

    func deleteCustomProvider(id: UUID) {
        customProviders.removeAll { $0.id == id }
        connectionReports.removeValue(forKey: ProviderSelection.custom(id).rawValue)
        if primaryProvider.customID == id { primaryProvider = .builtIn(.openAI) }
        if fallbackProvider.customID == id { fallbackProvider = .builtIn(.yandexGPT) }
    }

    func providerTitle(for selection: ProviderSelection) -> String {
        customProvider(for: selection)?.displayName.nonEmpty ?? selection.kind.title
    }

    func modelName(for selection: ProviderSelection) -> String {
        if let profile = customProvider(for: selection) { return profile.modelName }
        return modelName(for: selection.kind)
    }

    func modelName(for provider: ProviderKind) -> String {
        if let custom = defaults.string(forKey: "\(Key.customModels).\(provider.rawValue)"), !custom.isEmpty {
            return custom
        }
        return switch provider {
        case .mock: "mock-fast-ru"
        case .openAI: "gpt-5.4-mini"
        case .deepSeek: "deepseek-v4-flash"
        case .anthropic: "claude-sonnet-5"
        case .xAI: "grok-4.6"
        case .yandexGPT: "yandexgpt-5-pro/latest"
        case .custom: ""
        }
    }

    func modelSelectionPolicy(for selection: ProviderSelection) -> ModelSelectionPolicy {
        let model = modelName(for: selection)
        if selection.customID != nil {
            return .explicit(model)
        }
        let modelKey = "\(Key.customModels).\(selection.kind.rawValue)"
        let recommendedKey = "\(Key.recommendedModels).\(selection.kind.rawValue)"
        if defaults.string(forKey: recommendedKey) == model {
            return .recommended
        }
        if defaults.object(forKey: modelKey) != nil {
            return .explicit(model)
        }
        return .recommended
    }

    func prompt(for profile: PromptProfileKind) -> String {
        switch profile {
        case .live: systemPrompt
        case .conversation: conversationPrompt.isEmpty ? systemPrompt : conversationPrompt
        case .photo: photoPrompt.isEmpty ? systemPrompt : photoPrompt
        }
    }

    func promptConfiguration(for profile: PromptProfileKind) -> PromptConfiguration? {
        promptConfigurations[profile.rawValue]
    }

    func promptSnapshot(for profile: PromptProfileKind) -> PromptSnapshot {
        if let configuration = promptConfiguration(for: profile) {
            return PromptComposer.compose(profile: profile, configuration: configuration)
        }
        return PromptSnapshot(
            text: prompt(for: profile),
            version: "\(profile.rawValue):legacy-v1",
            styleRaw: "legacy"
        )
    }

    func savePromptConfiguration(
        style: ResponseStyle,
        includesCodeWhenUseful: Bool,
        additionalInstructions: String,
        for profile: PromptProfileKind
    ) {
        let revision = (promptConfigurations[profile.rawValue]?.revision ?? 0) + 1
        promptConfigurations[profile.rawValue] = PromptConfiguration(
            style: style,
            includesCodeWhenUseful: includesCodeWhenUseful,
            additionalInstructions: PromptComposer.normalizedAdditional(additionalInstructions),
            revision: revision
        )
    }

    func restoreLegacyPrompt(for profile: PromptProfileKind) {
        promptConfigurations.removeValue(forKey: profile.rawValue)
    }

    func setPrompt(_ value: String, for profile: PromptProfileKind) {
        restoreLegacyPrompt(for: profile)
        switch profile {
        case .live: systemPrompt = value
        case .conversation: conversationPrompt = value
        case .photo: photoPrompt = value
        }
    }

    func connectionReport(for selection: ProviderSelection) -> ProviderConnectionReport {
        var report = connectionReports[selection.rawValue] ?? .unconfigured
        if report.state == .verified, report.modelName != modelName(for: selection) {
            report.state = .unverified
        }
        return report
    }

    func configurationRevision(for selection: ProviderSelection) -> Int {
        configurationRevisions[selection.rawValue, default: 0]
    }

    func setConnectionReport(_ report: ProviderConnectionReport, for selection: ProviderSelection) {
        connectionReports[selection.rawValue] = report
    }

    /// Final step of the guided setup. The candidate secret has already been
    /// verified and copied to the provider's stable Keychain account.
    func activateVerifiedProvider(
        _ selection: ProviderSelection,
        modelName: String,
        yandexFolderID: String?,
        report: ProviderConnectionReport,
        modelSelectionPolicy: ModelSelectionPolicy? = nil
    ) {
        guard selection.customID == nil, selection.kind != .mock, selection.kind != .custom else { return }
        switch modelSelectionPolicy ?? self.modelSelectionPolicy(for: selection) {
        case .recommended:
            setRecommendedModelName(modelName, for: selection.kind)
        case .explicit(let explicitModel):
            guard explicitModel.trimmingCharacters(in: .whitespacesAndNewlines) == modelName else { return }
            setModelName(modelName, for: selection.kind)
        }
        if selection.kind == .yandexGPT, let yandexFolderID {
            self.yandexFolderID = yandexFolderID
        }
        // A key replacement is a configuration revision even when the model
        // did not change. This invalidates callbacks from older checks.
        markConnectionUnverified(selection)
        setConnectionReport(report, for: selection)
        primaryProvider = selection
        mockMode = false
    }

    func markConnectionUnverified(_ selection: ProviderSelection) {
        configurationRevisions[selection.rawValue, default: 0] += 1
        let hasConfiguration = !modelName(for: selection).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        connectionReports[selection.rawValue] = ProviderConnectionReport(
            state: hasConfiguration ? .unverified : .unconfigured,
            modelName: modelName(for: selection),
            checkedAt: nil,
            firstTokenMilliseconds: nil,
            totalMilliseconds: nil,
            errorCategory: nil
        )
    }

    func setModelName(_ value: String, for selection: ProviderSelection) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if var profile = customProvider(for: selection) {
            guard modelName(for: selection) != cleaned else { return }
            profile.modelName = cleaned
            updateCustomProvider(profile)
        } else {
            setModelName(cleaned, for: selection.kind)
        }
    }

    func setModelName(_ value: String, for provider: ProviderKind) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let recommendedKey = "\(Key.recommendedModels).\(provider.rawValue)"
        defaults.removeObject(forKey: recommendedKey)
        let modelKey = "\(Key.customModels).\(provider.rawValue)"
        guard modelName(for: provider) != cleaned else {
            defaults.set(cleaned, forKey: modelKey)
            return
        }
        defaults.set(cleaned, forKey: modelKey)
        markConnectionUnverified(.builtIn(provider))
    }

    private func setRecommendedModelName(_ value: String, for provider: ProviderKind) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelKey = "\(Key.customModels).\(provider.rawValue)"
        let recommendedKey = "\(Key.recommendedModels).\(provider.rawValue)"
        if modelName(for: provider) == cleaned {
            if defaults.object(forKey: modelKey) == nil {
                defaults.removeObject(forKey: recommendedKey)
            } else {
                defaults.set(cleaned, forKey: recommendedKey)
            }
            return
        }
        defaults.set(cleaned, forKey: modelKey)
        defaults.set(cleaned, forKey: recommendedKey)
        markConnectionUnverified(.builtIn(provider))
    }

    func inputRateRUB(for selection: ProviderSelection) -> Double {
        customProvider(for: selection)?.inputRateRUB ?? inputRateRUB(for: selection.kind)
    }

    func outputRateRUB(for selection: ProviderSelection) -> Double {
        customProvider(for: selection)?.outputRateRUB ?? outputRateRUB(for: selection.kind)
    }

    func inputRateRUB(for provider: ProviderKind) -> Double {
        defaults.double(forKey: "\(Key.inputRates).\(provider.rawValue)")
    }

    func outputRateRUB(for provider: ProviderKind) -> Double {
        defaults.double(forKey: "\(Key.outputRates).\(provider.rawValue)")
    }

    func setRates(input: Double, output: Double, for selection: ProviderSelection) {
        if var profile = customProvider(for: selection) {
            profile.inputRateRUB = max(0, input)
            profile.outputRateRUB = max(0, output)
            updateCustomProvider(profile)
        } else {
            setRates(input: input, output: output, for: selection.kind)
        }
    }

    func setRates(input: Double, output: Double, for provider: ProviderKind) {
        defaults.set(max(0, input), forKey: "\(Key.inputRates).\(provider.rawValue)")
        defaults.set(max(0, output), forKey: "\(Key.outputRates).\(provider.rawValue)")
        objectWillChange.send()
    }

    func estimatedCostRUB(for usage: TokenUsage, provider: ProviderSelection) -> Double {
        let input = Double(usage.inputTokens) / 1_000_000 * inputRateRUB(for: provider)
        let output = Double(usage.outputTokens) / 1_000_000 * outputRateRUB(for: provider)
        return input + output
    }

    func estimatedCostRUB(for usage: TokenUsage, provider: ProviderKind) -> Double {
        estimatedCostRUB(for: usage, provider: .builtIn(provider))
    }

    private func persistCustomProviders() {
        if let data = try? JSONEncoder().encode(customProviders) {
            defaults.set(data, forKey: Key.providerProfiles)
        }
    }


    private func persistConnectionReports() {
        if let data = try? JSONEncoder().encode(connectionReports) {
            defaults.set(data, forKey: Key.connectionReports)
        }
    }

    private func persistPromptConfigurations() {
        if let data = try? JSONEncoder().encode(promptConfigurations) {
            defaults.set(data, forKey: Key.promptConfigurations)
        }
    }
}

private struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
