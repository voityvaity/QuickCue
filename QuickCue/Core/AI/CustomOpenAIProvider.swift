import Foundation

struct CustomOpenAIProvider: AIProvider {
    let kind: ProviderKind = .custom
    let selection: ProviderSelection
    let modelName: String
    let capabilities = ProviderCapabilities(
        supportsText: true,
        supportsImages: false,
        supportsStreaming: true
    )

    private let profile: CustomProviderProfile
    private let credential: CredentialReader
    private let transport: SSETransport

    init(
        profile: CustomProviderProfile,
        credential: @escaping CredentialReader,
        transport: SSETransport = .init()
    ) {
        self.profile = profile
        self.selection = profile.selection
        self.modelName = profile.modelName
        self.credential = credential
        self.transport = transport
    }

    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AIProviderError.invalidConfiguration("Укажите ID модели для этого провайдера.")
                    }
                    guard let key = try credential(), !key.isEmpty else {
                        throw AIProviderError.missingCredential(.custom)
                    }
                    let endpoint = try Self.chatCompletionsEndpoint(from: profile.baseURL)
                    let authorization: String
                    switch profile.authScheme {
                    case .bearer: authorization = "Bearer \(key)"
                    case .apiKey: authorization = "Api-Key \(key)"
                    }
                    let urlRequest = try makeAuthorizedRequest(
                        url: endpoint,
                        body: openAICompatibleBody(request: request, model: modelName),
                        headers: ["Authorization": authorization]
                    )
                    for try await message in transport.stream(urlRequest) {
                        for event in parseChatCompletionEvent(message) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func chatCompletionsEndpoint(from input: String) throws -> URL {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw AIProviderError.invalidConfiguration("Укажите Base URL провайдера.")
        }
        if !raw.contains("://") { raw = "https://\(raw)" }
        guard var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AIProviderError.invalidConfiguration("Base URL должен быть безопасным HTTPS-адресом без логина, пароля и параметров.")
        }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") {
            // Пользователь указал полный endpoint.
        } else if path.hasSuffix("v1") {
            path += "/chat/completions"
        } else if path.isEmpty {
            path = "v1/chat/completions"
        } else {
            path += "/v1/chat/completions"
        }
        components.path = "/\(path)"

        guard let url = components.url else {
            throw AIProviderError.invalidConfiguration("Не удалось составить адрес Chat Completions.")
        }
        return url
    }
}
