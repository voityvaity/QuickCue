import Foundation

/// Fixed local vocabulary; never retain the server's error/finish text.
enum StreamFailure: String, Sendable, LocalizedError {
    case malformedEvent = "malformed_event"
    case outputLimit = "output_limit"
    case policyBlock = "policy_block"
    case resourceInterruption = "resource_interruption"
    case unsupportedOutput = "unsupported_output"
    case unsupportedTermination = "unsupported_termination"
    case reasoningOnly = "reasoning_only"

    var errorDescription: String? {
        switch self {
        case .malformedEvent: "Сервис вернул повреждённый поток ответа. Повторите запрос или проверьте совместимость API."
        case .outputLimit: "Достигнут лимит длины ответа. Это не ошибка ключа. Частичный текст сохранён."
        case .policyBlock: "Сервис ограничил ответ по своим правилам. Измените вопрос."
        case .resourceInterruption: "Сервис прервал ответ из-за нехватки ресурсов. Повторите запрос позже."
        case .unsupportedOutput: "Модель вернула вызов инструмента вместо обычного ответа. Выберите текстовую модель."
        case .unsupportedTermination: "Сервис завершил ответ неподдерживаемым способом. Проверьте совместимость модели."
        case .reasoningOnly: "Модель прислала только внутренние рассуждения, без ответа. Выберите быстрый режим без рассуждений."
        }
    }
}
