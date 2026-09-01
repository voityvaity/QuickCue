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
    case detailed

    var title: String {
        switch self {
        case .concise: "Короче"
        case .detailed: "Подробнее"
        }
    }

    var instruction: String {
        switch self {
        case .concise: "Ответь ещё короче: максимум три коротких тезиса."
        case .detailed: "Раскрой ответ подробнее и добавь один практический пример."
        }
    }
}
