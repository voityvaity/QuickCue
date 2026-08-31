import Foundation

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
            ["role": "system", "content": PromptFactory.conciseSystem],
            ["role": "user", "content": PromptFactory.userText(for: request)],
        ],
        "stream": true,
        "stream_options": ["include_usage": true],
        "max_tokens": request.maxOutputTokens,
        "temperature": 0.2,
    ]
}

func parseChatCompletionEvent(_ message: SSEMessage) -> [AIStreamEvent] {
    if message.data == "[DONE]" { return [.completed] }
    guard let json = JSONValue.object(message.data) else { return [] }
    var events: [AIStreamEvent] = []
    if let choices = json["choices"] as? [[String: Any]],
       let delta = choices.first?["delta"] as? [String: Any],
       let text = delta["content"] as? String,
       !text.isEmpty {
        events.append(.textDelta(text))
    }
    if let usage = json["usage"] as? [String: Any] {
        events.append(.usage(TokenUsage(
            inputTokens: JSONValue.int(usage["prompt_tokens"]),
            outputTokens: JSONValue.int(usage["completion_tokens"])
        )))
    }
    return events
}
