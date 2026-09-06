import Foundation
import SwiftData

enum PracticeQuestionRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case juniorPython
    case general

    var id: String { rawValue }
    var title: String { self == .juniorPython ? "Python junior" : "Общее интервью" }
}

enum PracticeDifficulty: String, CaseIterable, Codable, Identifiable, Sendable {
    case basic
    case medium
    case advanced

    var id: String { rawValue }
    var title: String {
        switch self {
        case .basic: "Базовый"
        case .medium: "Средний"
        case .advanced: "Сложный"
        }
    }
}

enum PracticeQuestionType: String, CaseIterable, Codable, Identifiable, Sendable {
    case technical
    case project
    case behavioral

    var id: String { rawValue }
    var title: String {
        switch self {
        case .technical: "Технический"
        case .project: "О проектах"
        case .behavioral: "Поведенческий"
        }
    }
}

enum PracticeQuestionProvenance: String, CaseIterable, Codable, Sendable {
    case editorial
    case user
    case history
    case aiSuggested

    var title: String {
        switch self {
        case .editorial: "База QuickCue"
        case .user: "Добавлено вами"
        case .history: "Сохранено из истории"
        case .aiSuggested: "Предложено AI"
        }
    }
}

struct QuestionBankFilters: Equatable, Sendable {
    var query = ""
    var topic: String?
    var role: PracticeQuestionRole?
    var difficulty: PracticeDifficulty?
    var type: PracticeQuestionType?
    var favoritesOnly = false

    func matches(_ question: PracticeQuestionRecord) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty,
           !question.text.localizedCaseInsensitiveContains(needle),
           !question.topic.localizedCaseInsensitiveContains(needle) { return false }
        if let topic, question.topic != topic { return false }
        if let role, question.roleRaw != role.rawValue { return false }
        if let difficulty, question.difficultyRaw != difficulty.rawValue { return false }
        if let type, question.typeRaw != type.rawValue { return false }
        return !favoritesOnly || question.isFavorite
    }
}

enum QuestionPersonalDataRedactor {
    static func redact(_ text: String) -> String {
        var value = text
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"(?:\+?7|8)[\s\-(]*\d{3}[\s\-)]*\d{3}[\s\-]*\d{2}[\s\-]*\d{2}"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "[скрыто]")
        }
        return value
    }
}

@MainActor
enum QuestionBankService {
    static let maximumQuestionCharacters = 1_000

    static func seedIfNeeded(in context: ModelContext) throws {
        let existing = Set(try context.fetch(FetchDescriptor<PracticeQuestionRecord>()).map(\.id))
        for seed in QuestionBankSeed.questions where !existing.contains(seed.id) {
            context.insert(PracticeQuestionRecord(
                id: seed.id,
                text: seed.text,
                topic: seed.topic,
                role: seed.role,
                difficulty: seed.difficulty,
                type: seed.type,
                provenance: .editorial,
                sourceLabel: "Редакционная база QuickCue"
            ))
        }
        if QuestionBankSeed.questions.contains(where: { !existing.contains($0.id) }) { try context.save() }
    }

    @discardableResult
    static func add(
        text: String,
        topic: String,
        role: PracticeQuestionRole,
        difficulty: PracticeDifficulty,
        type: PracticeQuestionType,
        provenance: PracticeQuestionProvenance = .user,
        sourceLabel: String? = nil,
        in context: ModelContext
    ) throws -> PracticeQuestionRecord? {
        let cleaned = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumQuestionCharacters))
        guard !cleaned.isEmpty else { return nil }
        let normalized = normalize(cleaned)
        let all = try context.fetch(FetchDescriptor<PracticeQuestionRecord>())
        if let existing = all.first(where: { normalize($0.text) == normalized }) {
            if existing.isCustom, existing.isArchived {
                existing.isArchived = false
                existing.updatedAt = .now
                try context.save()
            }
            return existing
        }
        let record = PracticeQuestionRecord(
            text: cleaned,
            topic: String(topic.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)).nilIfEmpty ?? "Своя тема",
            role: role,
            difficulty: difficulty,
            type: type,
            provenance: provenance,
            sourceLabel: sourceLabel ?? provenance.title
        )
        context.insert(record)
        try context.save()
        return record
    }

    static func update(
        _ question: PracticeQuestionRecord,
        text: String,
        topic: String,
        role: PracticeQuestionRole,
        difficulty: PracticeDifficulty,
        type: PracticeQuestionType,
        in context: ModelContext
    ) throws {
        guard question.isCustom else { return }
        let cleaned = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumQuestionCharacters))
        guard !cleaned.isEmpty else { return }
        question.text = cleaned
        question.topic = String(topic.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)).nilIfEmpty ?? "Своя тема"
        question.roleRaw = role.rawValue
        question.difficultyRaw = difficulty.rawValue
        question.typeRaw = type.rawValue
        question.updatedAt = .now
        try context.save()
    }

    static func toggleFavorite(_ question: PracticeQuestionRecord, in context: ModelContext) throws {
        question.isFavorite.toggle()
        question.updatedAt = .now
        try context.save()
    }

    static func archive(_ question: PracticeQuestionRecord, in context: ModelContext) throws {
        guard question.isCustom else { return }
        question.isArchived = true
        question.updatedAt = .now
        try context.save()
    }

    static func recordAttempt(questionID: UUID, in context: ModelContext) throws {
        guard let question = try context.fetch(FetchDescriptor<PracticeQuestionRecord>())
            .first(where: { $0.id == questionID }) else { return }
        question.attemptCount += 1
        question.updatedAt = .now
        try context.save()
    }

    static func practiceToday(from questions: [PracticeQuestionRecord], limit: Int = 5) -> [PracticeQuestionRecord] {
        Array(questions.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
            if $0.attemptCount != $1.attemptCount { return $0.attemptCount < $1.attemptCount }
            return $0.text.localizedStandardCompare($1.text) == .orderedAscending
        }.prefix(max(0, limit)))
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .joined(separator: " ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct QuestionSeed {
    let id: UUID
    let text: String
    let topic: String
    let role: PracticeQuestionRole
    let difficulty: PracticeDifficulty
    let type: PracticeQuestionType
}

private enum QuestionBankSeed {
    static let questions: [QuestionSeed] = {
        let rows: [(String, String, PracticeQuestionRole, PracticeDifficulty, PracticeQuestionType)] = [
            ("Чем список в Python отличается от кортежа и когда выбрать каждый из них?", "Python: основы", .juniorPython, .basic, .technical),
            ("Как работают изменяемые и неизменяемые типы в Python?", "Python: основы", .juniorPython, .basic, .technical),
            ("В чём разница между == и is?", "Python: основы", .juniorPython, .basic, .technical),
            ("Что такое область видимости переменной и правило LEGB?", "Python: основы", .juniorPython, .basic, .technical),
            ("Как устроены позиционные, именованные аргументы, *args и **kwargs?", "Python: основы", .juniorPython, .basic, .technical),
            ("Что делает конструкция with и зачем нужен контекстный менеджер?", "Python: основы", .juniorPython, .medium, .technical),
            ("Как обработать исключение и почему не стоит перехватывать Exception без причины?", "Python: основы", .juniorPython, .basic, .technical),
            ("Чем генератор отличается от списка и когда он экономит память?", "Python: основы", .juniorPython, .medium, .technical),
            ("Что такое декоратор и как написать простой декоратор с аргументами?", "Python: функции", .juniorPython, .medium, .technical),
            ("Что такое замыкание и где оно может пригодиться?", "Python: функции", .juniorPython, .medium, .technical),
            ("Как работают lambda, map, filter и списковые включения?", "Python: функции", .juniorPython, .basic, .technical),
            ("Почему опасно использовать изменяемый объект как значение аргумента по умолчанию?", "Python: функции", .juniorPython, .medium, .technical),
            ("Объясните наследование, композицию и случай, когда композиция лучше.", "ООП", .juniorPython, .medium, .technical),
            ("Для чего нужны dataclass и property?", "ООП", .juniorPython, .basic, .technical),
            ("Чем classmethod отличается от staticmethod и обычного метода?", "ООП", .juniorPython, .medium, .technical),
            ("Что такое магические методы __str__, __repr__ и __eq__?", "ООП", .juniorPython, .basic, .technical),
            ("Как работает сборщик мусора Python и что такое подсчёт ссылок?", "Python: runtime", .juniorPython, .advanced, .technical),
            ("Что ограничивает GIL и когда это действительно важно?", "Python: runtime", .juniorPython, .advanced, .technical),
            ("Чем поток, процесс и coroutine отличаются для I/O- и CPU-задач?", "Асинхронность", .juniorPython, .advanced, .technical),
            ("Как работают async, await и event loop?", "Асинхронность", .juniorPython, .medium, .technical),
            ("Как корректно обрабатывать отмену asyncio-задачи?", "Асинхронность", .juniorPython, .advanced, .technical),
            ("Что произойдёт, если вызвать блокирующую функцию внутри async-кода?", "Асинхронность", .juniorPython, .medium, .technical),
            ("Что такое HTTP-методы и какие из них считаются идемпотентными?", "Web/API", .juniorPython, .basic, .technical),
            ("Чем коды HTTP 400, 401, 403, 404 и 429 отличаются друг от друга?", "Web/API", .juniorPython, .basic, .technical),
            ("Как спроектировать пагинацию и какие компромиссы есть у offset и cursor?", "Web/API", .juniorPython, .advanced, .technical),
            ("Что такое REST и какие ограничения он накладывает на API?", "Web/API", .juniorPython, .medium, .technical),
            ("Как валидировать входные данные API и безопасно возвращать ошибки?", "Web/API", .juniorPython, .medium, .technical),
            ("Зачем нужны таймауты, повторы и идемпотентность во внешних запросах?", "Web/API", .juniorPython, .advanced, .technical),
            ("Что такое SQL JOIN и чем INNER JOIN отличается от LEFT JOIN?", "Базы данных", .juniorPython, .basic, .technical),
            ("Для чего нужен индекс в базе данных и почему индексов не должно быть слишком много?", "Базы данных", .juniorPython, .medium, .technical),
            ("Что такое транзакция и свойства ACID?", "Базы данных", .juniorPython, .medium, .technical),
            ("Как возникает N+1-запрос и как его обнаружить?", "Базы данных", .juniorPython, .advanced, .technical),
            ("Чем нормализация данных полезна и когда допустима денормализация?", "Базы данных", .juniorPython, .advanced, .technical),
            ("Как проверить функцию с помощью pytest и что должно входить в хороший unit-тест?", "Тестирование", .juniorPython, .basic, .technical),
            ("Чем unit-, integration- и end-to-end тесты отличаются по назначению?", "Тестирование", .juniorPython, .medium, .technical),
            ("Что такое mock и почему чрезмерное количество mock может ослабить тесты?", "Тестирование", .juniorPython, .medium, .technical),
            ("Как проверить обработку ошибки и граничные значения?", "Тестирование", .juniorPython, .basic, .technical),
            ("Что происходит при git merge и git rebase?", "Git", .general, .medium, .technical),
            ("Как безопасно разрешить конфликт слияния?", "Git", .general, .basic, .technical),
            ("Что вы проверяете перед отправкой pull request?", "Git", .general, .basic, .technical),
            ("Расскажите об одном своём проекте: задача, ваша роль, решение и результат.", "Проекты", .general, .basic, .project),
            ("Какое техническое решение в вашем проекте оказалось самым сложным и почему?", "Проекты", .general, .medium, .project),
            ("Как вы проверяли, что реализованная функция действительно работает?", "Проекты", .general, .basic, .project),
            ("Опишите ошибку в проекте, которую было трудно найти. Как вы её локализовали?", "Проекты", .general, .medium, .project),
            ("Какие компромиссы вы приняли из-за ограниченного времени?", "Проекты", .general, .medium, .project),
            ("Как бы вы изменили архитектуру своего проекта после полученного опыта?", "Проекты", .general, .advanced, .project),
            ("Как вы организовали конфигурацию и секреты в проекте?", "Проекты", .general, .medium, .project),
            ("Как вы работали с документацией незнакомой библиотеки?", "Проекты", .general, .basic, .project),
            ("Как вы измеряли производительность и где сначала искали узкое место?", "Проекты", .general, .advanced, .project),
            ("Какую часть проекта вы готовы показать и объяснить по строкам?", "Проекты", .general, .medium, .project),
            ("Расскажите о ситуации, когда вы получили критическую обратную связь.", "Поведение", .general, .basic, .behavioral),
            ("Что вы делаете, если не понимаете задачу или требования противоречат друг другу?", "Поведение", .general, .basic, .behavioral),
            ("Как вы сообщаете о риске не успеть к сроку?", "Поведение", .general, .medium, .behavioral),
            ("Опишите разногласие в команде и то, как вы искали решение.", "Поведение", .general, .medium, .behavioral),
            ("Расскажите о задаче, которую пришлось быстро изучить с нуля.", "Поведение", .general, .basic, .behavioral),
            ("Как вы расставляете приоритеты, когда одновременно есть несколько задач?", "Поведение", .general, .medium, .behavioral),
            ("Что вы делаете после собственной ошибки, затронувшей других людей?", "Поведение", .general, .medium, .behavioral),
            ("Почему вам интересна эта роль и какие задачи вы хотите решать?", "Мотивация", .general, .basic, .behavioral),
            ("Какой навык вы сейчас развиваете и как проверяете прогресс?", "Мотивация", .general, .basic, .behavioral),
            ("Какой вопрос вы хотели бы задать будущей команде и почему?", "Мотивация", .general, .basic, .behavioral),
        ]
        return rows.enumerated().compactMap { offset, row in
            let suffix = String(format: "%012d", offset + 1)
            guard let id = UUID(uuidString: "A1100000-0000-4000-8000-\(suffix)") else {
                return nil
            }
            return QuestionSeed(
                id: id,
                text: row.0,
                topic: row.1,
                role: row.2,
                difficulty: row.3,
                type: row.4
            )
        }
    }()
}
