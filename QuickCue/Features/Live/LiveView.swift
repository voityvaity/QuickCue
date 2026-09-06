import SwiftData
import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @State private var manualQuestion = ""
    @State private var showManualInput = false
    @Query private var usage: [UsageRecord]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if !settings.hasSeenQuickTips {
                        quickTips
                    }
                    dailyUsageSummary
                    ContextStatusBadge()
                    if let session = store.currentSession {
                        sessionSummary(session)
                    }
                    statusPanel
                    if showManualInput { manualPanel }

                    if store.pendingRequestCount > 0 {
                        Label(
                            "В очереди: \(store.pendingRequestCount)",
                            systemImage: "list.number"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(store.visibleAnswers) { answer in
                        AnswerCardView(answer: answer)
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("QuickCue")
            .toolbar { liveToolbar }
            .alert("QuickCue", isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.alertMessage = nil } }
            )) {
                Button("OK") { store.alertMessage = nil }
            } message: {
                Text(store.alertMessage ?? "")
            }
        }
    }

    @ToolbarContentBuilder
    private var liveToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink(destination: PreflightView()) {
                Image(systemName: "checkmark.circle")
            }
            .accessibilityLabel("Проверить готовность")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            NavigationLink(destination: PreparationHomeView()) {
                Image(systemName: "list.clipboard")
            }
            .accessibilityLabel("Подготовка к вакансии")
            if store.currentSession != nil {
                Button("Завершить") { store.endSession() }
            }
        }
    }

    private var quickTips: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Три быстрых шага", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    settings.hasSeenQuickTips = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Скрыть подсказки")
            }
            Label("Нажмите «Начать слушать» — аудио не сохраняется.", systemImage: "mic.fill")
            Label("Проверьте распознанный вопрос и при необходимости исправьте его.", systemImage: "pencil")
            Label("Звезда сохраняет полезный ответ в избранное.", systemImage: "star.fill")
        }
        .font(.subheadline)
        .padding(14)
        .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private var dailyUsageSummary: some View {
        let interval = Calendar.current.dateInterval(of: .day, for: .now)
        let records = usage.filter { item in
            guard let interval else { return false }
            return item.createdAt >= interval.start && item.createdAt < interval.end
        }
        let summary = UsageCostSummary(records: records)
        return DisclosureGroup {
            if let detail = summary.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            LabeledContent("Расход QuickCue сегодня", value: summary.title)
                .font(.caption.weight(.medium))
        }
        .padding(12)
        .background(Color.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private func sessionSummary(_ session: SessionRecord) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 8) {
                Text(elapsed(from: session.startedAt, to: timeline.date))
                Text("·")
                Text("\(session.questionCount) вопросов")
                Text("·")
                Text(UsageCostSummary(records: usage.filter { $0.sessionID == session.id }).title)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusPanel: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(store.isListening ? Color.red : Color.secondary)
                            .frame(width: 10, height: 10)
                        Text(store.isListening ? "Слушаю" : "Микрофон выключен")
                            .font(.title3.bold())
                    }

                    Text(store.isListening
                         ? (settings.answerTriggerPolicy == .automatic
                            ? "Говорите как обычно — вопросы определяются автоматически"
                            : "Речь сохраняется локально — отправляйте выбранную фразу кнопкой")
                         : "Начните сессию или сфотографируйте задачу одним нажатием")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if settings.mockMode {
                        Label("Тестовый режим · без сети", systemImage: "testtube.2")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else {
                        Text(settings.providerTitle(for: settings.primaryProvider))
                            .font(.caption.weight(.semibold))
                        ProviderConnectionBadge(selection: settings.primaryProvider)
                    }
                }
                Spacer(minLength: 4)
                QuickCaptureButton(presentation: .compact)
            }

            PhotoTransferDisclosure(compact: true)
            RetainedPhotoBadge()

            Picker("Когда отвечать", selection: $settings.answerTriggerPolicy) {
                ForEach(AnswerTriggerPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .pickerStyle(.segmented)

            if !store.liveTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Сейчас слышу", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)
                    Text(store.liveTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(13)
                .background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }

            Button(action: store.toggleListening) {
                Label(
                    store.isListening ? "Остановить прослушивание" : "Начать слушать",
                    systemImage: store.isListening ? "stop.fill" : "mic.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(store.isListening ? .red : .indigo)

            if let candidate = store.latestConfirmedTranscript {
                Button {
                    store.answerLatestConfirmedTranscript()
                } label: {
                    Label("Ответить сейчас", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(candidate.text)
            }

            Button {
                withAnimation { showManualInput.toggle() }
            } label: {
                Label(
                    showManualInput ? "Скрыть ручной ввод" : "Ввести вопрос",
                    systemImage: "square.and.pencil"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private var manualPanel: some View {
        HStack(spacing: 10) {
            TextField("Введите вопрос", text: $manualQuestion, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .submitLabel(.send)
                .onSubmit(submitManualQuestion)
            Button(action: submitManualQuestion) {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(manualQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Отправить вопрос")
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func submitManualQuestion() {
        let value = manualQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.submitManualQuestion(value)
        manualQuestion = ""
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
