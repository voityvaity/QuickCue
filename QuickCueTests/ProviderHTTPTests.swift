import Foundation
import XCTest
@testable import QuickCue

@MainActor
final class ProviderHTTPTests: XCTestCase {
    func testOpenAIResponsesPayloadAndAuthorization() async throws {
        let transport = makeTransport(body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Да\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":4,\"output_tokens\":1}}}\n\n")
        let provider = OpenAIProvider(modelName: "fixture-model", credential: { "fixture-token" }, transport: transport)
        try await consume(provider)
        let request = try XCTUnwrap(ProviderHTTPStub.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let body = try capturedJSON()
        XCTAssertEqual(body["model"] as? String, "fixture-model")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testAnthropicHeadersAndUsage() async throws {
        let transport = makeTransport(body: "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":11,\"output_tokens\":1}}}\n\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Да\"}}\n\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":3}}\n\ndata: {\"type\":\"message_stop\"}\n\n")
        let provider = AnthropicProvider(modelName: "fixture-model", credential: { "fixture-token" }, transport: transport)
        var usage: TokenUsage?
        for try await event in provider.stream(request: request()) {
            if case .usage(let value) = event { usage = value }
        }
        XCTAssertEqual(usage, TokenUsage(inputTokens: 11, outputTokens: 3))
        XCTAssertEqual(ProviderHTTPStub.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "fixture-token")
        XCTAssertEqual(ProviderHTTPStub.lastRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testYandexFolderAndModelURI() async throws {
        let provider = YandexGPTProvider(modelName: "yandexgpt-5-pro/latest", folderID: "fixture-folder", credential: { "fixture-token" }, transport: makeTransport(body: chatBody))
        try await consume(provider)
        XCTAssertEqual(ProviderHTTPStub.lastRequest?.value(forHTTPHeaderField: "x-folder-id"), "fixture-folder")
        XCTAssertEqual(try capturedJSON()["model"] as? String, "gpt://fixture-folder/yandexgpt-5-pro/latest")
    }

    func testCustomGatewayUsesConfiguredEndpointAndApiKeyScheme() async throws {
        let profile = CustomProviderProfile(baseURL: "https://gateway.example/custom/chat/completions", authScheme: .apiKey, modelName: "fixture-model")
        let provider = CustomOpenAIProvider(profile: profile, credential: { "fixture-token" }, transport: makeTransport(body: chatBody))
        try await consume(provider)
        XCTAssertEqual(ProviderHTTPStub.lastRequest?.url?.absoluteString, profile.baseURL)
        XCTAssertEqual(ProviderHTTPStub.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Api-Key fixture-token")
    }

    func testHTTPErrorDoesNotExposeGatewayBody() async {
        let provider = OpenAIProvider(modelName: "fixture-model", credential: { "fixture-token" }, transport: makeTransport(status: 401, body: "PRIVATE_CONTENT_MUST_NOT_APPEAR"))
        do {
            try await consume(provider)
            XCTFail("Expected rejected authentication")
        } catch {
            XCTAssertEqual(ProviderFailure.category(for: error), "unauthorized")
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE_CONTENT"))
        }
    }

    private var chatBody: String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"Да\"}}]}\n\ndata: [DONE]\n\n"
    }

    private func request() -> AIRequest { AIRequest(question: "Тест", context: []) }

    private func consume(_ provider: any AIProvider) async throws {
        var complete = false
        for try await event in provider.stream(request: request()) { if case .completed = event { complete = true } }
        XCTAssertTrue(complete)
    }

    private func makeTransport(status: Int = 200, body: String) -> SSETransport {
        ProviderHTTPStub.configure(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderHTTPStub.self]
        return SSETransport(session: URLSession(configuration: configuration))
    }

    private func capturedJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(ProviderHTTPStub.lastBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// No sockets are opened. XCTest executes these methods serially; state is lock-protected for URLSession callbacks.
private final class ProviderHTTPStub: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var responseBody = Data()
    private static var capturedRequest: URLRequest?
    private static var capturedBody: Data?

    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return capturedRequest }
    static var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return capturedBody }

    static func configure(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        responseBody = Data(body.utf8)
        capturedRequest = nil
        capturedBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        }
        Self.lock.lock()
        Self.capturedRequest = request
        Self.capturedBody = body
        let status = Self.status
        let responseBody = Self.responseBody
        Self.lock.unlock()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
