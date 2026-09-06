import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContextStatusBadge: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
    @Query private var profiles: [ContextProfile]

    private var configuredTitle: String? {
        guard let id = settings.selectedContextProfileID else { return nil }
        return profiles.first(where: { $0.id == id })?.title
    }

    var body: some View {
        NavigationLink {
            ContextProfilesView()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Контекст", systemImage: "person.text.rectangle")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(store.activeContextTitle ?? configuredTitle ?? "Без контекста")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                Text(disclosure)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .background(Color.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var disclosure: String {
        if store.activeContextWasTruncated { return "Снимок усечён и отправляется выбранному AI вместе с вопросом." }
        if store.activeContextTitle != nil { return "Снимок этого контекста отправляется выбранному AI вместе с вопросом." }
        if configuredTitle != nil { return "Будет зафиксирован при начале следующей сессии и передан выбранному AI." }
        return "Резюме и вакансия не обязательны — быстрый старт работает без них."
    }
}

struct ContextProfilesView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
    @Query(sort: \ContextProfile.updatedAt, order: .reverse) private var contexts: [ContextProfile]
    @Query(sort: \CandidateProfile.updatedAt, order: .reverse) private var candidates: [CandidateProfile]
    @Query(sort: \JobProfile.updatedAt, order: .reverse) private var jobs: [JobProfile]
    @Query(sort: \AttachmentRecord.updatedAt, order: .reverse) private var attachments: [AttachmentRecord]
    @State private var showNewCandidate = false
    @State private var showNewJob = false
    @State private var showNewContext = false
    @State private var showNewAttachment = false
    @State private var pendingContextID: UUID?
    @State private var pendingContextChange = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                selectionRow(id: nil, title: "Без контекста", subtitle: "Ничего дополнительного не отправляется")
                ForEach(contexts) { profile in
                    selectionRow(id: profile.id, title: profile.title, subtitle: contextSubtitle(profile))
                }
            } header: {
                Text("Для следующей сессии")
            } footer: {
                Text("Смена контекста завершает текущую сессию только после подтверждения. Прошлые ответы сохраняют свой неизменяемый снимок.")
            }

            Section("Контексты") {
                ForEach(contexts) { profile in
                    NavigationLink {
                        ContextProfileEditor(profile: profile)
                    } label: {
                        Label(profile.title, systemImage: "person.text.rectangle")
                    }
                }
                .onDelete(perform: deleteContexts)
                Button { showNewContext = true } label: {
                    Label("Создать контекст", systemImage: "plus.circle.fill")
                }
            }

            Section("Профили кандидата") {
                ForEach(candidates) { candidate in
                    NavigationLink {
                        CandidateProfileEditor(profile: candidate)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(candidate.title)
                            Text([candidate.level, candidate.skills].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete(perform: deleteCandidates)
                Button { showNewCandidate = true } label: {
                    Label("Добавить кандидата", systemImage: "person.crop.circle.badge.plus")
                }
            }

            Section("Вакансии") {
                ForEach(jobs) { job in
                    NavigationLink {
                        JobProfileEditor(profile: job)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(job.title)
                            Text([job.company, job.role].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete(perform: deleteJobs)
                Button { showNewJob = true } label: {
                    Label("Добавить вакансию", systemImage: "briefcase.badge.plus")
                }
            }

            Section("Материалы") {
                ForEach(attachments) { item in
                    NavigationLink {
                        AttachmentEditor(record: item)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text("\(ProfileAttachmentKind(rawValue: item.kindRaw)?.title ?? "Текст") · \(item.extractedText.count) символов")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteAttachments)
                Button { showNewAttachment = true } label: {
                    Label("Добавить текст, PDF, TXT или фото", systemImage: "paperclip")
                }
            }
        }
        .navigationTitle("Профили и вакансии")
        .sheet(isPresented: $showNewCandidate) { NavigationStack { CandidateProfileEditor(profile: nil) } }
        .sheet(isPresented: $showNewJob) { NavigationStack { JobProfileEditor(profile: nil) } }
        .sheet(isPresented: $showNewContext) { NavigationStack { ContextProfileEditor(profile: nil) } }
        .sheet(isPresented: $showNewAttachment) { AttachmentImportView() }
        .confirmationDialog(
            "Завершить текущую сессию и сменить контекст?",
            isPresented: $pendingContextChange,
            titleVisibility: .visible
        ) {
            Button("Завершить и сменить") {
                store.activateContextProfile(pendingContextID)
                pendingContextID = nil
                pendingContextChange = false
            }
            Button("Отмена", role: .cancel) {
                pendingContextID = nil
                pendingContextChange = false
            }
        } message: {
            Text("Текущая история не изменится. Новый снимок будет создан только для следующей сессии.")
        }
        .alert("Контекст", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func selectionRow(id: UUID?, title: String, subtitle: String) -> some View {
        Button {
            guard settings.selectedContextProfileID != id else { return }
            if store.currentSession != nil {
                pendingContextID = id
                pendingContextChange = true
            } else {
                store.activateContextProfile(id)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settings.selectedContextProfileID == id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo)
                }
            }
        }
    }

    private func contextSubtitle(_ profile: ContextProfile) -> String {
        let candidate = candidates.first { $0.id == profile.candidateProfileID }?.title
        let job = jobs.first { $0.id == profile.jobProfileID }?.title
        let result = [candidate, job].compactMap { $0 }.joined(separator: " · ")
        return result.isEmpty ? "Пустой контекст" : result
    }

    private func deleteContexts(at offsets: IndexSet) {
        for index in offsets {
            let item = contexts[index]
            if settings.selectedContextProfileID == item.id, store.currentSession != nil {
                errorMessage = "Сначала завершите текущую сессию или выберите другой контекст. Старый снимок останется в истории."
                continue
            }
            if settings.selectedContextProfileID == item.id { settings.selectedContextProfileID = nil }
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func deleteCandidates(at offsets: IndexSet) {
        for index in offsets {
            let item = candidates[index]
            guard !contexts.contains(where: { $0.candidateProfileID == item.id }) else {
                errorMessage = "Кандидат используется в контексте. Сначала уберите связь, затем удалите профиль."
                continue
            }
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func deleteJobs(at offsets: IndexSet) {
        for index in offsets {
            let item = jobs[index]
            guard !contexts.contains(where: { $0.jobProfileID == item.id }) else {
                errorMessage = "Вакансия используется в контексте. Сначала уберите связь, затем удалите вакансию."
                continue
            }
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func deleteAttachments(at offsets: IndexSet) {
        for index in offsets {
            let item = attachments[index]
            let isSelected = contexts.contains { ContextSnapshotBuilder.selectedAttachmentIDs(from: $0).contains(item.id) }
            guard !isSelected else {
                errorMessage = "Материал выбран в контексте. Сначала снимите выбор, затем удалите материал."
                continue
            }
            modelContext.delete(item)
        }
        try? modelContext.save()
    }
}

private struct CandidateProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allCandidates: [CandidateProfile]
    let profile: CandidateProfile?
    @State private var title: String
    @State private var level: String
    @State private var language: String
    @State private var skills: String
    @State private var experience: String
    @State private var projects: String
    @State private var education: String
    @State private var achievements: String
    @State private var isDefault: Bool

    init(profile: CandidateProfile?) {
        self.profile = profile
        _title = State(initialValue: profile?.title ?? "")
        _level = State(initialValue: profile?.level ?? "")
        _language = State(initialValue: profile?.language ?? "")
        _skills = State(initialValue: profile?.skills ?? "")
        _experience = State(initialValue: profile?.experience ?? "")
        _projects = State(initialValue: profile?.projects ?? "")
        _education = State(initialValue: profile?.education ?? "")
        _achievements = State(initialValue: profile?.achievements ?? "")
        _isDefault = State(initialValue: profile?.isDefault ?? false)
    }

    var body: some View {
        Form {
            Section("Основное") {
                TextField("Название, например «Python junior»", text: $title)
                TextField("Уровень", text: $level)
                TextField("Язык интервью", text: $language)
                Toggle("Использовать по умолчанию", isOn: $isDefault)
            }
            longField("Навыки", text: $skills)
            longField("Опыт", text: $experience)
            longField("Проекты", text: $projects)
            longField("Образование", text: $education)
            longField("Достижения", text: $achievements)
        }
        .navigationTitle(profile == nil ? "Новый кандидат" : "Кандидат")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить", action: save)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func longField(_ title: String, text: Binding<String>) -> some View {
        Section(title) { TextEditor(text: text).frame(minHeight: 90) }
    }

    private func save() {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let item = profile ?? CandidateProfile(title: cleaned)
        if profile == nil { modelContext.insert(item) } else { item.revision += 1 }
        item.title = cleaned
        item.level = level
        item.language = language
        item.skills = skills
        item.experience = experience
        item.projects = projects
        item.education = education
        item.achievements = achievements
        item.isDefault = isDefault
        item.updatedAt = .now
        if isDefault { allCandidates.filter { $0.id != item.id }.forEach { $0.isDefault = false } }
        try? modelContext.save()
        dismiss()
    }

}

private struct JobProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let profile: JobProfile?
    @State private var title: String
    @State private var company: String
    @State private var role: String
    @State private var topics: String
    @State private var vacancyText: String
    @State private var notes: String

    init(profile: JobProfile?) {
        self.profile = profile
        _title = State(initialValue: profile?.title ?? "")
        _company = State(initialValue: profile?.company ?? "")
        _role = State(initialValue: profile?.role ?? "")
        _topics = State(initialValue: profile?.topics ?? "")
        _vacancyText = State(initialValue: profile?.vacancyText ?? "")
        _notes = State(initialValue: profile?.notes ?? "")
    }

    var body: some View {
        Form {
            Section("Основное") {
                TextField("Название вакансии", text: $title)
                TextField("Компания", text: $company)
                TextField("Роль", text: $role)
                TextField("Темы и стек", text: $topics, axis: .vertical)
            }
            Section("Текст вакансии") { TextEditor(text: $vacancyText).frame(minHeight: 160) }
            Section("Мои заметки") { TextEditor(text: $notes).frame(minHeight: 100) }
            Section { Text("Название компании используется только как часть контекста интервью и не меняет выбранного AI-провайдера.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(profile == nil ? "Новая вакансия" : "Вакансия")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
    }

    private func save() {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let item = profile ?? JobProfile(title: cleaned)
        if profile == nil { modelContext.insert(item) } else { item.revision += 1 }
        item.title = cleaned
        item.company = company
        item.role = role
        item.topics = topics
        item.vacancyText = vacancyText
        item.notes = notes
        item.updatedAt = .now
        try? modelContext.save()
        dismiss()
    }
}

private struct ContextProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CandidateProfile.title) private var candidates: [CandidateProfile]
    @Query(sort: \JobProfile.title) private var jobs: [JobProfile]
    @Query(sort: \AttachmentRecord.title) private var attachments: [AttachmentRecord]
    let profile: ContextProfile?
    @State private var title: String
    @State private var scenario: String
    @State private var candidateID: UUID?
    @State private var jobID: UUID?
    @State private var attachmentIDs: Set<UUID>

    init(profile: ContextProfile?) {
        self.profile = profile
        _title = State(initialValue: profile?.title ?? "")
        _scenario = State(initialValue: profile?.scenario ?? "")
        _candidateID = State(initialValue: profile?.candidateProfileID)
        _jobID = State(initialValue: profile?.jobProfileID)
        let ids = profile.map { ContextSnapshotBuilder.selectedAttachmentIDs(from: $0) } ?? []
        _attachmentIDs = State(initialValue: Set(ids))
    }

    var body: some View {
        Form {
            Section("Контекст") {
                TextField("Название, например «Яндекс · Python»", text: $title)
                TextField("Сценарий или цель", text: $scenario, axis: .vertical)
            }
            Section {
                Picker("Кандидат", selection: $candidateID) {
                        Text("Не выбран").tag(Optional<UUID>.none)
                    ForEach(candidates) { Text($0.title).tag(Optional($0.id)) }
                }
                Picker("Вакансия", selection: $jobID) {
                        Text("Не выбрана").tag(Optional<UUID>.none)
                    ForEach(jobs) { Text($0.title).tag(Optional($0.id)) }
                }
            } footer: {
                Text("Все поля необязательны. Один профиль кандидата можно связать с несколькими вакансиями через разные контексты.")
            }
            Section("Выбранные материалы · до \(ContextSnapshotBuilder.maximumAttachments)") {
                if attachments.isEmpty {
                    Text("Материалов пока нет").foregroundStyle(.secondary)
                }
                ForEach(attachments) { item in
                    Button {
                        if attachmentIDs.contains(item.id) { attachmentIDs.remove(item.id) }
                        else if attachmentIDs.count < ContextSnapshotBuilder.maximumAttachments { attachmentIDs.insert(item.id) }
                    } label: {
                        HStack {
                            Text(item.title).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: attachmentIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            Section {
                Text("При начале сессии QuickCue создаёт локальный снимок до 12 000 символов. Документы считаются данными, а не командами. Снимок передаётся выбранному AI с вопросом.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(profile == nil ? "Новый контекст" : "Контекст")
        .task {
            if profile == nil, candidateID == nil {
                candidateID = candidates.first(where: { $0.isDefault })?.id
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
    }

    private func save() {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let item = profile ?? ContextProfile(title: cleaned)
        if profile == nil { modelContext.insert(item) } else { item.revision += 1 }
        item.title = cleaned
        item.scenario = scenario
        item.candidateProfileID = candidateID
        item.jobProfileID = jobID
        item.selectedAttachmentIDsData = ContextSnapshotBuilder.encodeAttachmentIDs(Array(attachmentIDs).sorted { $0.uuidString < $1.uuidString })
        item.updatedAt = .now
        try? modelContext.save()
        dismiss()
    }
}

private struct AttachmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let record: AttachmentRecord
    @State private var title: String
    @State private var text: String

    init(record: AttachmentRecord) {
        self.record = record
        _title = State(initialValue: record.title)
        _text = State(initialValue: record.extractedText)
    }

    var body: some View {
        Form {
            TextField("Название", text: $title)
            Section("Что удалось извлечь") { TextEditor(text: $text).frame(minHeight: 300) }
            Section { Text("Редактирование создаёт новую ревизию материала. Снимки прошлых сессий не меняются.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Материал")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") {
                    record.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    record.extractedText = String(ContextSnapshotBuilder.normalize(text).prefix(ProfileDocumentImporter.maximumExtractedCharacters))
                    record.revision += 1
                    record.updatedAt = .now
                    try? modelContext.save()
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct AttachmentImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var title = ""
    @State private var extractedText = ""
    @State private var kind: ProfileAttachmentKind = .text
    @State private var filename: String?
    @State private var byteCount = 0
    @State private var wasTruncated = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showFileImporter = true } label: { Label("Выбрать PDF или TXT", systemImage: "doc") }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Выбрать фото для OCR", systemImage: "photo")
                    }
                    Button {
                        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                            errorMessage = "Камера недоступна. Выберите фото или вставьте текст."
                            return
                        }
                        showCamera = true
                    } label: { Label("Сфотографировать документ", systemImage: "camera") }
                    if isProcessing { HStack { ProgressView(); Text("Извлекаю локально…") } }
                } header: {
                    Text("Источник")
                } footer: {
                    Text("Файл и фото не отправляются AI при импорте. QuickCue сохраняет только извлечённый текст; исходник остаётся в Files/Фото. DOCX нужно сохранить как PDF/TXT. Ссылки автоматически не открываются: вставьте доступный вам текст ниже, не включая личные параметры URL.")
                }
                Section("Предварительный просмотр") {
                    TextField("Название материала", text: $title)
                    TextEditor(text: $extractedText).frame(minHeight: 260)
                    Text("\(kind.title) · \(extractedText.count)/\(ProfileDocumentImporter.maximumExtractedCharacters) символов")
                        .font(.caption).foregroundStyle(.secondary)
                    if wasTruncated {
                        Label("Текст был усечён до лимита. Проверьте, что важная часть осталась.", systemImage: "scissors")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section {
                    Text("Проверьте и исправьте извлечённое до сохранения. Команды внутри документа не меняют настройки приложения и передаются модели только как справочные данные выбранного контекста.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Новый материал")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save).disabled(!canSave) }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                handleFile(result)
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await recognize(item) }
            }
            .onChange(of: extractedText) { _, value in
                if value.count > ProfileDocumentImporter.maximumExtractedCharacters {
                    wasTruncated = true
                    extractedText = String(value.prefix(ProfileDocumentImporter.maximumExtractedCharacters))
                }
            }
            .sheet(isPresented: $showCamera) {
                ContextCameraPicker { data in
                    showCamera = false
                    Task { await recognize(data) }
                } onCancel: { showCamera = false }
                    .ignoresSafeArea()
            }
            .alert("Материал", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isProcessing
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { throw ProfileDocumentImportError.emptyDocument }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let imported = try ProfileDocumentImporter.extract(from: url)
            kind = imported.kind
            filename = imported.filename
            byteCount = imported.byteCount
            wasTruncated = imported.wasTruncated
            title = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
            extractedText = imported.text
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recognize(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ProfileDocumentImportError.emptyDocument }
            await recognize(data)
        } catch { errorMessage = error.localizedDescription }
    }

    private func recognize(_ data: Data) async {
        guard data.count <= 10 * 1_024 * 1_024 else {
            errorMessage = "Фото больше 10 МБ. Выберите уменьшенную копию."
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        do {
            let text = try await TextRecognizer().recognize(jpeg: data)
            let normalized = ContextSnapshotBuilder.normalize(text)
            guard !normalized.isEmpty else { throw ProfileDocumentImportError.emptyDocument }
            kind = .photoOCR
            byteCount = data.count
            filename = nil
            if title.isEmpty { title = "Текст с фото" }
            extractedText = String(normalized.prefix(ProfileDocumentImporter.maximumExtractedCharacters))
            wasTruncated = normalized.count > extractedText.count
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        let record = AttachmentRecord(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            kindRaw: kind.rawValue,
            extractedText: ContextSnapshotBuilder.normalize(extractedText),
            sourceFilename: filename,
            sourceByteCount: byteCount,
            importWasTruncated: wasTruncated
        )
        modelContext.insert(record)
        try? modelContext.save()
        dismiss()
    }
}

private struct ContextCameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ContextCameraPicker
        init(parent: ContextCameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) else {
                parent.onCancel()
                return
            }
            parent.onCapture(data)
        }
    }
}
