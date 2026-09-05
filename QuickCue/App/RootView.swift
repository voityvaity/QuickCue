import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = TabNavigationCoordinator()

    var body: some View {
        TabView(selection: Binding(
            get: { navigation.selectedTab },
            set: { requestTab($0) }
        )) {
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.listeningPhase != .idle {
                ListeningStatusBanner()
            }
        }
        .confirmationDialog(
            "Микрофон работает",
            isPresented: Binding(
                get: { navigation.pendingTab != nil },
                set: { if !$0 { navigation.cancelPending() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Продолжать в фоне вкладок") { resolvePending(continueListening: true) }
            Button("Остановить и перейти", role: .destructive) { resolvePending(continueListening: false) }
            Button("Всегда продолжать") {
                settings.listeningNavigationPolicy = .continueWhileActive
                resolvePending(continueListening: true)
            }
            Button("Всегда останавливать", role: .destructive) {
                settings.listeningNavigationPolicy = .stopOnTabChange
                resolvePending(continueListening: false)
            }
            Button("Отмена", role: .cancel) { navigation.cancelPending() }
        } message: {
            Text("Перейти в «\(navigation.pendingTab?.title ?? "другую вкладку")» и продолжить распознавание или остановить микрофон?")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.handleSceneBecameActive() }
            else { store.handleSceneBecameInactive() }
        }
        .onChange(of: settings.listeningNavigationPolicy) { _, policy in
            if policy == .stopOnTabChange, store.listeningPhase != .idle,
               navigation.selectedTab != .live {
                store.stopAllListening()
            }
        }
    }

    private func requestTab(_ target: AppTab) {
        let result = navigation.request(
            target,
            whileListening: store.listeningPhase != .idle,
            policy: settings.listeningNavigationPolicy
        )
        if case .switched(_, shouldStop: true) = result {
            store.stopAllListening()
        }
    }

    private func resolvePending(continueListening: Bool) {
        let result = navigation.resolvePending(continueListening: continueListening)
        if case .switched(_, shouldStop: true) = result {
            store.stopAllListening()
        }
    }
}

private struct ListeningStatusBanner: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.listeningPhase == .listening ? "waveform" : "mic.fill")
                .foregroundStyle(.indigo)
            Text(store.listeningStatusTitle)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Стоп", role: .destructive) { store.stopAllListening() }
                .font(.subheadline.weight(.bold))
                .frame(minWidth: 58, minHeight: 44)
        }
        .padding(.horizontal, 14)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
