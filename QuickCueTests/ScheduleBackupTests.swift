import Foundation
import SwiftData
import XCTest
@testable import QuickCue

@MainActor
final class ScheduleBackupTests: XCTestCase {
    func testInvitationImportExtractsSafeURLAndTimeZoneButRequiresLaterConfirmation() {
        let suggestion = InterviewImportParser.parse("""
        Компания: Acme
        Вакансия: iOS developer
        Время: 15:00 МСК
        https://meet.example.test/room
        """)
        XCTAssertEqual(suggestion.company, "Acme")
        XCTAssertEqual(suggestion.role, "iOS developer")
        XCTAssertEqual(suggestion.timeZoneIdentifier, "Europe/Moscow")
        XCTAssertEqual(suggestion.meetingURL, "https://meet.example.test/room")
    }

    func testScheduleRejectsPastInvalidZoneAndCredentialURL() {
        XCTAssertNotNil(InterviewSchedulePolicy.validationMessage(
            scheduledAt: .now.addingTimeInterval(-1), timeZoneIdentifier: "UTC", meetingURL: ""
        ))
        XCTAssertNotNil(InterviewSchedulePolicy.validationMessage(
            scheduledAt: .now.addingTimeInterval(600), timeZoneIdentifier: "Not/AZone", meetingURL: ""
        ))
        XCTAssertNotNil(InterviewSchedulePolicy.validationMessage(
            scheduledAt: .now.addingTimeInterval(600), timeZoneIdentifier: "UTC",
            meetingURL: "https://user:password@example.test/room"
        ))
    }

    func testScheduleDuplicateUsesEventIdentityAndFiveMinuteWindow() throws {
        let date = Date.now.addingTimeInterval(3_600)
        let event = InterviewEventRecord(company: "Acme", role: "iOS", scheduledAt: date, timeZoneIdentifier: "UTC")
        XCTAssertTrue(InterviewSchedulePolicy.isDuplicate(
            company: " acme ", role: "IOS", scheduledAt: date.addingTimeInterval(60), existing: [event]
        ))
        XCTAssertFalse(InterviewSchedulePolicy.isDuplicate(
            company: "Acme", role: "iOS", scheduledAt: date, existing: [event], excludingID: event.id
        ))
    }

    func testScheduleKeepsSelectedZoneAcrossDSTBoundary() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: zone, year: 2027, month: 3, day: 15, hour: 10, minute: 30
        )))
        let components = try XCTUnwrap(InterviewSchedulePolicy.dateComponents(
            for: date, timeZoneIdentifier: zone.identifier
        ))
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(components.timeZone?.secondsFromGMT(for: date), -4 * 3_600)
    }

    func testInterviewDeepLinkOnlyReturnsCardIdentifier() {
        let id = UUID()
        XCTAssertEqual(InterviewNavigationRequestStore.id(from: URL(string: "quickcue://interview/\(id.uuidString)")!), id)
        XCTAssertNil(InterviewNavigationRequestStore.id(from: URL(string: "quickcue://camera/\(id.uuidString)")!))
    }

    func testPermissionDenialAndReminderReschedulePolicyAreDeterministic() {
        XCTAssertThrowsError(try InterviewSchedulePolicy.requireAccess(false, forCalendar: true)) {
            XCTAssertEqual($0 as? InterviewScheduleServiceError, .calendarDenied)
        }
        XCTAssertThrowsError(try InterviewSchedulePolicy.requireAccess(false, forCalendar: false)) {
            XCTAssertEqual($0 as? InterviewScheduleServiceError, .notificationsDenied)
        }
        let id = UUID()
        XCTAssertEqual(
            InterviewSchedulePolicy.reminderIdentifier(eventID: id),
            InterviewSchedulePolicy.reminderIdentifier(eventID: id)
        )
        let event = InterviewEventRecord(
            company: "Acme", role: "iOS", scheduledAt: .now.addingTimeInterval(3_600),
            timeZoneIdentifier: "UTC"
        )
        event.calendarEventIdentifier = "calendar-item"
        event.calendarScheduledAt = event.scheduledAt
        XCTAssertFalse(InterviewSchedulePolicy.calendarNeedsUpdate(event))
        event.scheduledAt = event.scheduledAt.addingTimeInterval(900)
        XCTAssertTrue(InterviewSchedulePolicy.calendarNeedsUpdate(event))
    }

    func testStoreZipRoundTripAndRejectsUnsafeOrModifiedData() throws {
        let archive = try StoreZipArchive.make(entries: [("manifest.json", Data("ok".utf8))])
        XCTAssertEqual(try StoreZipArchive.read(archive)["manifest.json"], Data("ok".utf8))
        XCTAssertThrowsError(try StoreZipArchive.make(entries: [("../secret", Data())]))

        var traversal = archive
        let nameRange = try XCTUnwrap(traversal.range(of: Data("manifest.json".utf8)))
        traversal.replaceSubrange(nameRange, with: Data("../ifest.json".utf8))
        XCTAssertThrowsError(try StoreZipArchive.read(traversal)) { error in
            XCTAssertEqual(error as? StoreZipArchiveError, .unsafePath)
        }

        var modified = archive
        let range = try XCTUnwrap(modified.range(of: Data("ok".utf8)))
        modified[range.lowerBound] ^= 0x01
        XCTAssertThrowsError(try StoreZipArchive.read(modified)) { error in
            XCTAssertEqual(error as? StoreZipArchiveError, .checksumMismatch)
        }

        var centralDirectoryModified = archive
        let centralSignature = Data([0x50, 0x4B, 0x01, 0x02])
        let centralStart = try XCTUnwrap(centralDirectoryModified.range(of: centralSignature)?.lowerBound)
        centralDirectoryModified[centralStart + 16] ^= 0x01
        XCTAssertThrowsError(try StoreZipArchive.read(centralDirectoryModified)) { error in
            XCTAssertEqual(error as? StoreZipArchiveError, .invalidArchive)
        }
    }

    func testBackupStagesThenRestoresWithoutOverwritingConflictsOrKeys() throws {
        let source = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let sourceContext = ModelContext(source)
        let session = SessionRecord(title: "Тестовая сессия", provider: .mock)
        sourceContext.insert(session)
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let relativePath = try PhotoStore().saveJPEG(jpeg)
        let photo = PhotoRecord(sessionID: session.id, relativePath: relativePath, recognizedText: "задача")
        sourceContext.insert(photo)
        try sourceContext.save()

        let suite = "ScheduleBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exported = try UserDataBackupService.export(context: sourceContext, settings: settings, directory: directory)

        let target = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let targetContext = ModelContext(target)
        let staging = try UserDataBackupService.stage(fileURL: exported.fileURL, context: targetContext)
        XCTAssertEqual(staging.preview.photoCount, 1)
        XCTAssertEqual(staging.preview.conflictCount, 0)
        XCTAssertFalse(String(decoding: try Data(contentsOf: exported.fileURL), as: UTF8.self).contains("keychainAccount"))

        try PhotoStore().delete(relativePath: relativePath)
        let result = try UserDataBackupService.promote(staging, context: targetContext, settings: settings)
        XCTAssertEqual(result.restoredPhotos, 1)
        XCTAssertEqual(try targetContext.fetchCount(FetchDescriptor<SessionRecord>()), 1)
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<PhotoRecord>()).first?.recognizedText, "задача")

        let secondStage = try UserDataBackupService.stage(fileURL: exported.fileURL, context: targetContext)
        XCTAssertEqual(secondStage.preview.conflictCount, 2)
        let repeated = try UserDataBackupService.promote(secondStage, context: targetContext, settings: settings)
        XCTAssertEqual(repeated.insertedObjects, 0)
        XCTAssertEqual(repeated.skippedConflicts, 2)
        try? PhotoStore().delete(relativePath: relativePath)
    }

    func testNewerBackupIsRejectedBeforeLiveStoreMutation() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let live = SessionRecord(title: "Живая история", provider: .mock)
        context.insert(live); try context.save()
        let payload = UserBackupPayload(schemaVersion: 1, entities: [], preparationPlans: [], customProviderProfiles: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let payloadData = try encoder.encode(payload)
        let manifest = UserBackupManifest(
            schemaVersion: 99, dataSchemaVersion: 99, createdAt: .now,
            appVersion: "future", appBuild: "999",
            files: [.init(name: "data.json", byteCount: payloadData.count, sha256: "not-used")]
        )
        let archive = try StoreZipArchive.make(entries: [
            ("manifest.json", try encoder.encode(manifest)), ("data.json", payloadData),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).quickcue-backup")
        defer { try? FileManager.default.removeItem(at: url) }
        try archive.write(to: url)
        XCTAssertThrowsError(try UserDataBackupService.stage(fileURL: url, context: context)) {
            XCTAssertEqual($0 as? UserBackupError, .unsupportedVersion)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<SessionRecord>()).first?.id, live.id)
    }

    func testRestoreDoesNotHideAnExistingLiveSessionWithImportedTombstone() throws {
        let source = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let sourceContext = ModelContext(source)
        let sessionID = UUID()
        let sourceSession = SessionRecord(id: sessionID, title: "Старая версия", provider: .mock)
        sourceContext.insert(sourceSession)
        sourceContext.insert(DeletedItemRecord(
            originalID: sessionID,
            kindRaw: "session",
            title: sourceSession.title,
            purgeAfter: .now.addingTimeInterval(86_400)
        ))
        try sourceContext.save()

        let suite = "ScheduleBackupConflictTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exported = try UserDataBackupService.export(context: sourceContext, settings: settings, directory: directory)

        let target = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let targetContext = ModelContext(target)
        let liveSession = SessionRecord(id: sessionID, title: "Живая версия", provider: .deepSeek)
        targetContext.insert(liveSession)
        try targetContext.save()

        let staging = try UserDataBackupService.stage(fileURL: exported.fileURL, context: targetContext)
        XCTAssertEqual(staging.preview.conflictCount, 2)
        let result = try UserDataBackupService.promote(staging, context: targetContext, settings: settings)
        XCTAssertEqual(result.skippedConflicts, 2)
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<SessionRecord>()).first?.title, "Живая версия")
        XCTAssertEqual(try targetContext.fetchCount(FetchDescriptor<DeletedItemRecord>()), 0)
    }

    func testBackupRestoresProfilesPracticeLinksAndSchedule() throws {
        let source = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(source)
        let candidate = CandidateProfile(title: "Кандидат")
        let job = JobProfile(title: "iOS роль"); job.company = "Acme"; job.role = "Developer"
        let attachment = AttachmentRecord(title: "Резюме", kindRaw: "txt", extractedText: "Swift")
        let profile = ContextProfile(title: "Контекст")
        profile.candidateProfileID = candidate.id; profile.jobProfileID = job.id
        profile.selectedAttachmentIDsData = try JSONEncoder().encode([attachment.id])
        let question = PracticeQuestionRecord(
            text: "Что такое actor?", topic: "Swift", role: .general, difficulty: .medium,
            type: .technical, provenance: .user, sourceLabel: "Тест"
        )
        let practice = PracticeSessionRecord(
            mode: .quick, interviewerRole: .engineer, difficulty: .medium,
            requestedRounds: 1, maxDurationSeconds: 300, questionIDs: [question.id]
        )
        practice.jobID = job.id; practice.jobTitle = job.title
        let turn = PracticeTurnRecord(sessionID: practice.id, question: question, orderIndex: 0)
        turn.answerText = "Actor изолирует состояние"; turn.statusRaw = PracticeTurnStatus.completed.rawValue
        let feedback = PracticeFeedbackRecord(sessionID: practice.id, turnID: turn.id, answerRevision: 1, requestID: UUID())
        feedback.statusRaw = PracticeFeedbackStatus.completed.rawValue; feedback.evidenceFragment = "изолирует состояние"
        let interview = InterviewEventRecord(
            company: "Acme", role: "Developer", scheduledAt: .now.addingTimeInterval(86_400),
            timeZoneIdentifier: "Europe/Moscow"
        )
        interview.jobID = job.id; interview.meetingURL = "https://meet.example.test/room"
        context.insert(candidate); context.insert(job); context.insert(attachment); context.insert(profile)
        context.insert(question); context.insert(practice); context.insert(turn); context.insert(feedback)
        context.insert(interview)
        try context.save()

        let suite = "ScheduleBackupGraphTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exported = try UserDataBackupService.export(context: context, settings: settings, directory: directory)

        let target = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let targetContext = ModelContext(target)
        let staging = try UserDataBackupService.stage(fileURL: exported.fileURL, context: targetContext)
        let result = try UserDataBackupService.promote(staging, context: targetContext, settings: settings)
        XCTAssertEqual(result.insertedObjects, 9)
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<ContextProfile>()).first?.jobProfileID, job.id)
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<PracticeTurnRecord>()).first?.questionID, question.id)
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<PracticeFeedbackRecord>()).first?.turnID, turn.id)
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<InterviewEventRecord>()).first?.jobID, job.id)
        XCTAssertNil(try targetContext.fetch(FetchDescriptor<InterviewEventRecord>()).first?.notificationIdentifier)
    }

    func testRecentlyDeletedRestoreAndPurgeAreSeparate() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = SessionRecord(title: "Вернуть", provider: .mock)
        context.insert(session); try context.save()
        try RecentlyDeletedService.moveSessions([session], existingTombstones: [], context: context)
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<DeletedItemRecord>()).first)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 1)
        try RecentlyDeletedService.restore(item, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DeletedItemRecord>()), 0)

        try RecentlyDeletedService.moveSessions([session], existingTombstones: [], context: context)
        let second = try XCTUnwrap(context.fetch(FetchDescriptor<DeletedItemRecord>()).first)
        try RecentlyDeletedService.purge(second, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 0)
    }

    func testSyncReadinessDoesNotClaimCloudKitFromCompilation() {
        let report = SyncReadinessEvaluator.current(signedCapabilityVerified: true, twoDeviceTestVerified: true)
        XCTAssertEqual(report.status, .deferred)
        XCTAssertFalse(report.cloudKitEntitlementCompiled)
        XCTAssertTrue(report.localBackupAvailable)
        XCTAssertTrue(SyncReadinessEvaluator.alwaysExcluded.contains { $0.contains("API-ключи") })
    }
}
