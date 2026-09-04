import Foundation
import SwiftData
import XCTest
@testable import QuickCue

@MainActor
final class SessionStoreTests: XCTestCase {
    func testEndCancelsQueuedWorkAndLateResultsCannotEnterNewSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.submitManualQuestion("Что такое первый вопрос?")
        store.submitManualQuestion("Что такое второй вопрос?")
        store.submitManualQuestion("Что такое третий вопрос?")
        try await waitUntil { fixture.provider.requests.count == 2 }
        let oldSessionID = try XCTUnwrap(store.currentSession?.id)
        let oldRecords = store.visibleAnswers
        let oldRequests = fixture.provider.requests
        XCTAssertEqual(store.pendingRequestCount, 1)

        store.endSession()
        XCTAssertNil(store.currentSession)
        XCTAssertEqual(store.activeRequestCount, 0)
        XCTAssertEqual(store.pendingRequestCount, 0)
        XCTAssertTrue(store.visibleAnswers.isEmpty)
        XCTAssertTrue(oldRecords.allSatisfy { $0.statusRaw == AnswerStatus.cancelled.rawValue })

        store.submitManualQuestion("Что такое новая сессия?")
        try await waitUntil { fixture.provider.requests.count == 3 }
        let newRequest = try XCTUnwrap(fixture.provider.requests.last)
        oldRequests.forEach { fixture.provider.complete($0.id, text: "СТАРЫЙ ОТВЕТ") }
        fixture.provider.complete(newRequest.id, text: "НОВЫЙ ОТВЕТ")
        try await waitUntil { store.visibleAnswers.first?.statusRaw == AnswerStatus.completed.rawValue }
        XCTAssertNotEqual(store.currentSession?.id, oldSessionID)
        XCTAssertEqual(store.visibleAnswers.count, 1)
        XCTAssertEqual(store.visibleAnswers.first?.answer, "НОВЫЙ ОТВЕТ")
        XCTAssertFalse(store.contextTurns.contains { $0.text.contains("СТАРЫЙ") })
        XCTAssertFalse(fixture.provider.requests.contains { $0.question.contains("третий") })
        try await waitUntil {
            let rows = (try? fixture.context.fetch(FetchDescriptor<UsageRecord>())) ?? []
            return rows.count == 3
        }
        let usage = try fixture.context.fetch(FetchDescriptor<UsageRecord>())
        XCTAssertEqual(usage.filter { $0.sessionID == oldSessionID }.count, 2)
    }

    func testInactiveCancelsAllKindsAndCannotAcceptNewRequestsUntilActive() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.submitManualQuestion("Как работает очередь?")
        try await waitUntil { fixture.provider.requests.count == 1 }
        let sessionID = try XCTUnwrap(store.currentSession?.id)
        let first = try XCTUnwrap(store.visibleAnswers.first)
        store.handleSceneBecameInactive()
        store.submitManualQuestion("Что не должно отправиться?")
        let photo = await store.answerPhoto(jpeg: Data([1]), recognizedText: "Скрытая фотография", expectedSessionID: sessionID)
        store.requestVariation(.concise, for: first)
        XCTAssertNil(photo)
        XCTAssertEqual(first.statusRaw, AnswerStatus.cancelled.rawValue)
        XCTAssertEqual(store.activeRequestCount, 0)
        XCTAssertEqual(store.pendingRequestCount, 0)
        XCTAssertEqual(store.visibleAnswers.count, 1)
        XCTAssertFalse(store.isListening)
        XCTAssertFalse(store.isConversationListening)

        store.handleSceneBecameActive()
        store.submitManualQuestion("Как продолжить работу?")
        try await waitUntil { fixture.provider.requests.count == 2 }
        XCTAssertEqual(store.currentSession?.id, sessionID)
    }

    func testPhotoCapturedInEndedSessionNeverCreatesOrUsesAnotherSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        let store = fixture.store
        let captureSessionID = try XCTUnwrap(store.preparePhotoSession())
        store.endSession()
        let afterEnd = await store.answerPhoto(jpeg: Data([1]), recognizedText: "Старое фото", expectedSessionID: captureSessionID)
        XCTAssertNil(afterEnd)
        XCTAssertNil(store.currentSession)
        store.submitManualQuestion("Что такое другая сессия?")
        let afterRestart = await store.answerPhoto(jpeg: Data([1]), recognizedText: "Старое фото", expectedSessionID: captureSessionID)
        XCTAssertNil(afterRestart)
        XCTAssertFalse(store.registerPhoto(sessionID: captureSessionID))
        XCTAssertEqual(store.currentSession?.photoCount, 0)
        XCTAssertEqual(store.visibleAnswers.count, 1)
    }

    func testPhotoConversationManualAndVariationsShareOneQueue() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.submitManualQuestion("Что такое первая задача?")
        store.submitManualQuestion("Что такое вторая задача?")
        try await waitUntil { fixture.provider.requests.count == 2 }
        let sessionID = try XCTUnwrap(store.currentSession?.id)
        let initial = try XCTUnwrap(store.visibleAnswers.first)
        let photo = Task {
            let answer = await store.answerPhoto(jpeg: Data([1]), recognizedText: "Текст фото", expectedSessionID: sessionID)
            return answer?.id
        }
        try await waitUntil { store.pendingRequestCount == 1 }
        store.requestVariation(.concise, for: initial)
        store.submitConversationText("Ручная реплика в диалоге")
        XCTAssertEqual(store.activeRequestCount, 2)
        XCTAssertEqual(store.pendingRequestCount, 3)
        XCTAssertEqual(fixture.provider.requests.count, 2)
        photo.cancel()
        let photoResult = await photo.value
        XCTAssertNil(photoResult)
        XCTAssertEqual(store.activeRequestCount, 2)
        XCTAssertEqual(store.pendingRequestCount, 2)
        store.endSession()
        XCTAssertEqual(store.pendingRequestCount, 0)
        XCTAssertEqual(fixture.provider.requests.count, 2)
    }

    func testSpeakerCorrectionIsUsedByNextAIRequest() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.submitConversationText("Я расскажу про actor")
        try await waitUntil { fixture.provider.requests.count == 1 }
        let message = try XCTUnwrap(store.visibleConversationMessages.first { $0.kindRaw == ConversationMessageKind.speech.rawValue })
        store.setSpeaker(.partner, for: message)
        XCTAssertEqual(message.speakerRaw, ConversationSpeaker.partner.rawValue)
        XCTAssertEqual(store.contextTurns.first?.role, ConversationSpeaker.partner.title)
        store.requestAnswer(for: message)
        try await waitUntil { fixture.provider.requests.count == 2 }
        let context = try XCTUnwrap(fixture.provider.requests.last?.context)
        XCTAssertEqual(context.first { $0.text == message.text }?.role, ConversationSpeaker.partner.title)
        let assistant = try XCTUnwrap(store.visibleConversationMessages.first { $0.speakerRaw == ConversationSpeaker.assistant.rawValue })
        store.setSpeaker(.me, for: assistant)
        XCTAssertEqual(assistant.speakerRaw, ConversationSpeaker.assistant.rawValue)
    }

    func testPhotoRetryNeverSilentlyDropsTheImage() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        let sessionID = try XCTUnwrap(fixture.store.preparePhotoSession())
        let photo = Task {
            let answer = await fixture.store.answerPhoto(jpeg: Data([1]), recognizedText: "Задача с фото", expectedSessionID: sessionID)
            return answer?.id
        }
        try await waitUntil { fixture.provider.requests.count == 1 }
        fixture.provider.complete(try XCTUnwrap(fixture.provider.requests.first?.id), text: "Решение")
        let photoID = await photo.value
        let resultID = try XCTUnwrap(photoID)
        let record = try XCTUnwrap(fixture.store.visibleAnswers.first { $0.id == resultID })
        fixture.store.retryAnswer(record)
        fixture.store.requestVariation(.concise, for: record)
        XCTAssertEqual(fixture.store.activeRequestCount, 0)
        XCTAssertEqual(fixture.store.pendingRequestCount, 0)
        XCTAssertEqual(fixture.provider.requests.count, 1)
        XCTAssertNotNil(fixture.store.alertMessage)
    }

    func testDeletedSessionDoesNotReceiveLateUsage() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        fixture.store.submitManualQuestion("Как удалить историю?")
        try await waitUntil { fixture.provider.requests.count == 1 }
        let requestID = try XCTUnwrap(fixture.provider.requests.first?.id)
        let session = try XCTUnwrap(fixture.store.currentSession)
        fixture.store.endSession()
        fixture.context.delete(session)
        try fixture.context.save()
        // All of the cancellation callbacks have to resume on the main actor after
        // the synchronous deletion above. A later new request acts as a drain barrier.
        fixture.provider.complete(requestID, text: "Поздний ответ")
        fixture.store.submitManualQuestion("Как продолжить после удаления?")
        try await waitUntil { fixture.provider.requests.count == 2 }
        fixture.provider.complete(try XCTUnwrap(fixture.provider.requests.last?.id), text: "Новый ответ")
        try await waitUntil { fixture.store.activeRequestCount == 0 }
        let rows = try fixture.context.fetch(FetchDescriptor<UsageRecord>())
        XCTAssertFalse(rows.contains { $0.requestID == requestID })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while !condition() {
            if Date.now >= deadline {
                XCTFail("Timed out waiting for deterministic test provider")
                throw SessionTestError.timedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private enum SessionTestError: Error { case timedOut }

@MainActor
private final class SessionFixture {
    let context: ModelContext
    let store: SessionStore
    let provider: SessionControlledProvider
    private let suite: String
    private let defaults: UserDefaults

    init() throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let testContext = ModelContext(container)
        let testSuite = "SessionStoreTests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: testSuite)!
        let testProvider = SessionControlledProvider()
        context = testContext
        suite = testSuite
        defaults = testDefaults
        provider = testProvider
        store = SessionStore(modelContext: testContext, settings: AppSettings(defaults: testDefaults), providerFactory: { _ in testProvider })
    }

    func close() {
        store.endSession()
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Locking keeps the test double safe when router workers call it off the main actor.
private final class SessionControlledProvider: AIProvider, @unchecked Sendable {
    let kind: ProviderKind = .mock
    let modelName = "controlled-local-test"
    let capabilities = ProviderCapabilities(supportsText: true, supportsImages: true, supportsStreaming: true)
    private let lock = NSLock()
    private var recordedRequests: [AIRequest] = []
    private var continuations: [UUID: AsyncThrowingStream<AIStreamEvent, Error>.Continuation] = [:]

    var requests: [AIRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            recordedRequests.append(request)
            continuations[request.id] = continuation
            lock.unlock()
        }
    }

    func complete(_ requestID: UUID, text: String) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: requestID)
        lock.unlock()
        continuation?.yield(.textDelta(text))
        continuation?.yield(.completed)
        continuation?.finish()
    }
}
