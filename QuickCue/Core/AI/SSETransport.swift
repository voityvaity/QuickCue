import Foundation

struct SSEMessage: Sendable {
    let event: String?
    let data: String
}

struct SSETransport: Sendable {
    typealias StreamFactory = @Sendable (URLRequest) -> AsyncThrowingStream<SSEMessage, Error>

    private let session: URLSession
    private let streamFactory: StreamFactory?

    init(session: URLSession = .shared) {
        self.session = session
        self.streamFactory = nil
    }

    init(streamFactory: @escaping StreamFactory) {
        self.session = .shared
        self.streamFactory = streamFactory
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<SSEMessage, Error> {
        if let streamFactory {
            return streamFactory(request)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError.badResponse(
                            -1,
                            "Некорректный HTTP-ответ"
                        )
                    }

                    guard (200...299).contains(http.statusCode) else {
                        // Никогда не включаем тело ответа:
                        // gateway может вернуть приватный prompt или credential.
                        throw AIProviderError.badResponse(
                            http.statusCode,
                            "http_error"
                        )
                    }

                    var eventName: String?
                    var dataLines: [String] = []

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                continuation.yield(
                                    SSEMessage(
                                        event: eventName,
                                        data: dataLines.joined(separator: "\n")
                                    )
                                )
                            }

                            eventName = nil
                            dataLines.removeAll(keepingCapacity: true)
                        } else if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst(6))
                                .trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(
                                String(line.dropFirst(5))
                                    .trimmingCharacters(in: .whitespaces)
                            )
                        }
                    }

                    if !dataLines.isEmpty {
                        continuation.yield(
                            SSEMessage(
                                event: eventName,
                                data: dataLines.joined(separator: "\n")
                            )
                        )
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
