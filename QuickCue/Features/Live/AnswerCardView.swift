import SwiftUI
import UIKit

struct AnswerCardView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @Bindable var answer: AnswerRecord
    @State private var showTechnicalDetails = false
    @State private var showQuestionEditor = false

    private var status: AnswerStatus {
        AnswerStatus(rawValue: answer.statusRaw) ?? .completed
    }

    private var isPhoto: Bool { answer.requestKindRaw == AnswerMode.photo.rawValue }
    private var isCurrentSession: Bool { store.currentSession?.id == answer.sessionID }

    private var answerFont: Font {
        switch settings.answerTextSize {
        case .compact: .callout
        case .standard: .body
        case .large: .title3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.providerTitle(for: ProviderSelection(rawValue: answer.providerRaw)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                Button { store.toggleFavorite(answer) } label: {
                    Image(systemName: answer.isFavorite ? "star.fill" : "star")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(answer.isFavorite ? .yellow : .secondary)
                .accessibilityLabel(answer.isFavorite ? "Убрать из избранного" : "Добавить в избранное")
                statusView
            }

            Text(answer.question)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if answer.isStale {
                Label("Относится к прежней версии вопроса", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if status == .failed || status == .cancelled {
                if !answer.answer.isEmpty {
                    Text(answer.answer).textSelection(.enabled)
                }
                Label(answer.errorMessage ?? (status == .cancelled ? "Запрос остановлен" : "Не удалось получить ответ"),
                      systemImage: status == .cancelled ? "stop.circle" : "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(status == .cancelled ? Color.secondary : Color.red)
                if isPhoto {
                    Text("Повторите отправку на экране проверки фото или переснимите задачу на вкладке «Камера».")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Повторить") { store.retryAnswer(answer) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isCurrentSession)
                }
                if !answer.answer.isEmpty {
                    actionButton("Копировать частичный ответ", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = answer.answer
                    }
                }
            } else if answer.answer.isEmpty {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(status == .queued ? "Ожидает в очереди…" : "Получаю ответ…")
                        .foregroundStyle(.secondary)
                }
            } else {
                displayedAnswer
                    .font(answerFont)
                    .textSelection(.enabled)
                    .animation(.default, value: answer.answer)

                HStack(spacing: 8) {
                    if !isPhoto {
                        actionButton("Короче", systemImage: "text.alignleft") {
                            store.requestVariation(.concise, for: answer)
                        }
                        .disabled(!canUseAnswerAction)
                        actionButton("Пример", systemImage: "lightbulb") {
                            store.requestVariation(.example, for: answer)
                        }
                        .disabled(!canUseAnswerAction)
                        actionButton("Исправить", systemImage: "pencil") {
                            showQuestionEditor = true
                        }
                        .disabled(!canEditQuestion)
                    }
                    Menu {
                        if !isPhoto {
                            Button("Подробнее", systemImage: "list.bullet.rectangle") {
                                store.requestVariation(.detailed, for: answer)
                            }
                            .disabled(!canUseAnswerAction)
                            Button("Другой ответ", systemImage: "arrow.triangle.2.circlepath") {
                                store.requestVariation(.alternative, for: answer)
                            }
                            .disabled(!canUseAnswerAction)
                        }
                        Button("Копировать", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = answer.answer
                        }
                    } label: {
                        Label("Ещё", systemImage: "ellipsis.circle")
                            .font(.caption.weight(.medium))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 16) {
                    Button {
                        store.setFeedback(1, for: answer)
                    } label: {
                        Label("Полезно", systemImage: answer.feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    Button {
                        store.setFeedback(-1, for: answer)
                    } label: {
                        Label("Неверно", systemImage: answer.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                    Spacer()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }

            if status == .queued || status == .thinking || status == .streaming {
                Button("Остановить ответ", role: .cancel) { store.cancelAnswer(answer) }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
            }

            DisclosureGroup("Подробности", isExpanded: $showTechnicalDetails) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Модель: \(answer.modelName)")
                    if answer.firstTokenMilliseconds > 0 {
                        Text("Первый фрагмент: \(answer.firstTokenMilliseconds) мс")
                    }
                    if answer.totalMilliseconds > 0 {
                        Text("Полностью: \(answer.totalMilliseconds) мс")
                    }
                    if answer.inputTokens + answer.outputTokens > 0 {
                        Text("Токены: \(answer.inputTokens) → \(answer.outputTokens)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.quaternary) }
        .sheet(isPresented: $showQuestionEditor) {
            QuestionCorrectionView(answer: answer)
                .environmentObject(store)
        }
    }

    private var canUseAnswerAction: Bool {
        isCurrentSession && status == .completed && !answer.isStale
    }

    private var canEditQuestion: Bool {
        isCurrentSession && answer.sourceTranscriptID != nil && status == .completed && !answer.isStale
    }

    private var displayedAnswer: Text {
        guard settings.highlightKeywords, status == .completed else { return Text(answer.answer) }
        let markers = ["важно", "итог", "пример", "ошибка", "сложность"]
        return answer.answer.components(separatedBy: " ").enumerated().reduce(Text("")) { partial, item in
            let token = item.element
            let separator = item.offset == 0 ? "" : " "
            let fragment = Text(separator + token)
            if markers.contains(where: { token.localizedCaseInsensitiveContains($0) }) {
                return partial + fragment.bold().foregroundColor(.indigo)
            }
            return partial + fragment
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .queued:
            Label("В очереди", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .thinking, .streaming:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(status == .thinking ? "Думаю" : "Пишу")
            }
            .foregroundStyle(.secondary)
        case .completed:
            if answer.firstTokenMilliseconds > 0 {
                Label("\(answer.firstTokenMilliseconds) мс", systemImage: "bolt.fill")
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Label("Ошибка", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Label("Остановлен", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct QuestionCorrectionView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let answer: AnswerRecord
    @State private var text: String

    init(answer: AnswerRecord) {
        self.answer = answer
        _text = State(initialValue: answer.question)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                } header: {
                    Text("Исправленный вопрос")
                } footer: {
                    Text("Старый ответ сохранится как ответ на прежнюю формулировку. Сохранение само по себе не отправляет запрос AI.")
                }

                Section {
                    Button("Только сохранить исправление") {
                        store.reviseQuestion(text, for: answer, answerAgain: false)
                        dismiss()
                    }
                    Button("Сохранить и ответить заново") {
                        store.reviseQuestion(text, for: answer, answerAgain: true)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Исправить вопрос")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }
}
