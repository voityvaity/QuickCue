import XCTest
@testable import QuickCue

final class MockAIProviderTests: XCTestCase {
    func testMockStreamsTextAndUsage() async throws {
        let provider = MockAIProvider()
        let request = AIRequest(question: "Что такое actor в Swift?", context: [])
        var text = ""
        var usage: TokenUsage?

        for try await event in provider.stream(request: request) {
            switch event {
            case .textDelta(let delta): text += delta
            case .usage(let value): usage = value
            case .completed: break
            }
        }

        XCTAssertFalse(text.isEmpty)
        XCTAssertNotNil(usage)
        XCTAssertEqual(provider.kind, .mock)
    }
}

