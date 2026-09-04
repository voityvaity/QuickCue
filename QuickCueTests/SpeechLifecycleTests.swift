import XCTest
@testable import QuickCue

final class SpeechLifecycleTests: XCTestCase {
    func testStopInvalidatesDelayedPermissionCompletion() {
        var lifecycle = SpeechLifecycle()
        let pending = lifecycle.beginStart()
        XCTAssertEqual(lifecycle.state, .starting)
        lifecycle.beginStop()
        XCTAssertEqual(lifecycle.state, .stopping)
        lifecycle.didStop()
        lifecycle.didStart(pending)
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertFalse(lifecycle.isCurrent(pending))
    }

    func testOldRecognizerCannotRestartNewGeneration() {
        var lifecycle = SpeechLifecycle()
        let old = lifecycle.beginStart()
        lifecycle.didStart(old)
        XCTAssertEqual(lifecycle.state, .listening)
        lifecycle.beginStop()
        lifecycle.didStop()
        let current = lifecycle.beginStart()
        lifecycle.didStart(old)
        XCTAssertEqual(lifecycle.state, .starting)
        lifecycle.didStart(current)
        XCTAssertEqual(lifecycle.state, .listening)
        XCTAssertFalse(lifecycle.isCurrent(old))
        XCTAssertTrue(lifecycle.isCurrent(current))
    }

    func testInstructionQuestionsAreRecognized() {
        let detector = QuestionDetector()
        for text in ["Опишите устройство индекса", "Назовите основные методы", "Приведите пример замыкания", "Перечислите типы коллекций"] {
            XCTAssertTrue(detector.detect(text).isQuestion, text)
        }
        XCTAssertFalse(detector.detect("Я думаю что это работает").isQuestion)
    }

    func testWrittenRussianRegressionCorpusMeetsQuestionThresholds() {
        // This is a deterministic text-rule regression, not a microphone accuracy benchmark.
        let questions = [
            "Что такое декоратор", "Как работает actor", "Почему возникает deadlock",
            "Зачем нужен индекс", "Где хранится контекст", "Когда вызывается deinit",
            "Какая сложность поиска", "Какие типы коллекций доступны", "Сколько памяти нужно",
            "Можно ли изменить tuple", "Нужно ли закрывать соединение", "В чем разница между list и tuple",
            "В чём отличие потока от процесса", "Каким образом работает отмена", "Чем отличается struct от class",
            "Верно ли что словарь сохраняет порядок", "Есть ли ограничение размера", "Расскажите о проекте",
            "Объясните устройство event loop", "Напишите функцию поиска", "Решите задачу с массивом",
            "Найдите ошибку в коде", "Сравните два алгоритма", "Опишите работу индекса",
            "Назовите принципы SOLID", "Приведите пример замыкания", "Перечислите уровни изоляции",
            "Можете объяснить этот подход", "Скажите, как работает очередь", "Этот код потокобезопасен?",
        ]
        let statements = [
            "Я думаю что это работает", "Мне кажется ответ правильный", "Я использовал Python на проекте",
            "У нас был небольшой сервис", "Мы работали командой из трёх человек", "Это зависит от размера данных",
            "Сначала я написал тесты", "Потом добавил индекс", "Проблема оказалась в сети",
            "Этот подход занимает меньше памяти", "Я не помню точный синтаксис", "Можно перейти к следующей теме",
            "Спасибо за объяснение", "Да я согласен с этим", "Результат был сохранён локально",
            "Что касается базы данных мы выбрали PostgreSQL", "Как оказалось это не ошибка",
            "Как я уже говорил мы использовали очередь", "Как мы договорились встреча начнётся позже",
            "Мы обсуждали как работает декоратор",
        ]
        XCTAssertEqual(questions.count, 30)
        XCTAssertEqual(statements.count, 20)
        let truePositive = questions.filter { QuestionDetector().detect($0).isQuestion }.count
        let falsePositive = statements.filter { QuestionDetector().detect($0).isQuestion }.count
        let precision = Double(truePositive) / Double(max(1, truePositive + falsePositive))
        let recall = Double(truePositive) / Double(questions.count)
        XCTAssertGreaterThanOrEqual(precision, 0.9)
        XCTAssertGreaterThanOrEqual(recall, 0.9)
    }
}
