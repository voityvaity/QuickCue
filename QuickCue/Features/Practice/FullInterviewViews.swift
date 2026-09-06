import SwiftData
import SwiftUI

struct FullInterviewSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeQuestionRecord.updatedAt, order: .reverse) private var questions: [PracticeQuestionRecord]
    @Query(sort: \JobProfile.updatedAt, order: .reverse) private var jobs: [JobProfile]
    @State private var interviewerRole: PracticeInterviewerRole = .engineer
    @State private var difficulty: PracticeDifficulty = .medium
    @State private var rounds = 3
    @State private var durationMinutes = 15
    @State private var selectedTopics: Set<String> = []
    @State private var selectedJobID: UUID?
    @State private var errorMessage: String?

    private var topics: [String] { Array(Set(questions.filter { !$0.isArchived }.map(\.topic))).sorted() }

    private var selectedQuestions: [PracticeQuestionRecord] {
        let active = questions.filter { !$0.isArchived }
        let exact = active.filter {
            $0.difficultyRaw == difficulty.rawValue
                && (selectedTopics.isEmpty || selectedTopics.contains($0.topic))
        }
        let fallback = active.filter { selectedTopics.isEmpty || selectedTopics.contains($0.topic) }
        let source = exact.count >= rounds ? exact : fallback
        return Array(source.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
            if $0.attemptCount != $1.attemptCount { return $0.attemptCount < $1.attemptCount }
            return $0.text < $1.text
        }.prefix(rounds))
    }

    private var configuration: PracticeLaunchConfiguration? {
        guard selectedQuestions.count == rounds else { return nil }
        let job = selectedJobID.flatMap { id in jobs.first { $0.id == id } }
            .map { PracticeJobSnapshot(job: $0) }
        return .init(
            mode: .full,
            questionIDs: selectedQuestions.map(\.id),
            interviewerRole: interviewerRole,
            difficulty: difficulty,
            rounds: rounds,
            maxDurationSeconds: durationMinutes * 60,
            jobSnapshot: job
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Формат интервьюера", selection: $interviewerRole) {
                    ForEach(PracticeInterviewerRole.allCases) { Text($0.title).tag($0) }
                }
                Picker("Сложность", selection: $difficulty) {
                    ForEach(PracticeDifficulty.allCases) { Text($0.title).tag($0) }
                }
                Picker("Количество вопросов", selection: $rounds) {
                    Text("Короткое · 3").tag(3)
                    Text("Обычное · 5").tag(5)
                    Text("Расширенное · 7").tag(7)
                }
                Picker("Лимит времени", selection: $durationMinutes) {
                    Text("10 минут").tag(10)
                    Text("15 минут").tag(15)
                    Text("30 минут").tag(30)
                }
            } header: {
                Text("Разумный пресет")
            } footer: {
                Text("Можно завершить интервью раньше. По окончании лимита принятые ответы сохранятся.")
            }

            Section {
                Menu {
                    Button("Все темы") { selectedTopics.removeAll() }
                    ForEach(topics, id: \.self) { topic in
                        Button {
                            if selectedTopics.contains(topic) { selectedTopics.remove(topic) }
                            else { selectedTopics.insert(topic) }
                        } label: {
                            Label(topic, systemImage: selectedTopics.contains(topic) ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    LabeledContent("Темы", value: selectedTopics.isEmpty ? "Все" : "Выбрано: \(selectedTopics.count)")
                }
                Picker("Вакансия", selection: $selectedJobID) {
                    Text("Без вакансии").tag(Optional<UUID>.none)
                    ForEach(jobs) { Text($0.title).tag(Optional($0.id)) }
                }
            } header: {
                Text("Контекст")
            } footer: {
                Text("Если выбрана вакансия, QuickCue использует её локальный снимок. Это учебная имитация, не официальный интервьюер компании и не доказанный процесс её найма.")
            }

            Section("Предпросмотр подборки") {
                ForEach(selectedQuestions) { question in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.text).lineLimit(2)
                        Text(question.topic).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if selectedQuestions.count < rounds {
                    Label("Для выбранных фильтров недостаточно вопросов", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if let configuration {
                    NavigationLink {
                        PracticeFlowView(configuration: configuration)
                    } label: {
                        Label("Начать учебное интервью", systemImage: "play.fill")
                            .fontWeight(.semibold)
                    }
                } else {
                    Label("Сначала выберите доступную подборку", systemImage: "play.slash")
                        .foregroundStyle(.secondary)
                }
                Text("Открытие интервью не отправляет данные. AI вызывается отдельно после каждого принятого ответа для разбора.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Полное интервью")
        .task {
            do { try QuestionBankService.seedIfNeeded(in: modelContext) }
            catch { errorMessage = "Не удалось открыть банк вопросов." }
        }
        .alert("Интервью", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }
}

struct PracticeHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeSessionRecord.createdAt, order: .reverse) private var sessions: [PracticeSessionRecord]
    @Query private var turns: [PracticeTurnRecord]
    @Query private var feedback: [PracticeFeedbackRecord]
    @Query private var usage: [UsageRecord]
    @State private var modeFilter = "all"
    @State private var searchText = ""
    @State private var sessionToDelete: PracticeSessionRecord?
    @State private var deletionError: String?

    private var completedSessions: [PracticeSessionRecord] {
        sessions.filter { $0.statusRaw == PracticeSessionStatus.completed.rawValue }
    }

    private var visibleSessions: [PracticeSessionRecord] {
        sessions.filter { session in
            if modeFilter != "all", session.modeRaw != modeFilter { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            let ownTurns = turns.filter { $0.sessionID == session.id }
            return session.jobTitle?.localizedCaseInsensitiveContains(query) == true
                || ownTurns.contains {
                    $0.questionText.localizedCaseInsensitiveContains(query)
                        || $0.topic.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var progress: PracticeSummary {
        let ids = Set(completedSessions.map(\.id))
        return PracticeSummaryBuilder.build(
            turns: turns.filter { ids.contains($0.sessionID) },
            feedback: feedback.filter { ids.contains($0.sessionID) }
        )
    }

    var body: some View {
        List {
            Section("Личный прогресс") {
                if progress.comparableAttemptCount == 0 {
                    ContentUnavailableView(
                        "Пока недостаточно данных",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Завершите тренировку со структурированным разбором. QuickCue не рисует рост без сопоставимых попыток.")
                    )
                } else {
                    Text(progress.text)
                    LabeledContent("Сопоставимых разборов", value: "\(progress.comparableAttemptCount)")
                    Text("Используется рубрика \(PracticeRubric.version). Изменение модели само по себе не считается ростом.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("Режим", selection: $modeFilter) {
                Text("Все").tag("all")
                Text("Быстрые").tag(PracticeMode.quick.rawValue)
                Text("Полные").tag(PracticeMode.full.rawValue)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            Section("Попытки") {
                if visibleSessions.isEmpty {
                    ContentUnavailableView("Попыток нет", systemImage: "clock", description: Text("Запустите практику из банка вопросов."))
                } else {
                    ForEach(visibleSessions) { session in
                        NavigationLink {
                            PracticeSessionDetailView(session: session)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(PracticeMode(rawValue: session.modeRaw)?.title ?? "Тренировка").font(.headline)
                                    Spacer()
                                    Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(session.jobTitle ?? turns.first(where: { $0.sessionID == session.id })?.topic ?? "Без вакансии")
                                    .font(.subheadline)
                                Text("ответов: \(session.completedRounds)/\(session.requestedRounds) · \(statusTitle(session.statusRaw))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions {
                            Button("Удалить", role: .destructive) { sessionToDelete = session }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Вакансия, тема или вопрос")
        .navigationTitle("Практика")
        .confirmationDialog("Удалить эту попытку и её разборы?", isPresented: Binding(
            get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let sessionToDelete { delete(sessionToDelete) }
                sessionToDelete = nil
            }
            Button("Отмена", role: .cancel) { sessionToDelete = nil }
        }
        .alert("История практики", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) { Button("OK") { deletionError = nil } } message: { Text(deletionError ?? "") }
    }

    private func statusTitle(_ raw: String) -> String {
        switch PracticeSessionStatus(rawValue: raw) {
        case .completed: "завершено"
        case .cancelled: "остановлено"
        case .interrupted: "прервано"
        case .active: "не завершено"
        case nil: "неизвестно"
        }
    }

    private func delete(_ session: PracticeSessionRecord) {
        let sessionTurns = turns.filter { $0.sessionID == session.id }
        let turnIDs = Set(sessionTurns.map(\.id))
        let sessionFeedback = feedback.filter { turnIDs.contains($0.turnID) }
        let requestIDs = Set(sessionFeedback.map(\.requestID))
        sessionFeedback.forEach { modelContext.delete($0) }
        sessionTurns.forEach { modelContext.delete($0) }
        usage.filter { $0.requestID.map(requestIDs.contains) ?? false }.forEach { modelContext.delete($0) }
        modelContext.delete(session)
        do { try modelContext.save() }
        catch { deletionError = "Не удалось полностью удалить попытку. Повторите после перезапуска." }
    }
}

private struct PracticeSessionDetailView: View {
    let session: PracticeSessionRecord
    @Query private var allTurns: [PracticeTurnRecord]
    @Query private var allFeedback: [PracticeFeedbackRecord]
    @Query private var allUsage: [UsageRecord]

    private var turns: [PracticeTurnRecord] {
        allTurns.filter { $0.sessionID == session.id }.sorted { $0.orderIndex < $1.orderIndex }
    }

    private var cost: UsageCostSummary {
        let turnIDs = Set(turns.map(\.id))
        let requestIDs = Set(allFeedback.filter { turnIDs.contains($0.turnID) }.map(\.requestID))
        return UsageCostSummary(records: allUsage.filter { $0.requestID.map(requestIDs.contains) ?? false })
    }

    var body: some View {
        List {
            Section("Итог") {
                Text(session.summaryText.isEmpty ? "Сессия завершена без итогового разбора." : session.summaryText)
                LabeledContent("Расходы разборов", value: cost.title)
                if let detail = cost.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if session.isCompanySimulation {
                    Label("Учебная имитация по вакансии, не официальный представитель компании", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(session.nextExercises.enumerated()), id: \.offset) { index, value in
                    Label(value, systemImage: "\(index + 1).circle")
                }
            }
            ForEach(turns) { turn in
                Section("Вопрос \(turn.orderIndex + 1) · \(turn.topic)") {
                    Text(turn.questionText).font(.headline).textSelection(.enabled)
                    if turn.answerText.isEmpty {
                        Text("Ответ не был принят").foregroundStyle(.secondary)
                    } else {
                        Text(turn.answerText).textSelection(.enabled)
                    }
                    if let feedback = latestFeedback(turnID: turn.id) {
                        if !feedback.evidenceFragment.isEmpty {
                            LabeledContent("Основание") { Text("«\(feedback.evidenceFragment)»").multilineTextAlignment(.trailing) }
                        }
                        ForEach(feedback.strengths, id: \.self) { Label($0, systemImage: "checkmark.circle") }
                        ForEach(feedback.improvements, id: \.self) { Label($0, systemImage: "arrow.up.circle") }
                        if !feedback.exampleAnswer.isEmpty {
                            DisclosureGroup("Пример более сильного ответа") {
                                Text(feedback.exampleAnswer).textSelection(.enabled)
                                Text("Пример не является фактом о вашем опыте.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink {
                        PracticeFlowView(configuration: .quick(questionID: turn.questionID))
                    } label: {
                        Label("Повторить этот вопрос", systemImage: "arrow.clockwise")
                    }
                    Text("Аудио не сохранялось; старую запись воспроизвести нельзя.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Попытка")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func latestFeedback(turnID: UUID) -> PracticeFeedbackRecord? {
        allFeedback.filter {
            $0.turnID == turnID && !$0.isStale
                && ($0.statusRaw == PracticeFeedbackStatus.completed.rawValue
                    || $0.statusRaw == PracticeFeedbackStatus.partial.rawValue)
        }.max { $0.createdAt < $1.createdAt }
    }
}
