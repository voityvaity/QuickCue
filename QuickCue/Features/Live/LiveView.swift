import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @State private var manualQuestion = ""
    @State private var showManualInput = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
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
            .toolbar {
                if store.currentSession != nil {
                    Button("Завершить") { store.endSession() }
                }
            }
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

    private func sessionSummary(_ session: SessionRecord) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 8) {
                Text(elapsed(from: session.startedAt, to: timeline.date))
                Text("·")
                Text("\(session.questionCount) вопросов")
                Text("·")
                Text(session.estimatedCostRUB.formatted(.currency(code: "RUB")))
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
                         ? "Говорите как обычно — вопросы определяются автоматически"
                         : "Начните сессию или сфотографируйте задачу одним нажатием")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(settings.mockMode ? "Тестовый режим" : settings.providerTitle(for: settings.primaryProvider))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(settings.mockMode ? Color.orange : Color.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            (settings.mockMode ? Color.orange : Color.green).opacity(0.1),
                            in: Capsule()
                        )
                }
                Spacer(minLength: 4)
                QuickCaptureButton(presentation: .compact)
            }

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
