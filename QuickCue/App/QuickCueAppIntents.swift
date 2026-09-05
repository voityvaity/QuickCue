import AppIntents
import Foundation

enum QuickCueNavigationRequestStore {
    static let cameraRequestNotification = Notification.Name("QuickCueCameraNavigationRequested")
    private static let cameraRequestKey = "navigation.pendingCameraRequest"

    @MainActor
    static func requestCamera(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(true, forKey: cameraRequestKey)
        notificationCenter.post(name: cameraRequestNotification, object: nil)
    }

    @MainActor
    static func consumeCameraRequest(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: cameraRequestKey) else { return false }
        defaults.removeObject(forKey: cameraRequestKey)
        return true
    }
}

struct OpenQuickCueCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Открыть камеру QuickCue"
    static var description = IntentDescription("Открывает экран камеры. Съёмка и отправка выполняются только после действий пользователя.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickCueNavigationRequestStore.requestCamera()
        return .result()
    }
}

struct QuickCueAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenQuickCueCameraIntent(),
            phrases: ["Открыть камеру в \(.applicationName)"],
            shortTitle: "Камера QuickCue",
            systemImageName: "camera.fill"
        )
    }
}
