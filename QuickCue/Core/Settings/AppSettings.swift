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
    }

    private let defaults: UserDefaults

    @Published var mockMode: Bool { didSet { defaults.set(mockMode, forKey: Key.mockMode) } }
    @Published var primaryProvider: ProviderKind { didSet { defaults.set(primaryProvider.rawValue, forKey: Key.primaryProvider) } }
    @Published var fallbackProvider: ProviderKind { didSet { defaults.set(fallbackProvider.rawValue, forKey: Key.fallbackProvider) } }
    @Published var fallbackDelaySeconds: Double { didSet { defaults.set(fallbackDelaySeconds, forKey: Key.fallbackDelay) } }
    @Published var monthlyBudgetRUB: Double { didSet { defaults.set(monthlyBudgetRUB, forKey: Key.monthlyBudget) } }
    @Published var sessionQuestionLimit: Int { didSet { defaults.set(sessionQuestionLimit, forKey: Key.sessionQuestionLimit) } }
    @Published var sessionPhotoLimit: Int { didSet { defaults.set(sessionPhotoLimit, forKey: Key.sessionPhotoLimit) } }
    @Published var contextMinutes: Int { didSet { defaults.set(contextMinutes, forKey: Key.contextMinutes) } }
    @Published var yandexFolderID: String { didSet { defaults.set(yandexFolderID, forKey: Key.yandexFolderID) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mockMode = defaults.object(forKey: Key.mockMode) as? Bool ?? true
        primaryProvider = ProviderKind(rawValue: defaults.string(forKey: Key.primaryProvider) ?? "") ?? .openAI
        fallbackProvider = ProviderKind(rawValue: defaults.string(forKey: Key.fallbackProvider) ?? "") ?? .yandexGPT
        fallbackDelaySeconds = defaults.object(forKey: Key.fallbackDelay) as? Double ?? 1.7
        monthlyBudgetRUB = defaults.object(forKey: Key.monthlyBudget) as? Double ?? 2_000
        sessionQuestionLimit = defaults.object(forKey: Key.sessionQuestionLimit) as? Int ?? 150
        sessionPhotoLimit = defaults.object(forKey: Key.sessionPhotoLimit) as? Int ?? 30
        contextMinutes = defaults.object(forKey: Key.contextMinutes) as? Int ?? 5
        yandexFolderID = defaults.string(forKey: Key.yandexFolderID) ?? ""
    }

    func modelName(for provider: ProviderKind) -> String {
        if let custom = defaults.string(forKey: "\(Key.customModels).\(provider.rawValue)"), !custom.isEmpty {
            return custom
        }
        switch provider {
        case .mock:
            return "mock-fast-ru"
        
        case .openAI:
            return "gpt-5.4-mini"
        
        case .deepSeek:
            return "deepseek-v4-flash"
        
        case .anthropic:
            return "claude-sonnet-5"
        
        case .xAI:
            return "grok-4.6"
        
        case .yandexGPT:
            return "yandexgpt/latest"
        }
    }

    func setModelName(_ value: String, for provider: ProviderKind) {
        defaults.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "\(Key.customModels).\(provider.rawValue)")
        objectWillChange.send()
    }

    func inputRateRUB(for provider: ProviderKind) -> Double {
        defaults.double(forKey: "\(Key.inputRates).\(provider.rawValue)")
    }

    func outputRateRUB(for provider: ProviderKind) -> Double {
        defaults.double(forKey: "\(Key.outputRates).\(provider.rawValue)")
    }

    func setRates(input: Double, output: Double, for provider: ProviderKind) {
        defaults.set(max(0, input), forKey: "\(Key.inputRates).\(provider.rawValue)")
        defaults.set(max(0, output), forKey: "\(Key.outputRates).\(provider.rawValue)")
        objectWillChange.send()
    }

    func estimatedCostRUB(for usage: TokenUsage, provider: ProviderKind) -> Double {
        let input = Double(usage.inputTokens) / 1_000_000 * inputRateRUB(for: provider)
        let output = Double(usage.outputTokens) / 1_000_000 * outputRateRUB(for: provider)
        return input + output
    }
}
