import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let mockMode = "settings.mockMode"
        static let primaryProvider = "settings.primaryProvider"
        static let fallbackProvider = "settings.fallbackProvider"
        static let fallbackDelay = "settings.fallbackDelay"
        static let monthlyBudget = "settings.monthlyBudget"
        static let sessionQuestionLimit = "settings.sessionQuestionLimit"
        static let sessionPhotoLimit = "settings.sessionPhotoLimit"
        static let contextMinutes = "settings.contextMinutes"
        static let yandexFolderID = "settings.yandexFolderID"
        static let customModels = "settings.customModels"
        static let inputRates = "settings.inputRates"
        static let outputRates = "settings.outputRates"
        static let systemPrompt = "settings.systemPrompt"
        static let conversationPrompt = "settings.conversationPrompt"
        static let photoPrompt = "settings.photoPrompt"
        static let appearance = "settings.appearance"
        static let connectionReports = "settings.connectionReports.v1"
        static let customProviders = "settings.customProviders.v1"
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
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    @Published private(set) var connectionReports: [String: ProviderConnectionReport] {
        didSet { persistConnectionReports() }
    }
    @Published private(set) var customProviders: [CustomProviderProfile] {
        didSet { persistCustomProviders() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decodedCustomProviders: [CustomProviderProfile]
        if let data = defaults.data(forKey: Key.customProviders),
           let decoded = try? JSONDecoder().decode([CustomProviderProfile].self, from: data) {
            decodedCustomProviders = decoded
        } else {
            decodedCustomProviders = []
        }
        let decodedConnectionReports: [String: ProviderConnectionReport]
        if let data = defaults.data(forKey: Key.connectionReports),
           let decoded = try? JSONDecoder().decode([String: ProviderConnectionReport].self, from: data) {
            decodedConnectionReports = decoded
        } else {
            decodedConnectionReports = [:]
        }

        mockMode = (defaults.object(forKey: Key.mockMode) as? Bool) ?? true
        primaryProvider = ProviderSelection(
            rawValue: defaults.string(forKey: Key.primaryProvider) ?? ProviderKind.openAI.rawValue
        )
        fallbackProvider = ProviderSelection(
            rawValue: defaults.string(forKey: Key.fallbackProvider) ?? ProviderKind.yandexGPT.rawValue
        )
        fallbackDelaySeconds = (defaults.object(forKey: Key.fallbackDelay) as? Double) ?? 1.7
        monthlyBudgetRUB = (defaults.object(forKey: Key.monthlyBudget) as? Double) ?? 2_000
        sessionQuestionLimit = (defaults.object(forKey: Key.sessionQuestionLimit) as? Int) ?? 150
        sessionPhotoLimit = (defaults.object(forKey: Key.sessionPhotoLimit) as? Int) ?? 30
        contextMinutes = (defaults.object(forKey: Key.contextMinutes) as? Int) ?? 5
        yandexFolderID = defaults.string(forKey: Key.yandexFolderID) ?? ""
        systemPrompt = defaults.string(forKey: Key.systemPrompt) ?? PromptFactory.defaultConciseSystem
        // Preserve the shipped shared prompt until per-mode editors are introduced.
        conversationPrompt = defaults.string(forKey: Key.conversationPrompt) ?? ""
        photoPrompt = defaults.string(forKey: Key.photoPrompt) ?? ""
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .light
        connectionReports = decodedConnectionReports
        customProviders = decodedCustomProviders

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
            || old.protocolKind != profile.protocolKind || old.authScheme != profile.authScheme {
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

    func prompt(for profile: PromptProfileKind) -> String {
        switch profile {
        case .live: systemPrompt
        case .conversation: conversationPrompt.isEmpty ? systemPrompt : conversationPrompt
        case .photo: photoPrompt.isEmpty ? systemPrompt : photoPrompt
        }
    }

    func setPrompt(_ value: String, for profile: PromptProfileKind) {
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
        guard modelName(for: selection) != cleaned else { return }
        if var profile = customProvider(for: selection) {
            profile.modelName = cleaned
            updateCustomProvider(profile)
        } else {
            setModelName(cleaned, for: selection.kind)
        }
    }

    func setModelName(_ value: String, for provider: ProviderKind) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelName(for: provider) != cleaned else { return }
        defaults.set(cleaned, forKey: "\(Key.customModels).\(provider.rawValue)")
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
            defaults.set(data, forKey: Key.customProviders)
        }
    }


    private func persistConnectionReports() {
        if let data = try? JSONEncoder().encode(connectionReports) {
            defaults.set(data, forKey: Key.connectionReports)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
