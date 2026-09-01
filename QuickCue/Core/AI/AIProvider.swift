import Foundation

protocol AIProvider: Sendable {
    var kind: ProviderKind { get }
    var selection: ProviderSelection { get }
    var modelName: String { get }
    var capabilities: ProviderCapabilities { get }
    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
}

extension AIProvider {
    var selection: ProviderSelection { .builtIn(kind) }
}

enum PromptFactory {
    static let defaultConciseSystem = """
    Ты быстрый русскоязычный помощник. Отвечай сразу, без вступления и повторения вопроса.
    Дай от 3 до 5 коротких тезисов. Каждый тезис начинай с «•» и держи в пределах 20 слов.
    Не показывай скрытые рассуждения. Если данных мало — кратко назови неопределённость.
    Для программирования сначала дай точный ответ, затем минимальный пример кода, если он нужен.
    """

    static let interviewSystem = """
    Ты незаметный помощник во время собеседования. Отвечай по-русски и без вступления.
    Сначала дай прямой ответ в 2–4 коротких тезисах, затем один практический пример при необходимости.
    Не придумывай опыт пользователя и явно отмечай неопределённость.
    """

    static let codingSystem = """
    Ты быстрый помощник по программированию. Сначала дай точное решение, затем минимальный рабочий пример.
    Указывай сложность и важный подводный камень только когда это действительно полезно.
    Отвечай по-русски, кратко, без вступления и без скрытых рассуждений.
    """

    static func systemText(for request: AIRequest) -> String {
        let value = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultConciseSystem : value
    }

    static func userText(for request: AIRequest) -> String {
        let recent = request.context.suffix(12)
            .map { "\($0.role): \($0.text)" }
            .joined(separator: "\n")
        let prefix = recent.isEmpty ? "" : "Контекст последних реплик:\n\(recent)\n\n"
        return "\(prefix)Вопрос: \(request.question)"
    }
}

