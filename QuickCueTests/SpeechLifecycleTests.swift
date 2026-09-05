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
        let questions = SpeechEvaluationCatalog.cases.filter(\.expectsQuestion).map(\.phrase)
        let statements = SpeechEvaluationCatalog.cases.filter { !$0.expectsQuestion }.map(\.phrase)
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
