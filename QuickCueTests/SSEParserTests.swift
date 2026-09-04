import XCTest
@testable import QuickCue

final class SSEParserTests: XCTestCase {
    func testOpenAICompatibleDelta() throws {
        let message = SSEMessage(
            event: nil,
            data: #"{"choices":[{"delta":{"content":"Привет"}}]}"#
        )
        let events = try parseChatCompletionEvent(message)
        guard case .textDelta(let text) = events.first else {
            return XCTFail("Ожидался текстовый delta")
        }
        XCTAssertEqual(text, "Привет")
    }

    func testDoneMarker() throws {
        let events = try parseChatCompletionEvent(SSEMessage(event: nil, data: "[DONE]"))
        guard case .completed = events.first else {
            return XCTFail("Ожидалось завершение")
        }
    }

    func testUsage() throws {
        let message = SSEMessage(
            event: nil,
            data: #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#
        )
        let events = try parseChatCompletionEvent(message)
        guard case .usage(let usage) = events.first else {
            return XCTFail("Ожидался usage")
        }
        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 5)
    }
}

