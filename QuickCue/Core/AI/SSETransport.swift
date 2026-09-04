import Foundation

struct SSEMessage: Sendable {
    let event: String?
    let data: String
}

struct SSETransport: Sendable {
    var session: URLSession = .shared

    func stream(_ request: URLRequest) -> AsyncThrowingStream<SSEMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError.badResponse(-1, "Некорректный HTTP-ответ")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        // A gateway may echo private prompts or credentials in its error body.
                        throw AIProviderError.badResponse(http.statusCode, "http_error")
                    }

                    var eventName: String?
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                continuation.yield(SSEMessage(event: eventName, data: dataLines.joined(separator: "\n")))
                            }
                            eventName = nil
                            dataLines.removeAll(keepingCapacity: true)
                        } else if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    if !dataLines.isEmpty {
                        continuation.yield(SSEMessage(event: eventName, data: dataLines.joined(separator: "\n")))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
