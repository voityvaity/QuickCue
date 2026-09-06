import SwiftData
import SwiftUI

struct PreparationHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessionStore: SessionStore
    @Query(sort: \JobProfile.updatedAt, order: .reverse) private var jobs: [JobProfile]
    @Query(sort: \ContextProfile.updatedAt, order: .reverse) private var contexts: [ContextProfile]
    @Query private var candidates: [CandidateProfile]
    @Query private var attachments: [AttachmentRecord]
    @StateObject private var plans = PreparationPlanStore()
    @State private var selectedJobID: UUID?
    @State private var selectedReferenceContextID: UUID?
    @State private var activePlan: PreparationPlanDraft?
    @State private var editorText = ""
    @State private var generationTask: Task<Void, Never>?
    @State private var generationID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if jobs.isEmpty {
                ContentUnavailableView {
                    Label("Добавьте вакансию", systemImage: "briefcase")
                } description: {
                    Text("Подготовка работает и без резюме, но ей нужен хотя бы текст или заметки о вакансии.")
                } actions: {
                    NavigationLink("Открыть профили и вакансии") { ContextProfilesView() }
                }
            } else {
                Section {
                    Picker("Вакансия", selection: $selectedJobID) {
                        ForEach(jobs) { job in Text(job.title).tag(Optional(job.id)) }
                    }
                    if let job = selectedJob {
                        if !job.role.isEmpty { LabeledContent("Роль", value: job.role) }
                        if !job.company.isEmpty { LabeledContent("Компания", value: job.company) }
                        if !job.topics.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Ключевые темы").font(.caption).foregroundStyle(.secondary)
                                Text(job.topics)
                            }
                        }
                        Picker("Материалы для плана", selection: $selectedReferenceContextID) {
                            Text("Только вакансия").tag(Optional<UUID>.none)
                            ForEach(contextsForSelectedJob) { profile in
                                Text(profile.title).tag(Optional(profile.id))
                            }
                        }
                    }
                    NavigationLink {
                        ContextProfilesView()
                    } label: {
                        Label("Материалы и профиль", systemImage: "paperclip")
                    }
                } header: {
                    Text("Контекст подготовки")
                } footer: {
                    Text("Выбор вакансии или материалов сам по себе ничего не отправляет. Контекст добавляется в план только после вашего явного выбора и нажатия «Создать».")
                }

                if let job = selectedJob {
                    Section {
                        Label(recipientDisclosure, systemImage: settings.mockMode ? "testtube.2" : "network")
                            .font(.subheadline)
                            .foregroundStyle(settings.mockMode ? .orange : .secondary)
                        Button {
                            generate(for: job)
                        } label: {
                            Label(activePlan == nil ? "Создать план подготовки" : "Создать новый план", systemImage: "sparkles")
                        }
                        .disabled(generationTask != nil)
                        if generationTask != nil {
                            HStack { ProgressView(); Text("AI составляет предполагаемые темы…") }
                            Button("Остановить") { cancelGeneration() }
                                .foregroundStyle(.red)
                        }
                    } header: {
                        Text("Подготовиться")
                    } footer: {
                        Text("Генерация запускается только этой кнопкой, проходит через общую очередь и учитывается как отдельная попытка. Факты о найме компании без источника не обещаются.")
                    }

                    if activePlan != nil {
                        Section {
                            TextEditor(text: $editorText)
                                .frame(minHeight: 320)
                            HStack {
                                Button("Сохранить правки") { saveEditor() }
                                Spacer()
                                Button("Удалить", role: .destructive) { deletePlan() }
                            }
                            if let activePlan {
                                Text("\(statusTitle(activePlan.status)) · версия \(activePlan.promptVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Редактируемый план")
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    PreflightView()
                } label: {
                    Label("Проверить готовность перед интервью", systemImage: "checkmark.circle")
                }
                NavigationLink {
                    NavigationPreviewView()
                } label: {
                    Label("Посмотреть будущую навигацию", systemImage: "rectangle.on.rectangle")
                }
            }
        }
        .navigationTitle("Подготовка")
        .onAppear {
            if selectedJobID == nil { selectedJobID = jobs.first?.id }
            loadLatest()
        }
        .onChange(of: selectedJobID) { _, _ in
            selectedReferenceContextID = nil
            loadLatest()
        }
        .onDisappear { cancelGeneration() }
        .alert("Подготовка", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var selectedJob: JobProfile? {
        guard let selectedJobID else { return nil }
        return jobs.first { $0.id == selectedJobID }
    }

    private var contextsForSelectedJob: [ContextProfile] {
        guard let selectedJobID else { return [] }
        return contexts.filter { $0.jobProfileID == selectedJobID }
    }

    private var recipientDisclosure: String {
        if settings.mockMode { return "Mock: план создастся без сети и расходов." }
        let material = selectedReferenceContextID == nil ? "текст вакансии" : "выбранный снимок контекста"
        return "В \(settings.providerTitle(for: settings.primaryProvider)) отправится \(material). Фото и исходные файлы не отправляются."
    }

    private func loadLatest() {
        guard let selectedJobID, let latest = plans.latest(jobID: selectedJobID) else {
            activePlan = nil
            editorText = ""
            return
        }
        activePlan = latest
        editorText = latest.text
    }

    private func generate(for job: JobProfile) {
        cancelGeneration()
        let snapshot = PreparationJobSnapshot(job: job, referenceContext: makeReferenceContext(for: job))
        var draft = PreparationPlanDraft(
            id: UUID(),
            jobID: job.id,
            jobRevision: job.revision,
            createdAt: .now,
            updatedAt: .now,
            status: .queued,
            text: "",
            jobSnapshot: snapshot,
            promptVersion: "preparation-plan-v1",
            providerRaw: nil,
            modelName: nil,
            safeErrorCategory: nil
        )
        activePlan = draft
        editorText = ""
        guard plans.save(draft) else {
            errorMessage = plans.storageErrorMessage
            activePlan = nil
            return
        }
        let currentGenerationID = draft.id
        generationID = currentGenerationID
        generationTask = Task {
            do {
                let result = try await sessionStore.generatePreparationPlan(
                    snapshot: snapshot,
                    planID: draft.id
                ) { text in
                    guard generationID == currentGenerationID else { return }
                    editorText = text
                    draft.text = text
                    draft.status = .streaming
                    activePlan = draft
                }
                guard generationID == currentGenerationID else { return }
                draft.text = result.text
                draft.status = .completed
                draft.providerRaw = result.provider.rawValue
                draft.modelName = result.modelName
                draft.promptVersion = result.promptVersion
                editorText = result.text
                activePlan = draft
                if !plans.save(draft) { errorMessage = plans.storageErrorMessage }
            } catch is CancellationError {
                guard generationID == currentGenerationID else { return }
                draft.text = editorText
                draft.status = .cancelled
                activePlan = draft
                if !plans.save(draft) { errorMessage = plans.storageErrorMessage }
            } catch {
                guard generationID == currentGenerationID else { return }
                draft.text = editorText
                draft.status = editorText.isEmpty ? .failed : .partial
                draft.safeErrorCategory = ProviderFailure.category(for: error)
                activePlan = draft
                let providerMessage = ProviderFailure.message(for: error)
                errorMessage = plans.save(draft) ? providerMessage : plans.storageErrorMessage
            }
            if generationID == currentGenerationID {
                generationTask = nil
                generationID = nil
            }
        }
    }

    private func makeReferenceContext(for job: JobProfile) -> BuiltContextSnapshot? {
        guard let selectedReferenceContextID,
              let profile = contexts.first(where: {
                  $0.id == selectedReferenceContextID && $0.jobProfileID == job.id
              }) else { return nil }
        let candidate = candidates.first { $0.id == profile.candidateProfileID }
        let selectedAttachmentIDs = Set(ContextSnapshotBuilder.selectedAttachmentIDs(from: profile))
        let selectedAttachments = attachments.filter { selectedAttachmentIDs.contains($0.id) }
        return ContextSnapshotBuilder.build(
            profile: profile,
            candidate: candidate,
            job: job,
            attachments: selectedAttachments
        )
    }

    private func cancelGeneration() {
        guard let id = activePlan?.id else { return }
        if generationID == id, generationTask != nil, var plan = activePlan {
            plan.text = editorText
            plan.status = .cancelled
            if plans.save(plan) { activePlan = plan }
            else { errorMessage = plans.storageErrorMessage }
        }
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        sessionStore.cancelPreparation(id)
    }

    private func saveEditor() {
        guard var plan = activePlan else { return }
        plan.text = editorText
        if plan.status == .failed || plan.status == .cancelled { plan.status = .draft }
        if plans.save(plan) {
            activePlan = plan
        } else {
            errorMessage = plans.storageErrorMessage
            loadLatest()
        }
    }

    private func deletePlan() {
        guard let id = activePlan?.id else { return }
        cancelGeneration()
        guard plans.delete(id) else {
            errorMessage = plans.storageErrorMessage
            return
        }
        activePlan = nil
        editorText = ""
    }

    private func statusTitle(_ status: PreparationPlanStatus) -> String {
        switch status {
        case .draft: "Черновик"
        case .queued: "В очереди"
        case .streaming: "Генерируется"
        case .completed: "Готов"
        case .partial: "Частичный результат"
        case .failed: "Ошибка"
        case .cancelled: "Остановлен"
        }
    }
}
