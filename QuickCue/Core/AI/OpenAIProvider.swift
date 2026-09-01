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
                    for try await message in transport.stream(urlRequest) {
                        guard let json = JSONValue.object(message.data), let type = json["type"] as? String else { continue }
                        if type == "response.output_text.delta", let delta = json["delta"] as? String {
                            continuation.yield(.textDelta(delta))
                        } else if type == "response.completed" {
                            if let response = json["response"] as? [String: Any],
                               let usage = response["usage"] as? [String: Any] {
                                continuation.yield(.usage(TokenUsage(
                                    inputTokens: JSONValue.int(usage["input_tokens"]),
                                    outputTokens: JSONValue.int(usage["output_tokens"])
                                )))
                            }
                            continuation.yield(.completed)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

