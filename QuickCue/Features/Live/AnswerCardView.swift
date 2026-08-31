import SwiftUI
import UIKit

struct AnswerCardView: View {
    @Bindable var answer: AnswerRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ProviderKind(rawValue: answer.providerRaw)?.title ?? answer.providerRaw)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                if answer.firstTokenMilliseconds > 0 {
                    Label("\(answer.firstTokenMilliseconds) мс", systemImage: "bolt.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            Text(answer.question)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(answer.answer.isEmpty ? "Получаю ответ…" : answer.answer)
                .font(.body)
                .textSelection(.enabled)
                .animation(.default, value: answer.answer)

            HStack {
                Button { UIPasteboard.general.string = answer.answer } label: {
                    Label("Копировать", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(answer.modelName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.quaternary) }
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }
}

