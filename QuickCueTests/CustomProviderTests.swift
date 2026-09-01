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
}
