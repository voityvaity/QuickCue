import Foundation

protocol SpeakerAttributing: Sendable {
    var explanation: String { get }
    func classify(
        detection: QuestionDetection,
        previousSpeaker: ConversationSpeaker?
    ) -> ConversationSpeaker
}

/// iOS speech-to-text returns words, not a stable speaker identity. The MVP makes a
/// transparent semantic guess: questions are usually the interlocutor and answers
/// are usually the owner. Every speech bubble remains manually correctable.
struct SemanticSpeakerAttributor: SpeakerAttributing {
    let explanation = "Роли пока определяются по смыслу фразы. Нажмите на метку, чтобы исправить говорящего."

    func classify(
        detection: QuestionDetection,
        previousSpeaker: ConversationSpeaker?
    ) -> ConversationSpeaker {
        if detection.isQuestion { return .partner }
        if previousSpeaker == .partner { return .me }
        return .me
    }
}

enum AnswerVariation {
    case concise
    case example
    case detailed
    case alternative

    var title: String {
        switch self {
        case .concise: "Короче"
        case .example: "Пример"
        case .detailed: "Подробнее"
        case .alternative: "Другой ответ"
        }
    }

    var instruction: String {
        switch self {
        case .concise: "Ответь ещё короче: максимум три коротких тезиса."
        case .example: "Дай один конкретный практический пример к ответу. Не повторяй весь ответ."
        case .detailed: "Раскрой ответ подробнее, сохраняя ясную структуру."
        case .alternative: "Сформулируй другой самостоятельный ответ на тот же вопрос, не копируя предыдущий текст."
        }
    }
}
