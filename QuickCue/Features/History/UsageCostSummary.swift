import Foundation

struct UsageCostSummary {
    let knownSubtotal: Double
    let unknownAttemptCount: Int
    let hasAttempts: Bool
    private let onlyMock: Bool
    private let onlyPreflight: Bool

    init(records: [UsageRecord]) {
        unknownAttemptCount = records.filter {
            $0.costSourceRaw == "unknown"
                || !$0.estimatedCostRUB.isFinite
                || ($0.costSourceRaw == nil && $0.estimatedCostRUB == 0 && $0.providerRaw != ProviderKind.mock.rawValue)
        }.count
        knownSubtotal = records.filter { $0.costSourceRaw != "unknown" && $0.estimatedCostRUB.isFinite }
            .reduce(0) { $0 + max(0, $1.estimatedCostRUB) }
        hasAttempts = !records.isEmpty
        onlyMock = records.allSatisfy { $0.providerRaw == ProviderKind.mock.rawValue }
        onlyPreflight = records.allSatisfy { $0.costSourceRaw == "not_sent" }
    }

    var title: String {
        guard hasAttempts else { return "Нет учтённых запросов" }
        if onlyPreflight { return "Без отправки в API" }
        let amount = knownSubtotal.formatted(.currency(code: "RUB"))
        if unknownAttemptCount > 0 {
            return knownSubtotal > 0 ? "≈ \(amount) + неизвестно" : "Расход неизвестен"
        }
        return onlyMock ? "Без расходов (Mock)" : "≈ \(amount)"
    }

    var detail: String? {
        unknownAttemptCount > 0
            ? "Не учтена стоимость попыток: \(unknownAttemptCount). Сервис может списать деньги и за отменённый запрос. Итог сверяйте в его кабинете."
            : nil
    }
}
