import XCTest
@testable import QuickCue

final class PhotoCapturePolicyTests: XCTestCase {
    func testOneCompleteHardwarePressCreatesOneCapture() {
        var gate = HardwareCaptureGate()
        XCTAssertFalse(gate.shouldCapture(.began))
        XCTAssertTrue(gate.shouldCapture(.ended))
        XCTAssertFalse(gate.shouldCapture(.ended))
        XCTAssertFalse(gate.shouldCapture(.cancelled))
    }

    func testCancelledHardwarePressNeverCaptures() {
        var gate = HardwareCaptureGate()
        XCTAssertFalse(gate.shouldCapture(.began))
        XCTAssertFalse(gate.shouldCapture(.cancelled))
        XCTAssertFalse(gate.shouldCapture(.ended))
    }

    func testBLEBurstsAreDebounced() {
        var gate = CaptureTriggerDebouncer(minimumInterval: 0.35)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(gate.accept(at: start))
        XCTAssertFalse(gate.accept(at: start.addingTimeInterval(0.1)))
        XCTAssertTrue(gate.accept(at: start.addingTimeInterval(0.36)))
    }

    func testPhotoDisclosureNamesHostAndPayload() {
        let vision = PhotoTransferDestination(
            title: "Gateway", host: "gateway.example", payload: .imageAndText
        )
        XCTAssertEqual(
            vision.disclosure,
            "Изображение и распознанный текст отправятся в Gateway · gateway.example."
        )
        let text = PhotoTransferDestination(
            title: "DeepSeek", host: "api.deepseek.com", payload: .recognizedTextOnly
        )
        XCTAssertTrue(text.disclosure.contains("только распознанный текст"))
        XCTAssertTrue(text.disclosure.contains("api.deepseek.com"))
    }

    func testMockDisclosurePromisesNoNetwork() {
        XCTAssertEqual(
            PhotoTransferDestination(title: "Mock", host: nil, payload: .none).disclosure,
            "Тестовый режим: фото и текст не отправляются в сеть."
        )
    }

    @MainActor
    func testCameraIntentRequestIsConsumedExactlyOnce() {
        let suite = "PhotoCapturePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        QuickCueNavigationRequestStore.requestCamera(defaults: defaults, notificationCenter: center)
        XCTAssertTrue(QuickCueNavigationRequestStore.consumeCameraRequest(defaults: defaults))
        XCTAssertFalse(QuickCueNavigationRequestStore.consumeCameraRequest(defaults: defaults))
    }
}
