import SwiftUI

@MainActor
struct ProviderSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator: ProviderSetupCoordinator
    @State private var showKeyEditor = false
    @State private var showTechnicalDetails = false

    init(settings: AppSettings) {
        _coordinator = StateObject(wrappedValue: ProviderSetupCoordinator(settings: settings))
    }

    var body: some View {
        Form {
            Section {
                Picker("Сервис", selection: providerBinding) {
                    ForEach(ProviderPreset.builtIn) { preset in
                        Text(preset.kind.title).tag(preset.kind)
                    }
                }
                .disabled(coordinator.state == .testing)

                LabeledContent {
                    Text(coordinator.preset.destinationHost)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Label(coordinator.preset.summary, systemImage: "network")
                }
            } header: {
                Text("1. Выберите сервис")
            } footer: {
                Text("QuickCue берёт модель из готового профиля и не меняет прежний ручной выбор. ID модели и токены в обычном сценарии вводить не нужно.")
            }

            Section {
                Button {
                    showKeyEditor = true
                } label: {
                    Label(
                        coordinator.credentialLength > 0 ? "Заменить подготовленный ключ" : "Ввести или сфотографировать ключ",
                        systemImage: "key.viewfinder"
                    )
                }
                .disabled(coordinator.state == .testing)

                if coordinator.credentialLength > 0 {
                    Label(
                        "Ключ подготовлен · \(coordinator.credentialLength) символов",
                        systemImage: "checkmark.shield.fill"
                    )
                    .foregroundStyle(.green)
                }

                if coordinator.preset.requiresFolderID {
                    TextField("Folder ID", text: $coordinator.yandexFolderID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(coordinator.state == .testing)
                    Text("Folder ID находится в Yandex Cloud. Отсутствие billing или прав будет показано отдельно от ошибки ключа.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("2. Добавьте ключ")
            } footer: {
                Text("Ключ остаётся в Keychain этого iPhone. Фото распознаётся локально и не добавляется в историю.")
            }

            Section {
                Button {
                    coordinator.connect()
                } label: {
                    HStack {
                        if coordinator.state == .testing {
                            ProgressView().controlSize(.small)
                        }
                        Text(coordinator.state == .testing ? "Проверяю полный ответ…" : "Подключить и использовать")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.canConnect)

                setupStatus

                DisclosureGroup("Технические подробности", isExpanded: $showTechnicalDetails) {
                    LabeledContent("Модель", value: coordinator.modelName)
                    LabeledContent("Получатель", value: coordinator.preset.destinationHost)
                    Text("Проверка выполняется только после нажатия кнопки выше и может списать небольшую сумму у провайдера.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("3. Проверьте подключение")
            } footer: {
                Text("До успешного полного ответа прежний ключ и выбранный AI не меняются. Два быстрых нажатия не запускают две проверки.")
            }
        }
        .navigationTitle("Подключить AI")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showKeyEditor) {
            KeyEditorView(
                title: coordinator.selectedProvider.title,
                keychainAccount: coordinator.candidateAccount,
                marksConnectionChanged: false,
                onSaved: coordinator.candidateStored
            )
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            coordinator.cancel()
        }
        .onDisappear {
            coordinator.cancel()
        }
    }

    @ViewBuilder
    private var setupStatus: some View {
        switch coordinator.state {
        case .editing:
            EmptyView()
        case .needsAdditionalFields:
            Label("Укажите Folder ID для YandexGPT.", systemImage: "info.circle.fill")
                .foregroundStyle(.orange)
        case .testing:
            Label("Тестовый запрос отправлен только выбранному сервису.", systemImage: "arrow.up.circle")
                .foregroundStyle(.secondary)
        case .failed(let category):
            Label(ProviderFailure.message(forCategory: category), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .connected(let report):
            VStack(alignment: .leading, spacing: 10) {
                Label("\(coordinator.selectedProvider.title) подключён и выбран", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let latency = report.firstTokenMilliseconds {
                    Text("Первые слова: \(latency) мс")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Готово") { dismiss() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var providerBinding: Binding<ProviderKind> {
        Binding(
            get: { coordinator.selectedProvider },
            set: { coordinator.select($0) }
        )
    }
}
