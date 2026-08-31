import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Эфир", systemImage: "waveform") }

            CameraModeView()
                .tabItem { Label("Камера", systemImage: "camera.viewfinder") }

            HistoryView()
                .tabItem { Label("История", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
        }
        .tint(.indigo)
    }
}

