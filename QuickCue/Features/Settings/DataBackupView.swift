import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DataBackupView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
    @State private var export: UserBackupExport?
    @State private var staging: UserBackupStaging?
    @State private var asksExportConfirmation = false
    @State private var asksRestoreConfirmation = false
    @State private var importsFile = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Label("Архив содержит историю, ответы, фото, резюме, вакансии, планы и тренировки.", systemImage: "person.crop.rectangle.stack")
                Label("API-ключи, значения секретных заголовков, аудио и диагностический журнал не входят.", systemImage: "key.slash")
                Text("Сохраните файл в надёжном месте: это незашифрованная личная резервная копия, которую сможет прочитать получивший её человек.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } header: { Text("Что попадёт в файл") }

            Section {
                Button { asksExportConfirmation = true } label: {
                    Label("Создать резервную копию", systemImage: "archivebox")
                }.disabled(busy)
                if let export {
                    ShareLink(item: export.fileURL) {
                        Label("Сохранить или отправить файл", systemImage: "square.and.arrow.up")
                    }
                    Text("Объектов: \(export.preview.newObjectCount) · фото: \(export.preview.photoCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Экспорт") }

            Section {
                Button { importsFile = true } label: {
                    Label("Выбрать копию для проверки", systemImage: "doc.badge.plus")
                }.disabled(busy)
                if let preview = staging?.preview {
                    LabeledContent("Версия источника", value: preview.appVersion)
                    LabeledContent("Создана", value: preview.createdAt.formatted())
                    LabeledContent("Новых объектов", value: "\(preview.newObjectCount)")
                    LabeledContent("Совпадений", value: "\(preview.conflictCount)")
                    LabeledContent("Фото", value: "\(preview.photoCount)")
                    LabeledContent("Планов", value: "\(preview.preparationPlanCount)")
                    LabeledContent("Профилей API без ключей", value: "\(preview.providerProfileCount)")
                    Button("Восстановить новые данные") { asksRestoreConfirmation = true }
                        .buttonStyle(.borderedProminent)
                }
            } header: { Text("Безопасное восстановление") } footer: {
                Text("Сначала архив проверяется без записи в базу. При восстановлении совпадающие ID остаются в живой версии; база не очищается и не заменяется.")
            }

            if busy { HStack { ProgressView(); Text("Проверяю локальные данные…") } }
            NavigationLink {
                RecentlyDeletedView()
            } label: {
                Label("Недавно удалённые", systemImage: "trash.slash")
            }
            NavigationLink {
                SyncReadinessView()
            } label: {
                Label("Синхронизация между устройствами", systemImage: "icloud.slash")
            }
        }
        .navigationTitle("Копия и восстановление")
        .confirmationDialog("Создать личную резервную копию?", isPresented: $asksExportConfirmation, titleVisibility: .visible) {
            Button("Создать локально") { createBackup() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Файл не содержит ключей, но содержит ваши личные тексты и фотографии и не шифруется QuickCue.") }
        .confirmationDialog("Добавить проверенные данные?", isPresented: $asksRestoreConfirmation, titleVisibility: .visible) {
            Button("Восстановить новые объекты") { restore() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Живые совпадающие объекты не перезаписываются. Обратная миграция в старую версию приложения не поддерживается.") }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            stage(url)
        }
        .alert("Резервная копия", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }

    private func createBackup() {
        guard store.currentSession == nil, store.listeningPhase == .idle else {
            message = "Сначала завершите активную сессию и остановите микрофон, чтобы копия была согласованной."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickCueBackups", isDirectory: true)
            export = try UserDataBackupService.export(context: modelContext, settings: settings, directory: directory)
        } catch { message = error.localizedDescription }
    }

    private func stage(_ url: URL) {
        busy = true
        defer { busy = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do { staging = try UserDataBackupService.stage(fileURL: url, context: modelContext) }
        catch { staging = nil; message = error.localizedDescription }
    }

    private func restore() {
        guard let staging else { return }
        guard store.currentSession == nil, store.listeningPhase == .idle else {
            message = "Сначала завершите активную сессию и остановите микрофон. Проверенный архив останется выбранным."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try UserDataBackupService.promote(staging, context: modelContext, settings: settings)
            self.staging = nil
            let planNote = result.failedPlans == 0 ? "" : " Не удалось записать планов: \(result.failedPlans)."
            message = "Восстановлено объектов: \(result.insertedObjects), фото: \(result.restoredPhotos), планов: \(result.restoredPlans). Совпадений пропущено: \(result.skippedConflicts).\(planNote) API-ключи нужно добавить заново."
        } catch { message = error.localizedDescription }
    }
}

private struct RecentlyDeletedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DeletedItemRecord.deletedAt, order: .reverse) private var items: [DeletedItemRecord]
    @State private var itemToPurge: DeletedItemRecord?
    @State private var message: String?

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("Недавно удалённых нет", systemImage: "trash.slash")
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline)
                        Text("Удалено \(item.deletedAt.formatted()) · окончательно после \(item.purgeAfter.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Восстановить") { restore(item) }.buttonStyle(.bordered)
                            Button("Удалить навсегда", role: .destructive) { itemToPurge = item }.buttonStyle(.bordered)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Недавно удалённые")
        .task { try? RecentlyDeletedService.purgeExpired(context: modelContext) }
        .confirmationDialog("Удалить навсегда?", isPresented: Binding(
            get: { itemToPurge != nil }, set: { if !$0 { itemToPurge = nil } }
        ), titleVisibility: .visible) {
            Button("Удалить навсегда", role: .destructive) {
                if let itemToPurge { purge(itemToPurge) }
                itemToPurge = nil
            }
            Button("Отмена", role: .cancel) { itemToPurge = nil }
        } message: { Text("Сессия, её ответы и фотографии будут удалены без возможности восстановления.") }
        .alert("Недавно удалённые", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }

    private func restore(_ item: DeletedItemRecord) {
        do { try RecentlyDeletedService.restore(item, context: modelContext) }
        catch { message = "Не удалось восстановить сессию. Данные не удалены." }
    }

    private func purge(_ item: DeletedItemRecord) {
        do { try RecentlyDeletedService.purge(item, context: modelContext) }
        catch { message = "Не удалось удалить все данные. Повторите после перезапуска." }
    }
}
