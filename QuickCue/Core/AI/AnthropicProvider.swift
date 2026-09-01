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
                    for try await message in transport.stream(urlRequest) {
                        guard let json = JSONValue.object(message.data), let type = json["type"] as? String else { continue }
                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String {
                            continuation.yield(.textDelta(text))
                        } else if type == "message_delta",
                                  let usage = json["usage"] as? [String: Any] {
                            continuation.yield(.usage(TokenUsage(
                                inputTokens: 0,
                                outputTokens: JSONValue.int(usage["output_tokens"])
                            )))
                        } else if type == "message_stop" {
                            continuation.yield(.completed)
                        } else if type == "error" {
                            let detail = (json["error"] as? [String: Any])?["message"] as? String ?? "Ошибка потока Claude"
                            throw AIProviderError.badResponse(200, detail)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
