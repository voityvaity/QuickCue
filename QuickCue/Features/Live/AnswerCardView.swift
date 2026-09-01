import SwiftUI
import UIKit

struct AnswerCardView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @Bindable var answer: AnswerRecord
    @State private var showTechnicalDetails = false

    private var status: AnswerStatus {
        AnswerStatus(rawValue: answer.statusRaw) ?? .completed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.providerTitle(for: ProviderSelection(rawValue: answer.providerRaw)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                statusView
            }

            Text(answer.question)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if status == .failed {
                Label(answer.errorMessage ?? "Не удалось получить ответ", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button("Повторить") { store.retryAnswer(answer) }
                    .buttonStyle(.borderedProminent)
            } else if answer.answer.isEmpty {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(status == .queued ? "Ожидает в очереди…" : "Получаю ответ…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(answer.answer)
                    .font(.body)
                    .textSelection(.enabled)
                    .animation(.default, value: answer.answer)

                HStack(spacing: 8) {
                    actionButton("Короче", systemImage: "text.alignleft") {
                        store.requestVariation(.concise, for: answer)
                    }
                    actionButton("Подробнее", systemImage: "list.bullet.rectangle") {
                        store.requestVariation(.detailed, for: answer)
                    }
                    actionButton("Копировать", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = answer.answer
                    }
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
