import AVKit
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct CameraModeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var camera = CameraService()
    @StateObject private var remote = BLERemoteCaptureController()
    @State private var isProcessing = false
    @State private var isSending = false
    @State private var recognizedText = ""
    @State private var errorMessage: String?
    @State private var previewData: Data?
    @State private var photoSessionID: UUID?
    @State private var savedPhoto: PhotoRecord?
    @State private var resultAnswer: AnswerRecord?
    @State private var operationTask: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var isVisible = false
    @State private var showFullAnswer = false
    @State private var completionCounter = 0
    @State private var captureAcceptedCounter = 0
    @State private var previewRestartID = UUID()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var didAutoCapture = false
    @State private var hardwareCaptureGate = HardwareCaptureGate()
    @State private var retainForSession = false

    let autoCaptureOnReady: Bool
    let includeInConversation: Bool
    let showsDismissButton: Bool

    private let photoStore = PhotoStore()
    private let textRecognizer = TextRecognizer()

    init(
        autoCaptureOnReady: Bool = false,
        includeInConversation: Bool = false,
        showsDismissButton: Bool = false
    ) {
        self.autoCaptureOnReady = autoCaptureOnReady
        self.includeInConversation = includeInConversation
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        NavigationStack {
            Group {
                if previewData != nil { reviewScreen }
                else { viewfinder }
            }
            .navigationTitle(previewData == nil ? "Фото-задача" : "Проверка снимка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                if previewData != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("К камере") { resetPhoto() }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if previewData == nil, camera.isFlashAvailable {
                        Menu {
                            Button("Вспышка выключена") { camera.flashMode = .off }
                            Button("Вспышка автоматически") { camera.flashMode = .auto }
                            Button("Вспышка включена") { camera.flashMode = .on }
                        } label: {
                            Image(systemName: flashSystemImage)
                        }
                        .accessibilityLabel("Режим вспышки")
                    }
                    if showsDismissButton {
                        Button("Закрыть", systemImage: "xmark") { dismiss() }
                    }
                }
            }
            .onAppear { isVisible = true }
            .onDisappear {
                isVisible = false
                cancelOperation()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cancelOperation() }
            }
            .onChange(of: store.currentSession?.id) { _, sessionID in
                if let photoSessionID, photoSessionID != sessionID { resetPhoto() }
            }
            .sensoryFeedback(.success, trigger: completionCounter)
            .sensoryFeedback(.impact(weight: .medium), trigger: captureAcceptedCounter)
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                importPhoto(item)
            }
            .navigationDestination(isPresented: $showFullAnswer) {
                if let resultAnswer {
                    ScrollView { AnswerCardView(answer: resultAnswer).padding() }
                        .background(Color(uiColor: .systemGroupedBackground))
                        .navigationTitle("Ответ по фото")
                }
            }
            .alert("Камера", isPresented: Binding(
                get: { errorMessage != nil || camera.lastError != nil },
                set: { if !$0 { errorMessage = nil; camera.lastError = nil } }
            )) {
                Button("OK") { errorMessage = nil; camera.lastError = nil }
            } message: {
                Text(errorMessage ?? camera.lastError ?? "")
            }
        }
    }

    private var viewfinder: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: camera.session) { point in
                camera.focus(at: point)
            }
                .ignoresSafeArea(edges: .top)
            if camera.authorizationDenied {
                ContentUnavailableView(
                    "Нужен доступ к камере", systemImage: "camera",
                    description: Text("Разрешите доступ в Настройках iPhone → QuickCue → Камера.")
                )
                .background(.regularMaterial)
            }
            VStack(spacing: 14) {
                if isProcessing {
                    HStack { ProgressView(); Text("Фотографирую и распознаю текст…") }
                        .padding(12)
                        .background(.ultraThinMaterial, in: Capsule())
                    Button("Отменить") {
                        cancelOperation()
                        previewRestartID = UUID()
                    }
                        .buttonStyle(.bordered)
                } else {
                    Text(camera.isConfigured
                         ? "Коснитесь экрана для фокуса. После снимка можно проверить текст."
                         : "Подготовка камеры…")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                HStack(spacing: 28) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .disabled(isProcessing)
                    .accessibilityLabel("Импортировать фотографию")

                    Button { takePhoto(source: .screenButton) } label: {
                        ZStack {
                            Circle().fill(.white).frame(width: 82, height: 82)
                            Circle().stroke(.black.opacity(0.25), lineWidth: 3).frame(width: 70, height: 70)
                            if isProcessing { ProgressView().tint(.black) }
                            else { Image(systemName: "camera.fill").font(.title).foregroundStyle(.black) }
                        }
                    }
                    .disabled(isProcessing || !camera.isConfigured || camera.authorizationDenied)
                    .accessibilityLabel("Сфотографировать задачу")

                    Image(systemName: camera.focusPoint == nil ? "viewfinder" : "viewfinder.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 58, height: 58)
                }
            }
            .padding()
        }
        .task(id: "\(scenePhase)-\(previewRestartID)") {
            guard scenePhase == .active else { return }
            await camera.configure()
            guard !Task.isCancelled, scenePhase == .active else { return }
            remote.onCapture = { source in takePhoto(source: source) }
            if settings.bleRemoteEnabled {
                remote.configure(
                    serviceUUID: settings.bleRemoteServiceUUID,
                    triggerCharacteristicUUID: settings.bleRemoteCharacteristicUUID
                )
                remote.start()
            }
            if autoCaptureOnReady, !didAutoCapture {
                didAutoCapture = true
                takePhoto(source: .screenButton)
            }
        }
        .onDisappear { camera.stop(); remote.stop() }
        .onCameraCaptureEvent(
            isEnabled: camera.isConfigured && !isProcessing && previewData == nil,
            action: handleCameraCaptureEvent
        )
    }

    private var reviewScreen: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let resultAnswer { resultCard(resultAnswer) }

                if let previewData, let image = UIImage(data: previewData) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(recognizedText.isEmpty ? "Текст не найден — можно ввести вручную" : "Проверьте распознанный текст",
                          systemImage: "text.viewfinder")
                        .font(.headline)
                    TextEditor(text: $recognizedText)
                        .frame(minHeight: 150)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .disabled(isSending)
                    Text("Исправьте текст, если камера распознала код или условие неточно.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                PhotoTransferDisclosure()

                Toggle("Использовать это фото в следующих вопросах сессии", isOn: $retainForSession)
                    .disabled(resultAnswer != nil || isSending || !selectedProviderSupportsImages)
                if !selectedProviderSupportsImages {
                    Text("Выбранная модель получает только OCR-текст, поэтому повторная отправка изображения недоступна.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if retainForSession {
                    Text("Фото будет повторно отправляться только выбранному сейчас AI до конца сессии или пока вы не отключите его.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if isSending {
                    HStack { ProgressView(); Text("Готовлю ответ по снимку…") }
                    Button("Остановить запрос") { cancelOperation() }
                        .buttonStyle(.bordered)
                } else {
                    HStack(spacing: 12) {
                        Button("Переснять") { resetPhoto() }
                            .buttonStyle(.bordered)
                        Button {
                            let operation = UUID()
                            operationID = operation
                            operationTask = Task { await sendReviewedPhoto(operation: operation) }
                        } label: {
                            Label(resultAnswer == nil ? "Отправить" : "Отправить ещё раз", systemImage: "arrow.up.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Label(savedPhoto == nil ? "Оригинал сохранится на iPhone при отправке" : "Оригинал сохранён в Истории на этом iPhone",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func resultCard(_ answer: AnswerRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(answer.statusRaw == AnswerStatus.completed.rawValue ? "Ответ готов" : "Ответ прерван",
                  systemImage: answer.statusRaw == AnswerStatus.completed.rawValue ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.headline).foregroundStyle(.indigo)
            Text(answer.answer.isEmpty ? answer.errorMessage ?? "Ответ не получен" : answer.answer)
                .lineLimit(8).textSelection(.enabled)
            HStack {
                Button("Открыть ответ") { showFullAnswer = true }
                Button("Копировать") { UIPasteboard.general.string = answer.answer }
                    .disabled(answer.answer.isEmpty)
                Button("Переснять") { resetPhoto() }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func takePhoto(source: CaptureTriggerSource) {
        guard !isProcessing, !isSending, previewData == nil, scenePhase == .active,
              let sessionID = store.preparePhotoSession() else { return }
        captureAcceptedCounter += 1
        photoSessionID = sessionID
        isProcessing = true
        let operation = UUID()
        operationID = operation
        operationTask = Task {
            do {
                await camera.configure()
                try checkActive(operation: operation, sessionID: sessionID)
                let jpeg = try await camera.capture()
                try checkActive(operation: operation, sessionID: sessionID)
                completionCounter += 1
                let text = try await textRecognizer.recognize(jpeg: jpeg)
                try checkActive(operation: operation, sessionID: sessionID)
                previewData = jpeg
                recognizedText = text
            } catch is CancellationError {
                // Leaving the screen or session must not show a stale error or send a photo.
            } catch {
                if operationID == operation { errorMessage = error.localizedDescription }
            }
            if operationID == operation { isProcessing = false }
        }
        _ = source
    }

    private func sendReviewedPhoto(operation: UUID) async {
        guard let previewData, let sessionID = photoSessionID else { return }
        isSending = true
        let text = recognizedText
        do {
            try checkActive(operation: operation, sessionID: sessionID)
            let upload = try ImageUploadPreparation.prepare(jpeg: previewData)
            let photo: PhotoRecord
            if let savedPhoto {
                photo = savedPhoto
                photo.recognizedText = text
            } else {
                let path = try photoStore.saveJPEG(previewData)
                guard store.registerPhoto(sessionID: sessionID) else {
                    try? photoStore.delete(relativePath: path)
                    throw CancellationError()
                }
                photo = PhotoRecord(sessionID: sessionID, relativePath: path, recognizedText: text)
                modelContext.insert(photo)
                savedPhoto = photo
            }
            try modelContext.save()
            let answer = await store.answerPhoto(
                jpeg: upload, recognizedText: text, photoRelativePath: photo.relativePath,
                includeInConversation: includeInConversation,
                expectedSessionID: sessionID,
                retainForSession: retainForSession
            )
            try checkActive(operation: operation, sessionID: sessionID)
            if let answer {
                photo.answerID = answer.id
                resultAnswer = answer
                try modelContext.save()
            } else {
                errorMessage = "Запрос остановлен. Снимок сохранён в Истории; его можно отправить снова."
            }
        } catch is CancellationError {
            // The scheduler's ticket is cancelled by the parent task cancellation handler.
        } catch {
            if operationID == operation { errorMessage = error.localizedDescription }
        }
        if operationID == operation { isSending = false }
    }

    private func checkActive(operation: UUID, sessionID: UUID) throws {
        try Task.checkCancellation()
        guard operationID == operation, isVisible, scenePhase == .active,
              store.currentSession?.id == sessionID else { throw CancellationError() }
    }

    private func cancelOperation() {
        operationID = UUID()
        operationTask?.cancel()
        operationTask = nil
        camera.stop()
        remote.stop()
        isProcessing = false
        isSending = false
    }

    private func resetPhoto() {
        cancelOperation()
        previewData = nil
        recognizedText = ""
        savedPhoto = nil
        resultAnswer = nil
        photoSessionID = nil
        showFullAnswer = false
        retainForSession = false
        selectedPhoto = nil
    }

    private var flashSystemImage: String {
        switch camera.flashMode {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.a.fill"
        case .on: "bolt.fill"
        @unknown default: "bolt.slash.fill"
        }
    }

    private var selectedProviderSupportsImages: Bool {
        ProviderRegistry(settings: settings).provider(settings.primaryProvider).capabilities.supportsImages
    }

    private func handleCameraCaptureEvent(_ event: AVCaptureEvent) {
        let phase: HardwareCapturePhase = switch event.phase {
        case .began: .began
        case .ended: .ended
        case .cancelled: .cancelled
        @unknown default: .cancelled
        }
        if hardwareCaptureGate.shouldCapture(phase) {
            takePhoto(source: .systemCameraButton)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        guard !isProcessing, !isSending, previewData == nil, scenePhase == .active,
              let sessionID = store.preparePhotoSession() else { return }
        photoSessionID = sessionID
        isProcessing = true
        let operation = UUID()
        operationID = operation
        operationTask = Task {
            defer { selectedPhoto = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      data.count <= PhotoInputPolicy.maximumImportedBytes,
                      let image = UIImage(data: data),
                      let jpeg = image.jpegData(compressionQuality: 0.94) else {
                    throw CameraError.invalidImport
                }
                try checkActive(operation: operation, sessionID: sessionID)
                let text = try await textRecognizer.recognize(jpeg: jpeg)
                try checkActive(operation: operation, sessionID: sessionID)
                previewData = jpeg
                recognizedText = text
                completionCounter += 1
            } catch is CancellationError {
                // Import cancellation never creates or sends a photo.
            } catch {
                if operationID == operation { errorMessage = error.localizedDescription }
            }
            if operationID == operation { isProcessing = false }
        }
    }
}
