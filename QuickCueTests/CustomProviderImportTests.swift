import Foundation
import XCTest
@testable import QuickCue

final class CustomProviderImportTests: XCTestCase {
    func testRoundTripContainsNoSecretOrLocalIdentifier() throws {
        let profile = CustomProviderProfile(
            displayName: "Private Gateway",
            baseURL: "https://gateway.example/v1",
            authScheme: .xAPIKey,
            modelName: "chat-model"
        )

        let json = try CustomProviderProfileCodec.encode(profile)
        let imported = try CustomProviderProfileCodec.decode(json)

        XCTAssertEqual(imported.profile.displayName, profile.displayName)
        XCTAssertEqual(imported.profile.baseURL, profile.baseURL)
        XCTAssertEqual(imported.profile.authScheme, .xAPIKey)
        XCTAssertEqual(imported.profile.modelName, "chat-model")
        XCTAssertEqual(imported.origin, "https://gateway.example")
        XCTAssertFalse(json.contains("\"apiKey\":"))
        XCTAssertFalse(json.contains(profile.id.uuidString))
        XCTAssertNotEqual(imported.profile.id, profile.id)
    }

    func testUnknownSecretAndCommandFieldsAreRejected() {
        for field in ["apiKey", "shellCommand", "certificate", "headers"] {
            let json = validJSON.replacingOccurrences(
                of: "\"modelID\":\"chat-model\"",
                with: "\"modelID\":\"chat-model\",\"\(field)\":\"fixture-value\""
            )
            XCTAssertThrowsError(try CustomProviderProfileCodec.decode(json)) { error in
                XCTAssertEqual(error as? CustomProviderProfileImportError, .unknownField(field))
            }
        }
    }

    func testRejectsUnsupportedVersionAndUnsafeURLs() {
        XCTAssertThrowsError(try CustomProviderProfileCodec.decode(
            validJSON.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        ))
        for url in [
            "http://gateway.example",
            "https://user:pass@gateway.example",
            "https://gateway.example/v1?key=fixture",
            "https://gateway.example/v1#fragment",
        ] {
            XCTAssertThrowsError(try CustomProviderProfileCodec.decode(
                validJSON.replacingOccurrences(of: "https://gateway.example/v1", with: url)
            ), url)
        }
    }

    func testRejectsOversizedProfile() {
        XCTAssertThrowsError(try CustomProviderProfileCodec.decode(String(repeating: "x", count: 65_537))) { error in
            XCTAssertEqual(error as? CustomProviderProfileImportError, .tooLarge)
        }
    }

    func testCredentialSchemesProduceOnlyTheirDeclaredHeader() {
        XCTAssertEqual(CustomAuthScheme.bearer.headers(credential: "fixture"), ["Authorization": "Bearer fixture"])
        XCTAssertEqual(CustomAuthScheme.apiKey.headers(credential: "fixture"), ["Authorization": "Api-Key fixture"])
        XCTAssertEqual(CustomAuthScheme.apiKeyHeader.headers(credential: "fixture"), ["Api-Key": "fixture"])
        XCTAssertEqual(CustomAuthScheme.xAPIKey.headers(credential: "fixture"), ["x-api-key": "fixture"])
    }

    func testCrossOriginRedirectIsRejectedForEveryCustomCredentialScheme() throws {
        let source = try XCTUnwrap(URL(string: "https://gateway.example/v1/chat/completions"))
        let otherOrigin = try XCTUnwrap(URL(string: "https://collector.example/v1/chat/completions"))
        let sameOrigin = try XCTUnwrap(URL(string: "https://gateway.example/redirected"))

        for scheme in CustomAuthScheme.allCases {
            XCTAssertEqual(scheme.headers(credential: "fixture").count, 1)
            XCTAssertFalse(SameOriginRedirectDelegate.permitsRedirect(from: source, to: otherOrigin), scheme.rawValue)
            XCTAssertTrue(SameOriginRedirectDelegate.permitsRedirect(from: source, to: sameOrigin), scheme.rawValue)
        }
    }

    func testNonAssistantModelsAreNotEligibleForAutomaticChoice() {
        for id in ["text-embedding-3", "gpt-realtime", "whisper-1", "image-generator", "tts-1"] {
            XCTAssertFalse(ProviderModelSelector.isPlausibleTextAssistant(modelID: id), id)
        }
        XCTAssertTrue(ProviderModelSelector.isPlausibleTextAssistant(modelID: "chat-model"))
    }

    private var validJSON: String {
        """
        {"schemaVersion":1,"displayName":"Gateway","baseURL":"https://gateway.example/v1","protocolKind":"openAIChatCompletions","authScheme":"bearer","modelID":"chat-model"}
        """
    }
}
