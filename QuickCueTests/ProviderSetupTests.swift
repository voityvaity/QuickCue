import XCTest
@testable import QuickCue

@MainActor
final class ProviderSetupTests: XCTestCase {
    func testSuccessfulCandidateReplacesStableKeyAndActivatesProvider() async throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        let coordinator = ProviderSetupCoordinator(
            settings: fixture.settings,
            secretStore: secrets,
            defaults: fixture.defaults,
            verifier: { provider, _ in
                XCTAssertEqual(provider.kind, .deepSeek)
                XCTAssertEqual(provider.modelName, fixture.settings.modelName(for: .deepSeek))
                return .init(firstTokenMilliseconds: 120, totalMilliseconds: 240)
            },
            metadataLoader: { _, _, _ in .unsupported }
        )
        try secrets.save("candidate-secret", account: coordinator.candidateAccount)
        coordinator.candidateStored(account: coordinator.candidateAccount)

        coordinator.connect()
        await coordinator.waitForConnection()

        XCTAssertEqual(try secrets.read(account: ProviderKind.deepSeek.keychainAccount), "candidate-secret")
        XCTAssertNil(try secrets.read(account: coordinator.candidateAccount))
        XCTAssertEqual(fixture.settings.primaryProvider, .builtIn(.deepSeek))
        XCTAssertFalse(fixture.settings.mockMode)
        XCTAssertEqual(fixture.settings.connectionReport(for: .builtIn(.deepSeek)).state, .verified)
        guard case .connected = coordinator.state else { return XCTFail("Expected connected state") }
    }

    func testFailedCandidateNeverReplacesWorkingKeyOrRouting() async throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        try secrets.save("working-secret", account: ProviderKind.deepSeek.keychainAccount)
        let selection = ProviderSelection.builtIn(.deepSeek)
        let existingReport = ProviderConnectionReport(
            state: .verified,
            modelName: fixture.settings.modelName(for: selection),
            checkedAt: .now,
            firstTokenMilliseconds: 100,
            totalMilliseconds: 200,
            errorCategory: nil
        )
        fixture.settings.primaryProvider = selection
        fixture.settings.mockMode = false
        fixture.settings.setConnectionReport(existingReport, for: selection)
        let originalPrimary = fixture.settings.primaryProvider
        let coordinator = ProviderSetupCoordinator(
            settings: fixture.settings,
            secretStore: secrets,
            defaults: fixture.defaults,
            verifier: { _, _ in throw AIProviderError.badResponse(401, "private-body") },
            metadataLoader: { _, _, _ in .unsupported }
        )
        try secrets.save("bad-candidate", account: coordinator.candidateAccount)
        coordinator.candidateStored(account: coordinator.candidateAccount)

        coordinator.connect()
        await coordinator.waitForConnection()

        XCTAssertEqual(try secrets.read(account: ProviderKind.deepSeek.keychainAccount), "working-secret")
        XCTAssertEqual(fixture.settings.primaryProvider, originalPrimary)
        XCTAssertFalse(fixture.settings.mockMode)
        XCTAssertEqual(fixture.settings.connectionReport(for: selection), existingReport)
        XCTAssertEqual(coordinator.state, .failed("unauthorized"))
    }

    func testDoubleConnectStartsExactlyOneVerification() async throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        var calls = 0
        let coordinator = ProviderSetupCoordinator(
            settings: fixture.settings,
            secretStore: secrets,
            defaults: fixture.defaults,
            verifier: { _, _ in
                calls += 1
                try await Task.sleep(for: .milliseconds(40))
                return .init(firstTokenMilliseconds: 10, totalMilliseconds: 20)
            },
            metadataLoader: { _, _, _ in .unsupported }
        )
        try secrets.save("candidate-secret", account: coordinator.candidateAccount)
        coordinator.candidateStored(account: coordinator.candidateAccount)

        coordinator.connect()
        coordinator.connect()
        await coordinator.waitForConnection()

        XCTAssertEqual(calls, 1)
    }

    func testCancelledRevisionCannotActivateLateSuccess() async throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        let originalPrimary = fixture.settings.primaryProvider
        let coordinator = ProviderSetupCoordinator(
            settings: fixture.settings,
            secretStore: secrets,
            defaults: fixture.defaults,
            verifier: { _, _ in
                try await Task.sleep(for: .milliseconds(40))
                return .init(firstTokenMilliseconds: 10, totalMilliseconds: 20)
            },
            metadataLoader: { _, _, _ in .unsupported }
        )
        try secrets.save("candidate-secret", account: coordinator.candidateAccount)
        coordinator.candidateStored(account: coordinator.candidateAccount)

        coordinator.connect()
        await Task.yield()
        coordinator.cancel()
        await coordinator.waitForConnection()

        XCTAssertEqual(fixture.settings.primaryProvider, originalPrimary)
        XCTAssertTrue(fixture.settings.mockMode)
        XCTAssertNil(try secrets.read(account: ProviderKind.deepSeek.keychainAccount))
        XCTAssertNil(try secrets.read(account: coordinator.candidateAccount))
        XCTAssertEqual(coordinator.state, .editing)
    }

    func testYandexRequiresFolderBeforeAnyVerification() async throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        var calls = 0
        let coordinator = ProviderSetupCoordinator(
            settings: fixture.settings,
            secretStore: secrets,
            defaults: fixture.defaults,
            verifier: { _, _ in
                calls += 1
                return .init(firstTokenMilliseconds: 10, totalMilliseconds: 20)
            },
            metadataLoader: { _, _, _ in .unsupported }
        )
        coordinator.select(.yandexGPT)
        try secrets.save("candidate-secret", account: coordinator.candidateAccount)
        coordinator.candidateStored(account: coordinator.candidateAccount)

        coordinator.connect()
        await coordinator.waitForConnection()

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(coordinator.state, .needsAdditionalFields)
    }

    func testPendingActivationRecoversIdempotentlyWithoutSecretInDefaults() throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        let candidateAccount = "api-key.setup.\(UUID().uuidString.lowercased())"
        try secrets.save("candidate-secret", account: candidateAccount)
        let model = fixture.settings.modelName(for: .deepSeek)
        let report = ProviderConnectionReport(
            state: .verified,
            modelName: model,
            checkedAt: .now,
            firstTokenMilliseconds: 10,
            totalMilliseconds: 20,
            errorCategory: nil
        )
        let activation = ProviderSetupActivation(
            selection: .builtIn(.deepSeek),
            modelName: model,
            yandexFolderID: nil,
            candidateAccount: candidateAccount,
            report: report
        )
        let recovery = ProviderSetupRecoveryStore(defaults: fixture.defaults)
        try recovery.begin(activation)
        XCTAssertFalse(defaults(fixture.defaults, contain: "candidate-secret"))

        recovery.recoverIfNeeded(settings: fixture.settings, secretStore: secrets)
        recovery.recoverIfNeeded(settings: fixture.settings, secretStore: secrets)

        XCTAssertEqual(try secrets.read(account: ProviderKind.deepSeek.keychainAccount), "candidate-secret")
        XCTAssertNil(try secrets.read(account: candidateAccount))
        XCTAssertEqual(fixture.settings.primaryProvider, .builtIn(.deepSeek))
        XCTAssertEqual(fixture.settings.connectionReport(for: .builtIn(.deepSeek)).state, .verified)
        XCTAssertFalse(defaults(fixture.defaults, contain: "candidate-secret"))
    }

    func testPreparedRecoveryNeverMistakesOldStableKeyForVerifiedCandidate() throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        let candidateAccount = "api-key.setup.\(UUID().uuidString.lowercased())"
        try secrets.save("old-stable-secret", account: ProviderKind.deepSeek.keychainAccount)
        try secrets.save("candidate-secret", account: candidateAccount)
        let model = fixture.settings.modelName(for: .deepSeek)
        let activation = ProviderSetupActivation(
            selection: .builtIn(.deepSeek),
            modelName: model,
            yandexFolderID: nil,
            candidateAccount: candidateAccount,
            report: ProviderConnectionReport(
                state: .verified,
                modelName: model,
                checkedAt: .now,
                firstTokenMilliseconds: 10,
                totalMilliseconds: 20,
                errorCategory: nil
            )
        )
        let recovery = ProviderSetupRecoveryStore(defaults: fixture.defaults)
        try recovery.begin(activation)
        try secrets.delete(account: candidateAccount)

        recovery.recoverIfNeeded(settings: fixture.settings, secretStore: secrets)

        XCTAssertEqual(try secrets.read(account: ProviderKind.deepSeek.keychainAccount), "old-stable-secret")
        XCTAssertTrue(fixture.settings.mockMode)
        XCTAssertNotEqual(fixture.settings.primaryProvider, .builtIn(.deepSeek))
        XCTAssertTrue(recovery.hasPendingActivation(candidateAccount: candidateAccount))
    }

    func testActivationFromB1WithoutModelPolicyStillDecodes() throws {
        let fixture = makeFixture()
        let model = fixture.settings.modelName(for: .deepSeek)
        let activation = ProviderSetupActivation(
            selection: .builtIn(.deepSeek),
            modelName: model,
            yandexFolderID: nil,
            candidateAccount: "api-key.setup.legacy-fixture",
            report: ProviderConnectionReport(
                state: .verified,
                modelName: model,
                checkedAt: .now,
                firstTokenMilliseconds: 10,
                totalMilliseconds: 20,
                errorCategory: nil
            ),
            modelSelectionPolicy: .recommended
        )
        let encoded = try JSONEncoder().encode(activation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["modelSelectionPolicy"])
        object.removeValue(forKey: "modelSelectionPolicy")

        let decoded = try JSONDecoder().decode(
            ProviderSetupActivation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.modelSelectionPolicy)
        XCTAssertTrue(decoded.isValid)
    }

    func testPresetsExposeOnlySupportedBuiltInSetupTargets() {
        let kinds = ProviderPreset.builtIn.map(\.kind.rawValue)
        XCTAssertEqual(Set(kinds), Set(["openAI", "deepSeek", "anthropic", "xAI", "yandexGPT"]))
        XCTAssertEqual(kinds.count, Set(kinds).count)
        XCTAssertNil(ProviderPreset.preset(for: .mock))
        XCTAssertNil(ProviderPreset.preset(for: .custom))
    }

    func testCoordinatorsStartWithDistinctTemporaryKeychainAccounts() {
        let fixture = makeFixture()
        let first = ProviderSetupCoordinator(settings: fixture.settings, defaults: fixture.defaults)
        let second = ProviderSetupCoordinator(settings: fixture.settings, defaults: fixture.defaults)

        XCTAssertTrue(first.candidateAccount.hasPrefix("api-key.setup."))
        XCTAssertTrue(second.candidateAccount.hasPrefix("api-key.setup."))
        XCTAssertNotEqual(first.candidateAccount, second.candidateAccount)
    }

    func testDiscoverySelectsKnownRecommendedModelAndKeepsRecommendedPolicy() async throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        let snapshot = ProviderMetadataSnapshot(
            models: [
                .init(id: "embedding-first", ownedBy: nil, capabilities: .unknown, isExperimental: false),
                .init(id: "deepseek-v4-pro", ownedBy: "deepseek", capabilities: .deepSeekText, isExperimental: false),
            ],
            fetchedAt: .now,
            expiresAt: .now.addingTimeInterval(3_600)
        )
        let coordinator = ProviderSetupCoordinator(
            settings: fixture.settings,
            secretStore: secrets,
            defaults: fixture.defaults,
            verifier: { provider, _ in
                XCTAssertEqual(provider.modelName, "deepseek-v4-pro")
                return .init(firstTokenMilliseconds: 10, totalMilliseconds: 20)
            },
            metadataLoader: { _, _, _ in .available(snapshot) }
        )
        try secrets.save("candidate-secret", account: coordinator.candidateAccount)
        coordinator.candidateStored(account: coordinator.candidateAccount)

        coordinator.connect()
        await coordinator.waitForConnection()

        XCTAssertEqual(coordinator.metadataStatus, .discovered)
        XCTAssertEqual(fixture.settings.modelName(for: .deepSeek), "deepseek-v4-pro")
        XCTAssertEqual(fixture.settings.modelSelectionPolicy(for: .builtIn(.deepSeek)), .recommended)
    }

    func testUnavailableDiscoveryFallsBackToKnownModelAndStillVerifies() async throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        let expectedModel = fixture.settings.modelName(for: .deepSeek)
        let coordinator = ProviderSetupCoordinator(
            settings: fixture.settings,
            secretStore: secrets,
            defaults: fixture.defaults,
            verifier: { provider, _ in
                XCTAssertEqual(provider.modelName, expectedModel)
                return .init(firstTokenMilliseconds: 10, totalMilliseconds: 20)
            },
            metadataLoader: { _, _, _ in .unavailable(.forbidden) }
        )
        try secrets.save("candidate-secret", account: coordinator.candidateAccount)
        coordinator.candidateStored(account: coordinator.candidateAccount)

        coordinator.connect()
        await coordinator.waitForConnection()

        XCTAssertEqual(coordinator.metadataStatus, .unavailable(.forbidden))
        guard case .connected = coordinator.state else { return XCTFail("Expected generation verification") }
    }

    func testExplicitModelSkipsDiscoveryAndIsNeverReplaced() async throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        fixture.settings.setModelName("manual-model", for: .deepSeek)
        var discoveryCalls = 0
        let coordinator = ProviderSetupCoordinator(
            settings: fixture.settings,
            secretStore: secrets,
            defaults: fixture.defaults,
            verifier: { provider, _ in
                XCTAssertEqual(provider.modelName, "manual-model")
                return .init(firstTokenMilliseconds: 10, totalMilliseconds: 20)
            },
            metadataLoader: { _, _, _ in
                discoveryCalls += 1
                return .unsupported
            }
        )
        try secrets.save("candidate-secret", account: coordinator.candidateAccount)
        coordinator.candidateStored(account: coordinator.candidateAccount)

        coordinator.connect()
        await coordinator.waitForConnection()

        XCTAssertEqual(discoveryCalls, 0)
        XCTAssertEqual(coordinator.metadataStatus, .explicit)
        XCTAssertEqual(fixture.settings.modelName(for: .deepSeek), "manual-model")
    }

    func testCancelledDiscoveryCannotActivateLateResult() async throws {
        let fixture = makeFixture()
        let secrets = FixtureSetupSecrets()
        var verifierCalls = 0
        let snapshot = ProviderMetadataSnapshot(
            models: [.init(id: "deepseek-v4-flash", ownedBy: nil, capabilities: .deepSeekText, isExperimental: false)],
            fetchedAt: .now,
            expiresAt: .now.addingTimeInterval(3_600)
        )
        let coordinator = ProviderSetupCoordinator(
            settings: fixture.settings,
            secretStore: secrets,
            defaults: fixture.defaults,
            verifier: { _, _ in
                verifierCalls += 1
                return .init(firstTokenMilliseconds: 10, totalMilliseconds: 20)
            },
            metadataLoader: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(40))
                return .available(snapshot)
            }
        )
        try secrets.save("candidate-secret", account: coordinator.candidateAccount)
        coordinator.candidateStored(account: coordinator.candidateAccount)

        coordinator.connect()
        await Task.yield()
        coordinator.cancel()
        await coordinator.waitForConnection()

        XCTAssertEqual(verifierCalls, 0)
        XCTAssertTrue(fixture.settings.mockMode)
        XCTAssertNil(try secrets.read(account: ProviderKind.deepSeek.keychainAccount))
        XCTAssertEqual(coordinator.state, .editing)
    }

    private func makeFixture() -> (settings: AppSettings, defaults: UserDefaults) {
        let suite = "ProviderSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (AppSettings(defaults: defaults), defaults)
    }

    private func defaults(_ defaults: UserDefaults, contain needle: String) -> Bool {
        defaults.dictionaryRepresentation().values.contains { value in
            if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
                return text.contains(needle)
            }
            return String(describing: value).contains(needle)
        }
    }
}

private final class FixtureSetupSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = value
    }

    func read(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = nil
    }
}
