import SwiftUI

struct PreflightView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
    @State private var checks: [PreflightCheck] = []

    var body: some View {
        List {
            Section {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(check.level))
                            .foregroundStyle(color(check.level))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.title).fontWeight(.semibold)
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Проверка без платного запроса")
            } footer: {
                Text("Экран читает только локальные разрешения и последнюю сохранённую проверку AI. Открытие этого экрана ничего не отправляет в сеть.")
            }

            Section {
                NavigationLink {
                    ContextProfilesView()
                } label: {
                    Label("Профили, вакансии и материалы", systemImage: "person.text.rectangle")
                }
                NavigationLink {
                    ProviderSetupView(
                        settings: settings,
                        verifier: { provider, requestID in
                            try await store.verifySetupProvider(provider, requestID: requestID)
                        }
                    )
                } label: {
                    Label("Проверить подключение AI", systemImage: "bolt.badge.checkmark")
                }
            } header: {
                Text("Если нужна настройка")
            } footer: {
                Text("Только кнопка теста подключения может выполнить короткий платный запрос. Сам переход в настройки — нет.")
            }

            Section {
                Button("Вернуться к быстрому старту") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("Готовность")
        .task { refresh() }
        .refreshable { refresh() }
    }

    private func refresh() {
        checks = PreflightEvaluator.current(settings: settings)
    }

    private func icon(_ level: PreflightLevel) -> String {
        switch level {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .blocked: "xmark.octagon.fill"
        case .informational: "info.circle.fill"
        }
    }

    private func color(_ level: PreflightLevel) -> Color {
        switch level {
        case .ready: .green
        case .attention: .orange
        case .blocked: .red
        case .informational: .indigo
        }
    }
}
