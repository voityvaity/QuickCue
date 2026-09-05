import Foundation
import OSLog

struct SSETransport: Sendable {
    typealias StreamFactory = @Sendable (URLRequest) -> AsyncThrowingStream<SSEMessage, Error>
    private let session: URLSession
    private let streamFactory: StreamFactory?
    private let allowsInsecureLoopback: Bool
    private let timeoutSeconds: Double
    private let maxStreamBytes: Int
    private static let logger = Logger(subsystem: "ru.quickcue.app", category: "stream.transport")

    init(session: URLSession = .shared, allowsInsecureLoopback: Bool = false,
         timeoutSeconds: Double = 60, maxStreamBytes: Int = 8_388_608) {
        self.session = session
        self.streamFactory = nil
        self.allowsInsecureLoopback = allowsInsecureLoopback
        self.timeoutSeconds = timeoutSeconds.isFinite ? min(120, max(0.01, timeoutSeconds)) : 60
        self.maxStreamBytes = max(1, maxStreamBytes)
    }

    /// Adapter fixtures only. Production always uses URLSession + SSEDecoder below.
    init(streamFactory: @escaping StreamFactory) {
        self.session = .shared
        self.streamFactory = streamFactory
        self.allowsInsecureLoopback = false
        self.timeoutSeconds = 60
        self.maxStreamBytes = 8_388_608
    }

    func stream(_ request: URLRequest, requestID: UUID = UUID()) -> AsyncThrowingStream<SSEMessage, Error> {
        if let streamFactory { return streamFactory(request) }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = Task {
                do {
                    guard let url = request.url, Self.permitted(url, loopback: allowsInsecureLoopback) else {
                        throw SSETransportFailure.invalidURL
                    }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await read(request, requestID: requestID, into: continuation) }
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                            throw URLError(.timedOut)
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func read(_ request: URLRequest, requestID: UUID,
                      into continuation: AsyncThrowingStream<SSEMessage, Error>.Continuation) async throws {
        var byteCount = 0
        var eventCount = 0
        var status = -1
        defer {
            // Only generated IDs and numeric counters; never URL/body/header/answer.
            Self.logger.info("request=\(requestID.uuidString, privacy: .public) http=\(status) bytes=\(byteCount) events=\(eventCount)")
        }
        let delegate = SameOriginRedirectDelegate()
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        // Explicitly close sockets on parser errors and early consumer exit, not just EOF.
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw SSETransportFailure.invalidResponse }
        status = http.statusCode
        guard (200...299).contains(status) else { throw SSETransportFailure.httpStatus(status) }
        guard http.mimeType?.lowercased() == "text/event-stream" else {
            throw SSETransportFailure.unexpectedContentType
        }
        var decoder = SSEDecoder()
        for try await byte in bytes {
            try Task.checkCancellation()
            byteCount += 1
            guard byteCount <= maxStreamBytes else { throw SSETransportFailure.streamTooLarge }
            if let message = try decoder.consume(byte: byte) {
                eventCount += 1
                switch continuation.yield(message) {
                case .enqueued: break
                case .dropped: throw SSETransportFailure.consumerTooSlow
                case .terminated: throw CancellationError()
                @unknown default: throw CancellationError()
                }
            }
        }
        try Task.checkCancellation()
        try decoder.finish()
    }

    private static func permitted(_ url: URL, loopback: Bool) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil, let host = url.host, !host.isEmpty else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return loopback && url.scheme == "http" && ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)
    }
}

/// URLSession may retain nonstandard secret headers on redirects: allow only same origin.
final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = task.originalRequest?.url, let destination = request.url,
              source.scheme?.lowercased() == destination.scheme?.lowercased(),
              source.host?.lowercased() == destination.host?.lowercased(),
              Self.port(source) == Self.port(destination),
              destination.user == nil, destination.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
}
