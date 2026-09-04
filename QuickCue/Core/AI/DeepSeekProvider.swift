import Foundation

struct DeepSeekProvider: AIProvider {
    let kind: ProviderKind = .deepSeek
    let modelName: String
    let capabilities = ProviderCapabilities(supportsText: true, supportsImages: false, supportsStreaming: true)
    private let credential: CredentialReader
    private let transport: SSETransport

    init(modelName: String, credential: @escaping CredentialReader, transport: SSETransport = .init()) {
        self.modelName = modelName
        self.credential = credential
        self.transport = transport
    }

    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        compatibleStream(
            request: request,
            provider: .deepSeek,
            modelName: modelName,
            endpoint: "https://api.deepseek.com/chat/completions",
            credential: credential,
            transport: transport,
            extraBody: ["thinking": ["type": "disabled"]]
        )
    }
}

func compatibleStream(
    request: AIRequest,
    provider: ProviderKind,
    modelName: String,
    endpoint: String,
    credential: @escaping CredentialReader,
    transport: SSETransport,
    headers: [String: String] = [:],
    extraBody: [String: Any] = [:]
) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                guard let key = try credential(), !key.isEmpty else { throw AIProviderError.missingCredential(provider) }
                var body = openAICompatibleBody(request: request, model: modelName)
                extraBody.forEach { body[$0.key] = $0.value }
                var requestHeaders = headers
                requestHeaders["Authorization"] = "Bearer \(key)"
                let urlRequest = try makeAuthorizedRequest(
                    url: URL(string: endpoint)!,
                    body: body,
                    headers: requestHeaders
                )
                var validator = StreamCompletionValidator()
                defer { LatencyLogger().streamSummary(provider: provider, requestID: request.id, validator: validator) }
                var decoder = ChatCompletionStreamDecoder()
                streamLoop: for try await message in transport.stream(urlRequest, requestID: request.id) {
                    for event in try decoder.events(for: message) {
                        validator.observe(event)
                        continuation.yield(event)
                        if case .completed = event { break streamLoop }
                    }
                }
                try decoder.finish()
                try validator.validate()
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
