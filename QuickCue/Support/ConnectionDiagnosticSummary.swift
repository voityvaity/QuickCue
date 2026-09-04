import Foundation

extension ProviderConnectionReport {
    /// Explicit share action only. Not telemetry; no free-text model/name/URL fields.
    func diagnosticSummary(provider: ProviderKind) -> String {
        let knownCategories = ["cancelled", "timeout", "offline", "host", "tls", "network", "unknown",
                               "credential_missing", "configuration", "vision_unsupported", "empty_response",
                               "incomplete_response", "stream_error", "unauthorized", "billing", "forbidden",
                               "model_or_endpoint", "rate_limit", "server", "invalid_http", "content_type",
                               "invalid_utf8", "event_too_large", "stream_too_large", "consumer_too_slow"]
        let code: String
        if let errorCategory, knownCategories.contains(errorCategory) || StreamFailure(rawValue: errorCategory) != nil {
            code = errorCategory
        } else { code = errorCategory == nil ? "none" : "unknown" }
        return [
            buildIdentity?.diagnosticText ?? "QuickCue revision=unknown",
            "provider=\(provider.rawValue)", "state=\(state.rawValue)", "error=\(code)",
            "request=\(requestID?.uuidString ?? "unknown")",
            "ttft_ms=\(firstTokenMilliseconds.map(String.init) ?? "unknown")",
            "total_ms=\(totalMilliseconds.map(String.init) ?? "unknown")",
        ].joined(separator: "\n")
    }
}
