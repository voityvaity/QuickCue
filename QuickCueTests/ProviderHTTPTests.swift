import Foundation
import XCTest
@testable import QuickCue

@MainActor
final class ProviderHTTPTests: XCTestCase {
    func testDeepSeekConnectionProbeUsesNeutralPromptAndNonThinkingStream() async throws {
        let stub = ProviderHTTPStub(body: chatBody)
        let provider = DeepSeekProvider(modelName: "fixture-model", credential: { "fixture-token" }, transport: stub.transport)
        _ = try await ProviderConnectionChecker.verify(provider: provider)
        let request = try XCTUnwrap(stub.lastRequest)
        XCTAssertEqual(request.url?.host, "api.deepseek.com")
        XCTAssertEqual(request.url?.path, "/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let body = try capturedJSON(from: stub)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(body["max_tokens"] as? Int, 32)
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("Это проверка подключения") == true)
        XCTAssertFalse(messages[0]["content"]?.contains("3–5") == true)
    }

    func testOpenAIResponsesPayloadAndAuthorization() async throws {
        let stub = ProviderHTTPStub(
            body: """
            data: {"type":"response.output_text.delta","delta":"Да"}

            data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":1}}}

            """ + "\n"
        )

        let provider = OpenAIProvider(
            modelName: "fixture-model",
            credential: { "fixture-token" },
            transport: stub.transport
        )

        try await consume(provider)

        let request = try XCTUnwrap(stub.lastRequest)

        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-token"
        )

        let body = try capturedJSON(from: stub)

        XCTAssertEqual(body["model"] as? String, "fixture-model")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testAnthropicHeadersAndUsage() async throws {
        let stub = ProviderHTTPStub(
            body: """
            data: {"type":"message_start","message":{"usage":{"input_tokens":11,"output_tokens":1}}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Да"}}

            data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":3}}

            data: {"type":"message_stop"}

            """ + "\n"
        )

        let provider = AnthropicProvider(
            modelName: "fixture-model",
            credential: { "fixture-token" },
            transport: stub.transport
        )

        var usage: TokenUsage?

        for try await event in provider.stream(request: request()) {
            if case .usage(let value) = event {
                usage = value
            }
        }

        XCTAssertEqual(
            usage,
            TokenUsage(
                inputTokens: 11,
                outputTokens: 3
            )
        )

        XCTAssertEqual(
            stub.lastRequest?.value(forHTTPHeaderField: "x-api-key"),
            "fixture-token"
        )

        XCTAssertEqual(
            stub.lastRequest?.value(forHTTPHeaderField: "anthropic-version"),
            "2023-06-01"
        )
    }

    func testYandexFolderAndModelURI() async throws {
        let stub = ProviderHTTPStub(body: chatBody)

        let provider = YandexGPTProvider(
            modelName: "yandexgpt-5-pro/latest",
            folderID: "fixture-folder",
            credential: { "fixture-token" },
            transport: stub.transport
        )

        try await consume(provider)

        XCTAssertEqual(
            stub.lastRequest?.value(forHTTPHeaderField: "x-folder-id"),
            "fixture-folder"
        )

        XCTAssertEqual(
            try capturedJSON(from: stub)["model"] as? String,
            "gpt://fixture-folder/yandexgpt-5-pro/latest"
        )
    }

    func testCustomGatewayUsesConfiguredEndpointAndApiKeyScheme() async throws {
        let stub = ProviderHTTPStub(body: chatBody)

        let profile = CustomProviderProfile(
            baseURL: "https://gateway.example/custom/chat/completions",
            authScheme: .apiKey,
            modelName: "fixture-model"
        )

        let provider = CustomOpenAIProvider(
            profile: profile,
            credential: { "fixture-token" },
            transport: stub.transport
        )

        try await consume(provider)

        XCTAssertEqual(
            stub.lastRequest?.url?.absoluteString,
            profile.baseURL
        )

        XCTAssertEqual(
            stub.lastRequest?.value(forHTTPHeaderField: "Authorization"),
            "Api-Key fixture-token"
        )
    }

    func testCustomGatewaySupportsExplicitApiKeyHeaders() async throws {
        for (scheme, header) in [
            (CustomAuthScheme.apiKeyHeader, "Api-Key"),
            (CustomAuthScheme.xAPIKey, "x-api-key"),
        ] {
            let stub = ProviderHTTPStub(body: chatBody)
            let profile = CustomProviderProfile(
                baseURL: "https://gateway.example/v1",
                authScheme: scheme,
                modelName: "fixture-model"
            )
            try await consume(CustomOpenAIProvider(
                profile: profile,
                credential: { "fixture-token" },
                transport: stub.transport
            ))

            XCTAssertEqual(stub.lastRequest?.value(forHTTPHeaderField: header), "fixture-token")
            XCTAssertNil(stub.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testHTTPErrorDoesNotExposeGatewayBody() async {
        let stub = ProviderHTTPStub(
            status: 401,
            body: "PRIVATE_CONTENT_MUST_NOT_APPEAR"
        )

        let provider = OpenAIProvider(
            modelName: "fixture-model",
            credential: { "fixture-token" },
            transport: stub.transport
        )

        do {
            try await consume(provider)
            XCTFail("Expected rejected authentication")
        } catch {
            XCTAssertEqual(
                ProviderFailure.category(for: error),
                "unauthorized"
            )

            XCTAssertFalse(
                error.localizedDescription.contains("PRIVATE_CONTENT")
            )
        }
    }

    private var chatBody: String {
        """
        data: {"choices":[{"delta":{"content":"Да"}}]}

        data: [DONE]

        """ + "\n"
    }

    private func request() -> AIRequest {
        AIRequest(
            question: "Тест",
            context: []
        )
    }

    private func consume(_ provider: any AIProvider) async throws {
        var complete = false

        for try await event in provider.stream(request: request()) {
            if case .completed = event {
                complete = true
            }
        }

        XCTAssertTrue(complete)
    }

    private func capturedJSON(
        from stub: ProviderHTTPStub
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(stub.lastBody)

        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
    }
}

private final class ProviderHTTPStub: @unchecked Sendable {
    private let lock = NSLock()

    private let status: Int
    private let responseBody: Data

    private var capturedRequest: URLRequest?
    private var capturedBody: Data?

    init(
        status: Int = 200,
        body: String
    ) {
        self.status = status
        self.responseBody = Data(body.utf8)
    }

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }

        return capturedRequest
    }

    var lastBody: Data? {
        lock.lock()
        defer { lock.unlock() }

        return capturedBody
    }

    var transport: SSETransport {
        SSETransport { [self] request in
            makeStream(for: request)
        }
    }

    private func makeStream(
        for request: URLRequest
    ) -> AsyncThrowingStream<SSEMessage, Error> {
        lock.lock()
        capturedRequest = request
        capturedBody = request.httpBody
        lock.unlock()

        let status = self.status
        let responseBody = self.responseBody

        return AsyncThrowingStream { continuation in
            guard (200...299).contains(status) else {
                continuation.finish(
                    throwing: AIProviderError.badResponse(
                        status,
                        "http_error"
                    )
                )
                return
            }

            do {
                var decoder = SSEDecoder()
                // Use the exact production framing, including UTF-8 across byte boundaries.
                for byte in responseBody {
                    if let message = try decoder.consume(byte: byte) { continuation.yield(message) }
                }
                try decoder.finish()
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}
