import Foundation

enum PhotoPayloadKind: String, Equatable, Sendable {
    case none
    case imageAndText
    case recognizedTextOnly
}

struct PhotoTransferDestination: Equatable, Sendable {
    let title: String
    let host: String?
    let payload: PhotoPayloadKind

    var disclosure: String {
        switch payload {
        case .none:
            return "Тестовый режим: фото и текст не отправляются в сеть."
        case .imageAndText:
            return "Изображение и распознанный текст отправятся в \(recipient)."
        case .recognizedTextOnly:
            return "В \(recipient) отправится только распознанный текст; оригинал останется на iPhone."
        }
    }

    private var recipient: String {
        guard let host, !host.isEmpty else { return title }
        return "\(title) · \(host)"
    }
}

enum PhotoTransferPolicy {
    @MainActor
    static func destination(
        for selection: ProviderSelection,
        settings: AppSettings,
        sendsImage: Bool
    ) -> PhotoTransferDestination {
        if settings.mockMode {
            return PhotoTransferDestination(title: "Mock", host: nil, payload: .none)
        }
        let host: String? = if let profile = settings.customProvider(for: selection) {
            URLComponents(string: profile.baseURL)?.host
        } else {
            switch selection.kind {
            case .openAI: "api.openai.com"
            case .deepSeek: "api.deepseek.com"
            case .anthropic: "api.anthropic.com"
            case .xAI: "api.x.ai"
            case .yandexGPT: "ai.api.cloud.yandex.net"
            case .mock, .custom: nil
            }
        }
        return PhotoTransferDestination(
            title: settings.providerTitle(for: selection),
            host: host,
            payload: sendsImage ? .imageAndText : .recognizedTextOnly
        )
    }
}

enum HardwareCapturePhase: Equatable, Sendable {
    case began
    case ended
    case cancelled
}

/// Requires one complete press and consumes its end exactly once.
struct HardwareCaptureGate: Sendable {
    private(set) var hasActivePress = false

    mutating func shouldCapture(_ phase: HardwareCapturePhase) -> Bool {
        switch phase {
        case .began:
            hasActivePress = true
            return false
        case .ended:
            guard hasActivePress else { return false }
            hasActivePress = false
            return true
        case .cancelled:
            hasActivePress = false
            return false
        }
    }
}

struct CaptureTriggerDebouncer: Sendable {
    let minimumInterval: TimeInterval
    private var lastAcceptedAt: Date?

    init(minimumInterval: TimeInterval = 0.35) {
        self.minimumInterval = minimumInterval
    }

    mutating func accept(at date: Date = .now) -> Bool {
        if let lastAcceptedAt, date.timeIntervalSince(lastAcceptedAt) < minimumInterval {
            return false
        }
        lastAcceptedAt = date
        return true
    }
}

enum PhotoInputPolicy {
    static let maximumImportedBytes = 20 * 1_024 * 1_024
}
