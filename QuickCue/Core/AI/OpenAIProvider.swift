import Foundation

struct OpenAIProvider: AIProvider {
    let kind: ProviderKind = .openAI
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
                        throw AIProviderError.missingCredential(.openAI)
                    }
                    let userContent: [[String: Any]]
                    if let image = request.imageJPEG {
                        userContent = [
                            ["type": "input_text", "text": PromptFactory.userText(for: request)],
                            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(image.base64EncodedString())"],
                        ]
                    } else {
                        userContent = [["type": "input_text", "text": PromptFactory.userText(for: request)]]
                    }
                    let body: [String: Any] = [
                        "model": modelName,
                        "instructions": PromptFactory.systemText(for: request),
                        "input": [["role": "user", "content": userContent]],
                        "stream": true,
                        "store": false,
                        "max_output_tokens": request.maxOutputTokens,
                    ]
                    let urlRequest = try makeAuthorizedRequest(
                        url: URL(string: "https://api.openai.com/v1/responses")!,
                        body: body,
                        headers: ["Authorization": "Bearer \(key)"]
                    )
                    var validator = StreamCompletionValidator()
                    defer { LatencyLogger().streamSummary(provider: kind, requestID: request.id, validator: validator) }
                    streamLoop: for try await message in transport.stream(urlRequest, requestID: request.id) {
                        for event in try parseResponsesEvent(message) {
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

