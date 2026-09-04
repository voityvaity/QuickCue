import SwiftUI

extension ProviderConnectionState {
    var title: String {
        switch self {
        case .unconfigured: "Не настроен"
        case .unverified: "Ключ сохранён · не проверен"
        case .verified: "Подключение проверено"
        case .failed: "Ошибка подключения"
        }
    }

    var shortTitle: String {
        switch self {
        case .unconfigured: "Не настроен"
        case .unverified: "Не проверен"
        case .verified: "Проверен"
        case .failed: "Ошибка"
        }
    }

    var systemImage: String {
        switch self {
        case .unconfigured: "circle"
        case .unverified: "key.fill"
        case .verified: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unconfigured: .secondary
        case .unverified: .orange
        case .verified: .green
        case .failed: .red
        }
    }
}

@MainActor
enum ProviderConnectionStatusStore {
    static func report(for selection: ProviderSelection, settings: AppSettings) -> ProviderConnectionReport {
        guard let account = keychainAccount(for: selection, settings: settings),
              (try? KeychainStore().read(account: account)) != nil else {
            return .unconfigured
        }

        let report = settings.connectionReport(for: selection)
        guard report.state != .unconfigured,
              report.modelName == settings.modelName(for: selection) else {
            return ProviderConnectionReport(
                state: .unverified, modelName: settings.modelName(for: selection),
                checkedAt: nil, firstTokenMilliseconds: nil, totalMilliseconds: nil, errorCategory: nil
            )
        }
        return report
    }

    static func keyChanged(account: String, settings: AppSettings) {
        for selection in settings.availableProviders where keychainAccount(for: selection, settings: settings) == account {
            settings.markConnectionUnverified(selection)
        }
    }

    static func keychainAccount(
        for selection: ProviderSelection,
        settings: AppSettings
    ) -> String? {
        if let custom = settings.customProvider(for: selection) {
            return custom.keychainAccount
        }
        guard selection.kind != .mock, selection.kind != .custom else { return nil }
        return selection.kind.keychainAccount
    }

}

struct ProviderConnectionBadge: View {
    @EnvironmentObject private var settings: AppSettings

    let selection: ProviderSelection
    var compact = false

    private var state: ProviderConnectionState {
        ProviderConnectionStatusStore.report(for: selection, settings: settings).state
    }

    var body: some View {
        Label(compact ? state.shortTitle : state.title, systemImage: state.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(state.color.opacity(0.1), in: Capsule())
            .accessibilityLabel("Состояние AI: \(state.title)")
    }
}

struct ProviderConnectionDetails: View {
    @EnvironmentObject private var settings: AppSettings
    let selection: ProviderSelection

    private var report: ProviderConnectionReport {
        ProviderConnectionStatusStore.report(for: selection, settings: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProviderConnectionBadge(selection: selection)
            if !report.modelName.isEmpty { Text("Модель: \(report.modelName)") }
            if let checked = report.checkedAt {
                Text("Проверка: \(checked.formatted(date: .abbreviated, time: .shortened))")
            }
            if let latency = report.firstTokenMilliseconds {
                Text("Первые слова: \(latency) мс")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
