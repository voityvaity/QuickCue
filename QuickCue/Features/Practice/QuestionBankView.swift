import SwiftData
import SwiftUI

struct QuestionBankView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeQuestionRecord.updatedAt, order: .reverse) private var questions: [PracticeQuestionRecord]
    @State private var filters = QuestionBankFilters()
    @State private var showAddQuestion = false
    @State private var errorMessage: String?

    private var activeQuestions: [PracticeQuestionRecord] { questions.filter { !$0.isArchived } }

    private var filtered: [PracticeQuestionRecord] {
        activeQuestions.filter(filters.matches).sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
            return $0.text.localizedStandardCompare($1.text) == .orderedAscending
        }
    }

    private var topics: [String] { Array(Set(activeQuestions.map(\.topic))).sorted() }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterMenu(title: filters.topic ?? "Все темы", systemImage: "tag") {
                            Button("Все темы") { filters.topic = nil }
                            ForEach(topics, id: \.self) { topic in Button(topic) { filters.topic = topic } }
                        }
                        filterMenu(title: filters.type?.title ?? "Все типы", systemImage: "square.stack.3d.up") {
                            Button("Все типы") { filters.type = nil }
                            ForEach(PracticeQuestionType.allCases) { value in Button(value.title) { filters.type = value } }
                        }
                        filterMenu(title: filters.role?.title ?? "Все роли", systemImage: "person.text.rectangle") {
                            Button("Все роли") { filters.role = nil }
                            ForEach(PracticeQuestionRole.allCases) { value in Button(value.title) { filters.role = value } }
                        }
                        filterMenu(title: filters.difficulty?.title ?? "Любая сложность", systemImage: "dial.medium") {
                            Button("Любая сложность") { filters.difficulty = nil }
                            ForEach(PracticeDifficulty.allCases) { value in Button(value.title) { filters.difficulty = value } }
                        }
                        Toggle(isOn: $filters.favoritesOnly) {
                            Label("Избранное", systemImage: filters.favoritesOnly ? "star.fill" : "star")
                        }
                        .toggleStyle(.button)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if filters == QuestionBankFilters(), !activeQuestions.isEmpty {
                Section("Попрактиковаться сегодня") {
                    ForEach(QuestionBankService.practiceToday(from: activeQuestions)) { question in
                        NavigationLink { QuestionDetailView(question: question) } label: {
                            QuestionRow(question: question)
                        }
                    }
                }
            }

            Section(filtered.isEmpty ? "" : "Все вопросы · \(filtered.count)") {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "Вопросы не найдены",
                        systemImage: "magnifyingglass",
                        description: Text("Измените фильтры или добавьте собственный вопрос.")
                    )
                } else {
                    ForEach(filtered) { question in
                        NavigationLink { QuestionDetailView(question: question) } label: {
                            QuestionRow(question: question)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                toggleFavorite(question)
                            } label: {
                                Label(question.isFavorite ? "Убрать" : "В избранное", systemImage: "star")
                            }
                            .tint(.yellow)
                        }
                    }
                }
            }
        }
        .searchable(text: $filters.query, prompt: "Вопрос или тема")
        .navigationTitle("Банк вопросов")
        .toolbar {
            Button { showAddQuestion = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Добавить свой вопрос")
        }
        .sheet(isPresented: $showAddQuestion) {
            NavigationStack { CustomQuestionEditor() }
        }
        .task { seedQuestions() }
        .alert("Банк вопросов", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func filterMenu<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
    }

    private func seedQuestions() {
        do { try QuestionBankService.seedIfNeeded(in: modelContext) }
        catch { errorMessage = "Не удалось открыть локальный банк. Данные не удалены; повторите после перезапуска." }
    }

    private func toggleFavorite(_ question: PracticeQuestionRecord) {
        do { try QuestionBankService.toggleFavorite(question, in: modelContext) }
        catch { errorMessage = "Не удалось сохранить избранное." }
    }
}

private struct QuestionRow: View {
    let question: PracticeQuestionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text(question.text).font(.body.weight(.medium))
                Spacer(minLength: 8)
                if question.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            HStack(spacing: 8) {
                Text(question.topic)
                Text(PracticeDifficulty(rawValue: question.difficultyRaw)?.title ?? "Сложность не указана")
                if question.attemptCount > 0 { Text("попыток: \(question.attemptCount)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text((PracticeQuestionProvenance(rawValue: question.provenanceRaw) ?? .user).title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.indigo)
        }
        .padding(.vertical, 4)
    }
}

struct QuestionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var question: PracticeQuestionRecord
    @State private var showEditor = false
    @State private var errorMessage: String?
    @State private var confirmArchive = false

    var body: some View {
        List {
            Section {
                Text(question.text).font(.title3.weight(.semibold)).textSelection(.enabled)
                LabeledContent("Тема", value: question.topic)
                LabeledContent("Тип", value: PracticeQuestionType(rawValue: question.typeRaw)?.title ?? "Не указан")
                LabeledContent("Сложность", value: PracticeDifficulty(rawValue: question.difficultyRaw)?.title ?? "Не указана")
                LabeledContent("Для роли", value: PracticeQuestionRole(rawValue: question.roleRaw)?.title ?? "Не указано")
                LabeledContent("Источник", value: question.sourceLabel)
                LabeledContent("Попыток", value: "\(question.attemptCount)")
            } footer: {
                Text(provenanceExplanation)
            }

            Section {
                NavigationLink {
                    PracticeFlowView(configuration: .quick(questionID: question.id))
                } label: {
                    Label("Начать быструю тренировку", systemImage: "play.fill")
                        .fontWeight(.semibold)
                }
                Button {
                    toggleFavorite()
                } label: {
                    Label(question.isFavorite ? "Убрать из избранного" : "Добавить в избранное", systemImage: question.isFavorite ? "star.slash" : "star")
                }
                if question.isCustom {
                    Button { showEditor = true } label: { Label("Изменить свой вопрос", systemImage: "pencil") }
                    Button("Убрать из банка", role: .destructive) { confirmArchive = true }
                }
            }
        }
        .navigationTitle("Вопрос")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) { NavigationStack { CustomQuestionEditor(question: question) } }
        .alert("Вопрос", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Убрать свой вопрос из банка?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Убрать", role: .destructive) {
                do {
                    try QuestionBankService.archive(question, in: modelContext)
                    dismiss()
                } catch { errorMessage = "Не удалось изменить локальный банк." }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Старые попытки останутся в истории и сохранят снимок текста вопроса.")
        }
    }

    private var provenanceExplanation: String {
        switch PracticeQuestionProvenance(rawValue: question.provenanceRaw) ?? .user {
        case .editorial: "Это собственная редакционная подборка QuickCue, а не база вопросов конкретной компании."
        case .user: "Вопрос создан вами и хранится локально."
        case .history: "Вопрос явно сохранён вами из локальной истории."
        case .aiSuggested: "Вопрос был предложен AI; это не подтверждение того, что его задаёт конкретная компания."
        }
    }

    private func toggleFavorite() {
        do { try QuestionBankService.toggleFavorite(question, in: modelContext) }
        catch { errorMessage = "Не удалось сохранить изменение." }
    }
}

struct CustomQuestionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let question: PracticeQuestionRecord?
    let provenance: PracticeQuestionProvenance
    let sourceLabel: String?
    @State private var text: String
    @State private var topic: String
    @State private var role: PracticeQuestionRole
    @State private var difficulty: PracticeDifficulty
    @State private var type: PracticeQuestionType
    @State private var errorMessage: String?

    init(
        question: PracticeQuestionRecord? = nil,
        prefilledText: String = "",
        provenance: PracticeQuestionProvenance = .user,
        sourceLabel: String? = nil
    ) {
        self.question = question
        self.provenance = provenance
        self.sourceLabel = sourceLabel
        _text = State(initialValue: question?.text ?? prefilledText)
        _topic = State(initialValue: question?.topic ?? "")
        _role = State(initialValue: question.flatMap { PracticeQuestionRole(rawValue: $0.roleRaw) } ?? .general)
        _difficulty = State(initialValue: question.flatMap { PracticeDifficulty(rawValue: $0.difficultyRaw) } ?? .basic)
        _type = State(initialValue: question.flatMap { PracticeQuestionType(rawValue: $0.typeRaw) } ?? .technical)
    }

    var body: some View {
        Form {
            Section("Текст вопроса") {
                TextEditor(text: $text).frame(minHeight: 140)
                Button("Скрыть найденные контакты") { text = QuestionPersonalDataRedactor.redact(text) }
                Text("Проверьте названия людей, компаний и проектов сами: QuickCue автоматически скрывает только похожие на email и телефон фрагменты.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Для поиска и тренировки") {
                TextField("Тема", text: $topic)
                Picker("Роль", selection: $role) { ForEach(PracticeQuestionRole.allCases) { Text($0.title).tag($0) } }
                Picker("Сложность", selection: $difficulty) { ForEach(PracticeDifficulty.allCases) { Text($0.title).tag($0) } }
                Picker("Тип", selection: $type) { ForEach(PracticeQuestionType.allCases) { Text($0.title).tag($0) } }
            }
        }
        .navigationTitle(question == nil ? "Новый вопрос" : "Изменить вопрос")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { save() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .alert("Не удалось сохранить", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        do {
            if let question {
                try QuestionBankService.update(
                    question, text: text, topic: topic, role: role,
                    difficulty: difficulty, type: type, in: modelContext
                )
            } else {
                _ = try QuestionBankService.add(
                    text: text, topic: topic, role: role,
                    difficulty: difficulty, type: type, provenance: provenance,
                    sourceLabel: sourceLabel, in: modelContext
                )
            }
            dismiss()
        } catch {
            errorMessage = "Локальная база недоступна. Введённый текст оставлен на экране."
        }
    }
}
