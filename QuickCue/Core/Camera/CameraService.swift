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
    private let sessionQueue = DispatchQueue(label: "ru.quickcue.camera.session", qos: .userInitiated)
    private var device: AVCaptureDevice?
    private var generation = 0
    private var continuation: CheckedContinuation<Data, Error>?
    private var captureID: Int64?
    private var captureToken: UUID?
    private var captureTimeout: Task<Void, Never>?

    func configure() async {
        let operation = generation
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if status == .authorized {
            allowed = true
        } else if status == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        } else {
            allowed = false
        }
        guard !Task.isCancelled, operation == generation else { return }
        guard allowed else { authorizationDenied = true; return }
        authorizationDenied = false
        lastError = nil
        guard !isConfigured else {
            await startAndWait()
            if Task.isCancelled, operation == generation { stop() }
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
            self.device = device
            session.commitConfiguration()
            isConfigured = true
            await startAndWait()
            if Task.isCancelled, operation == generation { stop() }
        } catch {
            session.commitConfiguration()
            lastError = error.localizedDescription
        }
    }

    func start() {
        guard isConfigured, !session.isRunning else { return }
        let captureSession = session
        sessionQueue.async { if !captureSession.isRunning { captureSession.startRunning() } }
    }

    private func startAndWait() async {
        guard isConfigured, !session.isRunning else { return }
        let captureSession = session
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if !captureSession.isRunning { captureSession.startRunning() }
                continuation.resume()
            }
        }
    }

    func stop() {
        generation += 1
        cancelCapture()
        let captureSession = session
        sessionQueue.async { if captureSession.isRunning { captureSession.stopRunning() } }
    }

    func capture() async throws -> Data {
        try Task.checkCancellation()
        guard isConfigured, session.isRunning else { throw CameraError.configuration }
        guard captureToken == nil else { throw CameraError.captureInProgress }
        let token = UUID()
        captureToken = token
        defer { if captureToken == token { captureToken = nil } }
        let operation = generation
        // Give a cold camera a bounded opportunity to settle, without blocking the UI.
        try await Task.sleep(nanoseconds: 120_000_000)
        for _ in 0..<8 {
            guard device?.isAdjustingFocus == true || device?.isAdjustingExposure == true else { break }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        try Task.checkCancellation()
        guard operation == generation, session.isRunning else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.photoQualityPrioritization = .balanced
                captureID = settings.uniqueID
                output.capturePhoto(with: settings, delegate: self)
                captureTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                    self?.cancelCapture(error: CameraError.noData, token: token)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelCapture(token: token) }
        }
    }

    private func cancelCapture(error: Error = CancellationError(), token: UUID? = nil) {
        guard token == nil || token == captureToken else { return }
        captureTimeout?.cancel()
        captureTimeout = nil
        captureID = nil
        captureToken = nil
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: error)
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.captureID == photo.resolvedSettings.uniqueID else { return }
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            self.captureID = nil
            self.captureTimeout?.cancel()
            self.captureTimeout = nil
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
