import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct InterviewScheduleView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InterviewEventRecord.scheduledAt) private var events: [InterviewEventRecord]
    @State private var createsEvent = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if futureEvents.isEmpty {
                ContentUnavailableView {
                    Label("Интервью не запланированы", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Добавьте карточку вручную или извлеките данные из приглашения. Доступ к почте не нужен.")
                } actions: {
                    Button("Добавить интервью") { createsEvent = true }
                }
            } else {
                Section("Ближайшие") {
                    ForEach(futureEvents) { event in
                        NavigationLink {
                            InterviewEventDetailView(event: event)
                        } label: {
                            eventRow(event)
                        }
                        .swipeActions {
                            Button("Удалить", role: .destructive) { delete(event) }
                        }
                    }
                }
            }
            if !pastEvents.isEmpty {
                Section("Прошедшие") {
                    ForEach(pastEvents.prefix(20)) { event in
                        NavigationLink { InterviewEventDetailView(event: event) } label: { eventRow(event) }
                    }
                }
            }
        }
        .navigationTitle("Расписание")
        .toolbar {
            Button { createsEvent = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Добавить интервью")
        }
        .sheet(isPresented: $createsEvent) {
            NavigationStack { InterviewEventEditorView(existing: events) }
        }
        .alert("Расписание", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var futureEvents: [InterviewEventRecord] { events.filter { $0.scheduledAt >= .now } }
    private var pastEvents: [InterviewEventRecord] { Array(events.filter { $0.scheduledAt < .now }.reversed()) }

    private func eventRow(_ event: InterviewEventRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text([event.company, event.role].filter { !$0.isEmpty }.joined(separator: " — "))
                .font(.headline)
            Text(InterviewSchedulePolicy.displayDate(event.scheduledAt, timeZoneIdentifier: event.timeZoneIdentifier))
                .foregroundStyle(.secondary)
            Text(TimeZone(identifier: event.timeZoneIdentifier)?.localizedName(for: .standard, locale: .current)
                 ?? event.timeZoneIdentifier)
                .font(.caption)
                .foregroundStyle(.secondary)
            if event.notificationIdentifier != nil {
                Label("Напоминание за 15 минут", systemImage: "bell.fill")
                    .font(.caption)
                    .foregroundStyle(.indigo)
            }
        }
        .padding(.vertical, 3)
    }

    private func delete(_ event: InterviewEventRecord) {
        InterviewSystemScheduleService().removeReminder(identifier: event.notificationIdentifier)
        modelContext.delete(event)
        do { try modelContext.save() }
        catch { errorMessage = "Не удалось удалить карточку. Системное событие календаря не удалялось." }
    }
}

struct InterviewEventDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    let event: InterviewEventRecord
    @State private var editsEvent = false
    @State private var actionInProgress = false
    @State private var message: String?

    var body: some View {
        List {
            Section("Интервью") {
                LabeledContent("Компания", value: event.company.isEmpty ? "Не указана" : event.company)
                LabeledContent("Вакансия", value: event.role.isEmpty ? "Не указана" : event.role)
                LabeledContent("Дата", value: InterviewSchedulePolicy.displayDate(event.scheduledAt, timeZoneIdentifier: event.timeZoneIdentifier))
                LabeledContent("Часовой пояс", value: event.timeZoneIdentifier)
                if !event.notes.isEmpty { Text(event.notes) }
            }
            if let raw = event.meetingURL, let url = InterviewImportParser.validatedMeetingURL(raw) {
                Section {
                    Button { openURL(url) } label: {
                        Label("Открыть ссылку встречи", systemImage: "video.fill")
                    }
                } footer: {
                    Text("Открывается только указанный адрес. QuickCue не добавляет к ссылке API-ключи или данные контекста.")
                }
            }
            Section {
                Button { addCalendar() } label: {
                    Label(calendarButtonTitle, systemImage: "calendar.badge.plus")
                }
                .disabled(actionInProgress || (event.calendarEventIdentifier != nil && !InterviewSchedulePolicy.calendarNeedsUpdate(event)))
                Button { addReminder() } label: {
                    Label(event.notificationIdentifier == nil ? "Напомнить за 15 минут" : "Перенести напоминание на это время", systemImage: "bell.badge")
                }
                .disabled(actionInProgress)
                if event.notificationIdentifier != nil {
                    Button("Удалить напоминание", role: .destructive) { removeReminder() }
                        .disabled(actionInProgress)
                }
            } header: {
                Text("Отдельные действия")
            } footer: {
                Text("Разрешение календаря и разрешение уведомлений запрашиваются отдельно, только после соответствующего нажатия.")
            }
            Section {
                NavigationLink {
                    PreparationHomeView(initialJobID: event.jobID)
                } label: {
                    Label("Открыть подготовку", systemImage: "list.clipboard")
                }
                Text("Открытие карточки или напоминания никогда не включает микрофон автоматически.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Карточка интервью")
        .toolbar { Button("Изменить") { editsEvent = true } }
        .sheet(isPresented: $editsEvent) {
            NavigationStack { InterviewEventEditorView(event: event) }
        }
        .alert("Расписание", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }

    private var calendarButtonTitle: String {
        if event.calendarEventIdentifier == nil { return "Добавить в календарь" }
        if InterviewSchedulePolicy.calendarNeedsUpdate(event) { return "Обновить время в календаре" }
        return "Добавлено в календарь"
    }

    private func addCalendar() {
        actionInProgress = true
        Task { @MainActor in
            defer { actionInProgress = false }
            do {
                event.calendarEventIdentifier = try await InterviewSystemScheduleService().addToCalendar(event)
                event.calendarScheduledAt = event.scheduledAt
                event.updatedAt = .now
                try modelContext.save()
                message = "Событие системного календаря сохранено с текущим временем."
            } catch { message = error.localizedDescription }
        }
    }

    private func addReminder() {
        actionInProgress = true
        Task { @MainActor in
            defer { actionInProgress = false }
            do {
                event.notificationIdentifier = try await InterviewSystemScheduleService().scheduleReminder(for: event)
                event.updatedAt = .now
                try modelContext.save()
                message = "Локальное напоминание установлено."
            } catch { message = error.localizedDescription }
        }
    }

    private func removeReminder() {
        InterviewSystemScheduleService().removeReminder(identifier: event.notificationIdentifier)
        event.notificationIdentifier = nil
        event.updatedAt = .now
        do { try modelContext.save() }
        catch { message = "Напоминание удалено из системы, но метку в карточке сохранить не удалось." }
    }
}

private struct InterviewEventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JobProfile.updatedAt, order: .reverse) private var jobs: [JobProfile]
    @Query(sort: \InterviewEventRecord.scheduledAt) private var allEvents: [InterviewEventRecord]
    let event: InterviewEventRecord?
    let suppliedExisting: [InterviewEventRecord]
    @State private var company = ""
    @State private var role = ""
    @State private var scheduledAt = Date.now.addingTimeInterval(24 * 60 * 60)
    @State private var timeZoneIdentifier = TimeZone.current.identifier
    @State private var meetingURL = ""
    @State private var notes = ""
    @State private var jobID: UUID?
    @State private var importText = ""
    @State private var confirmed = false
    @State private var showFileImporter = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importBusy = false
    @State private var errorMessage: String?

    init(event: InterviewEventRecord? = nil, existing: [InterviewEventRecord] = []) {
        self.event = event
        self.suppliedExisting = existing
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $importText).frame(minHeight: 90)
                Button("Извлечь из текста") { applySuggestion(InterviewImportParser.parse(importText)) }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Распознать скриншот", systemImage: "photo")
                }
                Button { showFileImporter = true } label: {
                    Label("Прочитать PDF или TXT", systemImage: "doc")
                }
                if importBusy { HStack { ProgressView(); Text("Распознаю локально…") } }
            } header: {
                Text("Необязательный импорт")
            } footer: {
                Text("Импорт выполняется локально и лишь заполняет черновик. Перед сохранением вы всё равно подтверждаете дату, часовой пояс и ссылку.")
            }

            Section("Карточка") {
                TextField("Компания", text: $company)
                TextField("Вакансия или роль", text: $role)
                DatePicker("Дата и время", selection: $scheduledAt)
                    .environment(\.timeZone, TimeZone(identifier: timeZoneIdentifier) ?? .current)
                Picker("Часовой пояс", selection: $timeZoneIdentifier) {
                    ForEach(timeZoneChoices, id: \.self) { identifier in
                        Text(identifier).tag(identifier)
                    }
                }
                TextField("Ссылка встречи (необязательно)", text: $meetingURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Заметка", text: $notes, axis: .vertical)
                Picker("Связанная вакансия", selection: $jobID) {
                    Text("Не выбрана").tag(Optional<UUID>.none)
                    ForEach(jobs) { Text($0.title).tag(Optional($0.id)) }
                }
            }
            Section {
                Toggle("Я проверил дату, часовой пояс и ссылку", isOn: $confirmed)
                Button(event == nil ? "Сохранить интервью" : "Сохранить изменения") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!confirmed)
            } footer: {
                Text("Календарь и напоминание подключаются позже отдельными кнопками в сохранённой карточке.")
            }
        }
        .navigationTitle(event == nil ? "Новое интервью" : "Изменить интервью")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        .onAppear(perform: load)
        .onChange(of: selectedPhoto) { _, item in if let item { scan(item) } }
        .onChange(of: scheduledAt) { _, _ in confirmed = false }
        .onChange(of: timeZoneIdentifier) { _, _ in confirmed = false }
        .onChange(of: meetingURL) { _, _ in confirmed = false }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .plainText], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importFile(url)
        }
        .alert("Не удалось сохранить", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var timeZoneChoices: [String] {
        Array(Set([timeZoneIdentifier, TimeZone.current.identifier, "Europe/Moscow", "Asia/Yekaterinburg", "Asia/Novosibirsk", "Asia/Vladivostok", "UTC"]))
            .sorted()
    }

    private func load() {
        guard let event else { return }
        company = event.company
        role = event.role
        scheduledAt = event.scheduledAt
        timeZoneIdentifier = event.timeZoneIdentifier
        meetingURL = event.meetingURL ?? ""
        notes = event.notes
        jobID = event.jobID
        confirmed = false
    }

    private func applySuggestion(_ suggestion: InterviewImportSuggestion) {
        importText = suggestion.sourceText
        if !suggestion.company.isEmpty { company = suggestion.company }
        if !suggestion.role.isEmpty { role = suggestion.role }
        if let date = suggestion.scheduledAt { scheduledAt = date }
        timeZoneIdentifier = suggestion.timeZoneIdentifier
        if let url = suggestion.meetingURL { meetingURL = url }
        confirmed = false
    }

    private func scan(_ item: PhotosPickerItem) {
        importBusy = true
        Task { @MainActor in
            defer { importBusy = false; selectedPhoto = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self), data.count <= 20_000_000 else {
                    throw ProfileDocumentImportError.oversized(maximumMegabytes: 20)
                }
                let text = try await TextRecognizer().recognize(jpeg: data)
                applySuggestion(InterviewImportParser.parse(text))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func importFile(_ url: URL) {
        importBusy = true
        defer { importBusy = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            applySuggestion(InterviewImportParser.parse(try ProfileDocumentImporter.extract(from: url).text))
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        guard let message = InterviewSchedulePolicy.validationMessage(
            scheduledAt: scheduledAt,
            timeZoneIdentifier: timeZoneIdentifier,
            meetingURL: meetingURL
        ) else {
            let source = suppliedExisting.isEmpty ? allEvents : suppliedExisting
            guard !InterviewSchedulePolicy.isDuplicate(
                company: company, role: role, scheduledAt: scheduledAt,
                existing: source, excludingID: event?.id
            ) else {
                errorMessage = "Похожая карточка уже есть на это время. Измените существующую или выберите другое время."
                return
            }
            let record = event ?? InterviewEventRecord(
                company: company, role: role, scheduledAt: scheduledAt,
                timeZoneIdentifier: timeZoneIdentifier
            )
            if let oldNotification = record.notificationIdentifier,
               record.scheduledAt != scheduledAt {
                InterviewSystemScheduleService().removeReminder(identifier: oldNotification)
                record.notificationIdentifier = nil
            }
            record.company = String(company.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            record.role = String(role.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            record.scheduledAt = scheduledAt
            record.timeZoneIdentifier = timeZoneIdentifier
            record.meetingURL = meetingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : meetingURL.trimmingCharacters(in: .whitespacesAndNewlines)
            record.notes = String(notes.prefix(4_000))
            record.jobID = jobID
            record.updatedAt = .now
            if event == nil { modelContext.insert(record) }
            do { try modelContext.save(); dismiss() }
            catch { errorMessage = "Карточка не сохранена. Живая история не изменялась." }
            return
        }
        errorMessage = message
    }
}
