import Foundation

struct MockAIProvider: AIProvider {
    let kind: ProviderKind = .mock
    let modelName = "mock-fast-ru"
    let capabilities = ProviderCapabilities(supportsText: true, supportsImages: true, supportsStreaming: true)

    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let chunks = mockChunks(for: request)
                    for (index, chunk) in chunks.enumerated() {
                        if Task.isCancelled { return }
                        try await Task.sleep(nanoseconds: index == 0 ? 180_000_000 : 95_000_000)
                        continuation.yield(.textDelta(chunk))
                    }
                    continuation.yield(.usage(TokenUsage(inputTokens: 42, outputTokens: 68)))
                    continuation.yield(.completed)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func mockChunks(for request: AIRequest) -> [String] {
        if request.mode == .photo {
            return [
                "• Mock распознал режим фото-задачи.\n",
                "• OCR-текст сохранён локально вместе со снимком.\n",
                "• Подключите vision-провайдера или серверный прокси для реального решения."
            ]
        }
        return [
            "• Вопрос обнаружен локально и отправлен в mock-провайдер.\n",
            "• Потоковый ответ появляется фрагментами без реального API-ключа.\n",
            "• В настройках можно выбрать подключаемого провайдера и latency fallback."
        ]
    }
}
