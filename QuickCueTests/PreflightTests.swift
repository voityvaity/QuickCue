import Foundation
import XCTest
@testable import QuickCue

final class PreflightTests: XCTestCase {
    func testDeniedAndStaleStatesNeverLookReady() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let checks = PreflightEvaluator.evaluate(.init(
            microphone: .denied,
            speech: .granted,
            camera: .undetermined,
            providerState: .verified,
            providerCheckedAt: now.addingTimeInterval(-PreflightEvaluator.verificationFreshness - 1),
            usesMock: false,
            hasContext: false,
            speechModeTitle: "Автоматически",
            providerTitle: "DeepSeek"
        ), now: now)

        XCTAssertEqual(try check("microphone", in: checks).level, .blocked)
        XCTAssertEqual(try check("provider", in: checks).level, .attention)
        XCTAssertEqual(try check("camera", in: checks).level, .attention)
    }

    func testMockIsExplicitlyReadyWithoutPretendingToVerifyNetwork() throws {
        let checks = PreflightEvaluator.evaluate(.init(
            microphone: .granted,
            speech: .granted,
            camera: .granted,
            providerState: .unconfigured,
            providerCheckedAt: nil,
            usesMock: true,
            hasContext: true,
            speechModeTitle: "Ручной",
            providerTitle: "Mock"
        ))

        let provider = try check("provider", in: checks)
        XCTAssertEqual(provider.level, .ready)
        XCTAssertTrue(provider.detail.contains("без сети"))
    }

    private func check(_ id: String, in checks: [PreflightCheck]) throws -> PreflightCheck {
        try XCTUnwrap(checks.first { $0.id == id })
    }
}
