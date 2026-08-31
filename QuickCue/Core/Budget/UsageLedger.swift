import Foundation
import SwiftData

@MainActor
struct UsageLedger {
    let modelContext: ModelContext

    func record(
        sessionID: UUID,
        provider: ProviderKind,
        kind: String,
        usage: TokenUsage,
        estimatedCostRUB: Double = 0
    ) {
        let row = UsageRecord(sessionID: sessionID, provider: provider, requestKind: kind)
        row.inputTokens = usage.inputTokens
        row.outputTokens = usage.outputTokens
        row.estimatedCostRUB = estimatedCostRUB
        modelContext.insert(row)
        try? modelContext.save()
    }

    func monthlySpend(now: Date = .now) -> Double {
        let calendar = Calendar.current
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else { return 0 }
        let descriptor = FetchDescriptor<UsageRecord>(predicate: #Predicate { $0.createdAt >= monthStart })
        return (try? modelContext.fetch(descriptor))?.reduce(0) { $0 + $1.estimatedCostRUB } ?? 0
    }
}

