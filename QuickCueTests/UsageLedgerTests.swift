import SwiftData
import XCTest
@testable import QuickCue

@MainActor
final class UsageLedgerTests: XCTestCase {
    func testCancelledAttemptHasUnknownCostAndCustomIdentity() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let suite = "UsageLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let selection = ProviderSelection.custom(UUID())
        let attempt = makeAttempt(selection: selection, outcome: .cancelled)
        let ledger = UsageLedger(modelContext: context)
        let sessionID = UUID()
        let row = ledger.recordAttempt(attempt, sessionID: sessionID, requestKind: "concise", settings: settings)
        _ = ledger.recordAttempt(attempt, sessionID: sessionID, requestKind: "concise", settings: settings)

        XCTAssertEqual(row.providerSelectionRaw, selection.rawValue)
        XCTAssertEqual(row.costSourceRaw, "unknown")
        XCTAssertEqual(row.usageSourceRaw, "unknown")
        XCTAssertEqual(row.outcomeRaw, "cancelled")
        XCTAssertEqual(try context.fetch(FetchDescriptor<UsageRecord>()).count, 1)
        XCTAssertEqual(ledger.monthlyUnpricedAttemptCount(), 1)
    }

    func testReportedUsageRequiresConfiguredPricesAndPersistsModel() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let suite = "UsageLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setRates(input: 100, output: 200, for: .openAI)
        let row = UsageLedger(modelContext: context).recordAttempt(
            makeAttempt(selection: .builtIn(.openAI), outcome: .succeeded, usage: TokenUsage(inputTokens: 1_000, outputTokens: 500)),
            sessionID: UUID(), requestKind: "concise", settings: settings
        )
        XCTAssertEqual(row.usageSourceRaw, "reported")
        XCTAssertEqual(row.costSourceRaw, "calculated")
        XCTAssertEqual(row.estimatedCostRUB, 0.2, accuracy: 0.00001)
        XCTAssertEqual(row.modelName, "test-model")
        XCTAssertEqual(row.costCurrencyCode, "RUB")
        XCTAssertEqual(row.pricingModelName, "test-model")
        XCTAssertNotNil(row.pricingSnapshotDate)
    }

    func testSuccessfulTextWithoutUsageIsMarkedEstimatedNotReported() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let suite = "UsageLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let row = UsageLedger(modelContext: ModelContext(container)).recordAttempt(
            makeAttempt(selection: .builtIn(.deepSeek), outcome: .succeeded),
            sessionID: UUID(), requestKind: "concise", settings: AppSettings(defaults: defaults)
        )
        XCTAssertEqual(row.usageSourceRaw, "estimated")
        XCTAssertEqual(row.costSourceRaw, "unknown")
        XCTAssertGreaterThan(row.inputTokens, 0)
        XCTAssertGreaterThan(row.outputTokens, 0)
    }

    func testImageWithoutReportedUsageRemainsUnknownEvenWithConfiguredPrices() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let suite = "UsageLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setRates(input: 100, output: 200, for: .openAI)
        let row = UsageLedger(modelContext: ModelContext(container)).recordAttempt(
            makeAttempt(selection: .builtIn(.openAI), outcome: .succeeded, hasImage: true),
            sessionID: UUID(), requestKind: "photo", settings: settings
        )
        XCTAssertEqual(row.usageSourceRaw, "unknown")
        XCTAssertEqual(row.costSourceRaw, "unknown")
    }

    func testMockIsExplicitlyFreeAndNegativeReportedTokensAreClamped() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let suite = "UsageLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = UsageLedger(modelContext: ModelContext(container))
        let row = ledger.recordAttempt(
            makeAttempt(selection: .builtIn(.mock), outcome: .succeeded, usage: TokenUsage(inputTokens: -1, outputTokens: -99)),
            sessionID: UUID(), requestKind: "concise", settings: AppSettings(defaults: defaults)
        )
        XCTAssertEqual(row.usageSourceRaw, "reported")
        XCTAssertEqual(row.costSourceRaw, "free_mock")
        XCTAssertEqual(row.estimatedCostRUB, 0)
        XCTAssertEqual(row.inputTokens, 0)
        XCTAssertEqual(row.outputTokens, 0)
        XCTAssertEqual(ledger.monthlyUnpricedAttemptCount(), 0)
    }

    func testMonthlyTotalsExcludeAdjacentMonthsAndMarkLegacyZeroAsUnknown() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let month = try XCTUnwrap(Calendar.current.dateInterval(of: .month, for: .now))
        for (date, cost) in [(month.start.addingTimeInterval(-1), 99.0), (month.start, 0.0), (month.end.addingTimeInterval(-1), 3.0), (month.end, 100.0)] {
            let row = UsageRecord(sessionID: UUID(), provider: .openAI, requestKind: "concise")
            row.createdAt = date
            row.estimatedCostRUB = cost
            context.insert(row)
        }
        try context.save()
        let ledger = UsageLedger(modelContext: context)
        XCTAssertEqual(ledger.monthlySpend(), 3, accuracy: 0.00001)
        XCTAssertEqual(ledger.monthlyUnpricedAttemptCount(), 1)
    }

    func testMissingCredentialDoesNotSuggestAnUnpricedRemoteCharge() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let suite = "UsageLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = UsageLedger(modelContext: ModelContext(container))
        let row = ledger.recordAttempt(
            makeAttempt(selection: .builtIn(.openAI), outcome: .failed, errorCode: "missing_credential"),
            sessionID: UUID(), requestKind: "concise", settings: AppSettings(defaults: defaults)
        )
        XCTAssertEqual(row.costSourceRaw, "not_sent")
        XCTAssertEqual(row.estimatedCostRUB, 0)
        XCTAssertEqual(ledger.monthlyUnpricedAttemptCount(), 0)
    }

    func testConnectionAttemptHasNoConversationAndUnknownPriceIsNotFree() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let suite = "UsageLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let row = UsageLedger(modelContext: context).recordAttempt(
            makeAttempt(selection: .builtIn(.deepSeek), outcome: .succeeded, usage: TokenUsage(inputTokens: 4, outputTokens: 1)),
            sessionID: nil, requestKind: "connection_test", settings: AppSettings(defaults: defaults)
        )

        XCTAssertNil(row.sessionID)
        XCTAssertEqual(row.requestKind, "connection_test")
        XCTAssertEqual(row.usageSourceRaw, "reported")
        XCTAssertEqual(row.costSourceRaw, "unknown")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SessionRecord>()).count, 0)
    }

    func testScheduledConnectionProbeRecordsOneAttemptWithoutCreatingSession() async throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let suite = "UsageLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(modelContext: context, settings: AppSettings(defaults: defaults))

        _ = try await store.verifySetupProvider(MockAIProvider(), requestID: UUID())

        let records = try context.fetch(FetchDescriptor<UsageRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.sessionID)
        XCTAssertEqual(records.first?.requestKind, "connection_test")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SessionRecord>()).count, 0)
    }

    private func makeAttempt(selection: ProviderSelection, outcome: AIRequestAttemptOutcome, usage: TokenUsage? = nil, hasImage: Bool = false, errorCode: String? = nil) -> AIRequestAttempt {
        AIRequestAttempt(
            attemptID: UUID(), requestID: UUID(), selection: selection, modelName: "test-model",
            startedAt: .now, endedAt: .now, outcome: outcome, usage: usage,
            inputCharacterCount: 90, outputCharacterCount: 30, hasImage: hasImage,
            errorCode: errorCode ?? (outcome == .cancelled ? "cancelled" : nil)
        )
    }
}
