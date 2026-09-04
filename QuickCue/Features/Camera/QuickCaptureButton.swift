import SwiftData
import SwiftUI

struct QuickCaptureButton: View {
    enum Presentation {
        case compact
        case conversation
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: SessionStore
    @StateObject private var controller = QuickCaptureController()
    @State private var captureTask: Task<Void, Never>?
    @State private var captureSessionID: UUID?
    @State private var captureOperationID = UUID()
    @State private var isCapturing = false

    let presentation: Presentation
    var includeInConversation = false

    var body: some View {
        Button {
            guard !isCapturing else { return }
            guard let sessionID = store.preparePhotoSession() else { return }
            captureSessionID = sessionID
            let operation = UUID()
            captureOperationID = operation
            isCapturing = true
            captureTask = Task {
                await controller.capture(
                    store: store,
                    modelContext: modelContext,
                    includeInConversation: includeInConversation
                )
                if captureOperationID == operation {
                    isCapturing = false
                    captureTask = nil
                }
            }
        } label: {
            switch presentation {
            case .compact:
                compactLabel
            case .conversation:
                conversationLabel
            }
        }
        .buttonStyle(.plain)
        .disabled(isCapturing || controller.phase.isBusy)
        .sensoryFeedback(.success, trigger: controller.completionCounter)
        .accessibilityLabel("Сфотографировать и сразу отправить")
        .accessibilityValue(controller.phase.title)
        .onDisappear(perform: cancelCapture)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelCapture() }
        }
        .onChange(of: store.currentSession?.id) { _, sessionID in
            if let captureSessionID, captureSessionID != sessionID { cancelCapture() }
        }
        .alert("Быстрая камера", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private func cancelCapture() {
        captureOperationID = UUID()
        captureTask?.cancel()
        captureTask = nil
        captureSessionID = nil
        isCapturing = false
        controller.cancel()
    }

    private var compactLabel: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.1))
                    .frame(width: 72, height: 72)
                if controller.phase.isBusy {
                    ProgressView().tint(.indigo)
                } else {
                    Image(systemName: controller.phase == .finished ? "checkmark" : "camera.fill")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.indigo)
                }
            }
            Text(controller.phase == .idle ? "Фото" : controller.phase.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 105)
        }
    }

    private var conversationLabel: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(width: 68, height: 68)
                if controller.phase.isBusy {
                    ProgressView().tint(.indigo)
                } else {
                    Image(systemName: controller.phase == .finished ? "checkmark" : "camera.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.indigo)
                }
            }
            Text("Фото")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
