import AVFoundation
import Foundation
import Speech

enum PreflightLevel: String, Equatable, Sendable {
    case ready
    case attention
    case blocked
    case informational
}

struct PreflightCheck: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let level: PreflightLevel
}

struct PreflightInput: Equatable, Sendable {
    enum Permission: Equatable, Sendable { case granted, denied, undetermined }
    let microphone: Permission
    let speech: Permission
    let camera: Permission
    let providerState: ProviderConnectionState
    let providerCheckedAt: Date?
    let usesMock: Bool
    let hasContext: Bool
    let speechModeTitle: String
    let providerTitle: String
}

enum PreflightEvaluator {
    static let verificationFreshness: TimeInterval = 24 * 60 * 60

    static func evaluate(_ input: PreflightInput, now: Date = .now) -> [PreflightCheck] {
        [
            permissionCheck(id: "microphone", title: "Микрофон", permission: input.microphone),
            permissionCheck(id: "speech", title: "Распознавание речи", permission: input.speech),
            providerCheck(input, now: now),
            PreflightCheck(
                id: "speech-mode",
                title: "Режим речи",
                detail: input.speechModeTitle,
                level: .informational
            ),
            PreflightCheck(
                id: "context",
                title: "Контекст",
                detail: input.hasContext ? "Выбран для новой сессии" : "Без профиля — быстрый старт доступен",
                level: input.hasContext ? .ready : .informational
            ),
            permissionCheck(id: "camera", title: "Камера (необязательно)", permission: input.camera),
        ]
    }

    @MainActor
    static func current(settings: AppSettings, now: Date = .now) -> [PreflightCheck] {
        let microphone: PreflightInput.Permission = switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
        let speech: PreflightInput.Permission = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .undetermined
        @unknown default: .undetermined
        }
        let camera: PreflightInput.Permission = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .undetermined
        @unknown default: .undetermined
        }
        let report = settings.connectionReport(for: settings.primaryProvider)
        return evaluate(.init(
            microphone: microphone,
            speech: speech,
            camera: camera,
            providerState: report.state,
            providerCheckedAt: report.checkedAt,
            usesMock: settings.mockMode,
            hasContext: settings.selectedContextProfileID != nil,
            speechModeTitle: "\(settings.answerTriggerPolicy.title) · \(settings.speakerAttributionMode.title)",
            providerTitle: settings.providerTitle(for: settings.primaryProvider)
        ), now: now)
    }

    private static func permissionCheck(
        id: String, title: String, permission: PreflightInput.Permission
    ) -> PreflightCheck {
        switch permission {
        case .granted: .init(id: id, title: title, detail: "Разрешено", level: .ready)
        case .denied: .init(id: id, title: title, detail: "Запрещено в настройках iPhone", level: .blocked)
        case .undetermined: .init(id: id, title: title, detail: "Будет запрошено при использовании", level: .attention)
        }
    }

    private static func providerCheck(_ input: PreflightInput, now: Date) -> PreflightCheck {
        if input.usesMock {
            return .init(id: "provider", title: "AI", detail: "Mock · без сети и расходов", level: .ready)
        }
        switch input.providerState {
        case .verified:
            guard let checkedAt = input.providerCheckedAt,
                  now.timeIntervalSince(checkedAt) <= verificationFreshness else {
                return .init(
                    id: "provider", title: "AI",
                    detail: "\(input.providerTitle) · проверка старше 24 часов",
                    level: .attention
                )
            }
            return .init(id: "provider", title: "AI", detail: "\(input.providerTitle) · проверен", level: .ready)
        case .unconfigured:
            return .init(id: "provider", title: "AI", detail: "Не настроен", level: .blocked)
        case .unverified:
            return .init(id: "provider", title: "AI", detail: "Сохранён, но не проверен", level: .attention)
        case .failed:
            return .init(id: "provider", title: "AI", detail: "Последняя проверка завершилась ошибкой", level: .blocked)
        }
    }
}
