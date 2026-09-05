import SwiftData
import SwiftUI

@MainActor
final class PersistenceController: ObservableObject {
    @Published private(set) var container: ModelContainer?
    @Published private(set) var sessionStore: SessionStore?
    @Published private(set) var failedToOpen = false
    private let settings: AppSettings
    private let configuration: ModelConfiguration?

    init(settings: AppSettings, configuration: ModelConfiguration? = nil) {
        self.settings = settings
        self.configuration = configuration
        open()
    }

    /// Uses SwiftData's original default store location. Never deletes, replaces or moves user data.
    func open() {
        guard container == nil else { return }
        do {
            let container = try Self.makeContainer(configuration: configuration)
            // Share SwiftUI's main context so history deletion and in-flight
            // publication guards observe the same model instances immediately.
            let context = container.mainContext
            try Self.reconcileInterruptedWork(in: context)
            self.sessionStore = SessionStore(modelContext: context, settings: settings)
            self.container = container
            self.failedToOpen = false
        } catch {
            self.failedToOpen = true
            LatencyLogger().failed(provider: .mock, error: error)
        }
    }

    static func makeContainer(configuration: ModelConfiguration? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: QuickCueSchemaV3.self)
        if let configuration {
            return try ModelContainer(for: schema, migrationPlan: QuickCueMigrationPlan.self, configurations: [configuration])
        }
        return try ModelContainer(for: schema, migrationPlan: QuickCueMigrationPlan.self)
    }

    static func reconcileInterruptedWork(in context: ModelContext) throws {
        let pending = Set(["queued", "thinking", "streaming"])
        for answer in try context.fetch(FetchDescriptor<AnswerRecord>()) where pending.contains(answer.statusRaw) {
            answer.statusRaw = "cancelled"
            answer.errorMessage = "Запрос прерван при закрытии приложения. Можно повторить его вручную."
        }
        for message in try context.fetch(FetchDescriptor<ConversationMessageRecord>()) where pending.contains(message.statusRaw) {
            message.statusRaw = "cancelled"
        }
        // An unclosed session belongs to the previous process; never resume its network work automatically.
        for session in try context.fetch(FetchDescriptor<SessionRecord>()) where session.endedAt == nil {
            session.endedAt = .now
        }
        try context.save()
    }
}

struct StorageRecoveryView: View {
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("История пока недоступна", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("QuickCue не смог открыть локальную базу. История и фотографии не удалены. Не переустанавливайте приложение: это может удалить данные. Попробуйте открыть базу ещё раз или сохраните резервную копию iPhone перед обращением за помощью.")
        } actions: {
            Button("Повторить открытие", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .tint(.indigo)
    }
}
