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
        XCTAssertEqual(settings.listeningNavigationPolicy, .ask)
        XCTAssertEqual(settings.answerTriggerPolicy, .automatic)
        XCTAssertFalse(settings.latencyFallbackEnabled)
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

    func testUpgradePreservesPreviouslyImplicitFallbackButFreshInstallDoesNotEnableIt() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "settings.mockMode")
        XCTAssertTrue(AppSettings(defaults: defaults).latencyFallbackEnabled)
        defaults.removeObject(forKey: "settings.latencyFallbackEnabled")
        defaults.removeObject(forKey: "settings.mockMode")
        XCTAssertFalse(AppSettings(defaults: defaults).latencyFallbackEnabled)
    }

    func testListeningAndAnswerPoliciesPersistIndependently() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.listeningNavigationPolicy = .continueWhileActive
        settings.answerTriggerPolicy = .manual

        let reopened = AppSettings(defaults: defaults)
        XCTAssertEqual(reopened.listeningNavigationPolicy, .continueWhileActive)
        XCTAssertEqual(reopened.answerTriggerPolicy, .manual)
    }

    func testMalformedCustomProfileDoesNotDiscardValidSibling() throws {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = CustomProviderProfile(
            displayName: "Still available",
            baseURL: "https://gateway.example/v1",
            modelName: "chat-model"
        )
        let encoded = try JSONEncoder().encode(valid)
        let validObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var invalidObject = validObject
        invalidObject["id"] = UUID().uuidString
        invalidObject["authScheme"] = "unsupported-auth"
        defaults.set(try JSONSerialization.data(withJSONObject: [validObject, invalidObject]), forKey: "settings.customProviders.v1")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.customProviders.map(\.id), [valid.id])
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

    func testConnectionVerificationPersistsAndModelEditInvalidatesIt() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let selection = ProviderSelection.builtIn(.openAI)
        settings.setConnectionReport(ProviderConnectionReport(
            state: .verified, modelName: settings.modelName(for: selection), checkedAt: .now,
            firstTokenMilliseconds: 100, totalMilliseconds: 250, errorCategory: nil
        ), for: selection)
        XCTAssertEqual(AppSettings(defaults: defaults).connectionReport(for: selection).state, .verified)
        settings.setModelName("different-model", for: selection)
        XCTAssertEqual(settings.connectionReport(for: selection).state, .unverified)
        XCTAssertNil(settings.connectionReport(for: selection).checkedAt)
    }

    func testCustomEndpointChangeInvalidatesVerificationButRatesDoNot() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        var profile = CustomProviderProfile(displayName: "Test", baseURL: "https://a.example", modelName: "m")
        settings.createCustomProvider(profile)
        settings.setConnectionReport(ProviderConnectionReport(state: .verified, modelName: "m", checkedAt: .now, firstTokenMilliseconds: 10, totalMilliseconds: 20, errorCategory: nil), for: profile.selection)
        settings.setRates(input: 100, output: 100, for: profile.selection)
        XCTAssertEqual(settings.connectionReport(for: profile.selection).state, .verified)
        profile.baseURL = "https://b.example"
        settings.updateCustomProvider(profile)
        XCTAssertEqual(settings.connectionReport(for: profile.selection).state, .unverified)
    }

    func testAppearanceDefaultsToLight() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: defaults).appearance, .light)
    }

    func testSharedPromptEditsStillApplyToAllModesAfterUpgrade() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Сохранённый пользовательский промпт", forKey: "settings.systemPrompt")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.prompt(for: .conversation), settings.systemPrompt)
        XCTAssertEqual(settings.prompt(for: .photo), settings.systemPrompt)
        settings.systemPrompt = "Новая инструкция"
        XCTAssertEqual(settings.prompt(for: .conversation), "Новая инструкция")
        XCTAssertEqual(settings.prompt(for: .photo), "Новая инструкция")
    }

    func testQueuedCredentialSnapshotNeverChangesWithKeyEditor() throws {
        let secrets = MutableFixtureSecrets()
        try secrets.save("old-fixture", account: "a")
        let snapshot = ProviderRegistry.snapshotCredential(account: "a", from: secrets)
        try secrets.save("new-fixture", account: "a")
        XCTAssertEqual(try snapshot(), "old-fixture")
        try secrets.delete(account: "a")
        XCTAssertEqual(try snapshot(), "old-fixture")
        XCTAssertNil(try ProviderRegistry.snapshotCredential(account: "a", from: secrets)())
    }

    func testManualModelSelectionIsExplicitEvenWhenItMatchesRecommendation() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = settings.modelName(for: .deepSeek)

        XCTAssertEqual(settings.modelSelectionPolicy(for: .builtIn(.deepSeek)), .recommended)
        settings.setModelName(model, for: .deepSeek)
        XCTAssertEqual(settings.modelSelectionPolicy(for: .builtIn(.deepSeek)), .explicit(model))
    }
}

private final class MutableFixtureSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func save(_ value: String, account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = value }
    func read(account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func delete(account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = nil }
}

