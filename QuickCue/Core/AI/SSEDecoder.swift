import Foundation

struct SSEMessage: Sendable, Equatable {
    let event: String?
    let data: String
}

/// No response bodies, URLs, headers or arbitrary server strings in these errors.
enum SSETransportFailure: Error, Equatable, LocalizedError {
    case invalidURL, invalidResponse, unexpectedContentType, invalidUTF8
    case eventTooLarge, streamTooLarge, truncatedEvent, consumerTooSlow
    case httpStatus(Int)

    var errorDescription: String? { "Некорректный поток ответа AI (\(safeCode))." }

    var safeCode: String {
        switch self {
        case .invalidURL: "configuration"
        case .invalidResponse: "invalid_http"
        case .unexpectedContentType: "content_type"
        case .invalidUTF8: "invalid_utf8"
        case .eventTooLarge: "event_too_large"
        case .streamTooLarge: "stream_too_large"
        case .truncatedEvent: "incomplete_response"
        case .consumerTooSlow: "consumer_too_slow"
        case .httpStatus(let status): "http_\(status)"
        }
    }
}

/// Incremental SSE framing shared by the real network transport and fixtures.
/// Follows WHATWG line endings/BOM/one optional space rules. EOF is NOT a delimiter.
struct SSEDecoder {
    private let maxEventBytes: Int
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var eventBytes = 0
    private var firstLine = true
    private var skipLF = false
    private var pendingFields = false

    init(maxEventBytes: Int = 1_048_576) {
        self.maxEventBytes = max(1, maxEventBytes)
    }

    mutating func consume<S: Sequence>(_ bytes: S) throws -> [SSEMessage] where S.Element == UInt8 {
        var messages: [SSEMessage] = []
        for byte in bytes {
            if let message = try consume(byte: byte) { messages.append(message) }
        }
        return messages
    }

    mutating func consume(byte: UInt8) throws -> SSEMessage? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        eventBytes += 1
        guard eventBytes <= maxEventBytes else { throw SSETransportFailure.eventTooLarge }
        if byte == 13 || byte == 10 {
            skipLF = byte == 13
            return try endLine()
        }
        line.append(byte)
        return nil
    }

    func finish() throws {
        // A trailing comment is harmless, but partial fields/data must never look successful.
        guard (line.isEmpty || line.first == 58), !pendingFields else {
            throw SSETransportFailure.truncatedEvent
        }
    }

    private mutating func endLine() throws -> SSEMessage? {
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        guard let text = String(bytes: line, encoding: .utf8) else {
            throw SSETransportFailure.invalidUTF8
        }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            let result = dataLines.isEmpty ? nil : SSEMessage(event: eventName, data: dataLines.joined(separator: "\n"))
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            eventBytes = 0
            pendingFields = false
            return result
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "data": dataLines.append(value); pendingFields = true
        case "event": eventName = value.isEmpty ? nil : value; pendingFields = true
        default: break // id/retry/extension fields do not contain answer data.
        }
        return nil
    }
}
