import XCTest
@testable import QuickCue

final class StreamTerminalTests: XCTestCase {
    func testRoleOnlyUsageOnlyAndReasoningOnlyAreNotAnswers() throws {
        var decoder = ChatCompletionStreamDecoder()
        XCTAssertTrue(try decoder.events(for: message(#"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#)).isEmpty)
        let usage = try decoder.events(for: message(#"{"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#))
        XCTAssertEqual(usage.count, 1)
        XCTAssertTrue(try decoder.events(for: message(#"{"choices":[{"delta":{"reasoning_content":"PRIVATE_REASONING"}}]}"#)).isEmpty)
        XCTAssertThrowsError(try decoder.events(for: message("[DONE]"))) { error in
            XCTAssertEqual(ProviderFailure.category(for: error), "reasoning_only")
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE_REASONING"))
        }
    }

    func testFinishReasonsPreservePartialAndUsageButNeverClaimSuccess() throws {
        for (reason, category) in [("length", "output_limit"), ("content_filter", "policy_block"),
                                   ("tool_calls", "unsupported_output"), ("insufficient_system_resource", "resource_interruption"),
                                   ("PRIVATE_UNKNOWN_REASON", "unsupported_termination")] {
            var decoder = ChatCompletionStreamDecoder()
            let events = try decoder.events(for: message("{\"choices\":[{\"delta\":{\"content\":\"Часть\"},\"finish_reason\":\"\(reason)\"}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2}}"))
            XCTAssertEqual(events.count, 2)
            guard case .textDelta = events[0], case .usage = events[1] else { return XCTFail("Preserve text and usage") }
            XCTAssertThrowsError(try decoder.events(for: message("[DONE]"))) { error in
                XCTAssertEqual(ProviderFailure.category(for: error), category)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE_UNKNOWN"))
            }
        }
    }

    func testStopRequiresTerminalAndText() throws {
        var decoder = ChatCompletionStreamDecoder()
        _ = try decoder.events(for: message(#"{"choices":[{"delta":{"content":"Да"},"finish_reason":"stop"}]}"#))
        XCTAssertThrowsError(try decoder.finish())
        let terminal = try decoder.events(for: message("[DONE]"))
        guard case .completed = terminal.first else { return XCTFail("Expected completion") }
        try decoder.finish()
    }

    func testMalformedJSONIsNotSilentlyIgnoredAndExtensionsAreIgnored() throws {
        for payload in ["{PRIVATE_BROKEN", "[1,2]", #"{"choices":"wrong"}"#] {
            var decoder = ChatCompletionStreamDecoder()
            XCTAssertThrowsError(try decoder.events(for: message(payload))) { error in
                XCTAssertEqual(ProviderFailure.category(for: error), "malformed_event")
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE_BROKEN"))
            }
        }
        var decoder = ChatCompletionStreamDecoder()
        XCTAssertTrue(try decoder.events(for: SSEMessage(event: "vendor.extension", data: "not JSON")).isEmpty)
        XCTAssertTrue(try decoder.events(for: SSEMessage(event: "vendor.extension", data: "[DONE]")).isEmpty)
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertThrowsError(try parseResponsesEvent(message("{broken")))
        var anthropic = AnthropicStreamDecoder()
        XCTAssertThrowsError(try anthropic.events(for: message("{broken")))
    }

    func testEmptyDoneAndPrematureEOFHaveDifferentFailures() throws {
        var decoder = ChatCompletionStreamDecoder()
        XCTAssertThrowsError(try decoder.finish()) { XCTAssertEqual(ProviderFailure.category(for: $0), "incomplete_response") }
        XCTAssertThrowsError(try decoder.events(for: message("[DONE]"))) { XCTAssertEqual(ProviderFailure.category(for: $0), "empty_response") }
    }

    func testConcatenatedJSONFramesAreMalformedNotEmptySuccess() {
        var decoder = ChatCompletionStreamDecoder()
        let merged = #"{"choices":[{"delta":{"content":"Да"}}]}"# + "\n[DONE]"
        XCTAssertThrowsError(try decoder.events(for: message(merged))) {
            XCTAssertEqual(ProviderFailure.category(for: $0), "malformed_event")
        }
        // This is a semantic regression, not proof that Darwin .lines merges events.
    }

    func testHTTPClassificationAndTransportMessagesStaySafe() {
        for (status, category) in [(401, "unauthorized"), (402, "billing"), (403, "forbidden"), (404, "model_or_endpoint"), (429, "rate_limit")] {
            XCTAssertEqual(ProviderFailure.category(for: SSETransportFailure.httpStatus(status)), category)
        }
        XCTAssertEqual(ProviderFailure.category(for: SSETransportFailure.truncatedEvent), "incomplete_response")
        XCTAssertEqual(SafeErrorCode.classify(SSETransportFailure.invalidUTF8), "invalid_utf8")
    }

    func testAnthropicOutputLimitNeverCompletes() throws {
        var decoder = AnthropicStreamDecoder()
        _ = try decoder.events(for: message(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#))
        XCTAssertThrowsError(try decoder.events(for: message(#"{"type":"message_stop"}"#))) {
            XCTAssertEqual(ProviderFailure.category(for: $0), "output_limit")
        }
    }

    func testMalformedAnthropicTerminalFieldsNeverComplete() throws {
        let malformed = [
            #"{"type":"message_delta","delta":{"stop_reason":7}}"#,
            #"{"type":"message_delta","delta":{}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":null}}"#,
            #"{"type":"message_delta","delta":"wrong"}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":"wrong"}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":true}}"#,
        ]

        for payload in malformed {
            var decoder = AnthropicStreamDecoder()
            XCTAssertThrowsError(try decoder.events(for: message(payload))) {
                XCTAssertEqual(ProviderFailure.category(for: $0), "malformed_event")
            }
        }

        var valid = AnthropicStreamDecoder()
        XCTAssertTrue(try valid.events(for: message(#"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":null}"#)).isEmpty)
        guard case .completed = try valid.events(for: message(#"{"type":"message_stop"}"#)).first else {
            return XCTFail("Expected valid completion")
        }
    }

    func testMalformedResponsesCompletionNeverCompletes() throws {
        let malformed = [
            #"{"type":"response.completed"}"#,
            #"{"type":"response.completed","response":"wrong"}"#,
            #"{"type":"response.completed","response":{}}"#,
            #"{"type":"response.completed","response":{"status":7}}"#,
            #"{"type":"response.completed","response":{"status":"failed"}}"#,
            #"{"type":"response.completed","response":{"status":"completed","usage":"wrong"}}"#,
            #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":true,"output_tokens":1}}}"#,
            #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":-1}}}"#,
        ]

        for payload in malformed {
            XCTAssertThrowsError(try parseResponsesEvent(message(payload))) {
                XCTAssertEqual(ProviderFailure.category(for: $0), "malformed_event")
            }
        }

        let completed = try parseResponsesEvent(message(#"{"type":"response.completed","response":{"status":"completed","usage":null}}"#))
        guard case .completed = completed.first else { return XCTFail("Expected valid completion") }
    }

    private func message(_ data: String) -> SSEMessage { SSEMessage(event: nil, data: data) }
}
