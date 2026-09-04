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
                                selection: .builtIn(provider)
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
                                selection: profile.selection
                            )
                        }
                    }

                    Button {
                        createdProviderID = UUID()
                    } label: {
                        Label("Добавить своего провайдера", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Подключение AI")
                } footer: {
                    Text("Можно добавить несколько OpenAI-совместимых сервисов. У каждого будут отдельные адрес, модель, тарифы и ключ в Keychain.")
                }

                Section("Поведение QuickCue") {
                    Picker("Оформление", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
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
                    Text("При запросе текст передаётся выбранному AI. Фото передаётся vision-модели, а текстовой модели — только распознанный текст. В тестовом режиме данные не отправляются.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: "\(BuildIdentity.current.version) (\(BuildIdentity.current.build))")
                    LabeledContent("Ревизия", value: BuildIdentity.current.revisionTitle)
                        .font(.footnote)
                    ShareLink(item: BuildIdentity.current.diagnosticText) {
                        Label("Поделиться номером сборки", systemImage: "square.and.arrow.up")
                    }
                    Text("Только версия и ревизия исходников. Без ключей, фотографий и содержимого разговоров.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        selection: ProviderSelection
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            ProviderConnectionBadge(selection: selection, compact: true)
        }
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
    @Environment(\.scenePhase) private var scenePhase
    let provider: ProviderKind

    @State private var modelName = ""
    @State private var inputRate = 0.0
    @State private var outputRate = 0.0
    @State private var showKeyEditor = false
    @State private var hasStoredKey = false
    @State private var testState: ProviderTestState = .idle
    @State private var testTask: Task<Void, Never>?

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
                        .onChange(of: settings.yandexFolderID) { _, _ in
                            settings.markConnectionUnverified(selection)
                            testState = .idle
                        }
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
                     : "QuickCue отправит короткий платный запрос, дождётся его завершения и покажет задержку до первых слов.")
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
        .onDisappear(perform: cancelTest)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelTest() }
        }
        .sheet(isPresented: $showKeyEditor, onDismiss: refreshKeyStatus) {
            KeyEditorView(
                title: provider.title,
                keychainAccount: provider.keychainAccount
            )
        }
    }

    private var connectionStatus: some View {
        ProviderConnectionDetails(selection: selection)
    }

    private var testButton: some View {
        Button {
            testTask?.cancel()
            testTask = Task { await testConnection() }
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
        guard !Task.isCancelled else { return }
        settings.setModelName(modelName, for: selection)
        testState = .testing
        do {
            let milliseconds = try await runProviderTest(selection, settings: settings)
            guard !Task.isCancelled else { return }
            testState = .success(milliseconds: milliseconds)
        } catch {
            guard !Task.isCancelled else { return }
            testState = .failure(error.localizedDescription)
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }
}

private struct CustomProviderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let providerID: UUID

    @State private var draft = CustomProviderProfile()
    @State private var showKeyEditor = false
    @State private var hasStoredKey = false
    @State private var testState: ProviderTestState = .idle
    @State private var confirmDelete = false
    @State private var validationMessage: String?
    @State private var testTask: Task<Void, Never>?

    private var isSaved: Bool { settings.customProviders.contains { $0.id == providerID } }
    private var hasUnsavedChanges: Bool {
        settings.customProviders.first { $0.id == providerID } != draft
    }

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
                if hasUnsavedChanges {
                    Label("Настройки не сохранены", systemImage: "pencil.circle")
                        .foregroundStyle(.orange)
                } else {
                    ProviderConnectionDetails(selection: draft.selection)
                }

                Button(hasStoredKey ? "Сохранить и заменить API-ключ" : "Сохранить и добавить API-ключ") {
                    if saveDraft() { showKeyEditor = true }
                }

                Button {
                    testTask?.cancel()
                    testTask = Task { await testConnection() }
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
                if let validationMessage {
                    Text(validationMessage).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Подключение")
            } footer: {
                Text("Ключ хранится отдельно от остальных провайдеров в Keychain этого iPhone. Проверка отправляет короткий платный запрос и ждёт его полного завершения.")
            }

            Section {
                Label("Запросы проходят через владельца этого шлюза", systemImage: "network.badge.shield.half.filled")
                Text("Не отправляйте через неизвестный посредник пароли, документы, коммерческие секреты и чувствительные данные. Уточняйте его правила хранения запросов и список реальных upstream-провайдеров.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Приватность")
            }

            if isSaved {
                Section {
                    Button("Удалить провайдера", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
        }
        .navigationTitle(draft.displayName)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { if saveDraft() { dismiss() } }
            }
        }
        .task { load() }
        .onDisappear(perform: cancelTest)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelTest() }
        }
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

    private func load() {
        if let profile = settings.customProviders.first(where: { $0.id == providerID }) {
            draft = profile
        } else {
            draft = CustomProviderProfile(id: providerID)
        }
        refreshKeyStatus()
    }

    @discardableResult
    private func saveDraft() -> Bool {
        draft.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.modelName = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.displayName.isEmpty, !draft.modelName.isEmpty,
              let url = URL(string: draft.baseURL), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            validationMessage = "Заполните название, ID модели и HTTPS-адрес без ключа, пароля и параметров запроса. Затем добавьте API-ключ."
            return false
        }
        draft.inputRateRUB = max(0, draft.inputRateRUB)
        draft.outputRateRUB = max(0, draft.outputRateRUB)
        let previous = settings.customProviders.first { $0.id == providerID }
        settings.createCustomProvider(draft)
        if previous?.baseURL != draft.baseURL || previous?.modelName != draft.modelName
            || previous?.protocolKind != draft.protocolKind || previous?.authScheme != draft.authScheme {
            settings.markConnectionUnverified(draft.selection)
            testState = .idle
        }
        validationMessage = nil
        return true
    }

    private func refreshKeyStatus() {
        hasStoredKey = (try? KeychainStore().read(account: draft.keychainAccount)) != nil
        testState = .idle
    }

    private func testConnection() async {
        guard !Task.isCancelled else { return }
        guard saveDraft() else { return }
        testState = .testing
        do {
            let milliseconds = try await runProviderTest(draft.selection, settings: settings)
            guard !Task.isCancelled else { return }
            testState = .success(milliseconds: milliseconds)
        } catch {
            guard !Task.isCancelled else { return }
            testState = .failure(error.localizedDescription)
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }

    private func deleteProvider() {
        cancelTest()
        do {
            try KeychainStore().delete(account: draft.keychainAccount)
            settings.deleteCustomProvider(id: providerID)
            dismiss()
        } catch {
            validationMessage = "Не удалось удалить API-ключ из Keychain. Провайдер оставлен в настройках; попробуйте снова."
        }
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
    let report = await ProviderConnectionChecker.check(selection: selection, settings: settings)
    guard report.state == .verified else {
        throw ProviderTestFailure(category: report.errorCategory)
    }
    return report.firstTokenMilliseconds ?? 0
}

private struct ProviderTestFailure: LocalizedError {
    let category: String?
    var errorDescription: String? {
        ProviderFailure.message(forCategory: category)
    }
}
