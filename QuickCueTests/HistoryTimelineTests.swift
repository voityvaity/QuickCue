import XCTest
@testable import QuickCue

@MainActor
final class HistoryTimelineTests: XCTestCase {
    func testTranscriptOnlySessionIsRepresented() {
        let transcript = TranscriptRecord(sessionID: UUID(), text: "Просто реплика без вопроса")
        let entries = HistoryTimelineEntry.build(transcripts: [transcript], messages: [], answers: [], photos: [])
        XCTAssertEqual(entries.map(\.id), [transcript.id])
        XCTAssertEqual(entries.first?.text, transcript.text)
    }

    func testChatMirrorsAreNotDuplicatedInTimeline() {
        let sessionID = UUID()
        let transcript = TranscriptRecord(sessionID: sessionID, text: "Что такое tuple?")
        let speech = ConversationMessageRecord(sessionID: sessionID, speaker: .partner, kind: .speech, text: transcript.text)
        let answer = AnswerRecord(sessionID: sessionID, question: transcript.text, answer: "Неизменяемый кортеж", provider: .mock, modelName: "mock")
        let mirror = ConversationMessageRecord(sessionID: sessionID, speaker: .assistant, kind: .answer, text: answer.answer, answerID: answer.id)
        let entries = HistoryTimelineEntry.build(transcripts: [transcript], messages: [speech, mirror], answers: [answer], photos: [])
        XCTAssertEqual(Set(entries.map(\.id)), Set([speech.id, answer.id]))
    }

    func testPhotoKeepsOriginalAndLinkedAnswer() {
        let sessionID = UUID()
        let answer = AnswerRecord(sessionID: sessionID, question: "Фото", provider: .mock, modelName: "mock")
        let photo = PhotoRecord(sessionID: sessionID, relativePath: "Photos/\(UUID().uuidString).jpg", recognizedText: "print(1)", answerID: answer.id)
        let mirror = ConversationMessageRecord(sessionID: sessionID, speaker: .me, kind: .photo, text: "Фото", photoRelativePath: photo.relativePath)
        let entries = HistoryTimelineEntry.build(transcripts: [], messages: [mirror], answers: [answer], photos: [photo])
        XCTAssertEqual(Set(entries.map(\.id)), Set([photo.id, answer.id]))
    }

    func testPhotoStoreRejectsTraversalAndAbsolutePaths() {
        for path in ["../default.store", "/tmp/photo.jpg", "Photos/../default.store", "Photos/invalid.jpg"] {
            XCTAssertThrowsError(try PhotoStore().url(for: path))
        }
    }

    func testEmptyUsageDoesNotPretendToBeFree() {
        let summary = UsageCostSummary(records: [])
        XCTAssertFalse(summary.hasAttempts)
        XCTAssertEqual(summary.title, "Нет учтённых запросов")
    }

    func testMockIsExplicitlyFree() {
        let record = UsageRecord(sessionID: UUID(), provider: .mock, requestKind: "text")
        let summary = UsageCostSummary(records: [record])
        XCTAssertEqual(summary.unknownAttemptCount, 0)
        XCTAssertEqual(summary.title, "Без расходов (Mock)")
    }

    func testUnknownAndLegacyPaidZeroAreNotShownAsFree() {
        let unknown = UsageRecord(sessionID: UUID(), provider: .openAI, requestKind: "text")
        unknown.costSourceRaw = "unknown"
        let legacy = UsageRecord(sessionID: UUID(), provider: .yandexGPT, requestKind: "text")
        let summary = UsageCostSummary(records: [unknown, legacy])
        XCTAssertEqual(summary.unknownAttemptCount, 2)
        XCTAssertEqual(summary.title, "Расход неизвестен")
        XCTAssertNotNil(summary.detail)
    }

    func testMixedCostsKeepKnownSubtotalAndUnknownWarning() {
        let priced = UsageRecord(sessionID: UUID(), provider: .openAI, requestKind: "text")
        priced.estimatedCostRUB = 1.25
        priced.costSourceRaw = "estimated"
        let unknown = UsageRecord(sessionID: UUID(), provider: .openAI, requestKind: "text")
        unknown.costSourceRaw = "unknown"
        let summary = UsageCostSummary(records: [priced, unknown])
        XCTAssertEqual(summary.knownSubtotal, 1.25, accuracy: 0.001)
        XCTAssertEqual(summary.unknownAttemptCount, 1)
        XCTAssertTrue(summary.title.contains("неизвестно"))
    }

    func testRejectedBeforeHTTPIsLabelledAsNotSent() {
        let record = UsageRecord(sessionID: UUID(), provider: .openAI, requestKind: "text")
        record.costSourceRaw = "not_sent"
        let summary = UsageCostSummary(records: [record])
        XCTAssertEqual(summary.unknownAttemptCount, 0)
        XCTAssertEqual(summary.title, "Без отправки в API")
    }
}
