import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
    @State private var createdProviderID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Тестовый режим", isOn: $settings.mockMode)

                    Toggle("Подключить резерв", isOn: $settings.latencyFallbackEnabled)

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
                    Text(routingExplanation + " Резерв иногда означает два платных запроса; на новой установке он выключен до вашего выбора.")
                }

                Section {
                    NavigationLink {
                        ProviderSetupView(
                            settings: settings,
                            verifier: { provider, requestID in
                                try await store.verifySetupProvider(provider, requestID: requestID)
                            }
                        )
                    } label: {
                        Label("Подключить AI за три шага", systemImage: "bolt.badge.checkmark.fill")
                            .fontWeight(.semibold)
                    }

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

                    if settings.corruptProviderProfileCount > 0 {
                        Label(
                            "Повреждённых профилей: \(settings.corruptProviderProfileCount). Исходная локальная копия сохранена для восстановления.",
                            systemImage: "externaldrive.badge.exclamationmark"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Подключение AI")
                } footer: {
                    Text("В быстром подключении достаточно выбрать сервис и добавить ключ. Ниже остаются подробные настройки и возможность добавить несколько OpenAI Chat Completions-совместимых сервисов со своим адресом.")
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

                    Picker("Размер текста ответов", selection: $settings.answerTextSize) {
                        ForEach(AnswerTextSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }

                    Toggle("Выделять ключевые слова", isOn: $settings.highlightKeywords)

                    Picker("При смене вкладки", selection: $settings.listeningNavigationPolicy) {
                        ForEach(ListeningNavigationPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }

                    Picker("Ответ на речь", selection: $settings.answerTriggerPolicy) {
                        ForEach(AnswerTriggerPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
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
                    Label("Микрофон работает только при активном приложении", systemImage: "hand.raised")
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

private enum CustomModelDiscoveryState: Equatable {
    case idle
    case loading
    case available(Int)
    case unavailable(String)
}

private struct BuiltInProviderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
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
            let milliseconds = try await runProviderTest(selection, store: store)
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
    @EnvironmentObject private var store: SessionStore
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
    @State private var discoveryTask: Task<Void, Never>?
    @State private var discoveryState: CustomModelDiscoveryState = .idle
    @State private var discoveredModels: [ProviderModelMetadata] = []
    @State private var showProfileImport = false
    @State private var secretHeaderToEdit: ProviderCredentialReference?

    private var isSaved: Bool { settings.customProviders.contains { $0.id == providerID } }
    private var hasUnsavedChanges: Bool {
        settings.customProviders.first { $0.id == providerID } != draft
    }

    var body: some View {
        Form {
            Section {
                Button {
                    showProfileImport = true
                } label: {
                    Label("Импортировать JSON или QR", systemImage: "qrcode.viewfinder")
                }
                if isSaved, let exportedProfile {
                    ShareLink(item: exportedProfile) {
                        Label("Поделиться профилем без ключа", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("Быстрое заполнение")
            } footer: {
                Text("Импорт не выполняет команды и не меняет настройки iPhone. Неизвестные поля отклоняются.")
            }

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

                DisclosureGroup("Дополнительные секретные заголовки") {
                    ForEach($draft.credentialReferences) { $reference in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Имя заголовка", text: $reference.headerName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            HStack {
                                Button("Добавить или заменить значение") {
                                    if saveDraft(requireModel: false) { secretHeaderToEdit = reference }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    removeSecretHeader(reference)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("Удалить секретный заголовок")
                            }
                        }
                    }
                    Button {
                        let id = UUID()
                        draft.credentialReferences.append(.init(
                            id: id,
                            headerName: "X-Custom-Token",
                            keychainAccount: draft.additionalSecretAccount(referenceID: id)
                        ))
                    } label: {
                        Label("Добавить секретный заголовок", systemImage: "plus.circle")
                    }
                    Text("Нужны только если это прямо указано в инструкции сервиса. Значения хранятся в Keychain и не входят в экспорт.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            } header: {
                Text("Провайдер")
            } footer: {
                Text("Для обычного адреса QuickCue добавит путь выбранного протокола. Можно вставить полный HTTPS-endpoint; незнакомый домен остаётся сторонним посредником.")
            }

            Section {
                if !draft.models.isEmpty {
                    Picker("Использовать", selection: $draft.selectedModelID) {
                        ForEach(draft.models) { model in
                            Text(model.displayName.isEmpty ? model.apiModelID : model.displayName)
                                .tag(Optional(model.id))
                        }
                    }
                }

                ForEach($draft.models) { $model in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("ID модели", text: $model.apiModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Понятное название (необязательно)", text: $model.displayName)
                        Toggle("Модель принимает фото", isOn: Binding(
                            get: { model.capabilities.vision.support == .supported },
                            set: { supportsImages in
                                model.capabilities = ProviderModelCapabilities(
                                    text: .init(support: .supported, provenance: .userDeclared),
                                    vision: .init(
                                        support: supportsImages ? .supported : .unknown,
                                        provenance: supportsImages ? .userDeclared : .unknown
                                    ),
                                    streaming: .init(support: .supported, provenance: .userDeclared)
                                )
                            }
                        ))
                        if draft.models.count > 1 {
                            Button("Удалить эту модель", role: .destructive) {
                                let removedID = model.id
                                draft.models.removeAll { $0.id == removedID }
                                if draft.selectedModelID == removedID { draft.selectedModelID = draft.models.first?.id }
                            }
                            .font(.footnote)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    let model = ModelProfile()
                    draft.models.append(model)
                    draft.selectedModelID = model.id
                } label: {
                    Label("Добавить модель", systemImage: "plus.circle")
                }

                Button {
                    discoveryTask?.cancel()
                    discoveryTask = Task { await discoverModels() }
                } label: {
                    HStack {
                        if discoveryState == .loading { ProgressView().controlSize(.small) }
                        Text("Получить доступные модели")
                    }
                }
                .disabled(
                    discoveryState == .loading || !hasStoredKey || draft.baseURL.isEmpty
                        || !draft.protocolKind.supportsModelDiscovery
                )

                if !draft.protocolKind.supportsModelDiscovery {
                    Text("Для Anthropic Messages нет стандартного /models — добавьте ID модели из инструкции сервиса.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !discoveredModels.isEmpty {
                    Picker("Добавить из каталога", selection: Binding(
                        get: { "" },
                        set: { addDiscoveredModel($0) }
                    )) {
                        Text("Выберите модель").tag("")
                        ForEach(discoveredModels) { model in
                            Text(model.id).tag(model.id)
                        }
                    }
                }
                if case .unavailable(let detail) = discoveryState {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }

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
                Text("QuickCue попробует получить каталог сам. Если сервис не поддерживает каталог или не сообщает назначение моделей, выберите модель из его инструкции. Модели для embeddings, аудио и realtime не выбираются автоматически. Тарифы нужны только для локальной оценки.")
            }

            if let originPreview {
                Section("Перед сохранением") {
                    LabeledContent("Владелец адреса", value: originPreview.origin)
                    LabeledContent("Протокол", value: originPreview.protocolTitle)
                    LabeledContent("Модели", value: draft.models.filter { !$0.apiModelID.isEmpty }.map(\.apiModelID).joined(separator: ", "))
                    LabeledContent("Выбрана", value: draft.modelName.isEmpty ? "Не выбрана" : draft.modelName)
                    Text(originPreview.dataDisclosure)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if hasUnsavedChanges {
                    Label("Настройки не сохранены", systemImage: "pencil.circle")
                        .foregroundStyle(.orange)
                } else {
                    ProviderConnectionDetails(selection: draft.selection)
                }

                Button(hasStoredKey ? "Сохранить и заменить API-ключ" : "Сохранить и добавить API-ключ") {
                    if saveDraft(requireModel: false) { showKeyEditor = true }
                }

                Button {
                    testTask?.cancel()
                    testTask = Task { await testConnection() }
                } label: {
                    HStack {
                        if testState == .testing { ProgressView().controlSize(.small) }
                        Text("Проверить и использовать")
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
        .onDisappear {
            cancelTest()
            discoveryTask?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelTest() }
        }
        .sheet(isPresented: $showKeyEditor, onDismiss: refreshKeyStatus) {
            KeyEditorView(
                title: draft.displayName,
                keychainAccount: draft.keychainAccount
            )
        }
        .sheet(item: $secretHeaderToEdit) { reference in
            KeyEditorView(
                title: "Заголовок \(reference.headerName)",
                keychainAccount: reference.keychainAccount,
                marksConnectionChanged: false,
                onSaved: { _ in
                    settings.markConnectionUnverified(draft.selection)
                    secretHeaderToEdit = nil
                }
            )
        }
        .sheet(isPresented: $showProfileImport) {
            CustomProviderImportView(profileID: providerID) { imported in
                draft = imported
                validationMessage = nil
                discoveredModels = []
                discoveryState = .idle
            }
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
    private func saveDraft(requireModel: Bool = true) -> Bool {
        draft.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.models = draft.models.map { model in
            var cleaned = model
            cleaned.apiModelID = model.apiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.displayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.displayName.isEmpty { cleaned.displayName = cleaned.apiModelID }
            cleaned.selectionPolicy = .explicit(cleaned.apiModelID)
            cleaned.inputRateRUB = max(0, cleaned.inputRateRUB)
            cleaned.outputRateRUB = max(0, cleaned.outputRateRUB)
            return cleaned
        }
        let nonEmptyModelIDs = draft.models.map(\.apiModelID).filter { !$0.isEmpty }
        guard Set(nonEmptyModelIDs).count == nonEmptyModelIDs.count else {
            validationMessage = "ID моделей в одном профиле не должны повторяться."
            return false
        }
        if draft.selectedModelID == nil { draft.selectedModelID = draft.models.first?.id }
        guard !draft.displayName.isEmpty, (!requireModel || !draft.modelName.isEmpty),
              let url = URL(string: draft.baseURL), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            validationMessage = requireModel
                ? "Заполните название, ID модели и HTTPS-адрес без ключа, пароля и параметров запроса."
                : "Заполните название и HTTPS-адрес без ключа, пароля и параметров запроса."
            return false
        }
        var seenHeaders = Set<String>()
        do {
            for reference in draft.credentialReferences {
                let normalized = try CustomSecretHeaderPolicy.normalized(reference.headerName)
                guard reference.keychainAccount == draft.additionalSecretAccount(referenceID: reference.id),
                      seenHeaders.insert(normalized.lowercased()).inserted else {
                    validationMessage = "Проверьте дополнительные заголовки: имена не должны повторяться."
                    return false
                }
            }
        } catch {
            validationMessage = error.localizedDescription
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

    private var exportedProfile: String? {
        try? CustomProviderProfileCodec.encode(draft)
    }

    private var originPreview: CustomProviderImportPreview? {
        if let preview = try? CustomProviderProfileCodec.preview(for: draft) { return preview }
        var temporary = draft
        temporary.modelName = temporary.modelName.isEmpty ? "model-not-selected" : temporary.modelName
        return try? CustomProviderProfileCodec.preview(for: temporary)
    }

    private func discoverModels() async {
        guard !Task.isCancelled else { return }
        do {
            _ = try CustomOpenAIProvider.modelsEndpoint(from: draft.baseURL, protocolKind: draft.protocolKind)
            discoveryState = .loading
            let profile = draft
            let keychainAccount = profile.keychainAccount
            let secretStore = KeychainStore()
            let result = try await ProviderMetadataClient().metadata(
                for: profile.selection,
                customProfile: profile,
                credential: { try secretStore.read(account: keychainAccount) },
                additionalHeaders: ProviderRegistry.secretHeaders(for: profile, from: secretStore, snapshot: true)
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .available(let snapshot):
                let candidates = snapshot.models.filter {
                    !$0.isExperimental && ProviderModelSelector.isPlausibleTextAssistant(modelID: $0.id)
                }
                discoveredModels = candidates
                discoveryState = candidates.isEmpty
                    ? .unavailable("Сервис не сообщил подходящих текстовых моделей. Введите ID из его инструкции.")
                    : .available(candidates.count)
                if candidates.count == 1, draft.modelName.isEmpty {
                    addDiscoveredModel(candidates[0].id)
                }
            case .unsupported:
                discoveryState = .unavailable("Этот сервис не предоставляет каталог /models. Введите ID из его инструкции.")
            case .unavailable(let reason):
                discoveryState = .unavailable(metadataExplanation(reason))
            }
        } catch is CancellationError {
            return
        } catch {
            discoveryState = .unavailable(error.localizedDescription)
        }
    }

    private func addDiscoveredModel(_ modelID: String) {
        guard !modelID.isEmpty else { return }
        if let existing = draft.models.first(where: { $0.apiModelID == modelID }) {
            draft.selectedModelID = existing.id
            return
        }
        let metadata = discoveredModels.first { $0.id == modelID }
        let model = ModelProfile(
            apiModelID: modelID,
            capabilities: metadata?.capabilities ?? .unknown,
            selectionPolicy: .explicit(modelID)
        )
        draft.models.removeAll { $0.apiModelID.isEmpty && $0.id == draft.selectedModelID }
        draft.models.append(model)
        draft.selectedModelID = model.id
    }

    private func metadataExplanation(_ reason: ProviderMetadataUnavailableReason) -> String {
        switch reason {
        case .credentialMissing: "Сначала добавьте API-ключ."
        case .unauthorized: "Ключ не принят сервисом. Рабочий профиль не менялся."
        case .forbidden: "У ключа нет доступа к каталогу моделей. Можно ввести ID вручную."
        case .rateLimited: "Сервис временно ограничил запросы. Повторите позже."
        case .offline: "Нет соединения с интернетом."
        case .timedOut: "Сервис не ответил вовремя."
        case .rejectedURL: "Проверьте безопасный HTTPS-адрес сервиса."
        case .invalidResponse: "Каталог сервиса имеет неподдерживаемый формат."
        case .responseTooLarge: "Каталог слишком большой для безопасного импорта."
        case .server: "Сервис не смог вернуть каталог. Введите ID из его инструкции."
        }
    }

    private func testConnection() async {
        guard !Task.isCancelled else { return }
        guard saveDraft() else { return }
        testState = .testing
        do {
            let milliseconds = try await runProviderTest(draft.selection, store: store)
            guard !Task.isCancelled else { return }
            settings.primaryProvider = draft.selection
            settings.mockMode = false
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
            for reference in draft.credentialReferences {
                try KeychainStore().delete(account: reference.keychainAccount)
            }
            try KeychainStore().delete(account: draft.keychainAccount)
            settings.deleteCustomProvider(id: providerID)
            dismiss()
        } catch {
            validationMessage = "Не удалось удалить API-ключ из Keychain. Провайдер оставлен в настройках; попробуйте снова."
        }
    }

    private func removeSecretHeader(_ reference: ProviderCredentialReference) {
        do {
            try KeychainStore().delete(account: reference.keychainAccount)
            draft.credentialReferences.removeAll { $0.id == reference.id }
            settings.createCustomProvider(draft)
            settings.markConnectionUnverified(draft.selection)
        } catch {
            validationMessage = "Не удалось удалить значение заголовка из Keychain. Профиль не изменён."
        }
    }
}

private struct PromptSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var profile: PromptProfileKind = .live
    @State private var style: ResponseStyle = .balanced
    @State private var includesCode = false
    @State private var additionalInstructions = ""
    @State private var usesLegacyPrompt = true
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Picker("Раздел", selection: $profile) {
                    ForEach(PromptProfileKind.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Отдельные настройки")
            } footer: {
                Text("Изменение одного раздела не меняет остальные. Активная сессия продолжает использовать снимок настроек, сделанный для каждого уже поставленного в очередь запроса.")
            }

            Section {
                Picker("Длина ответа", selection: $style) {
                    ForEach(ResponseStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                ForEach(ResponseStyle.allCases) { item in
                    if item == style {
                        Text(item.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Добавлять код, когда полезно", isOn: $includesCode)
            } header: {
                Text("Готовый стиль")
            }

            Section {
                TextEditor(text: $additionalInstructions)
                    .frame(minHeight: 150)
                    .textInputAutocapitalization(.sentences)

                HStack {
                    Text("\(additionalInstructions.count)/\(PromptComposer.maximumAdditionalCharacters) символов")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if saved {
                        Label("Сохранено", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Button(usesLegacyPrompt ? "Перейти на новые настройки" : "Сохранить настройки") {
                    settings.savePromptConfiguration(
                        style: style,
                        includesCodeWhenUseful: includesCode,
                        additionalInstructions: additionalInstructions,
                        for: profile
                    )
                    usesLegacyPrompt = false
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            } header: {
                Text("Дополнительные инструкции")
            } footer: {
                Text("Не вставляйте API-ключи. Текст ограничен 4000 символами и добавляется после безопасных правил QuickCue.")
            }

            if usesLegacyPrompt {
                Section("Текущая совместимость") {
                    Label("Старый промпт сохранён и продолжает работать", systemImage: "archivebox.fill")
                        .foregroundStyle(.secondary)
                    Text("Он будет заменён только для раздела «\(profile.title)» после нажатия кнопки выше. Остальные разделы останутся без изменений.")
                        .font(.footnote)
                }
            } else {
                Section {
                    Button("Вернуть прежний промпт для этого раздела", role: .destructive) {
                        settings.restoreLegacyPrompt(for: profile)
                        loadProfile()
                    }
                } footer: {
                    Text("Это не удаляет сохранённый ранее текст и не меняет другие разделы.")
                }
            }
        }
        .navigationTitle("Промпт и стиль")
        .task { loadProfile() }
        .onChange(of: profile) { _, _ in loadProfile() }
        .onChange(of: style) { _, _ in saved = false }
        .onChange(of: includesCode) { _, _ in saved = false }
        .onChange(of: additionalInstructions) { _, value in
            if value.count > PromptComposer.maximumAdditionalCharacters {
                additionalInstructions = String(value.prefix(PromptComposer.maximumAdditionalCharacters))
            }
            saved = false
        }
    }

    private func loadProfile() {
        if let configuration = settings.promptConfiguration(for: profile) {
            style = configuration.style
            includesCode = configuration.includesCodeWhenUseful
            additionalInstructions = configuration.additionalInstructions
            usesLegacyPrompt = false
        } else {
            style = .balanced
            includesCode = profile == .photo
            additionalInstructions = ""
            usesLegacyPrompt = true
        }
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
    store: SessionStore
) async throws -> Int {
    let report = await store.checkProviderConnection(selection)
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
