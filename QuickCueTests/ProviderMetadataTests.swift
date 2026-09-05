import Foundation
import XCTest
@testable import QuickCue

@MainActor
final class ProviderMetadataTests: XCTestCase {
    func testDeepSeekUsesOfficialModelsEndpointAndDoesNotSelectFirstItem() async throws {
        let recorder = MetadataRequestRecorder()
        let body = Data("""
        {
          "object": "list",
          "data": [
            {"id":"embedding-first","object":"model","owned_by":"deepseek"},
            {"id":"deepseek-v4-flash-vision-exp","object":"model","owned_by":"deepseek"},
            {"id":"deepseek-v4-flash","object":"model","owned_by":"deepseek"}
          ]
        }
        """.utf8)
        let client = ProviderMetadataClient(transport: ProviderMetadataTransport { request, _ in
            await recorder.record(request)
            return .init(statusCode: 200, mimeType: "application/json", data: body)
        })

        let result = try await client.metadata(
            for: .builtIn(.deepSeek),
            credential: { "fixture-token" }
        )

        let snapshot = try availableSnapshot(from: result)
        XCTAssertEqual(
            ProviderModelSelector.select(from: snapshot, policy: .recommended, provider: .deepSeek),
            "deepseek-v4-flash"
        )
        XCTAssertEqual(snapshot.models[0].capabilities.text.support, .unknown)
        XCTAssertTrue(snapshot.models[1].isExperimental)
        XCTAssertEqual(snapshot.models[2].capabilities.text.provenance, .preset)
        let recordedRequest = await recorder.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertNil(request.httpBody)
    }

    func testCustom404MeansUnsupportedAndUsesDerivedModelsEndpoint() async throws {
        let recorder = MetadataRequestRecorder()
        let profile = CustomProviderProfile(
            baseURL: "https://gateway.example/api/chat/completions",
            authScheme: .apiKey,
            modelName: "manual-model"
        )
        let client = ProviderMetadataClient(transport: ProviderMetadataTransport { request, _ in
            await recorder.record(request)
            return .init(statusCode: 404, mimeType: "application/json", data: Data())
        })

        let result = try await client.metadata(
            for: profile.selection,
            customProfile: profile,
            credential: { "fixture-token" }
        )

        XCTAssertEqual(result, .unsupported)
        let recordedRequest = await recorder.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/api/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Api-Key fixture-token")
    }

    func testUnsupportedYandexCatalogDoesNotReadCredential() async throws {
        let client = ProviderMetadataClient(transport: ProviderMetadataTransport { _, _ in
            XCTFail("Unsupported provider must not perform a request")
            return .init(statusCode: 500, mimeType: nil, data: Data())
        })

        let result = try await client.metadata(
            for: .builtIn(.yandexGPT),
            credential: { throw MetadataFixtureError.credentialRead }
        )

        XCTAssertEqual(result, .unsupported)
    }

    func testOversizedResponseIsUnavailableWithoutDecodingBody() async throws {
        let client = ProviderMetadataClient(
            transport: ProviderMetadataTransport { _, _ in
                .init(statusCode: 200, mimeType: "application/json", data: Data(repeating: 65, count: 33))
            },
            maxResponseBytes: 32
        )

        let result = try await client.metadata(
            for: .builtIn(.deepSeek),
            credential: { "fixture-token" }
        )

        XCTAssertEqual(result, .unavailable(.responseTooLarge))
    }

    func testCancelledURLSessionRemainsCancellation() async {
        let client = ProviderMetadataClient(transport: ProviderMetadataTransport { _, _ in
            throw URLError(.cancelled)
        })

        do {
            _ = try await client.metadata(
                for: .builtIn(.deepSeek),
                credential: { "fixture-token" }
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not be presented as catalog failure.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
    }

    func testExplicitSelectionNeverUsesCatalogReplacement() throws {
        let snapshot = ProviderMetadataSnapshot(
            models: [.init(id: "deepseek-v4-flash", ownedBy: nil, capabilities: .deepSeekText, isExperimental: false)],
            fetchedAt: .now,
            expiresAt: .now.addingTimeInterval(60)
        )

        XCTAssertEqual(
            ProviderModelSelector.select(from: snapshot, policy: .explicit(" my-private-model "), provider: .deepSeek),
            "my-private-model"
        )
        XCTAssertNil(
            ProviderModelSelector.select(from: snapshot, policy: .recommended, provider: .custom)
        )
    }

    func testMetadataCacheExpiresAndContainsNoCredential() throws {
        let suite = "ProviderMetadataTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = ProviderMetadataSnapshot(
            models: [.init(id: "deepseek-v4-flash", ownedBy: "deepseek", capabilities: .deepSeekText, isExperimental: false)],
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let cache = ProviderMetadataCache(defaults: defaults)

        cache.save(snapshot, for: .builtIn(.deepSeek), at: now)

        XCTAssertEqual(cache.freshSnapshot(for: .builtIn(.deepSeek), at: now.addingTimeInterval(59)), snapshot)
        XCTAssertNil(cache.freshSnapshot(for: .builtIn(.deepSeek), at: now.addingTimeInterval(60)))
        XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("fixture-token"))
    }

    private func availableSnapshot(from result: MetadataResult) throws -> ProviderMetadataSnapshot {
        guard case .available(let snapshot) = result else {
            throw MetadataFixtureError.notAvailable
        }
        return snapshot
    }
}

private actor MetadataRequestRecorder {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func lastRequest() -> URLRequest? {
        request
    }
}

private enum MetadataFixtureError: Error {
    case credentialRead
    case notAvailable
}
