import SwiftData
import SwiftUI

@main
struct QuickCueApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var persistence: PersistenceController

    init() {
        let settings = AppSettings()
        ProviderSetupRecoveryStore().recoverIfNeeded(settings: settings, secretStore: KeychainStore())
        _settings = StateObject(wrappedValue: settings)
        _persistence = StateObject(wrappedValue: PersistenceController(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = persistence.container, let sessionStore = persistence.sessionStore {
                    RootView()
                        .environmentObject(settings)
                        .environmentObject(sessionStore)
                        .modelContainer(container)
                } else {
                    StorageRecoveryView(retry: persistence.open)
                }
            }
            .preferredColorScheme(settings.appearance == .light ? .light : nil)
        }
    }
}

