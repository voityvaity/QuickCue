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
            XCTAssertEqual(usage.first?.sessionID, sessionID)
            XCTAssertEqual(usage.first?.inputTokens, 100)
            XCTAssertEqual(usage.first?.estimatedCostRUB, 0.25)
            XCTAssertNil(usage.first?.attemptID)
            XCTAssertNil(usage.first?.usageSourceRaw)
            XCTAssertNil(usage.first?.costCurrencyCode)
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

    func testVersionedV2StoreMigratesToV3AtSameURLAndReopens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let sessionID = UUID()
        var usageID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: QuickCueSchemaV2.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let context = ModelContext(container)
            let session = QuickCueSchemaV2.SessionRecord(id: sessionID, title: "V2", provider: .deepSeek)
            let usage = QuickCueSchemaV2.UsageRecord(sessionID: sessionID, provider: .deepSeek, requestKind: "concise")
            usage.requestID = UUID()
            usage.attemptID = UUID()
            usage.usageSourceRaw = "reported"
            usage.costSourceRaw = "unknown"
            usageID = usage.id
            context.insert(session)
            context.insert(usage)
            try context.save()
        }

        try autoreleasepool {
            let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let context = ModelContext(container)
            let usage = try XCTUnwrap(context.fetch(FetchDescriptor<QuickCue.UsageRecord>()).first)
            XCTAssertEqual(usage.id, usageID)
            XCTAssertEqual(usage.sessionID, sessionID)
            XCTAssertEqual(usage.requestKind, "concise")
            XCTAssertEqual(usage.usageSourceRaw, "reported")
            XCTAssertEqual(usage.costSourceRaw, "unknown")
            XCTAssertNil(usage.costCurrencyCode)
            usage.requestKind = "retry"
            try context.save()
        }

        try autoreleasepool {
            let reopened = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let usage = try ModelContext(reopened).fetch(FetchDescriptor<QuickCue.UsageRecord>()).first
            XCTAssertEqual(usage?.id, usageID)
            XCTAssertEqual(usage?.requestKind, "retry")
        }
    }

    func testVersionedV3StoreMigratesToV4WithRevisionDefaultsAndReopens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let sessionID = UUID()
        var answerID = UUID()
        var transcriptID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: QuickCueSchemaV3.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let context = ModelContext(container)
            let session = QuickCueSchemaV3.SessionRecord(id: sessionID, title: "V3", provider: .mock)
            let transcript = QuickCueSchemaV3.TranscriptRecord(sessionID: sessionID, text: "Старый вопрос?", isQuestion: true)
            let answer = QuickCueSchemaV3.AnswerRecord(
                sessionID: sessionID,
                question: transcript.text,
                answer: "Старый ответ",
                provider: .mock,
                modelName: "mock"
            )
            transcriptID = transcript.id
            answerID = answer.id
            context.insert(session)
            context.insert(transcript)
            context.insert(answer)
            try context.save()
        }

        try autoreleasepool {
            let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let context = ModelContext(container)
            let transcript = try XCTUnwrap(context.fetch(FetchDescriptor<QuickCue.TranscriptRecord>()).first)
            let answer = try XCTUnwrap(context.fetch(FetchDescriptor<QuickCue.AnswerRecord>()).first)
            XCTAssertEqual(transcript.id, transcriptID)
            XCTAssertEqual(transcript.revision, 1)
            XCTAssertEqual(answer.id, answerID)
            XCTAssertEqual(answer.questionRevision, 1)
            XCTAssertFalse(answer.isStale)
            XCTAssertFalse(answer.isFavorite)
            answer.isFavorite = true
            try context.save()
        }

        try autoreleasepool {
            let reopened = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let answer = try ModelContext(reopened).fetch(FetchDescriptor<QuickCue.AnswerRecord>()).first
            XCTAssertEqual(answer?.id, answerID)
            XCTAssertTrue(answer?.isFavorite == true)
        }
    }

    func testVersionedV4StoreMigratesToV5AndContextModelsReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let sessionID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: QuickCueSchemaV4.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let context = ModelContext(container)
            context.insert(QuickCueSchemaV4.SessionRecord(id: sessionID, title: "V4", provider: .mock))
            context.insert(QuickCueSchemaV4.AnswerRecord(
                sessionID: sessionID, question: "Старый вопрос", answer: "Старый ответ",
                provider: .mock, modelName: "mock"
            ))
            try context.save()
        }

        var candidateID = UUID()
        var jobID = UUID()
        var snapshotID = UUID()
        try autoreleasepool {
            let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let context = ModelContext(container)
            let session = try XCTUnwrap(context.fetch(FetchDescriptor<QuickCue.SessionRecord>()).first)
            let oldAnswer = try XCTUnwrap(context.fetch(FetchDescriptor<QuickCue.AnswerRecord>()).first)
            XCTAssertEqual(session.id, sessionID)
            XCTAssertNil(session.contextSnapshotID)
            XCTAssertNil(oldAnswer.contextSnapshotID)

            let candidate = CandidateProfile(title: "Кандидат")
            let job = JobProfile(title: "Вакансия")
            let profile = ContextProfile(title: "Контекст")
            profile.candidateProfileID = candidate.id
            profile.jobProfileID = job.id
            let snapshot = SessionContextSnapshot(
                sessionID: sessionID,
                contextProfileID: profile.id,
                contextProfileRevision: profile.revision,
                title: profile.title,
                text: "Снимок"
            )
            candidateID = candidate.id
            jobID = job.id
            snapshotID = snapshot.id
            context.insert(candidate)
            context.insert(job)
            context.insert(profile)
            context.insert(snapshot)
            session.contextSnapshotID = snapshot.id
            session.contextTitle = snapshot.title
            try context.save()
        }

        try autoreleasepool {
            let reopened = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let context = ModelContext(reopened)
            XCTAssertEqual(try context.fetch(FetchDescriptor<CandidateProfile>()).first?.id, candidateID)
            XCTAssertEqual(try context.fetch(FetchDescriptor<JobProfile>()).first?.id, jobID)
            XCTAssertEqual(try context.fetch(FetchDescriptor<SessionContextSnapshot>()).first?.id, snapshotID)
            XCTAssertEqual(try context.fetch(FetchDescriptor<QuickCue.SessionRecord>()).first?.contextSnapshotID, snapshotID)
        }
    }

    func testVersionedV5StoreMigratesToV6AndKeepsSpeechTimingOptional() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let sessionID = UUID()
        var transcriptID = UUID()
        var answerID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: QuickCueSchemaV5.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let context = ModelContext(container)
            let session = QuickCueSchemaV5.SessionRecord(id: sessionID, title: "V5", provider: .mock)
            let transcript = QuickCueSchemaV5.TranscriptRecord(
                sessionID: sessionID, text: "Как работает actor?", isQuestion: true
            )
            let answer = QuickCueSchemaV5.AnswerRecord(
                sessionID: sessionID, question: transcript.text, answer: "Через изоляцию.",
                provider: .mock, modelName: "mock"
            )
            transcriptID = transcript.id
            answerID = answer.id
            context.insert(session)
            context.insert(transcript)
            context.insert(answer)
            try context.save()
        }

        try autoreleasepool {
            let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let context = ModelContext(container)
            let transcript = try XCTUnwrap(context.fetch(FetchDescriptor<QuickCue.TranscriptRecord>()).first)
            let answer = try XCTUnwrap(context.fetch(FetchDescriptor<QuickCue.AnswerRecord>()).first)
            XCTAssertEqual(transcript.id, transcriptID)
            XCTAssertEqual(answer.id, answerID)
            XCTAssertNil(transcript.speechEngineRaw)
            XCTAssertNil(transcript.endpointDelayMilliseconds)
            XCTAssertNil(transcript.finalizationMilliseconds)
            XCTAssertNil(answer.queueWaitMilliseconds)
            transcript.speechEngineRaw = "SFSpeechRecognizer"
            answer.queueWaitMilliseconds = 12
            try context.save()
        }

        try autoreleasepool {
            let reopened = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let context = ModelContext(reopened)
            XCTAssertEqual(try context.fetch(FetchDescriptor<QuickCue.TranscriptRecord>()).first?.speechEngineRaw, "SFSpeechRecognizer")
            XCTAssertEqual(try context.fetch(FetchDescriptor<QuickCue.AnswerRecord>()).first?.queueWaitMilliseconds, 12)
        }
    }

    func testVersionedV6StoreMigratesToV7AndKeepsSpeakerMetadataOptional() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let sessionID = UUID()
        var messageID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: QuickCueSchemaV6.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let context = ModelContext(container)
            let session = QuickCueSchemaV6.SessionRecord(id: sessionID, title: "V6", provider: .mock)
            let message = QuickCueSchemaV6.ConversationMessageRecord(
                sessionID: sessionID, speaker: .partner, kind: .speech, text: "Старое сообщение"
            )
            messageID = message.id
            context.insert(session)
            context.insert(message)
            try context.save()
        }

        try autoreleasepool {
            let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let context = ModelContext(container)
            let message = try XCTUnwrap(context.fetch(FetchDescriptor<QuickCue.ConversationMessageRecord>()).first)
            XCTAssertEqual(message.id, messageID)
            XCTAssertNil(message.speakerSourceRaw)
            XCTAssertNil(message.speakerConfidence)
            XCTAssertFalse(message.speakerManuallyLocked)
            XCTAssertNil(message.diarizationLabelRaw)
            message.speakerSourceRaw = SpeakerAttributionSource.manual.rawValue
            message.speakerManuallyLocked = true
            try context.save()
        }

        try autoreleasepool {
            let reopened = try PersistenceController.makeContainer(configuration: ModelConfiguration(url: storeURL))
            let message = try ModelContext(reopened).fetch(FetchDescriptor<QuickCue.ConversationMessageRecord>()).first
            XCTAssertEqual(message?.speakerSourceRaw, SpeakerAttributionSource.manual.rawValue)
            XCTAssertTrue(message?.speakerManuallyLocked == true)
        }
    }

    func testVersionedV7StoreMigratesThroughQuestionAndPracticeSchemas() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let sessionID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: QuickCueSchemaV7.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let context = ModelContext(container)
            context.insert(QuickCueSchemaV7.SessionRecord(id: sessionID, title: "V7", provider: .mock))
            try context.save()
        }

        try autoreleasepool {
            let container = try PersistenceController.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<QuickCue.SessionRecord>()).first?.id, sessionID)
            try QuestionBankService.seedIfNeeded(in: context)
            let question = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeQuestionRecord>()).first)
            let practice = PracticeSessionRecord(
                mode: .quick,
                interviewerRole: .engineer,
                difficulty: .medium,
                requestedRounds: 1,
                maxDurationSeconds: 600,
                questionIDs: [question.id]
            )
            context.insert(practice)
            try context.save()
        }

        try autoreleasepool {
            let reopened = try PersistenceController.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(reopened)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuickCue.SessionRecord>()), 1)
            XCTAssertGreaterThanOrEqual(try context.fetchCount(FetchDescriptor<PracticeQuestionRecord>()), 50)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeSessionRecord>()), 1)
        }
    }

    func testVersionedV9StoreMigratesToV10AndKeepsOldDataWritable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let sessionID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: QuickCueSchemaV9.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let context = ModelContext(container)
            context.insert(QuickCueSchemaV7.SessionRecord(id: sessionID, title: "V9", provider: .mock))
            try context.save()
        }

        try autoreleasepool {
            let container = try PersistenceController.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<QuickCue.SessionRecord>()).first?.id, sessionID)
            context.insert(InterviewEventRecord(
                company: "Acme",
                role: "iOS",
                scheduledAt: .now.addingTimeInterval(86_400),
                timeZoneIdentifier: "Europe/Moscow"
            ))
            context.insert(DeletedItemRecord(
                originalID: sessionID,
                kindRaw: "session",
                title: "V9",
                purgeAfter: .now.addingTimeInterval(86_400)
            ))
            try context.save()
        }

        try autoreleasepool {
            let reopened = try PersistenceController.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(reopened)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuickCue.SessionRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<InterviewEventRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DeletedItemRecord>()), 1)
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

    func testInterruptedPracticeIsClosedWithoutDeletingAcceptedAnswer() throws {
        let container = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let question = PracticeQuestionRecord(
            text: "Вопрос?", topic: "Тема", role: .general,
            difficulty: .basic, type: .technical,
            provenance: .user, sourceLabel: "Тест"
        )
        context.insert(question)
        let session = PracticeSessionRecord(
            mode: .quick, interviewerRole: .engineer, difficulty: .basic,
            requestedRounds: 1, maxDurationSeconds: 600, questionIDs: [question.id]
        )
        context.insert(session)
        let turn = PracticeTurnRecord(sessionID: session.id, question: question, orderIndex: 0)
        turn.answerText = "Принятый частичный ответ"
        turn.statusRaw = PracticeTurnStatus.evaluating.rawValue
        context.insert(turn)
        let feedback = PracticeFeedbackRecord(
            sessionID: session.id, turnID: turn.id, answerRevision: 1, requestID: UUID()
        )
        feedback.statusRaw = PracticeFeedbackStatus.streaming.rawValue
        context.insert(feedback)
        try context.save()

        try PersistenceController.reconcileInterruptedWork(in: context)
        XCTAssertEqual(session.statusRaw, PracticeSessionStatus.interrupted.rawValue)
        XCTAssertNotNil(session.endedAt)
        XCTAssertEqual(turn.statusRaw, PracticeTurnStatus.cancelled.rawValue)
        XCTAssertEqual(turn.answerText, "Принятый частичный ответ")
        XCTAssertEqual(feedback.statusRaw, PracticeFeedbackStatus.cancelled.rawValue)
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
