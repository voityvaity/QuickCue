import AVFoundation
import SwiftUI
import UIKit

struct PairingQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> PairingQRScannerController {
        let controller = PairingQRScannerController()
        controller.onCode = onCode
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ controller: PairingQRScannerController, context: Context) {
        controller.onCode = onCode
        controller.onError = onError
    }

    static func dismantleUIViewController(_ controller: PairingQRScannerController, coordinator: ()) {
        controller.stop()
    }
}

final class PairingQRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ru.quickcue.pairing-scanner", qos: .userInitiated)
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureAfterPermission()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureAfterPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    if allowed { self?.configure() }
                    else { self?.onError?("Разрешите камеру, либо вставьте код привязки вручную.") }
                }
            }
        default:
            onError?("Разрешите камеру, либо вставьте код привязки вручную.")
        }
    }

    private func configure() {
        var configurationIsOpen = false
        do {
            guard let camera = AVCaptureDevice.default(for: .video) else { throw CameraError.noCamera }
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            configurationIsOpen = true
            guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraError.configuration }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            guard output.availableMetadataObjectTypes.contains(.qr) else { throw CameraError.configuration }
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            configurationIsOpen = false
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            self.preview = preview
            queue.async { [session] in if !session.isRunning { session.startRunning() } }
        } catch {
            if configurationIsOpen { session.commitConfiguration() }
            onError?("Не удалось открыть QR-сканер. Вставьте код вручную.")
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        delivered = true
        stop()
        onCode?(code)
    }
}
