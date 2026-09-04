import XCTest
@testable import QuickCue

final class TranscriptAssemblerTests: XCTestCase {
    func testGrowingPartialProducesOneFinalCandidate() {
        var assembler = TranscriptAssembler()
        assembler.beginUtterance()
        XCTAssertNil(assembler.receive("Как", isFinal: false))
        XCTAssertNil(assembler.receive("Как работает", isFinal: false))
        XCTAssertNil(assembler.receive("Как работает декоратор?", isFinal: false))
        XCTAssertEqual(assembler.receive("Как работает декоратор?", isFinal: true), "Как работает декоратор?")
        XCTAssertNil(assembler.receive("Как работает декоратор?", isFinal: true))
        XCTAssertEqual(assembler.partialText, "")
    }

    func testStopDiscardsPartialAndNewUtteranceIsIndependent() {
        var assembler = TranscriptAssembler()
        XCTAssertNil(assembler.receive("Как работает", isFinal: false))
        assembler.discard()
        XCTAssertTrue(assembler.partialText.isEmpty)
        XCTAssertEqual(assembler.receive("Что такое actor?", isFinal: true), "Что такое actor?")
    }

    func testIncompletePhraseWaitsLongerThanPunctuatedPhrase() {
        var assembler = TranscriptAssembler()
        assembler.receive("Как работает", isFinal: false)
        let incomplete = assembler.endpointDelayNanoseconds
        assembler.receive("Как работает декоратор?", isFinal: false)
        XCTAssertGreaterThan(incomplete, assembler.endpointDelayNanoseconds)
    }

    func testNormalizationAndRepeatedUtterances() {
        var assembler = TranscriptAssembler()
        XCTAssertEqual(assembler.receive("  Что  такое\nactor?  ", isFinal: true), "Что такое actor?")
        assembler.beginUtterance()
        XCTAssertEqual(assembler.receive("Что такое actor?", isFinal: true), "Что такое actor?")
    }
}
