import Foundation

/// Stateful terminal semantics shared by DeepSeek, Yandex, xAI and custom chat APIs.
/// Text/usage in a length-limited final chunk are yielded before reporting the failure.
struct ChatCompletionStreamDecoder {
    private var hasText = false
    private var hasReasoning = false
    private var terminal = false
    private var stopFailure: StreamFailure?
    private(set) var textEvents = 0
    private(set) var usageEvents = 0

    mutating func events(for message: SSEMessage) throws -> [AIStreamEvent] {
        guard !terminal else { throw StreamFailure.malformedEvent }
        if let name = message.event, !["message", "error"].contains(name) { return [] }
        if message.data == "[DONE]" {
            if let stopFailure { throw stopFailure }
            guard hasText else {
                if hasReasoning { throw StreamFailure.reasoningOnly }
                throw AIProviderError.emptyResponse
            }
            terminal = true
            return [.completed]
        }
        let events = try validatedChatCompletionEvents(message)
        if let json = JSONValue.object(message.data),
           let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
            if let delta = choice["delta"] as? [String: Any],
               let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                hasReasoning = true // Boolean only: never surface or log private reasoning.
            }
            if let reason = choice["finish_reason"] as? String {
                switch reason {
                case "stop": break
                case "length": stopFailure = .outputLimit
                case "content_filter": stopFailure = .policyBlock
                case "insufficient_system_resource": stopFailure = .resourceInterruption
                case "tool_calls", "function_call": stopFailure = .unsupportedOutput
                default: stopFailure = .unsupportedTermination
                }
            }
        }
        for event in events {
            switch event {
            case .textDelta(let text):
                textEvents += 1
                hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .usage: usageEvents += 1
            case .completed: break
            }
        }
        return events
    }

    func finish() throws {
        try Task.checkCancellation()
        if let stopFailure { throw stopFailure }
        // EOF without the protocol's terminal is an interruption, even with no text.
        guard terminal else { throw AIProviderError.incompleteResponse }
    }
}
