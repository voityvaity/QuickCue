import XCTest
@testable import QuickCue

final class QuestionDetectorTests: XCTestCase {
    private let detector = QuestionDetector()

    func testRussianQuestionWordIsDetectedWithoutQuestionMark() {
        let result = detector.detect("Как в Python работает декоратор")
        XCTAssertTrue(result.isQuestion)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.48)
    }

    func testImperativeProgrammingTaskIsDetected() {
        XCTAssertTrue(detector.detect("Напиши функцию для поиска дубликатов").isQuestion)
    }

    func testShortNoiseIsIgnored() {
        XCTAssertFalse(detector.detect("ну да").isQuestion)
    }

    func testStatementIsNotDetectedAsQuestion() {
        XCTAssertFalse(detector.detect("Я думаю что сегодня хорошая погода").isQuestion)
    }
}

