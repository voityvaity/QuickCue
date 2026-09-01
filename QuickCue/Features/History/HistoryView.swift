import SwiftData
import SwiftUI
import UIKit

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case speech = "Речь"
    case photo = "Фото"

    var id: String { rawValue }
}

private struct HistoryDay: Identifiable {
    let day: Date
    let sessions: [SessionRecord]
    var id: Date { day }
}

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AnswerRecord.createdAt, order: .reverse) private var answers: [AnswerRecord]
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]
    @Query(sort: \PhotoRecord.createdAt, order: .reverse) private var photos: [PhotoRecord]
    @Query private var transcripts: [TranscriptRecord]
    @Query private var usage: [UsageRecord]
    @Query private var conversationMessages: [ConversationMessageRecord]
    @State private var searchText = ""
    @State private var filter: HistoryFilter = .all
    @State private var confirmDeleteAll = false

    private var visibleSessions: [SessionRecord] {
        sessions.filter { session in
            let sessionAnswers = answersForSession(session)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = !sessionAnswers.isEmpty || photos.contains { $0.sessionID == session.id }
            case .speech: matchesFilter = sessionAnswers.contains { $0.requestKindRaw != AnswerMode.photo.rawValue }
            case .photo: matchesFilter = photos.contains { $0.sessionID == session.id }
            }
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            return sessionAnswers.contains {
                $0.question.localizedCaseInsensitiveContains(searchText)
                    || $0.answer.localizedCaseInsensitiveContains(searchText)
                    || $0.providerRaw.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private var days: [HistoryDay] {
        let grouped = Dictionary(grouping: visibleSessions) {
            Calendar.current.startOfDay(for: $0.startedAt)
        }
        return grouped.map { HistoryDay(day: $0.key, sessions: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Тип", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if days.isEmpty {
                    ContentUnavailableView(
                        "Ничего не найдено",
                        systemImage: "clock",
                        description: Text("Сессии, ответы и фотографии появятся здесь.")
                    )
                } else {
                    ForEach(days) { group in
                        Section(dayTitle(group.day)) {
                            ForEach(group.sessions) { session in
                                NavigationLink {
                                    SessionHistoryDetailView(
                                        session: session,
                                        answers: answersForSession(session),
                                        photos: photos.filter { $0.sessionID == session.id }
                                    )
                                } label: {
                                    sessionRow(session)
                                }
                            }
                        }
                    }

                    Section("Всего") {
                        LabeledContent("Сессий", value: "\(visibleSessions.count)")
                        LabeledContent("Фотографий", value: "\(photos.count)")
                        LabeledContent(
                            "Оценка расходов",
                            value: usage.reduce(0) { $0 + $1.estimatedCostRUB }
                                .formatted(.currency(code: "RUB"))
                        )
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
            .confirmationDialog(
                "Удалить всю локальную историю?",
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Удалить без возможности отмены", role: .destructive, action: deleteAll)
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
        let sessionAnswers = answersForSession(session)
        let sessionPhotos = photos.filter { $0.sessionID == session.id }
        let cost = session.estimatedCostRUB.formatted(.currency(code: "RUB"))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Сессия \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.headline)
                Spacer()
                if sessionAnswers.contains(where: { $0.statusRaw == AnswerStatus.failed.rawValue }) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            }
            Text("\(sessionAnswers.count) ответов  ·  \(sessionPhotos.count) фото  ·  \(cost)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let preview = sessionAnswers.first {
                Text(preview.question)
                    .font(.subheadline)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func answersForSession(_ session: SessionRecord) -> [AnswerRecord] {
        answers.filter { answer in
            guard answer.sessionID == session.id else { return false }
            switch filter {
            case .all: return true
            case .speech: return answer.requestKindRaw != AnswerMode.photo.rawValue
            case .photo: return answer.requestKindRaw == AnswerMode.photo.rawValue
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(day) { return "Вчера" }
        return day.formatted(date: .long, time: .omitted)
    }

    private func deleteAll() {
        let photoStore = PhotoStore()
        photos.forEach {
            try? photoStore.delete(relativePath: $0.relativePath)
            modelContext.delete($0)
        }
        conversationMessages.forEach { modelContext.delete($0) }
        answers.forEach { modelContext.delete($0) }
        transcripts.forEach { modelContext.delete($0) }
        usage.forEach { modelContext.delete($0) }
        sessions.forEach { modelContext.delete($0) }
        try? modelContext.save()
    }
}

private struct SessionHistoryDetailView: View {
    let session: SessionRecord
    let answers: [AnswerRecord]
    let photos: [PhotoRecord]

    var body: some View {
        List {
            Section("Сводка") {
                LabeledContent("Начало", value: session.startedAt.formatted())
                LabeledContent("Вопросов", value: "\(session.questionCount)")
                LabeledContent("Фотографий", value: "\(session.photoCount)")
                LabeledContent(
                    "Расходы",
                    value: session.estimatedCostRUB.formatted(.currency(code: "RUB"))
                )
                ShareLink(item: exportText) {
                    Label("Экспортировать сессию", systemImage: "square.and.arrow.up")
                }
            }

            if !photos.isEmpty {
                Section("Фотографии") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(photos) { photo in
                                HistoryPhotoThumbnail(photo: photo)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }

            Section("Ответы") {
                ForEach(answers) { answer in
                    NavigationLink {
                        AnswerHistoryDetailView(answer: answer)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(answer.question).font(.headline).lineLimit(2)
                            Text(answer.answer.isEmpty ? (answer.errorMessage ?? "Нет ответа") : answer.answer)
                                .font(.subheadline)
                                .foregroundStyle(answer.statusRaw == AnswerStatus.failed.rawValue ? .red : .secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Сессия")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var exportText: String {
        var lines = ["QuickCue — \(session.startedAt.formatted())", ""]
        for answer in answers.reversed() {
            lines.append("Вопрос: \(answer.question)")
            lines.append("Ответ: \(answer.answer.isEmpty ? (answer.errorMessage ?? "Ошибка") : answer.answer)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

private struct HistoryPhotoThumbnail: View {
    let photo: PhotoRecord
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(width: 150, height: 110)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: photo.relativePath) {
            guard let url = try? PhotoStore().url(for: photo.relativePath) else { return }
            image = UIImage(contentsOfFile: url.path)
        }
    }
}

private struct AnswerHistoryDetailView: View {
    @Bindable var answer: AnswerRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(answer.question).font(.title2.bold())
                if answer.statusRaw == AnswerStatus.failed.rawValue {
                    Label(answer.errorMessage ?? "Ошибка запроса", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text(answer.answer).textSelection(.enabled)
                }
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
