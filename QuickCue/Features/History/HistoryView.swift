import SwiftData
import SwiftUI
import UIKit

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case favorites = "Избранное"
    case speech = "Речь"
    case photo = "Фото"
    var id: String { rawValue }
}

private struct HistoryDay: Identifiable {
    let day: Date
    let sessions: [SessionRecord]
    var id: Date { day }
}

/// One chronological event; chat mirrors of answers/photos are omitted, not the saved originals.
enum HistoryTimelineEntry: Identifiable {
    case transcript(TranscriptRecord)
    case message(ConversationMessageRecord)
    case answer(AnswerRecord)
    case photo(PhotoRecord)

    var id: UUID {
        switch self {
        case .transcript(let item): item.id
        case .message(let item): item.id
        case .answer(let item): item.id
        case .photo(let item): item.id
        }
    }

    var date: Date {
        switch self {
        case .transcript(let item): item.createdAt
        case .message(let item): item.createdAt
        case .answer(let item): item.createdAt
        case .photo(let item): item.createdAt
        }
    }

    var title: String {
        switch self {
        case .transcript(let item): item.isQuestion ? "Речь · вопрос" : "Распознанная речь"
        case .message(let item): ConversationSpeaker(rawValue: item.speakerRaw)?.title ?? "Реплика"
        case .answer: "Ответ AI"
        case .photo: "Фотография"
        }
    }

    var text: String {
        switch self {
        case .transcript(let item): item.text
        case .message(let item): item.text
        case .answer(let item): item.question + "\n" + (item.answer.isEmpty ? item.errorMessage ?? "Ответ не получен" : item.answer)
        case .photo(let item): item.recognizedText.isEmpty ? "Без распознанного текста" : item.recognizedText
        }
    }

    static func build(
        transcripts: [TranscriptRecord], messages: [ConversationMessageRecord],
        answers: [AnswerRecord], photos: [PhotoRecord]
    ) -> [Self] {
        let answerIDs = Set(answers.map(\.id))
        let photoPaths = Set(photos.map(\.relativePath))
        let visibleMessages = messages.filter { message in
            if let answerID = message.answerID, answerIDs.contains(answerID), message.speakerRaw == ConversationSpeaker.assistant.rawValue { return false }
            if let path = message.photoRelativePath, photoPaths.contains(path) { return false }
            return true
        }
        let standaloneTranscripts = transcripts.filter { transcript in
            !messages.contains { message in
                message.kindRaw == ConversationMessageKind.speech.rawValue
                    && message.text == transcript.text
                    && abs(message.createdAt.timeIntervalSince(transcript.createdAt)) < 2
            }
        }
        return (standaloneTranscripts.map(Self.transcript) + visibleMessages.map(Self.message)
                + answers.map(Self.answer) + photos.map(Self.photo))
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
    }
}

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var store: SessionStore
    @Query(sort: \AnswerRecord.createdAt, order: .reverse) private var answers: [AnswerRecord]
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]
    @Query(sort: \PhotoRecord.createdAt, order: .reverse) private var photos: [PhotoRecord]
    @Query private var transcripts: [TranscriptRecord]
    @Query private var usage: [UsageRecord]
    @Query private var conversationMessages: [ConversationMessageRecord]
    @Query private var contextSnapshots: [SessionContextSnapshot]
    @State private var searchText = ""
    @State private var filter: HistoryFilter = .all
    @State private var contextFilter = ""
    @State private var confirmDeleteAll = false
    @State private var sessionToDelete: SessionRecord?
    @State private var deletionError: String?

    private var visibleSessions: [SessionRecord] {
        sessions.filter { session in
            let entries = timeline(session)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .favorites:
                matchesFilter = answers.contains { $0.sessionID == session.id && $0.isFavorite }
            case .speech:
                matchesFilter = transcripts.contains { $0.sessionID == session.id }
                    || conversationMessages.contains { $0.sessionID == session.id && $0.kindRaw == ConversationMessageKind.speech.rawValue }
                    || answers.contains { $0.sessionID == session.id && $0.requestKindRaw != AnswerMode.photo.rawValue }
            case .photo: matchesFilter = photos.contains { $0.sessionID == session.id }
            }
            guard matchesFilter else { return false }
            if contextFilter == "__without_context__" {
                guard session.contextTitle == nil else { return false }
            } else if !contextFilter.isEmpty {
                guard session.contextTitle == contextFilter else { return false }
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return session.title.localizedCaseInsensitiveContains(query)
                || session.contextTitle?.localizedCaseInsensitiveContains(query) == true
                || entries.contains { entry in
                if case .answer(let answer) = entry {
                    return entry.text.localizedCaseInsensitiveContains(query)
                        || answer.providerRaw.localizedCaseInsensitiveContains(query)
                        || answer.modelName.localizedCaseInsensitiveContains(query)
                }
                return entry.text.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var days: [HistoryDay] {
        Dictionary(grouping: visibleSessions) { Calendar.current.startOfDay(for: $0.startedAt) }
            .map { HistoryDay(day: $0.key, sessions: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    private var contextTitles: [String] {
        Array(Set(sessions.compactMap(\.contextTitle))).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Тип", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                if !contextTitles.isEmpty {
                    Picker("Контекст", selection: $contextFilter) {
                        Text("Все контексты").tag("")
                        Text("Без контекста").tag("__without_context__")
                        ForEach(contextTitles, id: \.self) { Text($0).tag($0) }
                    }
                }
                if days.isEmpty {
                    ContentUnavailableView("Ничего не найдено", systemImage: "clock", description: Text("Разговоры, ответы и фотографии появятся здесь."))
                } else {
                    ForEach(days) { group in
                        Section(dayTitle(group.day)) {
                            ForEach(group.sessions) { session in
                                NavigationLink {
                                    SessionHistoryDetailView(session: session, entries: timeline(session), usage: usage.filter { $0.sessionID == session.id })
                                } label: { sessionRow(session) }
                                .swipeActions {
                                    Button("Удалить", role: .destructive) { sessionToDelete = session }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Реплика, вопрос, ответ или модель")
            .navigationTitle("История")
            .toolbar {
                if !sessions.isEmpty {
                    Button(role: .destructive) { confirmDeleteAll = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Удалить всю историю")
                }
            }
            .confirmationDialog("Удалить всю локальную историю?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Удалить без возможности отмены", role: .destructive) { deleteSessions(ids: Set(sessions.map(\.id))) }
                Button("Отмена", role: .cancel) {}
            }
            .confirmationDialog("Удалить сессию, её реплики, ответы и фото?", isPresented: Binding(
                get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Удалить сессию", role: .destructive) {
                    if let sessionToDelete { deleteSessions(ids: [sessionToDelete.id]) }
                    sessionToDelete = nil
                }
                Button("Отмена", role: .cancel) { sessionToDelete = nil }
            }
            .alert("История", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
                Button("OK") { deletionError = nil }
            } message: { Text(deletionError ?? "") }
        }
    }

    private func timeline(_ session: SessionRecord) -> [HistoryTimelineEntry] {
        HistoryTimelineEntry.build(
            transcripts: transcripts.filter { $0.sessionID == session.id },
            messages: conversationMessages.filter { $0.sessionID == session.id },
            answers: answers.filter { $0.sessionID == session.id },
            photos: photos.filter { $0.sessionID == session.id }
        )
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
        let entries = timeline(session)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Сессия \(session.startedAt.formatted(date: .omitted, time: .shortened))").font(.headline)
            Text("\(session.questionCount) вопросов · \(session.photoCount) фото · \(session.endedAt == nil ? "не завершена" : "завершена")")
                .font(.caption).foregroundStyle(.secondary)
            if let summary = localSummary(for: session) {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            if let first = entries.first { Text(first.text).font(.subheadline).lineLimit(2) }
        }
        .padding(.vertical, 4)
    }

    private func localSummary(for session: SessionRecord) -> String? {
        let rows = answers.filter { $0.sessionID == session.id }
        guard !rows.isEmpty else { return nil }
        let completed = rows.filter { $0.statusRaw == AnswerStatus.completed.rawValue }
        let failed = rows.filter { $0.statusRaw == AnswerStatus.failed.rawValue }.count
        let firstTokens = completed.map(\.firstTokenMilliseconds).filter { $0 > 0 }.sorted()
        var parts = ["готово \(completed.count)/\(rows.count)"]
        if failed > 0 { parts.append("ошибок \(failed)") }
        if !firstTokens.isEmpty { parts.append("медиана первого текста \(firstTokens[firstTokens.count / 2]) мс") }
        return parts.joined(separator: " · ")
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(day) { return "Вчера" }
        return day.formatted(date: .long, time: .omitted)
    }

    private func deleteSessions(ids: Set<UUID>) {
        if let current = store.currentSession, ids.contains(current.id) { store.endSession() }
        let targets = photos.filter { $0.sessionID.map(ids.contains) ?? false }
        do {
            // Delete protected photo files before their references; surface any storage failure.
            for photo in targets { try PhotoStore().delete(relativePath: photo.relativePath) }
            targets.forEach { modelContext.delete($0) }
            conversationMessages.filter { ids.contains($0.sessionID) }.forEach { modelContext.delete($0) }
            answers.filter { ids.contains($0.sessionID) }.forEach { modelContext.delete($0) }
            transcripts.filter { ids.contains($0.sessionID) }.forEach { modelContext.delete($0) }
            usage.filter { $0.sessionID.map(ids.contains) ?? false }.forEach { modelContext.delete($0) }
            contextSnapshots.filter { ids.contains($0.sessionID) }.forEach { modelContext.delete($0) }
            sessions.filter { ids.contains($0.id) }.forEach { modelContext.delete($0) }
            try modelContext.save()
        } catch {
            deletionError = "Не удалось полностью удалить историю. Некоторые фото могли быть удалены. Повторите удаление после перезапуска приложения."
        }
    }
}

private struct SessionHistoryDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    let session: SessionRecord
    let entries: [HistoryTimelineEntry]
    let usage: [UsageRecord]

    private var cost: UsageCostSummary { UsageCostSummary(records: usage) }

    var body: some View {
        List {
            Section("Сводка") {
                LabeledContent("Начало", value: session.startedAt.formatted())
                LabeledContent("Вопросов", value: "\(session.questionCount)")
                LabeledContent("Фотографий", value: "\(session.photoCount)")
                LabeledContent("Контекст", value: session.contextTitle ?? "Без контекста")
                LabeledContent("Оценка расходов", value: cost.title)
                if let detail = cost.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                ShareLink(item: exportText) { Label("Экспортировать текст сессии", systemImage: "square.and.arrow.up") }
                Text("Экспорт включает реплики, ответы и текст фотографий. Оригинал фото можно отправить отдельно, открыв его ниже.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Лента сессии") {
                ForEach(entries) { entry in
                    switch entry {
                    case .answer(let answer):
                        NavigationLink { AnswerHistoryDetailView(answer: answer) } label: { eventLabel(entry) }
                    case .photo(let photo):
                        NavigationLink { PhotoHistoryDetailView(photo: photo) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                eventLabel(entry)
                                HistoryPhotoThumbnail(relativePath: photo.relativePath)
                            }
                        }
                    case .message, .transcript:
                        eventLabel(entry).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Сессия")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func eventLabel(_ entry: HistoryTimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.title).font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.text).font(.subheadline)
            if case .answer(let answer) = entry {
                Text("\(settings.providerTitle(for: ProviderSelection(rawValue: answer.providerRaw))) · \(answer.modelName) · \(answer.firstTokenMilliseconds) мс")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var exportText: String {
        var lines = ["QuickCue — \(session.startedAt.formatted())", "Расходы: \(cost.title)"]
        if let detail = cost.detail { lines.append(detail) }
        lines.append("")
        for entry in entries {
            lines.append("[\(entry.date.formatted(date: .omitted, time: .standard))] \(entry.title)")
            lines.append(entry.text)
            if case .answer(let answer) = entry {
                lines.append("AI: \(settings.providerTitle(for: ProviderSelection(rawValue: answer.providerRaw))); модель: \(answer.modelName); первый фрагмент: \(answer.firstTokenMilliseconds) мс; полностью: \(answer.totalMilliseconds) мс; состояние: \(answer.statusRaw)")
            }
            if case .photo(let photo) = entry { lines.append("Оригинал на iPhone: \(photo.relativePath)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

private struct HistoryPhotoThumbnail: View {
    let relativePath: String
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if loaded { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .frame(width: 150, height: 110)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: relativePath) {
            defer { loaded = true }
            guard let url = try? PhotoStore().url(for: relativePath) else { return }
            image = UIImage(contentsOfFile: url.path)
        }
    }
}

private struct PhotoHistoryDetailView: View {
    let photo: PhotoRecord
    @State private var image: UIImage?
    @State private var url: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { ContentUnavailableView("Фото недоступно", systemImage: "photo") }
                Text(photo.recognizedText).textSelection(.enabled)
                if let url { ShareLink(item: url) { Label("Отправить оригинал фото", systemImage: "square.and.arrow.up") } }
            }.padding()
        }
        .navigationTitle("Фотография")
        .task(id: photo.relativePath) {
            url = try? PhotoStore().url(for: photo.relativePath)
            if let url { image = UIImage(contentsOfFile: url.path) }
        }
    }
}

private struct AnswerHistoryDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
    @Bindable var answer: AnswerRecord
    @State private var showSaveToBank = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text(answer.question).font(.title2.bold())
                    Spacer()
                    Button { store.toggleFavorite(answer) } label: {
                        Image(systemName: answer.isFavorite ? "star.fill" : "star")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(answer.isFavorite ? Color.yellow : Color.secondary)
                    .accessibilityLabel(answer.isFavorite ? "Убрать из избранного" : "Добавить в избранное")
                }
                if !answer.answer.isEmpty { Text(answer.answer).textSelection(.enabled) }
                if answer.requestKindRaw != AnswerMode.photo.rawValue {
                    Button { showSaveToBank = true } label: {
                        Label("Сохранить вопрос для практики", systemImage: "books.vertical")
                    }
                }
                if answer.statusRaw == AnswerStatus.failed.rawValue || answer.statusRaw == AnswerStatus.cancelled.rawValue {
                    Label(answer.errorMessage ?? "Ответ прерван", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Divider()
                LabeledContent("Провайдер", value: settings.providerTitle(for: ProviderSelection(rawValue: answer.providerRaw)))
                LabeledContent("Модель", value: answer.modelName)
                LabeledContent("Первый фрагмент", value: "\(answer.firstTokenMilliseconds) мс")
                LabeledContent("Полностью", value: "\(answer.totalMilliseconds) мс")
                LabeledContent("Токены", value: "\(answer.inputTokens) → \(answer.outputTokens)")
            }.padding()
        }
        .navigationTitle("Ответ")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSaveToBank) {
            NavigationStack {
                CustomQuestionEditor(
                    prefilledText: answer.question,
                    provenance: .history,
                    sourceLabel: "История QuickCue"
                )
            }
        }
    }
}
