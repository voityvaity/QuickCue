import XCTest
@testable import QuickCue

@MainActor
final class AppSettingsTests: XCTestCase {
    func testFreshSettingsStartInMockMode() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.mockMode)
        XCTAssertEqual(settings.sessionQuestionLimit, 150)
        XCTAssertEqual(settings.sessionPhotoLimit, 30)
        XCTAssertEqual(settings.contextMinutes, 5)
    }

    func testCostEstimateUsesConfigurableRates() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setRates(input: 100, output: 200, for: .openAI)

        let cost = settings.estimatedCostRUB(
            for: TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000),
            provider: .openAI
        )
        XCTAssertEqual(cost, 200, accuracy: 0.001)
    }

    func testRegistryCanTestRealProviderWhileMockModeIsEnabled() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        let provider = ProviderRegistry(settings: settings).provider(
            .yandexGPT,
            honorMockMode: false
        )

        XCTAssertEqual(provider.kind, .yandexGPT)
    }

    func testSeveralCustomProvidersRemainIndependent() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let first = CustomProviderProfile(
            displayName: "Gateway A",
            baseURL: "https://a.example",
            modelName: "model-a"
        )
        let second = CustomProviderProfile(
            displayName: "Gateway B",
            baseURL: "https://b.example/v1",
            modelName: "model-b"
        )

        settings.addCustomProvider(first)
        settings.addCustomProvider(second)
        settings.primaryProvider = first.selection
        settings.fallbackProvider = second.selection

        XCTAssertEqual(settings.customProviders.count, 2)
        XCTAssertEqual(settings.providerTitle(for: settings.primaryProvider), "Gateway A")
        XCTAssertEqual(settings.modelName(for: settings.fallbackProvider), "model-b")

        settings.deleteCustomProvider(id: first.id)

        XCTAssertEqual(settings.customProviders.map(\.id), [second.id])
        XCTAssertEqual(settings.primaryProvider, .builtIn(.openAI))
        XCTAssertEqual(settings.fallbackProvider, second.selection)
    }
}

