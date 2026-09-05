import Foundation
import XCTest
@testable import QuickCue

final class CustomProviderImportTests: XCTestCase {
    func testRoundTripContainsNoSecretOrLocalIdentifier() throws {
        var profile = CustomProviderProfile(
            displayName: "Private Gateway",
            baseURL: "https://gateway.example/v1",
            authScheme: .xAPIKey,
            models: [
                ModelProfile(apiModelID: "chat-model", displayName: "Chat"),
                ModelProfile(apiModelID: "vision-model", displayName: "Vision", capabilities: .init(
                    text: .init(support: .supported, provenance: .userDeclared),
                    vision: .init(support: .supported, provenance: .userDeclared),
                    streaming: .init(support: .supported, provenance: .userDeclared)
                )),
            ]
        )
        let referenceID = UUID()
        profile.credentialReferences = [.init(
            id: referenceID,
            headerName: "X-Tenant-Token",
            keychainAccount: profile.additionalSecretAccount(referenceID: referenceID)
        )]
        profile.selectedModelID = profile.models[1].id

        let json = try CustomProviderProfileCodec.encode(profile)
        let imported = try CustomProviderProfileCodec.decode(json)

        XCTAssertEqual(imported.profile.displayName, profile.displayName)
        XCTAssertEqual(imported.profile.baseURL, profile.baseURL)
        XCTAssertEqual(imported.profile.authScheme, .xAPIKey)
        XCTAssertEqual(imported.profile.modelName, "vision-model")
        XCTAssertEqual(imported.profile.models.map(\.apiModelID), ["chat-model", "vision-model"])
        XCTAssertEqual(imported.profile.credentialReferences.map(\.headerName), ["X-Tenant-Token"])
        XCTAssertEqual(imported.origin, "https://gateway.example")
        XCTAssertFalse(json.contains("\"apiKey\":"))
        XCTAssertFalse(json.contains(profile.id.uuidString))
        XCTAssertFalse(json.contains(referenceID.uuidString))
        XCTAssertFalse(json.contains("api-key.custom"))
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
            validJSON.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
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

    func testUnknownProtocolAndNestedModelFieldAreRejected() {
        XCTAssertThrowsError(try CustomProviderProfileCodec.decode(
            validJSON.replacingOccurrences(of: "openAIChatCompletions", with: "imaginaryProtocol")
        ))
        let nested = """
        {"schemaVersion":2,"displayName":"Gateway","baseURL":"https://gateway.example/v1","protocolKind":"openAIResponses","authScheme":"bearer","models":[{"modelID":"chat-model","command":"do-not-run"}],"additionalSecretHeaderNames":[]}
        """
        XCTAssertThrowsError(try CustomProviderProfileCodec.decode(nested)) { error in
            XCTAssertEqual(error as? CustomProviderProfileImportError, .unknownField("models.command"))
        }
    }

    func testReservedImportedSecretHeadersAreRejected() {
        let json = """
        {"schemaVersion":2,"displayName":"Gateway","baseURL":"https://gateway.example/v1","protocolKind":"openAIResponses","authScheme":"bearer","models":[{"modelID":"chat-model"}],"additionalSecretHeaderNames":["Host"]}
        """
        XCTAssertThrowsError(try CustomProviderProfileCodec.decode(json))
    }

    func testSelectedModelMustExistAndModelIDsMustBeUnique() {
        let missingSelection = """
        {"schemaVersion":2,"displayName":"Gateway","baseURL":"https://gateway.example/v1","protocolKind":"openAIResponses","authScheme":"bearer","models":[{"modelID":"chat-model"}],"selectedModel":"missing-model","additionalSecretHeaderNames":[]}
        """
        XCTAssertThrowsError(try CustomProviderProfileCodec.decode(missingSelection))

        let duplicateModels = """
        {"schemaVersion":2,"displayName":"Gateway","baseURL":"https://gateway.example/v1","protocolKind":"openAIResponses","authScheme":"bearer","models":[{"modelID":"chat-model"},{"modelID":"chat-model"}],"selectedModel":"chat-model","additionalSecretHeaderNames":[]}
        """
        XCTAssertThrowsError(try CustomProviderProfileCodec.decode(duplicateModels))
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
        let additionalSecretHeaders = ["X-Tenant-Token", "X-Organization-Secret"]
        for header in additionalSecretHeaders {
            XCTAssertNoThrow(try CustomSecretHeaderPolicy.normalized(header))
            XCTAssertFalse(SameOriginRedirectDelegate.permitsRedirect(from: source, to: otherOrigin), header)
            XCTAssertTrue(SameOriginRedirectDelegate.permitsRedirect(from: source, to: sameOrigin), header)
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
