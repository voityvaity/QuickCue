import Foundation

enum CustomProviderProfileImportError: LocalizedError, Equatable {
    case tooLarge
    case invalidDocument
    case unsupportedVersion
    case unknownField(String)
    case invalidProfile(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            "Файл настроек слишком большой. Максимум — 64 КБ."
        case .invalidDocument:
            "Не удалось прочитать настройки провайдера. Нужен JSON-профиль QuickCue."
        case .unsupportedVersion:
            "Эта версия профиля пока не поддерживается QuickCue."
        case .unknownField(let field):
            "Профиль содержит неподдерживаемое поле «\(field)»."
        case .invalidProfile(let detail):
            detail
        }
    }
}

struct CustomProviderImportModel: Codable, Equatable, Sendable {
    let modelID: String
    let displayName: String?
    let supportsImages: Bool?
}

struct CustomProviderImportDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let displayName: String
    let baseURL: String
    let protocolKind: CustomProviderProtocol
    let authScheme: CustomAuthScheme
    let modelID: String?
    let models: [CustomProviderImportModel]?
    let selectedModel: String?
    let additionalSecretHeaderNames: [String]?
}

struct CustomProviderImportPreview: Equatable, Sendable {
    let profile: CustomProviderProfile
    let origin: String
    let endpoint: String

    var protocolTitle: String { profile.protocolKind.title }
    var dataDisclosure: String {
        profile.selectedModel?.capabilities.vision.support == .supported
            ? "Текст запросов и выбранные изображения"
            : "Текст запросов; изображения не отправляются этой модели"
    }
}

enum CustomProviderProfileCodec {
    static let maximumBytes = 65_536
    private static let allowedFields: Set<String> = [
        "schemaVersion", "displayName", "baseURL", "protocolKind", "authScheme", "modelID",
        "models", "selectedModel", "additionalSecretHeaderNames",
    ]

    static func decode(_ text: String, profileID: UUID = UUID()) throws -> CustomProviderImportPreview {
        guard let data = text.data(using: .utf8), data.count <= maximumBytes else {
            throw CustomProviderProfileImportError.tooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CustomProviderProfileImportError.invalidDocument
        }
        guard let dictionary = object as? [String: Any] else {
            throw CustomProviderProfileImportError.invalidDocument
        }
        if let unknown = Set(dictionary.keys).subtracting(allowedFields).sorted().first {
            throw CustomProviderProfileImportError.unknownField(unknown)
        }
        if let rawModels = dictionary["models"] as? [[String: Any]] {
            let allowedModelFields = Set(["modelID", "displayName", "supportsImages"])
            for model in rawModels {
                if let unknown = Set(model.keys).subtracting(allowedModelFields).sorted().first {
                    throw CustomProviderProfileImportError.unknownField("models.\(unknown)")
                }
            }
        }

        let document: CustomProviderImportDocument
        do {
            document = try JSONDecoder().decode(CustomProviderImportDocument.self, from: data)
        } catch {
            throw CustomProviderProfileImportError.invalidDocument
        }
        guard [1, 2].contains(document.schemaVersion) else {
            throw CustomProviderProfileImportError.unsupportedVersion
        }
        let models: [ModelProfile]
        if document.schemaVersion == 1 {
            guard let modelID = document.modelID else { throw CustomProviderProfileImportError.invalidDocument }
            models = [ModelProfile(apiModelID: modelID)]
        } else {
            guard let imported = document.models, !imported.isEmpty, imported.count <= 100 else {
                throw CustomProviderProfileImportError.invalidDocument
            }
            models = imported.map { item in
                let capabilities = ProviderModelCapabilities(
                    text: .init(support: .supported, provenance: .userDeclared),
                    vision: .init(
                        support: item.supportsImages == true ? .supported : .unknown,
                        provenance: item.supportsImages == nil ? .unknown : .userDeclared
                    ),
                    streaming: .init(support: .supported, provenance: .userDeclared)
                )
                return ModelProfile(
                    apiModelID: item.modelID,
                    displayName: item.displayName ?? item.modelID,
                    capabilities: capabilities,
                    selectionPolicy: .explicit(item.modelID)
                )
            }
        }
        let selectedModelID: UUID?
        if let requested = document.selectedModel {
            guard let selected = models.first(where: { $0.apiModelID == requested }) else {
                throw CustomProviderProfileImportError.invalidProfile("Выбранная модель отсутствует в списке профиля.")
            }
            selectedModelID = selected.id
        } else {
            selectedModelID = models.first?.id
        }
        var profile = CustomProviderProfile(
            id: profileID,
            displayName: document.displayName,
            baseURL: document.baseURL,
            protocolKind: document.protocolKind,
            authScheme: document.authScheme,
            models: models,
            selectedModelID: selectedModelID
        )
        var seenHeaders = Set<String>()
        for rawName in document.additionalSecretHeaderNames ?? [] {
            let name = try CustomSecretHeaderPolicy.normalized(rawName)
            guard seenHeaders.insert(name.lowercased()).inserted else {
                throw CustomProviderProfileImportError.invalidProfile("Имена секретных заголовков не должны повторяться.")
            }
            let referenceID = UUID()
            profile.credentialReferences.append(.init(
                id: referenceID,
                headerName: name,
                keychainAccount: profile.additionalSecretAccount(referenceID: referenceID)
            ))
        }
        return try preview(for: profile)
    }

    static func encode(_ profile: CustomProviderProfile) throws -> String {
        let preview = try preview(for: profile)
        let document = CustomProviderImportDocument(
            schemaVersion: 2,
            displayName: preview.profile.displayName,
            baseURL: preview.profile.baseURL,
            protocolKind: preview.profile.protocolKind,
            authScheme: preview.profile.authScheme,
            modelID: nil,
            models: preview.profile.models.map { model in
                CustomProviderImportModel(
                    modelID: model.apiModelID,
                    displayName: model.displayName,
                    supportsImages: model.capabilities.vision.support == .supported ? true : nil
                )
            },
            selectedModel: preview.profile.selectedModel?.apiModelID,
            additionalSecretHeaderNames: preview.profile.credentialReferences.map(\.headerName)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CustomProviderProfileImportError.invalidDocument
        }
        return value
    }

    static func preview(for profile: CustomProviderProfile) throws -> CustomProviderImportPreview {
        var cleaned = profile
        cleaned.displayName = cleaned.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.baseURL = cleaned.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.models = cleaned.models.map { model in
            var value = model
            value.apiModelID = model.apiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            value.displayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return value
        }
        guard !cleaned.displayName.isEmpty, cleaned.displayName.count <= 80 else {
            throw CustomProviderProfileImportError.invalidProfile("Укажите название сервиса длиной до 80 символов.")
        }
        guard !cleaned.models.isEmpty, cleaned.models.count <= 100,
              cleaned.models.allSatisfy({ !$0.apiModelID.isEmpty && $0.apiModelID.count <= 160
                  && !$0.apiModelID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw CustomProviderProfileImportError.invalidProfile("Укажите корректный ID модели длиной до 160 символов.")
        }
        guard Set(cleaned.models.map(\.apiModelID)).count == cleaned.models.count else {
            throw CustomProviderProfileImportError.invalidProfile("ID моделей в одном профиле не должны повторяться.")
        }
        var seenHeaders = Set<String>()
        for reference in cleaned.credentialReferences {
            let name = try CustomSecretHeaderPolicy.normalized(reference.headerName)
            guard reference.keychainAccount == cleaned.additionalSecretAccount(referenceID: reference.id),
                  seenHeaders.insert(name.lowercased()).inserted else {
                throw CustomProviderProfileImportError.invalidProfile("Повреждена ссылка на секретный заголовок.")
            }
        }
        guard let suppliedURL = URLComponents(string: cleaned.baseURL),
              suppliedURL.scheme?.lowercased() == "https",
              suppliedURL.host?.isEmpty == false,
              suppliedURL.user == nil, suppliedURL.password == nil,
              suppliedURL.query == nil, suppliedURL.fragment == nil else {
            throw CustomProviderProfileImportError.invalidProfile(
                "Base URL должен быть безопасным HTTPS-адресом без логина, пароля и параметров."
            )
        }
        let endpoint: URL
        do {
            endpoint = try CustomOpenAIProvider.endpoint(from: cleaned.baseURL, protocolKind: cleaned.protocolKind)
        } catch {
            throw CustomProviderProfileImportError.invalidProfile(error.localizedDescription)
        }
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw CustomProviderProfileImportError.invalidProfile("Не удалось определить владельца адреса API.")
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return CustomProviderImportPreview(
            profile: cleaned,
            origin: "https://\(host)\(port)",
            endpoint: endpoint.absoluteString
        )
    }
}
