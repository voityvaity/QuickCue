import Foundation
import SwiftData

@MainActor
struct UsageLedger {
    let modelContext: ModelContext

    /// `estimatedCostRUB` is a known subtotal, never a claim that an unpriced attempt was free.
    @discardableResult
    func recordAttempt(
        _ attempt: AIRequestAttempt,
        sessionID: UUID,
        requestKind: String,
        settings: AppSettings
    ) -> UsageRecord {
        let attemptID = attempt.attemptID
        let existing = FetchDescriptor<UsageRecord>(predicate: #Predicate { $0.attemptID == attemptID })
        if let row = (try? modelContext.fetch(existing))?.first { return row }

        let row = UsageRecord(sessionID: sessionID, provider: attempt.selection.kind, requestKind: requestKind)
        row.createdAt = attempt.startedAt
        row.requestID = attempt.requestID
        row.attemptID = attempt.attemptID
        row.providerSelectionRaw = attempt.selection.rawValue
        row.modelName = attempt.modelName
        row.outcomeRaw = attempt.outcome.rawValue
        row.errorCode = attempt.errorCode
        row.durationMilliseconds = attempt.durationMilliseconds

        let isMock = attempt.selection.kind == .mock
        let rejectedBeforeSend = attempt.outcome == .failed && attempt.usage == nil
            && ["missing_credential", "configuration", "unsupported_image"].contains(attempt.errorCode ?? "")
        let usage: TokenUsage?
        if let reported = attempt.usage {
            usage = TokenUsage(inputTokens: max(0, reported.inputTokens), outputTokens: max(0, reported.outputTokens))
            row.usageSourceRaw = "reported"
        } else if attempt.outcome == .succeeded, !attempt.hasImage {
            // Deliberately coarse local estimate for Cyrillic text, not a provider tokenizer.
            usage = TokenUsage(
                inputTokens: max(1, Int(ceil(Double(attempt.inputCharacterCount) / 3))),
                outputTokens: max(1, Int(ceil(Double(attempt.outputCharacterCount) / 3)))
            )
            row.usageSourceRaw = "estimated"
        } else {
            // A cancelled request may still be billed remotely; its unseen output cannot be estimated.
            usage = nil
            row.usageSourceRaw = "unknown"
        }
        row.inputTokens = usage?.inputTokens ?? 0
        row.outputTokens = usage?.outputTokens ?? 0
        let inputRate = settings.inputRateRUB(for: attempt.selection)
        let outputRate = settings.outputRateRUB(for: attempt.selection)
        if isMock {
            row.costSourceRaw = "free_mock"
        } else if rejectedBeforeSend {
            // These allow-listed provider errors are raised before HTTP transport starts.
            row.costSourceRaw = "not_sent"
        } else if let usage, inputRate.isFinite, outputRate.isFinite, inputRate > 0, outputRate > 0 {
            row.estimatedCostRUB = settings.estimatedCostRUB(for: usage, provider: attempt.selection)
            row.costSourceRaw = "estimated"
        } else {
            row.costSourceRaw = "unknown"
        }
        modelContext.insert(row)
        do {
            try modelContext.save()
        } catch {
            LatencyLogger().failed(provider: attempt.selection.kind, error: error, requestID: attempt.requestID)
        }
        return row
    }

    func record(
        sessionID: UUID,
        provider: ProviderKind,
        kind: String,
        usage: TokenUsage,
        estimatedCostRUB: Double = 0
    ) {
        let row = UsageRecord(sessionID: sessionID, provider: provider, requestKind: kind)
        row.inputTokens = max(0, usage.inputTokens)
        row.outputTokens = max(0, usage.outputTokens)
        row.estimatedCostRUB = estimatedCostRUB.isFinite ? max(0, estimatedCostRUB) : 0
        row.usageSourceRaw = "reported"
        row.costSourceRaw = provider == .mock ? "free_mock" : (row.estimatedCostRUB > 0 ? "estimated" : "unknown")
        modelContext.insert(row)
        try? modelContext.save()
    }

    func monthlySpend(now: Date = .now) -> Double {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: now) else { return 0 }
        let monthStart = interval.start
        let monthEnd = interval.end
        let descriptor = FetchDescriptor<UsageRecord>(predicate: #Predicate { $0.createdAt >= monthStart && $0.createdAt < monthEnd })
        return (try? modelContext.fetch(descriptor))?.reduce(0) {
            $0 + ($1.estimatedCostRUB.isFinite ? max(0, $1.estimatedCostRUB) : 0)
        } ?? 0
    }

    func monthlyUnpricedAttemptCount(now: Date = .now) -> Int {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: now) else { return 0 }
        let monthStart = interval.start
        let monthEnd = interval.end
        let descriptor = FetchDescriptor<UsageRecord>(predicate: #Predicate { $0.createdAt >= monthStart && $0.createdAt < monthEnd })
        return ((try? modelContext.fetch(descriptor)) ?? []).filter {
            $0.costSourceRaw == "unknown" || !$0.estimatedCostRUB.isFinite
                || ($0.costSourceRaw == nil && $0.estimatedCostRUB <= 0 && $0.providerRaw != ProviderKind.mock.rawValue)
        }.count
    }
}

