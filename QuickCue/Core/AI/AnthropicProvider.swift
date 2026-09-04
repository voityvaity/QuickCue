import Foundation

struct AnthropicProvider: AIProvider {
    let kind: ProviderKind = .anthropic
    let modelName: String
    let capabilities = ProviderCapabilities(supportsText: true, supportsImages: true, supportsStreaming: true)
    private let credential: CredentialReader
    private let transport: SSETransport

    init(modelName: String, credential: @escaping CredentialReader, transport: SSETransport = .init()) {
        self.modelName = modelName
        self.credential = credential
        self.transport = transport
    }

    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = try credential(), !key.isEmpty else {
                        throw AIProviderError.missingCredential(.anthropic)
                    }
                    var content: [[String: Any]] = [["type": "text", "text": PromptFactory.userText(for: request)]]
                    if let image = request.imageJPEG {
                        content.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": image.base64EncodedString(),
                            ],
                        ])
                    }
                    let body: [String: Any] = [
                        "model": modelName,
                        "system": PromptFactory.systemText(for: request),
                        "messages": [["role": "user", "content": content]],
                        "max_tokens": request.maxOutputTokens,
                        "thinking": ["type": "disabled"],
                        "stream": true,
                    ]
                    let urlRequest = try makeAuthorizedRequest(
                        url: URL(string: "https://api.anthropic.com/v1/messages")!,
                        body: body,
                        headers: [
                            "x-api-key": key,
                            "anthropic-version": "2023-06-01",
                        ]
                    )
                    var decoder = AnthropicStreamDecoder()
                    var validator = StreamCompletionValidator()
                    defer { LatencyLogger().streamSummary(provider: kind, requestID: request.id, validator: validator) }
                    streamLoop: for try await message in transport.stream(urlRequest, requestID: request.id) {
                        for event in try decoder.events(for: message) {
                            validator.observe(event)
                            continuation.yield(event)
                            if case .completed = event { break streamLoop }
                        }
                    }
                    try validator.validate()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
