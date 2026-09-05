import Foundation

enum CapabilitySupport: String, Codable, Sendable {
    case supported
    case unsupported
    case unknown
}

enum CapabilityProvenance: String, Codable, Sendable {
    case preset
    case userDeclared
    case discovered
    case tested
    case unknown
}

struct ModelCapabilityEvidence: Codable, Equatable, Sendable {
    let support: CapabilitySupport
    let provenance: CapabilityProvenance

    static let unknown = Self(support: .unknown, provenance: .unknown)
    static let presetSupported = Self(support: .supported, provenance: .preset)
    static let presetUnsupported = Self(support: .unsupported, provenance: .preset)
}

struct ProviderModelCapabilities: Codable, Equatable, Sendable {
    let text: ModelCapabilityEvidence
    let vision: ModelCapabilityEvidence
    let streaming: ModelCapabilityEvidence

    static let unknown = Self(text: .unknown, vision: .unknown, streaming: .unknown)
    static let deepSeekText = Self(
        text: .presetSupported,
        vision: .presetUnsupported,
        streaming: .presetSupported
    )
}

struct ProviderModelMetadata: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let ownedBy: String?
    let capabilities: ProviderModelCapabilities
    let isExperimental: Bool
}

struct ProviderMetadataSnapshot: Codable, Equatable, Sendable {
    let models: [ProviderModelMetadata]
    let fetchedAt: Date
    let expiresAt: Date

    func isFresh(at date: Date) -> Bool {
        expiresAt > date
    }
}

enum ProviderMetadataUnavailableReason: String, Codable, Equatable, Sendable {
    case credentialMissing
    case unauthorized
    case forbidden
    case rateLimited
    case offline
    case timedOut
    case rejectedURL
    case invalidResponse
    case responseTooLarge
    case server
}

enum MetadataResult: Equatable, Sendable {
    case available(ProviderMetadataSnapshot)
    case unsupported
    case unavailable(ProviderMetadataUnavailableReason)
}

enum ModelSelectionPolicy: Codable, Equatable, Sendable {
    case recommended
    case explicit(String)
}

enum ProviderMetadataStatus: Equatable, Sendable {
    case notRequested
    case explicit
    case cached
    case discovered
    case unsupported
    case unavailable(ProviderMetadataUnavailableReason)
    case noRecommendedModel
}

enum ProviderModelSelector {
    private static let recommendedModels: [ProviderKind: [String]] = [
        .deepSeek: ["deepseek-v4-flash", "deepseek-v4-pro"],
    ]

    static func select(
        from snapshot: ProviderMetadataSnapshot,
        policy: ModelSelectionPolicy,
        provider: ProviderKind
    ) -> String? {
        switch policy {
        case .explicit(let model):
            let cleaned = model.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        case .recommended:
            var modelsByID: [String: ProviderModelMetadata] = [:]
            for model in snapshot.models where modelsByID[model.id] == nil {
                modelsByID[model.id] = model
            }
            return recommendedModels[provider, default: []].first { id in
                guard let model = modelsByID[id] else { return false }
                return !model.isExperimental && model.capabilities.text.support == .supported
            }
        }
    }

    static func isExperimental(modelID: String) -> Bool {
        let id = modelID.lowercased()
        return ["experimental", "preview", "beta", "-exp", "_exp"].contains { id.contains($0) }
    }
}

struct ProviderMetadataHTTPResponse: Sendable {
    let statusCode: Int
    let mimeType: String?
    let data: Data
}

enum ProviderMetadataTransportFailure: Error {
    case invalidResponse
    case responseTooLarge
}

struct ProviderMetadataTransport: @unchecked Sendable {
    typealias Loader = @Sendable (URLRequest, Int) async throws -> ProviderMetadataHTTPResponse

    private let session: URLSession
    private let loader: Loader?

    init(session: URLSession = .shared) {
        self.session = session
        self.loader = nil
    }

    init(loader: @escaping Loader) {
        self.session = .shared
        self.loader = loader
    }

    func load(_ request: URLRequest, maxBytes: Int) async throws -> ProviderMetadataHTTPResponse {
        if let loader {
            let response = try await loader(request, maxBytes)
            guard response.data.count <= maxBytes else {
                throw ProviderMetadataTransportFailure.responseTooLarge
            }
            return response
        }

        let delegate = SameOriginRedirectDelegate()
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderMetadataTransportFailure.invalidResponse
        }
        if http.expectedContentLength > Int64(maxBytes) {
            throw ProviderMetadataTransportFailure.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, max(0, Int(http.expectedContentLength))))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maxBytes else {
                throw ProviderMetadataTransportFailure.responseTooLarge
            }
            data.append(byte)
        }
        try Task.checkCancellation()
        return ProviderMetadataHTTPResponse(
            statusCode: http.statusCode,
            mimeType: http.mimeType,
            data: data
        )
    }
}

struct ProviderMetadataClient: Sendable {
    private struct ModelsEnvelope: Decodable {
        struct Model: Decodable {
            let id: String
            let object: String?
            let ownedBy: String?

            enum CodingKeys: String, CodingKey {
                case id
                case object
                case ownedBy = "owned_by"
            }
        }

        let object: String?
        let data: [Model]
    }

    private let transport: ProviderMetadataTransport
    private let now: @Sendable () -> Date
    private let maxResponseBytes: Int
    private let maxModels: Int
    private let maxModelIDLength: Int
    private let cacheLifetime: TimeInterval

    init(
        transport: ProviderMetadataTransport = .init(),
        now: @escaping @Sendable () -> Date = { Date() },
        maxResponseBytes: Int = 262_144,
        maxModels: Int = 200,
        maxModelIDLength: Int = 160,
        cacheLifetime: TimeInterval = 86_400
    ) {
        self.transport = transport
        self.now = now
        self.maxResponseBytes = max(1, maxResponseBytes)
        self.maxModels = max(1, maxModels)
        self.maxModelIDLength = max(1, maxModelIDLength)
        self.cacheLifetime = max(60, cacheLifetime)
    }

    static func supportsDiscovery(for selection: ProviderSelection, customProfile: CustomProviderProfile? = nil) -> Bool {
        selection.kind == .deepSeek || (selection.customID != nil && customProfile != nil)
    }

    func metadata(
        for selection: ProviderSelection,
        customProfile: CustomProviderProfile? = nil,
        credential: CredentialReader
    ) async throws -> MetadataResult {
        guard Self.supportsDiscovery(for: selection, customProfile: customProfile) else {
            return .unsupported
        }
        guard let key = try credential(), !key.isEmpty else {
            return .unavailable(.credentialMissing)
        }
        let request: URLRequest
        do {
            request = try makeRequest(for: selection, customProfile: customProfile, key: key)
        } catch {
            return .unavailable(.rejectedURL)
        }

        do {
            let response = try await transport.load(request, maxBytes: maxResponseBytes)
            try Task.checkCancellation()
            if response.statusCode == 404, selection.customID != nil {
                return .unsupported
            }
            guard (200...299).contains(response.statusCode) else {
                return .unavailable(Self.failure(forHTTPStatus: response.statusCode))
            }
            if let mimeType = response.mimeType?.lowercased(),
               mimeType != "application/json", !mimeType.hasSuffix("+json") {
                return .unavailable(.invalidResponse)
            }
            guard response.data.count <= maxResponseBytes else {
                return .unavailable(.responseTooLarge)
            }
            let envelope: ModelsEnvelope
            do {
                envelope = try JSONDecoder().decode(ModelsEnvelope.self, from: response.data)
            } catch {
                return .unavailable(.invalidResponse)
            }
            guard envelope.data.count <= maxModels else {
                return .unavailable(.responseTooLarge)
            }
            if selection.kind == .deepSeek {
                guard envelope.object == "list", envelope.data.allSatisfy({ $0.object == "model" }) else {
                    return .unavailable(.invalidResponse)
                }
            }

            var seen = Set<String>()
            var models: [ProviderModelMetadata] = []
            for item in envelope.data {
                let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, id.count <= maxModelIDLength,
                      id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                    return .unavailable(.invalidResponse)
                }
                guard seen.insert(id).inserted else { continue }
                let knownDeepSeekTextModel = selection.kind == .deepSeek
                    && ["deepseek-v4-flash", "deepseek-v4-pro"].contains(id)
                models.append(ProviderModelMetadata(
                    id: id,
                    ownedBy: item.ownedBy,
                    capabilities: knownDeepSeekTextModel ? .deepSeekText : .unknown,
                    isExperimental: ProviderModelSelector.isExperimental(modelID: id)
                ))
            }
            let fetchedAt = now()
            return .available(ProviderMetadataSnapshot(
                models: models,
                fetchedAt: fetchedAt,
                expiresAt: fetchedAt.addingTimeInterval(cacheLifetime)
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch ProviderMetadataTransportFailure.responseTooLarge {
            return .unavailable(.responseTooLarge)
        } catch ProviderMetadataTransportFailure.invalidResponse {
            return .unavailable(.invalidResponse)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            return .unavailable(Self.failure(for: error))
        } catch {
            return .unavailable(.server)
        }
    }

    private func makeRequest(
        for selection: ProviderSelection,
        customProfile: CustomProviderProfile?,
        key: String
    ) throws -> URLRequest {
        let endpoint: URL
        let authorization: String
        switch selection.kind {
        case .deepSeek where selection.customID == nil:
            endpoint = URL(string: "https://api.deepseek.com/models")!
            authorization = "Bearer \(key)"
        case .custom:
            guard let profile = customProfile, profile.selection == selection else {
                throw AIProviderError.invalidConfiguration("Профиль провайдера не найден.")
            }
            endpoint = try CustomOpenAIProvider.modelsEndpoint(from: profile.baseURL)
            switch profile.authScheme {
            case .bearer: authorization = "Bearer \(key)"
            case .apiKey: authorization = "Api-Key \(key)"
            }
        default:
            throw AIProviderError.invalidConfiguration("Каталог моделей не поддерживается.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func failure(forHTTPStatus status: Int) -> ProviderMetadataUnavailableReason {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 429: .rateLimited
        default: .server
        }
    }

    private static func failure(for error: URLError) -> ProviderMetadataUnavailableReason {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: .offline
        case .timedOut: .timedOut
        case .badURL, .unsupportedURL, .userAuthenticationRequired: .rejectedURL
        default: .server
        }
    }
}

@MainActor
struct ProviderMetadataCache {
    private static let storageKey = "provider.metadata.cache.v1"
    private let defaults: UserDefaults
    private let maxEntries: Int

    init(defaults: UserDefaults = .standard, maxEntries: Int = 128) {
        self.defaults = defaults
        self.maxEntries = max(1, maxEntries)
    }

    func freshSnapshot(for selection: ProviderSelection, at date: Date = .now) -> ProviderMetadataSnapshot? {
        guard let snapshot = snapshots()[selection.rawValue], snapshot.isFresh(at: date) else { return nil }
        return snapshot
    }

    func save(_ snapshot: ProviderMetadataSnapshot, for selection: ProviderSelection, at date: Date = .now) {
        var values = snapshots().filter { $0.value.isFresh(at: date) }
        values[selection.rawValue] = snapshot
        if values.count > maxEntries {
            let retained = values.sorted { $0.value.expiresAt > $1.value.expiresAt }.prefix(maxEntries)
            values = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func snapshots() -> [String: ProviderMetadataSnapshot] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let values = try? JSONDecoder().decode([String: ProviderMetadataSnapshot].self, from: data) else {
            return [:]
        }
        return values
    }
}
