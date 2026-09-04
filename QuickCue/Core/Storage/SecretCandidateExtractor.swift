import Foundation

enum SecretCandidateExtractor {
    private static let expression = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9][A-Za-z0-9._-]{15,}"#
    )

    static func bestCandidate(in recognizedText: String) -> String? {
        candidates(in: recognizedText).first
    }

    static func candidates(in recognizedText: String) -> [String] {
        let sourceCandidates = matches(in: recognizedText)
        let compactCandidates = recognizedText
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("aqvn") || lower.contains("sk-") || lower.contains("api_key")
            }
            .flatMap { line in
                matches(in: line.replacingOccurrences(of: " ", with: ""))
            }

        return Array(Set(sourceCandidates + compactCandidates))
            .filter(isPlausibleSecret)
            .sorted { score($0) == score($1) ? $0 < $1 : score($0) > score($1) }
    }

    private static func matches(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func isPlausibleSecret(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard value.count >= 16, value.count <= 512 else { return false }
        guard !lower.hasPrefix("http"), !lower.contains(".com"), !lower.contains(".ru") else { return false }
        return value.contains(where: \.isNumber) && value.contains(where: \.isLetter)
    }

    private static func score(_ value: String) -> Int {
        let lower = value.lowercased()
        var result = min(value.count, 160)
        if lower.hasPrefix("sk-") { result += 200 }
        if lower.hasPrefix("aqvn") { result += 200 }
        if lower.contains("api") { result += 20 }
        if value.contains("-") { result += 10 }
        return result
    }
}
