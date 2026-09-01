import SwiftData
import SwiftUI

@main
struct QuickCueApp: App {
    private let container: ModelContainer
    @StateObject private var settings: AppSettings
    @StateObject private var sessionStore: SessionStore

    init() {
        let schema = Schema([
            SessionRecord.self,
            TranscriptRecord.self,
            AnswerRecord.self,
            PhotoRecord.self,
            UsageRecord.self,
            ConversationMessageRecord.self,
        ])

        do {
            let container = try ModelContainer(for: schema)
            self.container = container

            let settings = AppSettings()
            _settings = StateObject(wrappedValue: settings)
            _sessionStore = StateObject(
                wrappedValue: SessionStore(
                    modelContext: ModelContext(container),
                    settings: settings
                )
            )
        } catch {
            fatalError("Не удалось открыть локальную базу QuickCue: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(sessionStore)
        }
        .modelContainer(container)
    }
}

