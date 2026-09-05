import XCTest
@testable import QuickCue

final class CustomProviderTests: XCTestCase {
    func testBuildsChatCompletionsEndpointFromHost() throws {
        let url = try CustomOpenAIProvider.chatCompletionsEndpoint(
            from: "https://gateway.example"
        )
        XCTAssertEqual(url.absoluteString, "https://gateway.example/v1/chat/completions")
    }

    func testBuildsChatCompletionsEndpointFromVersionedBaseURL() throws {
        let url = try CustomOpenAIProvider.chatCompletionsEndpoint(
            from: "https://gateway.example/v1"
        )
        XCTAssertEqual(url.absoluteString, "https://gateway.example/v1/chat/completions")
    }

    func testKeepsFullChatCompletionsEndpoint() throws {
        let url = try CustomOpenAIProvider.chatCompletionsEndpoint(
            from: "https://gateway.example/api/chat/completions"
        )
        XCTAssertEqual(url.absoluteString, "https://gateway.example/api/chat/completions")
    }

    func testRejectsInsecureOrCredentialBearingURL() {
        XCTAssertThrowsError(
            try CustomOpenAIProvider.chatCompletionsEndpoint(from: "http://gateway.example")
        )
        XCTAssertThrowsError(
            try CustomOpenAIProvider.chatCompletionsEndpoint(from: "https://user:pass@gateway.example")
        )
    }

    func testBuildsEndpointsForEveryDeclaredProtocol() throws {
        XCTAssertEqual(
            try CustomOpenAIProvider.endpoint(from: "https://gateway.example/v1", protocolKind: .openAIResponses).path,
            "/v1/responses"
        )
        XCTAssertEqual(
            try CustomOpenAIProvider.endpoint(from: "https://gateway.example", protocolKind: .anthropicMessages).path,
            "/v1/messages"
        )
        XCTAssertEqual(
            try CustomOpenAIProvider.modelsEndpoint(from: "https://gateway.example/v1", protocolKind: .openAIResponses).path,
            "/v1/models"
        )
        XCTAssertThrowsError(
            try CustomOpenAIProvider.modelsEndpoint(from: "https://gateway.example/v1", protocolKind: .anthropicMessages)
        )
    }

    func testRejectsReservedOrMalformedAdditionalHeaderNames() throws {
        for name in ["Host", "Content-Length", "Authorization", "x-api-key", "Bad Header", "X:Bad", ""] {
            XCTAssertThrowsError(try CustomSecretHeaderPolicy.normalized(name), name)
        }
        XCTAssertEqual(try CustomSecretHeaderPolicy.normalized(" X-Tenant-Token "), "X-Tenant-Token")
    }
}
