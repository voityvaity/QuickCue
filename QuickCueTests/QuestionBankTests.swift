import SwiftData
import XCTest
@testable import QuickCue

@MainActor
final class QuestionBankTests: XCTestCase {
    func testEditorialSeedIsLargeUniqueAndIdempotent() throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let first = try context.fetch(FetchDescriptor<PracticeQuestionRecord>())
        XCTAssertGreaterThanOrEqual(first.count, 50)
        XCTAssertLessThanOrEqual(first.count, 100)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
        XCTAssertEqual(Set(first.map { QuestionBankService.normalize($0.text) }).count, first.count)
        XCTAssertTrue(first.allSatisfy { $0.provenanceRaw == PracticeQuestionProvenance.editorial.rawValue })

        try QuestionBankService.seedIfNeeded(in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeQuestionRecord>()), first.count)
    }

    func testSearchFiltersAndEmptyResultAreLocalDeterministicRules() throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let questions = try context.fetch(FetchDescriptor<PracticeQuestionRecord>())
        var filters = QuestionBankFilters()
        filters.query = "async"
        filters.role = .juniorPython
        filters.type = .technical
        let matches = questions.filter(filters.matches)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.allSatisfy { $0.text.localizedCaseInsensitiveContains("async") })

        filters.query = "такого вопроса точно нет 918273"
        XCTAssertTrue(questions.filter(filters.matches).isEmpty)
    }

    func testCustomQuestionCanBeRedactedAndDuplicateDoesNotMultiply() throws {
        let context = try makeContext()
        let raw = "Позвоните +7 (912) 345-67-89 или name@example.com. Как устроен проект?"
        let redacted = QuestionPersonalDataRedactor.redact(raw)
        XCTAssertFalse(redacted.contains("name@example.com"))
        XCTAssertFalse(redacted.contains("345-67-89"))

        let first = try XCTUnwrap(QuestionBankService.add(
            text: redacted, topic: "Проект", role: .general,
            difficulty: .basic, type: .project, in: context
        ))
        let duplicate = try XCTUnwrap(QuestionBankService.add(
            text: "  \(redacted)  ", topic: "Другое", role: .general,
            difficulty: .advanced, type: .project, in: context
        ))
        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeQuestionRecord>()), 1)

        try QuestionBankService.archive(first, in: context)
        XCTAssertTrue(first.isArchived)
        let restored = try XCTUnwrap(QuestionBankService.add(
            text: redacted, topic: "Проект", role: .general,
            difficulty: .basic, type: .project, in: context
        ))
        XCTAssertEqual(restored.id, first.id)
        XCTAssertFalse(restored.isArchived)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeQuestionRecord>()), 1)
    }

    func testTodaySelectionPrefersFavoritesThenLeastPracticed() throws {
        let context = try makeContext()
        let favorite = try XCTUnwrap(QuestionBankService.add(
            text: "Избранный вопрос?", topic: "A", role: .general,
            difficulty: .basic, type: .behavioral, in: context
        ))
        favorite.isFavorite = true
        favorite.attemptCount = 10
        let fresh = try XCTUnwrap(QuestionBankService.add(
            text: "Свежий вопрос?", topic: "B", role: .general,
            difficulty: .basic, type: .behavioral, in: context
        ))
        let result = QuestionBankService.practiceToday(from: [fresh, favorite], limit: 2)
        XCTAssertEqual(result.map(\.id), [favorite.id, fresh.id])
    }

    private func makeContext() throws -> ModelContext {
        let container = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }
}
