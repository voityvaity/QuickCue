import Foundation

typealias SecretHeadersReader = @Sendable () throws -> [String: String]

enum CustomSecretHeaderPolicy {
    private static let forbidden = Set([
        "host", "content-length", "content-type", "accept",
        "authorization", "api-key", "x-api-key",
    ])

    static func normalized(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              name.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar.value == 45)
              }), !forbidden.contains(name.lowercased()) else {
            throw AIProviderError.invalidConfiguration(
                "Недопустимое имя секретного заголовка. Host, Content-Length и служебные заголовки QuickCue изменять нельзя."
            )
        }
        return name
    }
}

/// Custom endpoint adapter. The historical name remains source-compatible with B3a.
struct CustomOpenAIProvider: AIProvider {
    let kind: ProviderKind = .custom
    let selection: ProviderSelection
    let modelName: String
    let capabilities: ProviderCapabilities

    private let profile: CustomProviderProfile
    private let credential: CredentialReader
    private let additionalHeaders: SecretHeadersReader
    private let transport: SSETransport

    init(
        profile: CustomProviderProfile,
        credential: @escaping CredentialReader,
        additionalHeaders: @escaping SecretHeadersReader = { [:] },
        transport: SSETransport = .init()
    ) {
        self.profile = profile
        self.selection = profile.selection
        self.modelName = profile.modelName
        self.credential = credential
        self.additionalHeaders = additionalHeaders
        self.transport = transport
        self.capabilities = ProviderCapabilities(
            supportsText: true,
            supportsImages: profile.selectedModel?.capabilities.vision.support == .supported,
            supportsStreaming: true
        )
    }

    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AIProviderError.invalidConfiguration("Укажите ID модели для этого провайдера.")
                    }
                    guard request.imageJPEG == nil || capabilities.supportsImages else {
                        throw AIProviderError.unsupportedImage(.custom)
                    }
                    guard let key = try credential(), !key.isEmpty else {
                        throw AIProviderError.missingCredential(.custom)
                    }
                    let endpoint = try Self.endpoint(from: profile.baseURL, protocolKind: profile.protocolKind)
                    var headers = profile.authScheme.headers(credential: key)
                    for (name, value) in try additionalHeaders() {
                        let normalized = try CustomSecretHeaderPolicy.normalized(name)
                        guard !value.isEmpty, headers.keys.allSatisfy({ $0.caseInsensitiveCompare(normalized) != .orderedSame }) else {
                            throw AIProviderError.invalidConfiguration("Секретный заголовок пуст или дублирует авторизацию.")
                        }
                        headers[normalized] = value
                    }
                    let body: [String: Any]
                    switch profile.protocolKind {
                    case .openAIChatCompletions:
                        body = Self.chatCompletionsBody(request: request, model: modelName)
                    case .openAIResponses:
                        body = Self.responsesBody(request: request, model: modelName)
                    case .anthropicMessages:
                        body = Self.anthropicBody(request: request, model: modelName)
                        if headers.keys.allSatisfy({ $0.caseInsensitiveCompare("anthropic-version") != .orderedSame }) {
                            headers["anthropic-version"] = "2023-06-01"
                        }
                    }
                    let urlRequest = try makeAuthorizedRequest(url: endpoint, body: body, headers: headers)
                    var validator = StreamCompletionValidator()
                    defer { LatencyLogger().streamSummary(provider: kind, requestID: request.id, validator: validator) }

                    switch profile.protocolKind {
                    case .openAIChatCompletions:
                        var decoder = ChatCompletionStreamDecoder()
                        chatLoop: for try await message in transport.stream(urlRequest, requestID: request.id) {
                            for event in try decoder.events(for: message) {
                                validator.observe(event)
                                continuation.yield(event)
                                if case .completed = event { break chatLoop }
                            }
                        }
                        try decoder.finish()

                    case .openAIResponses:
                        responsesLoop: for try await message in transport.stream(urlRequest, requestID: request.id) {
                            for event in try parseResponsesEvent(message) {
                                validator.observe(event)
                                continuation.yield(event)
                                if case .completed = event { break responsesLoop }
                            }
                        }

                    case .anthropicMessages:
                        var decoder = AnthropicStreamDecoder()
                        anthropicLoop: for try await message in transport.stream(urlRequest, requestID: request.id) {
                            for event in try decoder.events(for: message) {
                                validator.observe(event)
                                continuation.yield(event)
                                if case .completed = event { break anthropicLoop }
                            }
                        }
                    }
                    try validator.validate()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func endpoint(from input: String, protocolKind: CustomProviderProtocol) throws -> URL {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw AIProviderError.invalidConfiguration("Укажите Base URL провайдера.") }
        if !raw.contains("://") { raw = "https://\(raw)" }
        guard var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AIProviderError.invalidConfiguration("Base URL должен быть безопасным HTTPS-адресом без логина, пароля и параметров.")
        }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = protocolKind.endpointSuffix
        if path.hasSuffix(suffix) {
            // Full endpoint supplied.
        } else if path.hasSuffix("v1") {
            path += "/\(suffix)"
        } else if path.isEmpty {
            path = "v1/\(suffix)"
        } else {
            path += "/v1/\(suffix)"
        }
        components.path = "/\(path)"
        guard let url = components.url else {
            throw AIProviderError.invalidConfiguration("Не удалось составить адрес \(protocolKind.title).")
        }
        return url
    }

    static func chatCompletionsEndpoint(from input: String) throws -> URL {
        try endpoint(from: input, protocolKind: .openAIChatCompletions)
    }

    static func modelsEndpoint(
        from input: String,
        protocolKind: CustomProviderProtocol = .openAIChatCompletions
    ) throws -> URL {
        guard protocolKind.supportsModelDiscovery else {
            throw AIProviderError.invalidConfiguration("Этот протокол не предоставляет стандартный каталог /models.")
        }
        let apiEndpoint = try endpoint(from: input, protocolKind: protocolKind)
        guard var components = URLComponents(url: apiEndpoint, resolvingAgainstBaseURL: false) else {
            throw AIProviderError.invalidConfiguration("Не удалось составить адрес каталога моделей.")
        }
        var parts = components.path.split(separator: "/").map(String.init)
        switch protocolKind {
        case .openAIChatCompletions:
            guard parts.count >= 2, Array(parts.suffix(2)) == ["chat", "completions"] else {
                throw AIProviderError.invalidConfiguration("Не удалось составить адрес каталога моделей.")
            }
            parts.removeLast(2)
        case .openAIResponses:
            guard parts.last == "responses" else {
                throw AIProviderError.invalidConfiguration("Не удалось составить адрес каталога моделей.")
            }
            parts.removeLast()
        case .anthropicMessages:
            throw AIProviderError.invalidConfiguration("Этот протокол не предоставляет стандартный каталог /models.")
        }
        parts.append("models")
        components.path = "/" + parts.joined(separator: "/")
        guard let url = components.url else {
            throw AIProviderError.invalidConfiguration("Не удалось составить адрес каталога моделей.")
        }
        return url
    }

    private static func chatCompletionsBody(request: AIRequest, model: String) -> [String: Any] {
        let userContent: Any
        if let image = request.imageJPEG {
            userContent = [
                ["type": "text", "text": PromptFactory.userText(for: request)],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]],
            ]
        } else {
            userContent = PromptFactory.userText(for: request)
        }
        return [
            "model": model,
            "messages": [
                ["role": "system", "content": PromptFactory.systemText(for: request)],
                ["role": "user", "content": userContent],
            ],
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": request.maxOutputTokens,
            "temperature": 0.2,
        ]
    }

    private static func responsesBody(request: AIRequest, model: String) -> [String: Any] {
        var content: [[String: Any]] = [["type": "input_text", "text": PromptFactory.userText(for: request)]]
        if let image = request.imageJPEG {
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(image.base64EncodedString())"])
        }
        return [
            "model": model,
            "instructions": PromptFactory.systemText(for: request),
            "input": [["role": "user", "content": content]],
            "stream": true,
            "store": false,
            "max_output_tokens": request.maxOutputTokens,
        ]
    }

    private static func anthropicBody(request: AIRequest, model: String) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": PromptFactory.userText(for: request)]]
        if let image = request.imageJPEG {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()],
            ])
        }
        return [
            "model": model,
            "system": PromptFactory.systemText(for: request),
            "messages": [["role": "user", "content": content]],
            "max_tokens": request.maxOutputTokens,
            "thinking": ["type": "disabled"],
            "stream": true,
        ]
    }
}
