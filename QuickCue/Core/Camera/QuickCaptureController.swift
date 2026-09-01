import SwiftData
import SwiftUI

enum QuickCapturePhase: Equatable {
    case idle
    case preparing
    case capturing
    case recognizing
    case answering
    case finished

    var title: String {
        switch self {
        case .idle: "Сфотографировать"
        case .preparing: "Открываю камеру…"
        case .capturing: "Фотографирую…"
        case .recognizing: "Распознаю текст…"
        case .answering: "Готовлю ответ…"
        case .finished: "Фото отправлено"
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .capturing, .recognizing, .answering: true
        case .idle, .finished: false
        }
    }
}

@MainActor
final class QuickCaptureController: ObservableObject {
    @Published private(set) var phase: QuickCapturePhase = .idle
    @Published var errorMessage: String?
    @Published private(set) var completionCounter = 0

    private let camera = CameraService()
    private let textRecognizer = TextRecognizer()
    private let photoStore = PhotoStore()

    func capture(
        store: SessionStore,
        modelContext: ModelContext,
        includeInConversation: Bool
    ) async {
        guard !phase.isBusy else { return }
        do {
            phase = .preparing
            await camera.configure()
            guard camera.isConfigured else {
                throw CameraError.configuration
            }

            phase = .capturing
            let jpeg = try await camera.capture()
            camera.stop()

            phase = .recognizing
            let recognizedText = try await textRecognizer.recognize(jpeg: jpeg)
            let sessionID = store.registerPhoto()
            let path = try photoStore.saveJPEG(jpeg)
            let photo = PhotoRecord(
                sessionID: sessionID,
                relativePath: path,
                recognizedText: recognizedText
            )
            modelContext.insert(photo)

            phase = .answering
            if let answer = await store.answerPhoto(
                jpeg: jpeg,
                recognizedText: recognizedText,
                includeInConversation: includeInConversation,
                photoRelativePath: path
            ) {
                photo.answerID = answer.id
                photo.sessionID = answer.sessionID
            }
            try modelContext.save()
            phase = .finished
            completionCounter += 1
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if phase == .finished { phase = .idle }
        } catch {
            camera.stop()
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }
}
