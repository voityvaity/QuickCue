import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var createdProviderID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Тестовый режим", isOn: $settings.mockMode)

                    Picker("Основной AI", selection: $settings.primaryProvider) {
                        ForEach(settings.availableProviders) { selection in
                            Text(settings.providerTitle(for: selection)).tag(selection)
                        }
                    }

                    Picker("Резервный AI", selection: $settings.fallbackProvider) {
                        ForEach(settings.availableProviders) { selection in
                            Text(settings.providerTitle(for: selection)).tag(selection)
                        }
                    }
                } header: {
                    Text("Маршрутизация ответов")
                } footer: {
                    Text(routingExplanation)
                }

                Section {
                    ForEach(builtInProviders) { provider in
                        NavigationLink {
                            BuiltInProviderSettingsView(provider: provider)
                        } label: {
                            providerRow(
                                title: provider.title,
                                systemImage: providerIcon(provider),
                                keychainAccount: provider.keychainAccount
                            )
                        }
                    }

                    ForEach(settings.customProviders) { profile in
                        NavigationLink {
                            CustomProviderSettingsView(providerID: profile.id)
                        } label: {
                            providerRow(
                                title: profile.displayName,
                                systemImage: "server.rack",
                                keychainAccount: profile.keychainAccount
                            )
                        }
                    }

                    Button {
                        let profile = CustomProviderProfile()
                        settings.addCustomProvider(profile)
                        createdProviderID = profile.id
                    } label: {
                        Label("Добавить своего провайдера", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Подключение AI")
                } footer: {
                    Text("Можно добавить несколько OpenAI-совместимых сервисов. У каждого будут отдельные адрес, модель, тарифы и ключ в Keychain.")
                }

                Section("Поведение QuickCue") {
                    NavigationLink {
                        PromptSettingsView()
                    } label: {
                        Label("Промпт и стиль ответа", systemImage: "text.quote")
                    }

                    NavigationLink {
                        SpeakerDetectionInfoView()
                    } label: {
                        LabeledContent {
                            Text("Быстрое")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Различение голосов", systemImage: "person.2.wave.2")
                        }
                    }
                }

                Section("Расходы и лимиты") {
                    NavigationLink {
                        LimitsSettingsView()
                    } label: {
                        LabeledContent {
                            Text(settings.monthlyBudgetRUB == 0
                                 ? "Без предупреждения"
                                 : "до \(settings.monthlyBudgetRUB.formatted(.number)) ₽")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Контроль использования", systemImage: "gauge.with.dots.needle.67percent")
                        }
                    }
                }

                Section("Конфиденциальность") {
                    Label("Аудио не сохраняется", systemImage: "waveform.slash")
                    Label("Текст, ответы и фото хранятся локально", systemImage: "iphone.gen3")
                    Label("API-ключи хранятся в Keychain", systemImage: "key.fill")
                    Label("При смене вкладки микрофон останавливается", systemImage: "hand.raised")
                }
            }
            .navigationTitle("Настройки")
            .navigationDestination(item: $createdProviderID) { id in
                CustomProviderSettingsView(providerID: id)
            }
        }
    }

    private var builtInProviders: [ProviderKind] {
        ProviderKind.allCases.filter { $0 != .mock && $0 != .custom }
    }

    private var routingExplanation: String {
        if settings.mockMode {
            return "Сейчас используются безопасные тестовые ответы без сети и расходов. Настройки подключений можно подготовить заранее."
        }
        if settings.primaryProvider == settings.fallbackProvider {
            return "Основной и резервный AI совпадают — резервный запрос запускаться не будет."
        }
        return "Если основной AI не начал отвечать вовремя, QuickCue параллельно запускает резервный и показывает первый ответ."
    }

    private func providerIcon(_ provider: ProviderKind) -> String {
        switch provider {
        case .openAI: "circle.hexagongrid.fill"
        case .deepSeek: "water.waves"
        case .anthropic: "a.circle.fill"
        case .xAI: "x.circle.fill"
        case .yandexGPT: "y.circle.fill"
        case .mock, .custom: "sparkles"
        }
    }

    private func providerRow(
        title: String,
        systemImage: String,
        keychainAccount: String
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            ProviderKeyStatus(keychainAccount: keychainAccount)
        }
    }
}

private struct ProviderKeyStatus: View {
    let keychainAccount: String
    @State private var hasKey = false

    var body: some View {
        Image(systemName: hasKey ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(hasKey ? Color.green : Color.secondary)
            .task { refresh() }
    }

    private func refresh() {
        hasKey = (try? KeychainStore().read(account: keychainAccount)) != nil
    }
}

private enum ProviderTestState: Equatable {
    case idle
    case testing
    case success(milliseconds: Int)
    case failure(String)
}

private struct BuiltInProviderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    let provider: ProviderKind

    @State private var modelName = ""
    @State private var inputRate = 0.0
    @State private var outputRate = 0.0
    @State private var showKeyEditor = false
    @State private var hasStoredKey = false
    @State private var testState: ProviderTestState = .idle

    private var selection: ProviderSelection { .builtIn(provider) }

    var body: some View {
        Form {
            Section {
                connectionStatus

                Button(hasStoredKey ? "Заменить API-ключ" : "Добавить API-ключ") {
                    showKeyEditor = true
                }

                if provider == .yandexGPT {
                    TextField("Folder ID", text: $settings.yandexFolderID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                testButton

                if case .failure(let detail) = testState {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Подключение")
            } footer: {
                Text(provider == .yandexGPT
                     ? "Нужны привязанный платёжный аккаунт, Folder ID, роль ai.languageModels.user и API-ключ сервисного аккаунта."
                     : "QuickCue отправит короткий тестовый запрос и покажет задержку до первых слов.")
            }

            Section {
                DisclosureGroup("Модель и стоимость") {
                    TextField("ID модели", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Сохранить ID модели") {
                        settings.setModelName(modelName, for: selection)
                    }
                    rateFields
                    Button("Сохранить тарифы") {
                        settings.setRates(input: inputRate, output: outputRate, for: selection)
                    }
                }
            } header: {
                Text("Расширенные настройки")
            } footer: {
                Text("Тарифы используются только для локальной оценки расходов и не списывают деньги.")
            }
        }
        .navigationTitle(provider.title)
        .task { load() }
        .sheet(isPresented: $showKeyEditor, onDismiss: refreshKeyStatus) {
            KeyEditorView(
                title: provider.title,
                keychainAccount: provider.keychainAccount
            )
        }
    }

    private var connectionStatus: some View {
        LabeledContent("Состояние") {
            Label(statusTitle, systemImage: statusIcon)
                .foregroundStyle(statusColor)
        }
    }

    private var testButton: some View {
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
    }

    private var rateFields: some View {
        Group {
            LabeledContent("Ввод / 1 млн токенов") {
                TextField("0", value: $inputRate, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                Text("₽")
            }
            LabeledContent("Вывод / 1 млн токенов") {
                TextField("0", value: $outputRate, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                Text("₽")
            }
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

    private func load() {
        modelName = settings.modelName(for: selection)
        inputRate = settings.inputRateRUB(for: selection)
        outputRate = settings.outputRateRUB(for: selection)
        refreshKeyStatus()
    }

    private func refreshKeyStatus() {
        hasStoredKey = (try? KeychainStore().read(account: provider.keychainAccount)) != nil
        testState = .idle
    }

    private func testConnection() async {
        settings.setModelName(modelName, for: selection)
        testState = .testing
        do {
            testState = .success(milliseconds: try await runProviderTest(selection, settings: settings))
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }
}

private struct CustomProviderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let providerID: UUID

    @State private var draft = CustomProviderProfile()
    @State private var showKeyEditor = false
    @State private var hasStoredKey = false
    @State private var testState: ProviderTestState = .idle
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                TextField("Название", text: $draft.displayName)
                TextField("Base URL или полный endpoint", text: $draft.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Picker("API-протокол", selection: $draft.protocolKind) {
                    ForEach(CustomProviderProtocol.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }

                Picker("Авторизация", selection: $draft.authScheme) {
                    ForEach(CustomAuthScheme.allCases) { scheme in
                        Text(scheme.title).tag(scheme)
                    }
                }

                Button("Заполнить для CheapVibeCode") {
                    draft.displayName = "CheapVibeCode"
                    draft.baseURL = "https://ru.cheapvibecode.ru"
                    draft.protocolKind = .openAIChatCompletions
                    draft.authScheme = .bearer
                }
            } header: {
                Text("Провайдер")
            } footer: {
                Text("Для обычного адреса QuickCue добавит /v1/chat/completions. Можно вставить и полный HTTPS-endpoint.")
            }

            Section {
                TextField("ID модели", text: $draft.modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                LabeledContent("Ввод / 1 млн токенов") {
                    TextField("0", value: $draft.inputRateRUB, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text("₽")
                }
                LabeledContent("Вывод / 1 млн токенов") {
                    TextField("0", value: $draft.outputRateRUB, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text("₽")
                }
            } header: {
                Text("Модель и стоимость")
            } footer: {
                Text("ID модели берётся из кабинета конкретного сервиса. Тарифы нужны только для локальной оценки.")
            }

            Section {
                LabeledContent("Состояние") {
                    Label(statusTitle, systemImage: statusIcon)
                        .foregroundStyle(statusColor)
                }

                Button(hasStoredKey ? "Заменить API-ключ" : "Добавить API-ключ") {
                    saveDraft()
                    showKeyEditor = true
                }

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if testState == .testing { ProgressView().controlSize(.small) }
                        Text("Сохранить и проверить")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(testState == .testing || !hasStoredKey)

                if case .failure(let detail) = testState {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Подключение")
            } footer: {
                Text("Ключ хранится отдельно от остальных провайдеров в Keychain этого iPhone.")
            }

            Section {
                Label("Запросы проходят через владельца этого шлюза", systemImage: "network.badge.shield.half.filled")
                Text("Не отправляйте через неизвестный посредник пароли, документы, коммерческие секреты и чувствительные данные. Уточняйте его правила хранения запросов и список реальных upstream-провайдеров.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Приватность")
            }

            Section {
                Button("Удалить провайдера", role: .destructive) {
                    confirmDelete = true
                }
            }
        }
        .navigationTitle(draft.displayName)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { saveDraft() }
            }
        }
        .task { load() }
        .onDisappear { saveDraft() }
        .sheet(isPresented: $showKeyEditor, onDismiss: refreshKeyStatus) {
            KeyEditorView(
                title: draft.displayName,
                keychainAccount: draft.keychainAccount
            )
        }
        .alert("Удалить провайдера?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { deleteProvider() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Настройки и API-ключ этого провайдера будут удалены с iPhone.")
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

    private func load() {
        if let profile = settings.customProviders.first(where: { $0.id == providerID }) {
            draft = profile
        }
        refreshKeyStatus()
    }

    private func saveDraft() {
        draft.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.displayName.isEmpty { draft.displayName = "Свой API" }
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.modelName = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.inputRateRUB = max(0, draft.inputRateRUB)
        draft.outputRateRUB = max(0, draft.outputRateRUB)
        settings.updateCustomProvider(draft)
    }

    private func refreshKeyStatus() {
        hasStoredKey = (try? KeychainStore().read(account: draft.keychainAccount)) != nil
        testState = .idle
    }

    private func testConnection() async {
        saveDraft()
        testState = .testing
        do {
            testState = .success(milliseconds: try await runProviderTest(draft.selection, settings: settings))
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    private func deleteProvider() {
        try? KeychainStore().delete(account: draft.keychainAccount)
        settings.deleteCustomProvider(id: providerID)
        dismiss()
    }
}

private struct PromptSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var draft = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Button("Короткие тезисы") { apply(PromptFactory.defaultConciseSystem) }
                Button("Собеседование") { apply(PromptFactory.interviewSystem) }
                Button("Программирование") { apply(PromptFactory.codingSystem) }
            } header: {
                Text("Готовые варианты")
            } footer: {
                Text("Вариант заполняет редактор ниже — его можно изменить перед сохранением.")
            }

            Section {
                TextEditor(text: $draft)
                    .frame(minHeight: 260)
                    .font(.body)
                    .textInputAutocapitalization(.sentences)

                HStack {
                    Text("\(draft.count) символов")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if saved {
                        Label("Сохранено", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Button("Сохранить промпт") {
                    settings.systemPrompt = draft
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            } header: {
                Text("Системный промпт")
            } footer: {
                Text("QuickCue автоматически добавляет к нему распознанный вопрос и последние реплики. Не вставляйте сюда API-ключи.")
            }
        }
        .navigationTitle("Промпт")
        .task { draft = settings.systemPrompt }
        .onChange(of: draft) { _, _ in saved = false }
    }

    private func apply(_ value: String) {
        draft = value
        saved = false
    }
}

private struct LimitsSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Предупредить после") {
                    TextField("2000", value: $settings.monthlyBudgetRUB, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text("₽")
                }
            } header: {
                Text("Месячные расходы")
            } footer: {
                Text("Это локальная оценка по введённым тарифам. Значение 0 отключает предупреждение; запросы автоматически не блокируются.")
            }

            Section {
                Stepper(
                    "Вопросов: \(settings.sessionQuestionLimit)",
                    value: $settings.sessionQuestionLimit,
                    in: 10...500,
                    step: 10
                )
                Stepper(
                    "Фотографий: \(settings.sessionPhotoLimit)",
                    value: $settings.sessionPhotoLimit,
                    in: 5...100,
                    step: 5
                )
            } header: {
                Text("Одна сессия")
            } footer: {
                Text("После достижения значения QuickCue показывает предупреждение и продолжает работу.")
            }

            Section {
                LabeledContent(
                    "Запуск резерва",
                    value: settings.fallbackDelaySeconds.formatted(.number.precision(.fractionLength(1))) + " с"
                )
                Slider(value: $settings.fallbackDelaySeconds, in: 0.8...3.0, step: 0.1)
                Stepper(
                    "Контекст разговора: \(settings.contextMinutes) мин",
                    value: $settings.contextMinutes,
                    in: 1...30
                )
            } header: {
                Text("Скорость и контекст")
            } footer: {
                Text("Меньшая задержка резерва ускоряет ответ, но может отправить один вопрос сразу двум платным провайдерам.")
            }
        }
        .navigationTitle("Лимиты")
    }
}

private struct SpeakerDetectionInfoView: View {
    var body: some View {
        List {
            Section {
                Label("Мгновенная расшифровка Apple Speech", systemImage: "bolt.fill")
                Label("Предположение роли по смыслу", systemImage: "text.bubble")
                Label("Исправление стрелкой одним нажатием", systemImage: "arrow.left.arrow.right")
            } header: {
                Text("Сейчас")
            } footer: {
                Text("Этот режим самый быстрый и не отправляет аудио внешнему сервису, но не узнаёт человека по голосу.")
            }

            Section {
                Label("Yandex SpeechKit умеет размечать до двух говорящих", systemImage: "person.2.fill")
                Label("OpenAI Transcribe Diarize разделяет аудио по спикерам", systemImage: "waveform.badge.magnifyingglass")
                Text("Облачная диаризация требует отправки аудио, отдельного тарифа и добавляет задержку. Её разумно подключить вторым проходом: быстрый текст показывать сразу, а роли уточнять через несколько секунд.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Точное облачное различение")
            } footer: {
                Text("В этой сборке облачная отправка аудио ещё не включена.")
            }
        }
        .navigationTitle("Голоса")
    }
}

@MainActor
private func runProviderTest(
    _ selection: ProviderSelection,
    settings: AppSettings
) async throws -> Int {
    let client = ProviderRegistry(settings: settings).provider(
        selection,
        honorMockMode: false
    )
    let request = AIRequest(
        question: "Ответь одним словом: работает?",
        context: [],
        mode: .concise,
        imageJPEG: nil,
        maxOutputTokens: 12,
        systemPrompt: settings.systemPrompt
    )
    let clock = ContinuousClock()
    let started = clock.now
    for try await event in client.stream(request: request) {
        if case .textDelta(let text) = event, !text.isEmpty {
            return started.duration(to: clock.now).milliseconds
        }
    }
    throw AIProviderError.emptyResponse
}

private extension Duration {
    var milliseconds: Int {
        let components = self.components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
