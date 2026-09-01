import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Тестовый режим", isOn: $settings.mockMode)
                    Picker("Основной AI", selection: $settings.primaryProvider) {
                        ForEach(ProviderKind.allCases.filter { $0 != .mock }) {
                            Text($0.title).tag($0)
                        }
                    }
                    Picker("Резервный AI", selection: $settings.fallbackProvider) {
                        ForEach(ProviderKind.allCases.filter { $0 != .mock }) {
                            Text($0.title).tag($0)
                        }
                    }
                } header: {
                    Text("Ответы")
                } footer: {
                    Text(settings.mockMode
                         ? "Сейчас используются безопасные тестовые ответы без сети и расходов."
                         : "Ответы отправляются выбранному провайдеру. Ключ хранится только на iPhone.")
                }

                Section("Подключение AI") {
                    ForEach(ProviderKind.allCases.filter { $0 != .mock }) { provider in
                        NavigationLink {
                            ProviderSettingsView(provider: provider)
                        } label: {
                            HStack {
                                Label(provider.title, systemImage: "sparkles")
                                Spacer()
                                ProviderKeyStatus(provider: provider)
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("Месячный бюджет") {
                        TextField("2000", value: $settings.monthlyBudgetRUB, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Text("₽")
                    }
                    Stepper(
                        "Вопросов за сессию: \(settings.sessionQuestionLimit)",
                        value: $settings.sessionQuestionLimit,
                        in: 10...500,
                        step: 10
                    )
                    Stepper(
                        "Фото за сессию: \(settings.sessionPhotoLimit)",
                        value: $settings.sessionPhotoLimit,
                        in: 5...100,
                        step: 5
                    )
                    Stepper(
                        "Контекст: \(settings.contextMinutes) мин",
                        value: $settings.contextMinutes,
                        in: 1...30
                    )
                } header: {
                    Text("Лимиты")
                } footer: {
                    Text("QuickCue предупреждает о лимите, но не прерывает личную сессию.")
                }

                Section("Дополнительно") {
                    VStack(alignment: .leading) {
                        LabeledContent(
                            "Запуск резерва",
                            value: settings.fallbackDelaySeconds.formatted(
                                .number.precision(.fractionLength(1))
                            ) + " с"
                        )
                        Slider(value: $settings.fallbackDelaySeconds, in: 0.8...3.0, step: 0.1)
                    }
                }

                Section("Конфиденциальность") {
                    Label("Аудио не сохраняется", systemImage: "waveform.slash")
                    Label("Текст, ответы и фото хранятся локально", systemImage: "iphone.gen3")
                    Label("Экран не гаснет во время прослушивания", systemImage: "sun.max")
                    Label("При смене вкладки микрофон останавливается", systemImage: "hand.raised")
                }
            }
            .navigationTitle("Настройки")
        }
    }
}

private struct ProviderKeyStatus: View {
    let provider: ProviderKind
    @State private var hasKey = false

    var body: some View {
        Image(systemName: hasKey ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(hasKey ? Color.green : Color.secondary)
            .task { refresh() }
    }

    private func refresh() {
        hasKey = (try? KeychainStore().read(account: provider.keychainAccount)) != nil
    }
}

private enum ProviderTestState: Equatable {
    case idle
    case testing
    case success(milliseconds: Int)
    case failure(String)
}

private struct ProviderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    let provider: ProviderKind
    @State private var modelName = ""
    @State private var inputRate = 0.0
    @State private var outputRate = 0.0
    @State private var showKeyEditor = false
    @State private var hasStoredKey = false
    @State private var testState: ProviderTestState = .idle

    var body: some View {
        Form {
            Section {
                LabeledContent("Состояние") {
                    Label(
                        statusTitle,
                        systemImage: statusIcon
                    )
                    .foregroundStyle(statusColor)
                }

                Button(hasStoredKey ? "Заменить API-ключ" : "Добавить API-ключ") {
                    showKeyEditor = true
                }

                if provider == .yandexGPT {
                    TextField("Folder ID", text: $settings.yandexFolderID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if testState == .testing { ProgressView().controlSize(.small) }
                        Text("Проверить подключение")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(testState == .testing || !hasStoredKey)
            } header: {
                Text("Подключение")
            } footer: {
                if provider == .yandexGPT {
                    Text("Folder ID находится на странице каталога Yandex Cloud.")
                } else {
                    Text("QuickCue отправит короткий тестовый запрос и покажет задержку.")
                }
            }

            Section("Расширенные настройки") {
                DisclosureGroup("Модель и тарифы") {
                    TextField("ID модели", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Сохранить ID модели") {
                        settings.setModelName(modelName, for: provider)
                    }

                    LabeledContent("Ввод / 1 млн токенов") {
                        TextField("0", value: $inputRate, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                        Text("₽")
                    }
                    LabeledContent("Вывод / 1 млн токенов") {
                        TextField("0", value: $outputRate, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                        Text("₽")
                    }
                    Button("Сохранить тарифы") {
                        settings.setRates(input: inputRate, output: outputRate, for: provider)
                    }
                }
            }
        }
        .navigationTitle(provider.title)
        .task {
            modelName = settings.modelName(for: provider)
            inputRate = settings.inputRateRUB(for: provider)
            outputRate = settings.outputRateRUB(for: provider)
            refreshKeyStatus()
        }
        .sheet(isPresented: $showKeyEditor, onDismiss: refreshKeyStatus) {
            KeyEditorView(provider: provider)
        }
    }

    private var statusTitle: String {
        switch testState {
        case .idle: hasStoredKey ? "Ключ сохранён" : "Нужен API-ключ"
        case .testing: "Проверяю…"
        case .success(let milliseconds): "Работает · \(milliseconds) мс"
        case .failure: "Ошибка подключения"
        }
    }

    private var statusIcon: String {
        switch testState {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.circle.fill"
        case .testing: "hourglass"
        case .idle: hasStoredKey ? "key.fill" : "key.slash"
        }
    }

    private var statusColor: Color {
        switch testState {
        case .success: .green
        case .failure: .red
        case .testing: .indigo
        case .idle: hasStoredKey ? .orange : .secondary
        }
    }

    private func refreshKeyStatus() {
        hasStoredKey = (try? KeychainStore().read(account: provider.keychainAccount)) != nil
        testState = .idle
    }

    private func testConnection() async {
        settings.setModelName(modelName, for: provider)
        testState = .testing
        let clock = ContinuousClock()
        let started = clock.now

        do {
            let client = ProviderRegistry(settings: settings).provider(
                provider,
                honorMockMode: false
            )
            let request = AIRequest(
                question: "Ответь одним словом: работает?",
                context: [],
                mode: .concise,
                imageJPEG: nil,
                maxOutputTokens: 12
            )
            var receivedText = false
            for try await event in client.stream(request: request) {
                if case .textDelta(let text) = event, !text.isEmpty {
                    receivedText = true
                    break
                }
            }
            guard receivedText else { throw AIProviderError.emptyResponse }
            testState = .success(milliseconds: started.duration(to: clock.now).milliseconds)
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = self.components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
