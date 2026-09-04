import SwiftUI

/// Mirrors SessionStore's photo route: the primary decides the payload for both attempts.
struct PhotoTransferDisclosure: View {
    @EnvironmentObject private var settings: AppSettings
    var compact = false

    private var detail: String {
        if settings.mockMode { return "Тестовый режим: фото и текст не отправляются в сеть." }
        let primary = settings.primaryProvider
        let fallback = settings.fallbackProvider
        let registry = ProviderRegistry(settings: settings)
        let sendsImage = registry.provider(primary).capabilities.supportsImages
        let main = description(for: primary, sendsImage: sendsImage)
        if fallback == primary { return main }
        if sendsImage, !registry.provider(fallback).capabilities.supportsImages {
            return main + " Резерв \(settings.providerTitle(for: fallback)) для фото отключён: он не принимает изображения."
        }
        return main + " При запуске резерва: " + description(for: fallback, sendsImage: sendsImage)
    }

    var body: some View {
        Label(detail, systemImage: "network.badge.shield.half.filled")
            .font(compact ? .caption2 : .caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(detail)
    }

    private func description(for selection: ProviderSelection, sendsImage: Bool) -> String {
        let provider = ProviderRegistry(settings: settings).provider(selection)
        let title = settings.providerTitle(for: selection)
        if provider.kind == .mock { return "\(title): без сети." }
        return sendsImage
            ? "Изображение и текст отправятся в \(title)."
            : "В \(title) отправится только распознанный текст."
    }
}
