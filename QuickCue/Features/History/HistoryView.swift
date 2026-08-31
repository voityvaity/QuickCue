import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AnswerRecord.createdAt, order: .reverse) private var answers: [AnswerRecord]
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]
    @Query(sort: \PhotoRecord.createdAt, order: .reverse) private var photos: [PhotoRecord]
    @Query private var transcripts: [TranscriptRecord]
    @Query private var usage: [UsageRecord]
    @State private var searchText = ""
    @State private var confirmDeleteAll = false

    private var filteredAnswers: [AnswerRecord] {
        guard !searchText.isEmpty else { return answers }
        return answers.filter {
            $0.question.localizedCaseInsensitiveContains(searchText)
                || $0.answer.localizedCaseInsensitiveContains(searchText)
                || $0.providerRaw.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if answers.isEmpty {
                    ContentUnavailableView("История пока пуста", systemImage: "clock", description: Text("Ответы и фото появятся после первой сессии."))
                } else {
                    Section("Ответы: \(filteredAnswers.count)") {
                        ForEach(filteredAnswers) { answer in
                            NavigationLink {
                                AnswerDetailView(answer: answer)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(answer.question).font(.headline).lineLimit(2)
                                    Text(answer.answer).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    HStack {
                                        Text(ProviderKind(rawValue: answer.providerRaw)?.title ?? answer.providerRaw)
                                        Spacer()
                                        Text(answer.createdAt, style: .time)
                                    }
                                    .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .onDelete(perform: deleteAnswers)
                    }

                    Section("Сводка") {
                        LabeledContent("Сессий", value: "\(sessions.count)")
                        LabeledContent("Фотографий", value: "\(photos.count)")
                        LabeledContent("Оценка расходов", value: usage.reduce(0) { $0 + $1.estimatedCostRUB }.formatted(.currency(code: "RUB")))
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Вопрос, ответ или провайдер")
            .navigationTitle("История")
            .toolbar {
                if !sessions.isEmpty || !answers.isEmpty {
                    Button(role: .destructive) { confirmDeleteAll = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .confirmationDialog("Удалить всю локальную историю?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Удалить без возможности отмены", role: .destructive, action: deleteAll)
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private func deleteAnswers(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(filteredAnswers[index]) }
        try? modelContext.save()
    }

    private func deleteAll() {
        let photoStore = PhotoStore()
        photos.forEach {
            try? photoStore.delete(relativePath: $0.relativePath)
            modelContext.delete($0)
        }
        answers.forEach { modelContext.delete($0) }
        transcripts.forEach { modelContext.delete($0) }
        usage.forEach { modelContext.delete($0) }
        sessions.forEach { modelContext.delete($0) }
        try? modelContext.save()
    }
}

private struct AnswerDetailView: View {
    @Bindable var answer: AnswerRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(answer.question).font(.title2.bold())
                Text(answer.answer).textSelection(.enabled)
                Divider()
                LabeledContent("Провайдер", value: ProviderKind(rawValue: answer.providerRaw)?.title ?? answer.providerRaw)
                LabeledContent("Модель", value: answer.modelName)
                LabeledContent("Первый фрагмент", value: "\(answer.firstTokenMilliseconds) мс")
                LabeledContent("Полностью", value: "\(answer.totalMilliseconds) мс")
                LabeledContent("Токены", value: "\(answer.inputTokens) → \(answer.outputTokens)")
            }
            .padding()
        }
        .navigationTitle("Ответ")
        .navigationBarTitleDisplayMode(.inline)
    }
}
