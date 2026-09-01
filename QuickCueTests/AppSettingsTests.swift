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
}

