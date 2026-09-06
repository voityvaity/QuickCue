import SwiftUI

struct NavigationPreviewView: View {
    @State private var selected = 0

    private let items = [
        ("Помощник", "waveform"),
        ("Подготовка", "list.clipboard"),
        ("Практика", "figure.run"),
        ("История", "clock.arrow.circlepath"),
        ("Настройки", "gearshape"),
    ]

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Только интерактивный preview", systemImage: "rectangle.on.rectangle")
                    .font(.headline)
                Text("Он не меняет нынешние пять вкладок. «Эфир» и «Диалог» позже могут стать двумя режимами одного Помощника, а камера останется большой кнопкой внутри.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))

            RoundedRectangle(cornerRadius: 24)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    VStack(spacing: 14) {
                        Image(systemName: items[selected].1)
                            .font(.system(size: 44))
                            .foregroundStyle(.indigo)
                        Text(items[selected].0).font(.title2.bold())
                        Text(previewText(selected))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }
                .frame(height: 320)

            HStack(alignment: .top, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    Button {
                        selected = index
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: items[index].1).font(.title3)
                            Text(items[index].0).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(selected == index ? Color.indigo : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Значимый переход навигации будет отдельным изменением только после вашего одобрения этого preview. Сейчас QuickCue сохраняет знакомый интерфейс.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Spacer()
        }
        .padding()
        .navigationTitle("Preview навигации")
    }

    private func previewText(_ index: Int) -> String {
        switch index {
        case 0: "Эфир и Диалог без потери активной сессии; камера, микрофон и завершение остаются быстрыми."
        case 1: "Вакансии, материалы, предполагаемые темы и редактируемый план подготовки."
        case 2: "Будущий вход в тренировки. Банк вопросов относится только к следующему этапу и здесь не реализован."
        case 3: "Единая лента прошлых сессий, ответов и фото."
        default: "AI, промпты, лимиты, речь, диагностика и приватность."
        }
    }
}
