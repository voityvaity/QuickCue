import Foundation
import CoreFoundation

typealias CredentialReader = @Sendable () throws -> String?

enum JSONValue {
    static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func object(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let count = number.doubleValue
        guard count.isFinite, count >= 0, count < Double(Int.max), count.rounded(.down) == count else { return nil }
        return Int(count)
    }
}

func makeAuthorizedRequest(
    url: URL,
    body: [String: Any],
    headers: [String: String]
) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.httpBody = try JSONValue.data(body)
    return request
}

func openAICompatibleBody(request: AIRequest, model: String) -> [String: Any] {
    [
        "model": model,
        "messages": [
            ["role": "system", "content": PromptFactory.systemText(for: request)],
            ["role": "user", "content": PromptFactory.userText(for: request)],
        ],
        "stream": true,
        "stream_options": ["include_usage": true],
        "max_tokens": request.maxOutputTokens,
        "temperature": 0.2,
    ]
}

func parseChatCompletionEvent(_ message: SSEMessage) throws -> [AIStreamEvent] {
    if let event = message.event, !["message", "error"].contains(event) { return [] }
    if message.data == "[DONE]" { return [.completed] }
    if message.data.isEmpty { return [] }
    guard let json = JSONValue.object(message.data) else { throw StreamFailure.malformedEvent }
    if message.event == "error" || json["error"] != nil { throw AIProviderError.badResponse(200, "stream_error") }
    if let choices = json["choices"], !(choices is [[String: Any]]) { throw StreamFailure.malformedEvent }
    if let choice = (json["choices"] as? [[String: Any]])?.first {
        if let delta = choice["delta"], !(delta is [String: Any]) { throw StreamFailure.malformedEvent }
        if let content = (choice["delta"] as? [String: Any])?["content"], !(content is NSNull), !(content is String) {
            throw StreamFailure.malformedEvent
        }
        if let reason = choice["finish_reason"], !(reason is NSNull), !(reason is String) { throw StreamFailure.malformedEvent }
    }
    var events: [AIStreamEvent] = []
    if let choices = json["choices"] as? [[String: Any]],
       let delta = choices.first?["delta"] as? [String: Any],
       let text = delta["content"] as? String,
       !text.isEmpty {
        events.append(.textDelta(text))
    }
    if let usage = json["usage"] as? [String: Any],
       let input = JSONValue.tokenCount(usage["prompt_tokens"]),
       let output = JSONValue.tokenCount(usage["completion_tokens"]) {
        events.append(.usage(TokenUsage(
            inputTokens: input,
            outputTokens: output
        )))
    }
    return events
}

struct StreamCompletionValidator {
    private(set) var hasText = false
    private(set) var completed = false
    private(set) var textEvents = 0
    private(set) var usageEvents = 0

    mutating func observe(_ event: AIStreamEvent) {
        switch event {
        case .textDelta(let text):
            textEvents += 1
            hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .completed: completed = true
        case .usage: usageEvents += 1
        }
    }

    func validate() throws {
        try Task.checkCancellation()
        guard completed else { throw AIProviderError.incompleteResponse }
        guard hasText else { throw AIProviderError.emptyResponse }
    }
}

func validatedChatCompletionEvents(_ message: SSEMessage) throws -> [AIStreamEvent] {
    try parseChatCompletionEvent(message)
}

func parseResponsesEvent(_ message: SSEMessage) throws -> [AIStreamEvent] {
    guard let json = JSONValue.object(message.data), let type = json["type"] as? String else { throw StreamFailure.malformedEvent }
    switch type {
    case "response.output_text.delta":
        guard let delta = json["delta"] as? String else { throw StreamFailure.malformedEvent }
        return [.textDelta(delta)]
    case "response.refusal.delta":
        return (json["delta"] as? String).map { [.textDelta($0)] } ?? []
    case "response.completed":
        guard let response = json["response"] as? [String: Any],
              response["status"] as? String == "completed" else {
            throw StreamFailure.malformedEvent
        }
        var events: [AIStreamEvent] = []
        if let rawUsage = response["usage"], !(rawUsage is NSNull) {
            guard let usage = rawUsage as? [String: Any] else { throw StreamFailure.malformedEvent }
            let rawInput = usage["input_tokens"]
            let rawOutput = usage["output_tokens"]
            if let rawInput, !(rawInput is NSNull), JSONValue.tokenCount(rawInput) == nil {
                throw StreamFailure.malformedEvent
            }
            if let rawOutput, !(rawOutput is NSNull), JSONValue.tokenCount(rawOutput) == nil {
                throw StreamFailure.malformedEvent
            }
            if let input = JSONValue.tokenCount(rawInput), let output = JSONValue.tokenCount(rawOutput) {
                events.append(.usage(TokenUsage(inputTokens: input, outputTokens: output)))
            }
        }
        events.append(.completed)
        return events
    case "response.incomplete":
        if let response = json["response"] as? [String: Any],
           let detail = response["incomplete_details"] as? [String: Any] {
            if detail["reason"] as? String == "max_output_tokens" { throw StreamFailure.outputLimit }
            if detail["reason"] as? String == "content_filter" { throw StreamFailure.policyBlock }
        }
        throw AIProviderError.incompleteResponse
    case "response.failed", "error": throw AIProviderError.badResponse(200, "stream_error")
    default: return []
    }
}

struct AnthropicStreamDecoder {
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var stopFailure: StreamFailure?

    mutating func events(for message: SSEMessage) throws -> [AIStreamEvent] {
        guard let json = JSONValue.object(message.data), let type = json["type"] as? String else { throw StreamFailure.malformedEvent }
        switch type {
        case "message_start":
            if let body = json["message"] as? [String: Any], let usage = body["usage"] as? [String: Any] {
                if let input = JSONValue.tokenCount(usage["input_tokens"]) {
                    let creation = JSONValue.tokenCount(usage["cache_creation_input_tokens"]) ?? 0
                    let read = JSONValue.tokenCount(usage["cache_read_input_tokens"]) ?? 0
                    let (subtotal, overflow1) = input.addingReportingOverflow(creation)
                    let (total, overflow2) = subtotal.addingReportingOverflow(read)
                    inputTokens = overflow1 || overflow2 ? nil : total
                }
                outputTokens = JSONValue.tokenCount(usage["output_tokens"])
                if let inputTokens, let outputTokens {
                    return [.usage(TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens))]
                }
            }
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                return [.textDelta(text)]
            }
        case "message_delta":
            guard let delta = json["delta"] as? [String: Any],
                  let reason = delta["stop_reason"] as? String else {
                throw StreamFailure.malformedEvent
            }
            switch reason {
            case "end_turn", "stop_sequence": break
            case "max_tokens": stopFailure = .outputLimit
            case "refusal": stopFailure = .policyBlock
            case "tool_use": stopFailure = .unsupportedOutput
            default: stopFailure = .unsupportedTermination
            }
            if let rawUsage = json["usage"], !(rawUsage is NSNull) {
                guard let usage = rawUsage as? [String: Any] else { throw StreamFailure.malformedEvent }
                if let rawOutput = usage["output_tokens"], !(rawOutput is NSNull), JSONValue.tokenCount(rawOutput) == nil {
                    throw StreamFailure.malformedEvent
                }
                if let output = JSONValue.tokenCount(usage["output_tokens"]) { outputTokens = output }
                if let inputTokens, let outputTokens {
                    return [.usage(TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens))]
                }
            }
        case "message_stop":
            if let stopFailure { throw stopFailure }
            return [.completed]
        case "error": throw AIProviderError.badResponse(200, "stream_error")
        default: break
        }
        return []
    }
}
