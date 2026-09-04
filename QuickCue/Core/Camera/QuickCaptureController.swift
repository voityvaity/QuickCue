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
    private var generation = 0

    func cancel() {
        generation += 1
        camera.stop()
        phase = .idle
    }

    func capture(
        store: SessionStore,
        modelContext: ModelContext,
        includeInConversation: Bool
    ) async {
        guard !phase.isBusy else { return }
        let operation = generation
        guard let sessionID = store.preparePhotoSession() else { return }
        do {
            phase = .preparing
            await camera.configure()
            try checkActive(operation: operation, sessionID: sessionID, store: store)
            guard camera.isConfigured else {
                throw CameraError.configuration
            }

            phase = .capturing
            let jpeg = try await camera.capture()
            try checkActive(operation: operation, sessionID: sessionID, store: store)
            completionCounter += 1
            camera.stop()

            phase = .recognizing
            let recognizedText = try await textRecognizer.recognize(jpeg: jpeg)
            try checkActive(operation: operation, sessionID: sessionID, store: store)
            guard store.registerPhoto(sessionID: sessionID) else { throw CancellationError() }
            let path = try photoStore.saveJPEG(jpeg)
            let photo = PhotoRecord(
                sessionID: sessionID,
                relativePath: path,
                recognizedText: recognizedText
            )
            modelContext.insert(photo)
            try modelContext.save()

            phase = .answering
            if let answer = await store.answerPhoto(
                jpeg: try ImageUploadPreparation.prepare(jpeg: jpeg),
                recognizedText: recognizedText,
                includeInConversation: includeInConversation,
                photoRelativePath: path,
                expectedSessionID: sessionID
            ) {
                photo.answerID = answer.id
                photo.sessionID = answer.sessionID
            }
            try modelContext.save()
            try checkActive(operation: operation, sessionID: sessionID, store: store)
            phase = .finished
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if operation == generation, phase == .finished { phase = .idle }
        } catch is CancellationError {
            if operation == generation { camera.stop(); phase = .idle }
        } catch {
            if operation == generation {
                camera.stop()
                phase = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    private func checkActive(operation: Int, sessionID: UUID, store: SessionStore) throws {
        try Task.checkCancellation()
        guard operation == generation, store.currentSession?.id == sessionID else { throw CancellationError() }
    }
}
