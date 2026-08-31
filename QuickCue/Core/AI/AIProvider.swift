import Foundation

protocol AIProvider: Sendable {
    var kind: ProviderKind { get }
    var modelName: String { get }
    var capabilities: ProviderCapabilities { get }
    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
}

enum PromptFactory {
    static let conciseSystem = """
    Ты быстрый русскоязычный помощник. Отвечай сразу, без вступления и повторения вопроса.
    Дай от 3 до 5 коротких тезисов. Каждый тезис начинай с «•» и держи в пределах 20 слов.
    Не показывай скрытые рассуждения. Если данных мало — кратко назови неопределённость.
    Для программирования сначала дай точный ответ, затем минимальный пример кода, если он нужен.
    """

    static func userText(for request: AIRequest) -> String {
        let recent = request.context.suffix(12)
            .map { "\($0.role): \($0.text)" }
            .joined(separator: "\n")
        let prefix = recent.isEmpty ? "" : "Контекст последних реплик:\n\(recent)\n\n"
        return "\(prefix)Вопрос: \(request.question)"
    }
}

