import SwiftUI

private enum AppTab: Hashable {
    case live
    case conversation
    case camera
    case history
    case settings
}

struct RootView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .live

    var body: some View {
        TabView(selection: $selectedTab) {
            LiveView()
                .tag(AppTab.live)
                .tabItem { Label("Эфир", systemImage: "waveform") }

            ConversationView()
                .tag(AppTab.conversation)
                .tabItem { Label("Диалог", systemImage: "bubble.left.and.bubble.right") }

            CameraModeView()
                .tag(AppTab.camera)
                .tabItem { Label("Камера", systemImage: "camera.fill") }

            HistoryView()
                .tag(AppTab.history)
                .tabItem { Label("История", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tag(AppTab.settings)
                .tabItem { Label("Настройки", systemImage: "gearshape") }
        }
        .tint(.indigo)
        .preferredColorScheme(settings.appearance == .light ? .light : nil)
        .onChange(of: selectedTab) { _, _ in
            store.stopAllListening()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.handleSceneBecameActive() }
            else { store.handleSceneBecameInactive() }
        }
    }
}
