import Foundation

struct XAIProvider: AIProvider {
    let kind: ProviderKind = .xAI
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
            provider: .xAI,
            modelName: modelName,
            endpoint: "https://api.x.ai/v1/chat/completions",
            credential: credential,
            transport: transport
        )
    }
}

