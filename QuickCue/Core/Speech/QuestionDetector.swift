import Foundation

struct QuestionDetection: Equatable, Sendable {
    let normalizedText: String
    let confidence: Double
    let isQuestion: Bool
}

struct QuestionDetector: Sendable {
    private let strongStarts = [
        "кто", "что", "где", "когда", "куда", "откуда", "почему", "зачем", "как",
        "какой", "какая", "какие", "сколько", "чей", "можно ли", "нужно ли",
        "расскажи", "расскажите", "объясни", "объясните", "покажи", "покажите",
        "напиши", "напишите", "реши", "решите", "найди", "найдите", "сравни", "сравните",
    ]

    private let weakSignals = [
        "ли ", "верно что", "правда что", "в чем", "в чём", "каким образом",
        "что будет если", "что выведет", "как работает", "в чем разница", "в чём разница",
    ]

    func detect(_ rawText: String) -> QuestionDetection {
        let text = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let lower = text.lowercased()
        guard text.count >= 5 else { return .init(normalizedText: text, confidence: 0, isQuestion: false) }

        var score = 0.0
        if text.hasSuffix("?") { score += 0.55 }
        if strongStarts.contains(where: { lower == $0 || lower.hasPrefix("\($0) ") }) { score += 0.48 }
        if weakSignals.contains(where: lower.contains) { score += 0.28 }
        if lower.contains(" или ") { score += 0.08 }
        if text.split(separator: " ").count >= 4 { score += 0.07 }
        if lower.hasPrefix("я думаю") || lower.hasPrefix("мне кажется") { score -= 0.18 }

        let confidence = min(max(score, 0), 1)
        return QuestionDetection(normalizedText: text, confidence: confidence, isQuestion: confidence >= 0.48)
    }
}

