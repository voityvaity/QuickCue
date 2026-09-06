import SwiftData
import SwiftUI
import UIKit

struct PracticeFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var sessionStore: SessionStore
    let configuration: PracticeLaunchConfiguration

    var body: some View {
        PracticeFlowHost(
            configuration: configuration,
            modelContext: modelContext,
            sessionStore: sessionStore
        )
    }
}

private struct PracticeFlowHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var coordinator: PracticeSessionCoordinator
    let configuration: PracticeLaunchConfiguration
    let sessionStore: SessionStore
    @State private var speakQuestions = false
    @State private var showHint = false

    init(
        configuration: PracticeLaunchConfiguration,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) {
        self.configuration = configuration
        self.sessionStore = sessionStore
        _coordinator = StateObject(wrappedValue: PracticeSessionCoordinator(
            modelContext: modelContext,
            sessionStore: sessionStore
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = coordinator.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                }
                switch coordinator.phase {
                case .ready: readyPanel
                case .asking: askingPanel
                case .listening: answerPanel(followUp: false)
                case .evaluating: evaluatingPanel
                case .followUp: followUpPanel
                case .feedback: feedbackPanel
                case .finished: finishedPanel
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(configuration.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if coordinator.session?.endedAt == nil, coordinator.phase != .ready {
                Button("Завершить") { coordinator.finishSession() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { coordinator.handleAppInactive() }
        }
        .onChange(of: coordinator.phase) { _, _ in updateIdleTimer() }
        .onDisappear {
            coordinator.leaveScreen()
            UIApplication.shared.isIdleTimerDisabled = sessionStore.isListening || sessionStore.isConversationListening
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(coordinator.phase.title, systemImage: phaseIcon)
                    .font(.headline)
                    .foregroundStyle(.indigo)
                Spacer()
                if coordinator.session != nil, coordinator.phase != .finished {
                    Text(coordinator.progressTitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            if configuration.mode == .full {
                Text(configuration.jobSnapshot == nil
                     ? "Учебная имитация интервью"
                     : "Имитация по выбранной вакансии — QuickCue не является представителем компании")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var readyPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(configuration.mode == .quick
                 ? "Один вопрос, уточнение при необходимости и разбор по понятной рубрике."
                 : "До \(configuration.rounds) вопросов с возможностью завершить раньше.")
                .font(.title3.weight(.semibold))
            Toggle("Озвучивать вопросы", isOn: $speakQuestions)
            if !settings.mockMode {
                ProviderConnectionBadge(selection: settings.primaryProvider)
            }
            Text("Во время озвучивания микрофон выключен, поэтому QuickCue не запишет собственный голос как ваш ответ. Аудио ответа не сохраняется.")
                .font(.caption).foregroundStyle(.secondary)
            Label("Старт не обращается к AI. Разбор начнётся только после отправки вашего ответа.", systemImage: "hand.raised")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                sessionStore.stopAllListening()
                coordinator.start(configuration: configuration, speakQuestions: speakQuestions)
            } label: {
                Label("Начать тренировку", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .practiceCard()
    }

    private var askingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            questionText
            Label("Микрофон выключен на время озвучивания", systemImage: "speaker.wave.2")
                .font(.caption).foregroundStyle(.secondary)
            ProgressView().frame(maxWidth: .infinity)
            Button("Пропустить озвучивание") { coordinator.skipQuestionSpeech() }
                .frame(minHeight: 44)
        }
        .practiceCard()
    }

    private func answerPanel(followUp: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !followUp { questionText }
            answerControls
        }
        .practiceCard()
    }

    private var answerControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: $coordinator.draftAnswer)
                .frame(minHeight: 180)
                .padding(8)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(.quaternary) }
            if showHint {
                Label(localHint, systemImage: "lightbulb")
                    .font(.subheadline)
                    .foregroundStyle(.indigo)
            }
            Button(showHint ? "Скрыть подсказку" : "Нужна подсказка") { showHint.toggle() }
                .font(.subheadline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    voiceButton
                    submitButton
                }
                VStack(spacing: 10) {
                    voiceButton
                    submitButton
                }
            }
            Text(recipientDisclosure)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var voiceButton: some View {
        Button {
            coordinator.toggleListening()
        } label: {
            Label(coordinator.isListening ? "Стоп" : "Ответить голосом", systemImage: coordinator.isListening ? "stop.fill" : "mic.fill")
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.bordered)
        .tint(coordinator.isListening ? .red : .indigo)
    }

    private var submitButton: some View {
        Button {
            coordinator.submitAnswer()
        } label: {
            Label("Я закончил отвечать", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.borderedProminent)
        .tint(.indigo)
        .disabled(!coordinator.canSubmitAnswer)
    }

    private var evaluatingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
            Text("Получаю структурированный разбор…").font(.headline)
            Text("Принятый ответ уже сохранён локально. Остановка или ошибка сервиса его не удалит.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Остановить разбор", role: .cancel) {
                coordinator.cancelEvaluation()
            }
            .frame(minHeight: 44)
        }
        .practiceCard()
    }

    private var followUpPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            feedbackContent
            Divider()
            Label("Уточняющий вопрос", systemImage: "arrow.turn.down.right")
                .font(.headline).foregroundStyle(.indigo)
            Text(coordinator.turn?.followUpQuestion ?? "")
                .font(.title3.weight(.semibold))
            answerControls
            Button("Завершить без уточнения") { coordinator.skipFollowUp() }
                .frame(minHeight: 44)
        }
        .practiceCard()
    }

    private var feedbackPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            feedbackContent
            if coordinator.feedback?.statusRaw == PracticeFeedbackStatus.failed.rawValue
                || coordinator.feedback?.statusRaw == PracticeFeedbackStatus.cancelled.rawValue {
                Button("Повторить разбор") { coordinator.retryEvaluation() }
                    .buttonStyle(.borderedProminent)
            }
            if coordinator.turn?.answerText.isEmpty == false {
                Button("Исправить текст и разобрать снова") { coordinator.reviseAnswer() }
            }
            Menu {
                ForEach(PracticeExampleStyle.allCases.filter { $0 != .standard }) { style in
                    Button(style.title) { coordinator.requestExample(style: style) }
                }
            } label: {
                Label("Другой формат примера", systemImage: "text.badge.star")
            }
            Text(coordinator.selectedExampleStyle.preview + " Переработка начнёт отдельный AI-запрос только после выбора пункта меню.")
                .font(.caption).foregroundStyle(.secondary)
            if let feedback = coordinator.feedback,
               let provider = feedback.providerRaw,
               let model = feedback.modelName {
                Text("Разбор: \(settings.providerTitle(for: ProviderSelection(rawValue: provider))) · \(model) · \(feedback.rubricVersion)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if configuration.mode == .full {
                HStack {
                    Button("Завершить интервью") { coordinator.finishSession() }
                    Spacer()
                    Button("Следующий вопрос") { coordinator.nextQuestion() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Button("Завершить тренировку") { coordinator.finishSession() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .practiceCard()
    }

    @ViewBuilder
    private var feedbackContent: some View {
        if let feedback = coordinator.feedback {
            if feedback.statusRaw == PracticeFeedbackStatus.partial.rawValue {
                Label("Частичный разбор: формат ответа AI был неполным", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !feedback.evidenceFragment.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Фрагмент вашего ответа").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("«\(feedback.evidenceFragment)»").italic().textSelection(.enabled)
                    if let answeredAt = coordinator.turn?.answeredAt {
                        Text("Ответ принят \(answeredAt.formatted(date: .omitted, time: .standard)); аудиозаписи нет.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            feedbackList("Что уже хорошо", items: feedback.strengths, color: .green)
            feedbackList("Что улучшить", items: feedback.improvements, color: .orange)
            if !feedback.exampleAnswer.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Пример более сильного ответа").font(.headline)
                    Text(feedback.exampleAnswer).textSelection(.enabled)
                    Text("Это пример формулировки, а не факт о вашем опыте.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            scoresView(feedback)
            comparisonView
            Label("Аудио не сохранялось: доступен текст, но не воспроизведение записи.", systemImage: "waveform.slash")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Разбор пока недоступен.").foregroundStyle(.secondary)
        }
    }

    private var finishedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(coordinator.session?.summaryText ?? "Попытка сохранена локально.")
                .font(.title3.weight(.semibold))
            if let exercises = coordinator.session?.nextExercises, !exercises.isEmpty {
                Text("Следующие упражнения").font(.headline)
                ForEach(Array(exercises.enumerated()), id: \.offset) { index, exercise in
                    Label(exercise, systemImage: "\(index + 1).circle.fill")
                }
            }
            if configuration.mode == .quick {
                Button("Повторить тот же вопрос") { coordinator.repeatSameQuestion() }
                    .buttonStyle(.borderedProminent)
            }
            NavigationLink {
                PracticeHistoryView()
            } label: {
                Label("История и прогресс", systemImage: "chart.line.uptrend.xyaxis")
            }
        }
        .practiceCard()
    }

    private var questionText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(coordinator.turn?.topic ?? "Вопрос")
                .font(.caption.weight(.semibold)).foregroundStyle(.indigo)
            Text(coordinator.turn?.questionText ?? "Подготавливаю вопрос…")
                .font(.title2.bold()).textSelection(.enabled)
        }
    }

    private var recipientDisclosure: String {
        if settings.mockMode { return "Mock: ответ останется на устройстве, расходов нет." }
        let primary = settings.providerTitle(for: settings.primaryProvider)
        guard settings.latencyFallbackEnabled, settings.fallbackProvider != settings.primaryProvider else {
            return "После кнопки текст ответа отправится в \(primary) для разбора. Аудио не отправляется."
        }
        let fallback = settings.providerTitle(for: settings.fallbackProvider)
        return "После кнопки текст ответа отправится в \(primary). При задержке или ошибке запрос может также уйти в резервный \(fallback). Аудио не отправляется."
    }

    private var phaseIcon: String {
        switch coordinator.phase {
        case .ready: "checkmark.circle"
        case .asking: "person.wave.2"
        case .listening: "mic"
        case .evaluating: "sparkles"
        case .followUp: "arrow.turn.down.right"
        case .feedback: "text.badge.checkmark"
        case .finished: "flag.checkered"
        }
    }

    @ViewBuilder
    private func feedbackList(_ title: String, items: [String], color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: "circle.fill")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(color)
                }
            }
        }
    }

    @ViewBuilder
    private func scoresView(_ feedback: PracticeFeedbackRecord) -> some View {
        let rows: [(String, Int?)] = [
            ("Точность", feedback.accuracyScore),
            ("Полнота", feedback.completenessScore),
            ("Структура", feedback.structureScore),
            ("Пример", feedback.examplesScore),
        ]
        if rows.contains(where: { $0.1 != nil }) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Рубрика · \(feedback.rubricVersion)").font(.headline)
                ForEach(rows, id: \.0) { row in
                    if let value = row.1 { LabeledContent(row.0, value: "\(value) из 5") }
                }
                Text("Баллы помогают сравнить сопоставимые попытки и не являются прогнозом найма.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var comparisonView: some View {
        if let comparison = coordinator.comparison {
            VStack(alignment: .leading, spacing: 6) {
                Text("Изменение к прошлой попытке").font(.headline)
                ForEach(comparison.deltas.keys.sorted(), id: \.self) { key in
                    let delta = comparison.deltas[key] ?? 0
                    LabeledContent(PracticeRubric.metricTitles[key] ?? key, value: delta == 0 ? "без изменения" : String(format: "%+d", delta))
                }
                if let notice = comparison.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Сравнение показано только для одинаковой версии рубрики.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var localHint: String {
        switch PracticeQuestionType(rawValue: coordinator.turn?.typeRaw ?? "") {
        case .technical: "Сформулируйте прямой ответ, приведите короткий пример и назовите одно ограничение или крайний случай."
        case .project: "Опишите задачу, лично выполненное действие, проверяемый результат и один принятый компромисс."
        case .behavioral: "Используйте структуру: ситуация → задача → ваше действие → результат."
        case nil: "Начните с главной мысли и подтвердите её конкретным примером."
        }
    }

    private func updateIdleTimer() {
        let practiceActive = coordinator.session?.endedAt == nil && coordinator.phase != .ready
            && coordinator.phase != .finished
        UIApplication.shared.isIdleTimerDisabled = practiceActive
            || sessionStore.isListening || sessionStore.isConversationListening
    }
}

private extension View {
    func practiceCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(.quaternary) }
    }
}
