import SwiftUI

struct QuickCaptureButton: View {
    enum Presentation {
        case compact
        case conversation
    }

    @State private var showsCaptureFlow = false

    let presentation: Presentation
    var includeInConversation = false

    var body: some View {
        Button {
            showsCaptureFlow = true
        } label: {
            switch presentation {
            case .compact:
                compactLabel
            case .conversation:
                conversationLabel
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Открыть камеру и сфотографировать задачу")
        .accessibilityHint("После снимка QuickCue покажет фото, распознанный текст и получателя перед отправкой")
        .fullScreenCover(isPresented: $showsCaptureFlow) {
            CameraModeView(
                autoCaptureOnReady: true,
                includeInConversation: includeInConversation,
                showsDismissButton: true
            )
        }
    }

    private var compactLabel: some View {
        VStack(spacing: 5) {
            Circle()
                .fill(Color.indigo.opacity(0.1))
                .frame(width: 76, height: 76)
                .overlay {
                    Image(systemName: "camera.fill")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.indigo)
                }
            Text("Фото")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var conversationLabel: some View {
        VStack(spacing: 7) {
            Circle()
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "camera.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.indigo)
                }
            Text("Фото")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
