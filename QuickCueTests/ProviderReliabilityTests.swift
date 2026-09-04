import XCTest
@testable import QuickCue

final class ProviderStreamParsingTests: XCTestCase {
    func testIncompleteResponsesEventFailsInsteadOfSuccess() {
        let event = SSEMessage(event: nil, data: #"{"type":"response.incomplete","response":{"status":"incomplete"}}"#)
        XCTAssertThrowsError(try parseResponsesEvent(event))
    }

    func testResponsesCompletionIncludesUsageBeforeCompletion() throws {
        let events = try parseResponsesEvent(SSEMessage(event: nil, data: #"{"type":"response.completed","response":{"usage":{"input_tokens":30,"output_tokens":12}}}"#))
        XCTAssertEqual(events.count, 2)
        guard case .usage(let usage) = events[0], case .completed = events[1] else {
            return XCTFail("Expected usage then completion")
        }
        XCTAssertEqual(usage, TokenUsage(inputTokens: 30, outputTokens: 12))
    }

    func testAnthropicKeepsInputUsageAcrossMessageDelta() throws {
        var decoder = AnthropicStreamDecoder()
        _ = try decoder.events(for: SSEMessage(event: nil, data: #"{"type":"message_start","message":{"usage":{"input_tokens":40,"cache_read_input_tokens":10,"output_tokens":1}}}"#))
        let events = try decoder.events(for: SSEMessage(event: nil, data: #"{"type":"message_delta","usage":{"output_tokens":17}}"#))
        guard let event = events.first, case .usage(let usage) = event else { return XCTFail("Missing usage") }
        XCTAssertEqual(usage, TokenUsage(inputTokens: 50, outputTokens: 17))
    }

    func testEmbeddedGatewayErrorIsNotAnEmptySuccess() {
        XCTAssertThrowsError(try validatedChatCompletionEvents(SSEMessage(event: nil, data: #"{"error":{"message":"PRIVATE_CONTENT_MUST_NOT_APPEAR"}}"#)))
        let error = AIProviderError.badResponse(200, "PRIVATE_CONTENT_MUST_NOT_APPEAR")
        XCTAssertEqual(ProviderFailure.category(for: error), "stream_error")
        XCTAssertFalse(error.localizedDescription.contains("200"))
        XCTAssertFalse(error.localizedDescription.contains("PRIVATE_CONTENT"))
    }

    func testMissingUsageIsNotReportedAsZeroTokens() throws {
        let chat = parseChatCompletionEvent(SSEMessage(event: nil, data: #"{"usage":{}}"#))
        XCTAssertTrue(chat.isEmpty)
        let response = try parseResponsesEvent(SSEMessage(event: nil, data: #"{"type":"response.completed","response":{"usage":{}}}"#))
        XCTAssertEqual(response.count, 1)
        guard case .completed = response[0] else { return XCTFail("Only completion expected") }
        var decoder = AnthropicStreamDecoder()
        XCTAssertTrue(try decoder.events(for: SSEMessage(event: nil, data: #"{"type":"message_start","message":{"usage":{}}}"#)).isEmpty)
        XCTAssertTrue(try decoder.events(for: SSEMessage(event: nil, data: #"{"type":"message_delta","usage":{"output_tokens":5}}"#)).isEmpty)
    }

    func testMalformedTokenCountsAreUnknown() {
        for data in [#"{"usage":{"prompt_tokens":true,"completion_tokens":5}}"#,
                     #"{"usage":{"prompt_tokens":1.5,"completion_tokens":5}}"#,
                     #"{"usage":{"prompt_tokens":-1,"completion_tokens":5}}"#] {
            XCTAssertTrue(parseChatCompletionEvent(SSEMessage(event: nil, data: data)).isEmpty)
        }
    }

    func testErrorBodyNeverAppearsInUserMessage() {
        let error = AIProviderError.badResponse(401, "PRIVATE_CONTENT_MUST_NOT_APPEAR")
        XCTAssertFalse(error.localizedDescription.contains("PRIVATE_CONTENT"))
        XCTAssertEqual(ProviderFailure.category(for: error), "unauthorized")
    }

    func testValidatorRejectsTextWithoutCompletion() {
        var validator = StreamCompletionValidator()
        validator.observe(.textDelta("Частичный ответ"))
        XCTAssertThrowsError(try validator.validate())
    }

    func testValidatorRejectsWhitespaceEvenWithCompletion() {
        var validator = StreamCompletionValidator()
        validator.observe(.textDelta(" \n"))
        validator.observe(.completed)
        XCTAssertThrowsError(try validator.validate())
    }
}

@MainActor
final class ProviderConnectionCheckerTests: XCTestCase {
    func testVerifierWaitsForCompletedStream() async throws {
        let result = try await ProviderConnectionChecker.verify(provider: VerificationProvider(events: [.textDelta("Да"), .completed]))
        XCTAssertGreaterThanOrEqual(result.totalMilliseconds, result.firstTokenMilliseconds)
    }

    func testVerifierRejectsFirstTokenThenError() async {
        do {
            _ = try await ProviderConnectionChecker.verify(provider: VerificationProvider(events: [.textDelta("Да")], failure: true))
            XCTFail("A first token is not a successful connection test")
        } catch {
            XCTAssertEqual(ProviderFailure.category(for: error), "incomplete_response")
        }
    }

    func testVerifierRejectsUnterminatedStream() async {
        do {
            _ = try await ProviderConnectionChecker.verify(provider: VerificationProvider(events: [.textDelta("Да")]))
            XCTFail("Missing completion should fail")
        } catch {
            XCTAssertEqual(ProviderFailure.category(for: error), "incomplete_response")
        }
    }

    func testVerifierTimesOutAndCancelsSlowProvider() async {
        do {
            _ = try await ProviderConnectionChecker.verify(provider: VerificationProvider(events: [], delay: 2_000_000_000), timeoutSeconds: 0.02)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(ProviderFailure.category(for: error), "timeout")
        }
    }
}

private struct VerificationProvider: AIProvider {
    let kind = ProviderKind.mock
    let modelName = "test-fixture"
    let capabilities = ProviderCapabilities(supportsText: true, supportsImages: false, supportsStreaming: true)
    let events: [AIStreamEvent]
    var failure = false
    var delay: UInt64 = 0

    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    for event in events { continuation.yield(event) }
                    if failure { throw AIProviderError.incompleteResponse }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
