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

struct CustomProviderImportDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let displayName: String
    let baseURL: String
    let protocolKind: CustomProviderProtocol
    let authScheme: CustomAuthScheme
    let modelID: String
}

struct CustomProviderImportPreview: Equatable, Sendable {
    let profile: CustomProviderProfile
    let origin: String
    let endpoint: String

    var protocolTitle: String { profile.protocolKind.title }
    var dataDisclosure: String { "Текст запросов; изображения не поддерживаются этим протоколом" }
}

enum CustomProviderProfileCodec {
    static let maximumBytes = 65_536
    private static let allowedFields: Set<String> = [
        "schemaVersion", "displayName", "baseURL", "protocolKind", "authScheme", "modelID",
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

        let document: CustomProviderImportDocument
        do {
            document = try JSONDecoder().decode(CustomProviderImportDocument.self, from: data)
        } catch {
            throw CustomProviderProfileImportError.invalidDocument
        }
        guard document.schemaVersion == 1 else {
            throw CustomProviderProfileImportError.unsupportedVersion
        }
        let profile = CustomProviderProfile(
            id: profileID,
            displayName: document.displayName,
            baseURL: document.baseURL,
            protocolKind: document.protocolKind,
            authScheme: document.authScheme,
            modelName: document.modelID
        )
        return try preview(for: profile)
    }

    static func encode(_ profile: CustomProviderProfile) throws -> String {
        let preview = try preview(for: profile)
        let document = CustomProviderImportDocument(
            schemaVersion: 1,
            displayName: preview.profile.displayName,
            baseURL: preview.profile.baseURL,
            protocolKind: preview.profile.protocolKind,
            authScheme: preview.profile.authScheme,
            modelID: preview.profile.modelName
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
        cleaned.modelName = cleaned.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.displayName.isEmpty, cleaned.displayName.count <= 80 else {
            throw CustomProviderProfileImportError.invalidProfile("Укажите название сервиса длиной до 80 символов.")
        }
        guard !cleaned.modelName.isEmpty, cleaned.modelName.count <= 160,
              !cleaned.modelName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CustomProviderProfileImportError.invalidProfile("Укажите корректный ID модели длиной до 160 символов.")
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
            endpoint = try CustomOpenAIProvider.chatCompletionsEndpoint(from: cleaned.baseURL)
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
