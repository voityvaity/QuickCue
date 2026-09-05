import SwiftUI

/// Mirrors SessionStore's photo route: the primary decides the payload for both attempts.
struct PhotoTransferDisclosure: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
    var compact = false

    private var detail: String {
        let primary = settings.primaryProvider
        let fallback = settings.fallbackProvider
        let registry = ProviderRegistry(settings: settings)
        let sendsImage = registry.provider(primary).capabilities.supportsImages
        let main = PhotoTransferPolicy.destination(
            for: primary,
            settings: settings,
            sendsImage: sendsImage
        ).disclosure
        let retained = store.retainedPhotoCount > 0
            ? " Повторное использование включено для одного фото; отключить его можно рядом с кнопкой камеры."
            : ""
        if settings.mockMode || fallback == primary { return main + retained }
        if sendsImage, !registry.provider(fallback).capabilities.supportsImages {
            return main + " Резерв \(settings.providerTitle(for: fallback)) для фото отключён: он не принимает изображения." + retained
        }
        let fallbackDetail = PhotoTransferPolicy.destination(
            for: fallback,
            settings: settings,
            sendsImage: sendsImage
        ).disclosure
        return main + " При запуске резерва: " + fallbackDetail + retained
    }

    var body: some View {
        Label(detail, systemImage: "network.badge.shield.half.filled")
            .font(compact ? .caption2 : .caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(detail)
    }
}

struct RetainedPhotoBadge: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        if store.retainedPhotoCount > 0 {
            HStack(spacing: 8) {
                Label("Фото используется дальше · 1", systemImage: "photo.badge.checkmark")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Отключить") { store.clearRetainedPhoto() }
                    .font(.caption.weight(.semibold))
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
        }
    }
}
