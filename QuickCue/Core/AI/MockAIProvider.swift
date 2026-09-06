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
        if request.systemPrompt.contains(PracticePrompt.marker) {
            return practiceChunks(for: request)
        }
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

    private func practiceChunks(for request: AIRequest) -> [String] {
        let answer = extract(tag: "user_answer", from: request.question)
        let evidence = String((answer.split(separator: "\n").first.map(String.init) ?? answer).prefix(140))
        let wantsFollowUp = request.question.contains("Предложи одно короткое уместное уточнение")
        let followUpValue: Any = wantsFollowUp
            ? "Какой конкретный пример подтверждает ваш ответ?"
            : NSNull()
        let object: [String: Any] = [
            "evidence": evidence,
            "strengths": ["Ответ относится к заданному вопросу.", "Основная мысль сформулирована явно."],
            "improvements": ["Добавьте один конкретный пример и обозначьте важное ограничение."],
            "exampleAnswer": "Сначала дам прямой тезис, затем короткий пример и назову ограничение решения.",
            "followUpQuestion": followUpValue,
            "scores": ["accuracy": 4, "completeness": 3, "structure": 4, "examples": 2],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return ["{\"improvements\":[\"Mock-разбор недоступен\"]}"]
        }
        let first = text.index(text.startIndex, offsetBy: text.count / 3)
        let second = text.index(first, offsetBy: text.count / 3)
        return [String(text[..<first]), String(text[first..<second]), String(text[second...])]
    }

    private func extract(tag: String, from text: String) -> String {
        guard let start = text.range(of: "<\(tag)>")?.upperBound,
              let end = text.range(of: "</\(tag)>", range: start..<text.endIndex)?.lowerBound else { return "Ответ пользователя" }
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
