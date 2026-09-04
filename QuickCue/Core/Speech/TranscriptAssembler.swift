import Foundation

/// Partial hypotheses are display-only. Only a final recognizer segment may be submitted.
struct TranscriptAssembler {
    private(set) var partialText = ""
    private var didConfirm = false

    mutating func beginUtterance() {
        partialText = ""
        didConfirm = false
    }

    @discardableResult
    mutating func receive(_ text: String, isFinal: Bool) -> String? {
        guard !didConfirm else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        partialText = normalized
        guard isFinal, !normalized.isEmpty else { return nil }
        didConfirm = true
        partialText = ""
        return normalized
    }

    mutating func discard() { beginUtterance() }

    /// Short/incomplete hypotheses need a longer pause before asking Speech for its final result.
    var endpointDelayNanoseconds: UInt64 {
        let words = partialText.split(separator: " ").count
        if words < 3 || partialText.hasSuffix("…") { return 1_300_000_000 }
        if partialText.hasSuffix("?") || partialText.hasSuffix("!") || partialText.hasSuffix(".") {
            return 500_000_000
        }
        return 900_000_000
    }
}
