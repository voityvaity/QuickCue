import Foundation
import SwiftData
import XCTest
import QuickCueLegacyFixture
@testable import QuickCue

@MainActor
final class MigrationTests: XCTestCase {
    func testOriginalUnversionedStoreMigratesAtSameURLAndKeepsAllSixModels() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let sessionID = UUID()
        let transcriptID = UUID()
        let answerID = UUID()
        let photoID = UUID()
        let usageID = UUID()
        let messageID = UUID()
        let question = "Как работает декоратор?"
        let answer = "• Оборачивает функцию."

        // Do not use QuickCueSchemaV1 here: shipped v0.3 had no VersionedSchema.
        // Release the original SQLite container before reopening the identical URL.
        try autoreleasepool {
            let original = Schema([
                QuickCueLegacyFixture.SessionRecord.self,
                QuickCueLegacyFixture.TranscriptRecord.self,
                QuickCueLegacyFixture.AnswerRecord.self,
                QuickCueLegacyFixture.PhotoRecord.self,
                QuickCueLegacyFixture.UsageRecord.self,
                QuickCueLegacyFixture.ConversationMessageRecord.self
            ])
            let configuration = ModelConfiguration(schema: original, url: storeURL)
            let container = try ModelContainer(for: original, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(QuickCueLegacyFixture.SessionRecord(id: sessionID, title: "Исходная сессия"))
            context.insert(QuickCueLegacyFixture.TranscriptRecord(id: transcriptID, sessionID: sessionID, text: question))
            context.insert(QuickCueLegacyFixture.AnswerRecord(id: answerID, sessionID: sessionID, question: question, answer: answer))
            context.insert(QuickCueLegacyFixture.PhotoRecord(id: photoID, sessionID: sessionID, answerID: answerID, relativePath: "photos/original.jpg"))
            context.insert(QuickCueLegacyFixture.UsageRecord(id: usageID, sessionID: sessionID))
            context.insert(QuickCueLegacyFixture.ConversationMessageRecord(id: messageID, sessionID: sessionID, answerID: answerID, text: answer))
            try context.save()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        try autoreleasepool {
            let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let context = ModelContext(container)
            let sessions = try context.fetch(FetchDescriptor<QuickCue.SessionRecord>())
            let transcripts = try context.fetch(FetchDescriptor<QuickCue.TranscriptRecord>())
            let answers = try context.fetch(FetchDescriptor<QuickCue.AnswerRecord>())
            let photos = try context.fetch(FetchDescriptor<QuickCue.PhotoRecord>())
            let usage = try context.fetch(FetchDescriptor<QuickCue.UsageRecord>())
            let messages = try context.fetch(FetchDescriptor<QuickCue.ConversationMessageRecord>())
            XCTAssertEqual([sessions.count, transcripts.count, answers.count, photos.count, usage.count, messages.count], Array(repeating: 1, count: 6))
            XCTAssertEqual(sessions.first?.id, sessionID)
            XCTAssertEqual(sessions.first?.title, "Исходная сессия")
            XCTAssertEqual(sessions.first?.estimatedCostRUB, 0.25)
            XCTAssertEqual(transcripts.first?.id, transcriptID)
            XCTAssertEqual(transcripts.first?.sessionID, sessionID)
            XCTAssertEqual(transcripts.first?.text, question)
            XCTAssertEqual(answers.first?.id, answerID)
            XCTAssertEqual(answers.first?.answer, answer)
            XCTAssertEqual(answers.first?.firstTokenMilliseconds, 520)
            XCTAssertEqual(answers.first?.feedback, 1)
            XCTAssertNil(answers.first?.promptSnapshot)
            XCTAssertNil(answers.first?.promptVersion)
            XCTAssertEqual(photos.first?.id, photoID)
            XCTAssertEqual(photos.first?.relativePath, "photos/original.jpg")
            XCTAssertEqual(photos.first?.answerID, answerID)
            XCTAssertEqual(usage.first?.id, usageID)
            XCTAssertEqual(usage.first?.inputTokens, 100)
            XCTAssertEqual(usage.first?.estimatedCostRUB, 0.25)
            XCTAssertNil(usage.first?.attemptID)
            XCTAssertNil(usage.first?.usageSourceRaw)
            XCTAssertEqual(messages.first?.id, messageID)
            XCTAssertEqual(messages.first?.answerID, answerID)
            XCTAssertEqual(messages.first?.text, answer)
            // New optional fields can be written after migration, not just read.
            answers.first?.promptSnapshot = "Новый промпт"
            usage.first?.usageSourceRaw = "reported"
            try context.save()
        }
        try autoreleasepool {
            let reopened = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let context = ModelContext(reopened)
            XCTAssertEqual(try context.fetch(FetchDescriptor<QuickCue.AnswerRecord>()).first?.promptSnapshot, "Новый промпт")
            XCTAssertEqual(try context.fetch(FetchDescriptor<QuickCue.UsageRecord>()).first?.usageSourceRaw, "reported")
        }
    }

    func testRecoveryPreservesCorruptStoreAndAllowsRetryWithoutReset() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let originalBytes = Data("Not a SQLite database; retain this file for recovery.".utf8)
        try originalBytes.write(to: storeURL)
        let suite = "MigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PersistenceController(settings: AppSettings(defaults: defaults), configuration: ModelConfiguration(url: storeURL))
        XCTAssertTrue(controller.failedToOpen)
        XCTAssertNil(controller.container)
        XCTAssertNil(controller.sessionStore)
        XCTAssertEqual(try Data(contentsOf: storeURL), originalBytes)
        controller.open()
        XCTAssertTrue(controller.failedToOpen)
        XCTAssertEqual(try Data(contentsOf: storeURL), originalBytes)
    }

    func testInterruptedWorkIsCancelledWithoutErasingPartialText() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = QuickCue.SessionRecord(title: "Прерванная сессия", provider: .mock)
        context.insert(session)
        let answer = QuickCue.AnswerRecord(sessionID: session.id, question: "Вопрос", answer: "Частичный ответ", provider: .mock, modelName: "mock", status: .streaming)
        context.insert(answer)
        let message = QuickCue.ConversationMessageRecord(sessionID: session.id, speaker: .assistant, kind: .answer, text: answer.answer, status: .streaming, answerID: answer.id)
        context.insert(message)
        try context.save()
        try PersistenceController.reconcileInterruptedWork(in: context)
        XCTAssertEqual(answer.statusRaw, "cancelled")
        XCTAssertEqual(answer.answer, "Частичный ответ")
        XCTAssertEqual(message.statusRaw, "cancelled")
        XCTAssertEqual(message.text, "Частичный ответ")
        XCTAssertNotNil(session.endedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<QuickCue.AnswerRecord>()).count, 1)
    }

    func testApplicationStoreUsesTheSameContextAsSwiftUIHistory() throws {
        let suite = "MigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PersistenceController(settings: AppSettings(defaults: defaults), configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try XCTUnwrap(controller.sessionStore)
        let container = try XCTUnwrap(controller.container)
        _ = store.preparePhotoSession()
        let session = try XCTUnwrap(store.currentSession)
        XCTAssertTrue(session.modelContext === container.mainContext)
        store.endSession()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickCueMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
