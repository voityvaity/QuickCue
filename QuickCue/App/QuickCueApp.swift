import SwiftData
import SwiftUI

@main
struct QuickCueApp: App {
    @UIApplicationDelegateAdaptor(InterviewNotificationDelegate.self) private var notificationDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var persistence: PersistenceController
    @StateObject private var diagnosticsDelivery: DiagnosticsDeliveryController

    init() {
        let settings = AppSettings()
        let diagnosticsDelivery = DiagnosticsDeliveryController(settings: settings)
        ProviderSetupRecoveryStore().recoverIfNeeded(settings: settings, secretStore: KeychainStore())
        _settings = StateObject(wrappedValue: settings)
        _diagnosticsDelivery = StateObject(wrappedValue: diagnosticsDelivery)
        _persistence = StateObject(wrappedValue: PersistenceController(
            settings: settings,
            onSessionEnded: diagnosticsDelivery.sessionEnded
        ))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = persistence.container, let sessionStore = persistence.sessionStore {
                    RootView()
                        .environmentObject(settings)
                        .environmentObject(sessionStore)
                        .environmentObject(diagnosticsDelivery)
                        .modelContainer(container)
                } else {
                    StorageRecoveryView(retry: persistence.open)
                }
            }
            .preferredColorScheme(settings.appearance == .light ? .light : nil)
        }
    }
}

