import AVFoundation
import Combine
import Foundation

@MainActor
final class CameraService: NSObject, ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var authorizationDenied = false
    @Published var lastError: String?

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var continuation: CheckedContinuation<Data, Error>?

    func configure() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if status == .authorized {
            allowed = true
        } else if status == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        } else {
            allowed = false
        }
        guard allowed else { authorizationDenied = true; return }
        guard !isConfigured else {
            await startAndWait()
            return
        }

        do {
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                throw CameraError.noCamera
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraError.configuration }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            isConfigured = true
            await startAndWait()
        } catch {
            session.commitConfiguration()
            lastError = error.localizedDescription
        }
    }

    func start() {
        guard isConfigured, !session.isRunning else { return }
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async { captureSession.startRunning() }
    }

    private func startAndWait() async {
        guard isConfigured, !session.isRunning else { return }
        let captureSession = session
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                captureSession.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() {
        guard session.isRunning else { return }
        let captureSession = session
        DispatchQueue.global(qos: .utility).async { captureSession.stopRunning() }
    }

    func capture() async throws -> Data {
        guard isConfigured else { throw CameraError.configuration }
        guard continuation == nil else { throw CameraError.captureInProgress }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .balanced
            output.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor in
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            if let error { continuation.resume(throwing: error) }
            else if let data = photo.fileDataRepresentation() { continuation.resume(returning: data) }
            else { continuation.resume(throwing: CameraError.noData) }
        }
    }
}

enum CameraError: LocalizedError {
    case noCamera
    case configuration
    case captureInProgress
    case noData

    var errorDescription: String? {
        switch self {
        case .noCamera: "Камера не найдена."
        case .configuration: "Не удалось настроить камеру."
        case .captureInProgress: "Снимок уже выполняется."
        case .noData: "Камера не вернула фотографию."
        }
    }
}
