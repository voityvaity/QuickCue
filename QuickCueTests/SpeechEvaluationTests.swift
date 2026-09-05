import XCTest
@testable import QuickCue

@MainActor
final class SpeechEvaluationTests: XCTestCase {
    func testCatalogHasStableThirtyQuestionTwentyStatementShape() {
        XCTAssertEqual(SpeechEvaluationCatalog.cases.count, 50)
        XCTAssertEqual(SpeechEvaluationCatalog.cases.filter(\.expectsQuestion).count, 30)
        XCTAssertEqual(SpeechEvaluationCatalog.cases.filter { !$0.expectsQuestion }.count, 20)
        XCTAssertEqual(Set(SpeechEvaluationCatalog.cases.map(\.id)).count, 50)
    }

    func testSummaryKeepsSampleCountClassificationAndNearestRankPercentiles() {
        let samples = [
            sample(id: 0, expectedQuestion: true, detectedQuestion: true, finalization: 100),
            sample(id: 1, expectedQuestion: true, detectedQuestion: false, finalization: 200),
            sample(id: 2, expectedQuestion: false, detectedQuestion: true, finalization: 300),
            sample(id: 3, expectedQuestion: false, detectedQuestion: false, finalization: 400, duplicates: 2),
        ]
        let summary = SpeechEvaluationSummary(report: report(id: UUID(), samples: samples))
        XCTAssertEqual(summary.sampleCount, 4)
        XCTAssertEqual(summary.precision, 0.5, accuracy: 0.001)
        XCTAssertEqual(summary.recall, 0.5, accuracy: 0.001)
        XCTAssertEqual(summary.duplicateEvents, 2)
        XCTAssertEqual(summary.finalizationP50Milliseconds, 200)
        XCTAssertEqual(summary.finalizationP95Milliseconds, 400)
    }

    func testArchiveIsBoundedAndCorruptPayloadDoesNotCrash() throws {
        let suite = "SpeechEvaluationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = SpeechBenchmarkArchive(defaults: defaults)
        for index in 0..<7 {
            archive.save(report(id: UUID(), samples: [sample(id: index)]))
        }
        XCTAssertEqual(archive.load().count, 5)
        defaults.set(Data("not-json".utf8), forKey: "speech.benchmarkReports.v1")
        XCTAssertTrue(archive.load().isEmpty)
    }

    func testLateDuplicateFinalIsCountedInsteadOfBecomingAnotherSample() {
        let suite = "SpeechEvaluationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = BenchmarkRecognizer()
        let runner = SpeechBenchmarkRunner(recognizer: recognizer, defaults: defaults)

        runner.startCurrent()
        recognizer.emit("Что такое декоратор", isFinal: true)
        recognizer.emit("Что такое декоратор", isFinal: true)

        XCTAssertEqual(runner.samples.count, 1)
        XCTAssertEqual(runner.samples.first?.duplicateEvents, 1)
        XCTAssertEqual(runner.currentIndex, 1)
    }

    private func report(id: UUID, samples: [SpeechEvaluationSample]) -> SpeechEvaluationReport {
        SpeechEvaluationReport(
            id: id, createdAt: .now, appVersion: "test", appBuild: "1", revision: "fixture",
            operatingSystem: "iOS test", deviceFamily: "iPhone", engine: "fixture",
            locale: "ru_RU", condition: .quiet, samples: samples
        )
    }

    private func sample(
        id: Int,
        expectedQuestion: Bool = true,
        detectedQuestion: Bool = true,
        finalization: Int? = nil,
        duplicates: Int = 0
    ) -> SpeechEvaluationSample {
        SpeechEvaluationSample(
            caseID: id, expectedText: "fixture", recognizedText: "fixture",
            expectedQuestion: expectedQuestion, detectedQuestion: detectedQuestion,
            confidence: 1, endpointDelayMilliseconds: 500,
            finalizationMilliseconds: finalization, duplicateEvents: duplicates
        )
    }
}

@MainActor
private final class BenchmarkRecognizer: SpeechRecognizing {
    private(set) var state: SpeechRecognitionState = .idle
    var onStateChange: ((SpeechRecognitionState) -> Void)?
    var onTranscript: ((String, Bool, Double) -> Void)?
    var onUtteranceStarted: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    func start() async throws {
        state = .listening
        onStateChange?(state)
        onUtteranceStarted?()
    }

    func stop() {
        state = .idle
        onStateChange?(state)
    }

    func finishCurrentUtterance() {}

    func emit(_ text: String, isFinal: Bool) {
        onTranscript?(text, isFinal, 1)
    }
}
