import Foundation

struct YandexGPTProvider: AIProvider {
    let kind: ProviderKind = .yandexGPT
    let modelName: String
    let capabilities = ProviderCapabilities(supportsText: true, supportsImages: false, supportsStreaming: true)
    private let folderID: String
    private let credential: CredentialReader
    private let transport: SSETransport

    init(modelName: String, folderID: String, credential: @escaping CredentialReader, transport: SSETransport = .init()) {
        self.modelName = modelName
        self.folderID = folderID
        self.credential = credential
        self.transport = transport
    }

    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !folderID.isEmpty else {
                        throw AIProviderError.invalidConfiguration("Для YandexGPT укажите Folder ID в Настройках.")
                    }
                    guard let key = try credential(), !key.isEmpty else {
                        throw AIProviderError.missingCredential(.yandexGPT)
                    }
                    let modelURI = modelName.hasPrefix("gpt://") ? modelName : "gpt://\(folderID)/\(modelName)"
                    let body = openAICompatibleBody(request: request, model: modelURI)
                    let urlRequest = try makeAuthorizedRequest(
                        url: URL(string: "https://ai.api.cloud.yandex.net/v1/chat/completions")!,
                        body: body,
                        headers: [
                            "Authorization": "Api-Key \(key)",
                            "x-folder-id": folderID,
                        ]
                    )
                    for try await message in transport.stream(urlRequest) {
                        for event in parseChatCompletionEvent(message) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
