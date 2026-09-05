import Foundation
import SwiftData
import XCTest
@testable import QuickCue

@MainActor
final class SessionStoreTests: XCTestCase {
    func testManualSpeechSavesTranscriptButSendsOnlyAfterExplicitTap() async throws {
        let recognizer = ControlledSpeechRecognizer()
        let fixture = try SessionFixture(
            configureSettings: { $0.answerTriggerPolicy = .manual },
            speechRecognizer: recognizer
        )
        defer { fixture.close() }

        fixture.store.startListening()
        try await waitUntil { fixture.store.listeningPhase == .listening }
        recognizer.emit("Как работает actor?", isFinal: true)

        XCTAssertEqual(fixture.provider.requests.count, 0)
        XCTAssertEqual(fixture.store.latestConfirmedTranscript?.text, "Как работает actor?")
        fixture.store.answerLatestConfirmedTranscript()
        try await waitUntil { fixture.provider.requests.count == 1 }
        XCTAssertEqual(fixture.provider.requests.first?.question, "Как работает actor?")
    }

    func testContinuingAcrossTabsDoesNotRestartRecognizerOrDuplicateQuestion() async throws {
        let recognizer = ControlledSpeechRecognizer()
        let fixture = try SessionFixture(speechRecognizer: recognizer)
        defer { fixture.close() }
        var navigation = TabNavigationCoordinator()

        fixture.store.startListening()
        try await waitUntil { fixture.store.listeningPhase == .listening }
        XCTAssertEqual(
            navigation.request(.history, whileListening: true, policy: .continueWhileActive),
            .switched(.history, shouldStop: false)
        )
        XCTAssertEqual(
            navigation.request(.conversation, whileListening: true, policy: .continueWhileActive),
            .switched(.conversation, shouldStop: false)
        )
        recognizer.emit("Как работает", isFinal: false)
        recognizer.emit("Как работает очередь?", isFinal: true)
        try await waitUntil { fixture.provider.requests.count == 1 }

        XCTAssertEqual(recognizer.startCount, 1)
        XCTAssertEqual(recognizer.stopCount, 0)
        XCTAssertEqual(fixture.provider.requests.first?.question, "Как работает очередь?")
    }

    func testSensitiveInputPauseAndBackgroundStopWithoutAutomaticResume() async throws {
        let recognizer = ControlledSpeechRecognizer()
        let fixture = try SessionFixture(speechRecognizer: recognizer)
        defer { fixture.close() }

        fixture.store.startListening()
        try await waitUntil { fixture.store.listeningPhase == .listening }
        XCTAssertTrue(fixture.store.pauseForSensitiveInput())
        XCTAssertEqual(fixture.store.listeningPhase, .idle)
        XCTAssertEqual(recognizer.stopCount, 1)

        fixture.store.startListening()
        try await waitUntil { fixture.store.listeningPhase == .listening }
        fixture.store.handleSceneBecameInactive()
        fixture.store.handleSceneBecameActive()
        XCTAssertEqual(fixture.store.listeningPhase, .idle)
        XCTAssertEqual(recognizer.startCount, 2)
        XCTAssertEqual(recognizer.stopCount, 2)
    }

    func testChangingAnswerPolicyDuringUtteranceDoesNotSendFinalOrBackfillIt() async throws {
        let recognizer = ControlledSpeechRecognizer()
        let fixture = try SessionFixture(speechRecognizer: recognizer)
        defer { fixture.close() }

        fixture.store.startListening()
        try await waitUntil { fixture.store.listeningPhase == .listening }
        recognizer.emit("Как работает", isFinal: false)
        fixture.settings.answerTriggerPolicy = .manual
        recognizer.emit("Как работает actor?", isFinal: true)
        XCTAssertEqual(fixture.provider.requests.count, 0)

        fixture.settings.answerTriggerPolicy = .automatic
        await Task.yield()
        XCTAssertEqual(fixture.provider.requests.count, 0)
        recognizer.emit("Что такое очередь?", isFinal: true)
        try await waitUntil { fixture.provider.requests.count == 1 }
        XCTAssertEqual(fixture.provider.requests.first?.question, "Что такое очередь?")
        XCTAssertEqual(recognizer.startCount, 1)
    }

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

    func testQuestionCorrectionKeepsOldAnswerAndDoesNotSendUntilExplicitlyRequested() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        fixture.store.submitManualQuestion("Что такое актр?")
        try await waitUntil { fixture.provider.requests.count == 1 }
        fixture.provider.complete(try XCTUnwrap(fixture.provider.requests.first?.id), text: "Старый ответ")
        try await waitUntil { fixture.store.activeRequestCount == 0 }
        let oldAnswer = try XCTUnwrap(fixture.store.visibleAnswers.first)

        fixture.store.reviseQuestion("Что такое actor?", for: oldAnswer, answerAgain: false)

        XCTAssertEqual(fixture.provider.requests.count, 1)
        XCTAssertEqual(oldAnswer.answer, "Старый ответ")
        XCTAssertTrue(oldAnswer.isStale)
        XCTAssertEqual(fixture.store.contextTurns.last?.text, "Что такое actor?")

        fixture.store.submitManualQuestion("Что такое isolation?")
        try await waitUntil { fixture.provider.requests.count == 2 }
        fixture.provider.complete(try XCTUnwrap(fixture.provider.requests.last?.id), text: "Ещё ответ")
        try await waitUntil { fixture.store.activeRequestCount == 0 }
        let currentAnswer = try XCTUnwrap(fixture.store.visibleAnswers.first)
        fixture.store.reviseQuestion("Что такое actor isolation?", for: currentAnswer, answerAgain: true)
        try await waitUntil { fixture.provider.requests.count == 3 }
        let revised = try XCTUnwrap(fixture.store.visibleAnswers.first)
        XCTAssertEqual(revised.question, "Что такое actor isolation?")
        XCTAssertEqual(revised.questionRevision, currentAnswer.questionRevision + 1)
        XCTAssertFalse(revised.isStale)
    }

    func testVariationIsBoundToSpecificAnswerRevision() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        fixture.store.submitManualQuestion("Что такое actor?")
        try await waitUntil { fixture.provider.requests.count == 1 }
        fixture.provider.complete(try XCTUnwrap(fixture.provider.requests.first?.id), text: "Первый ответ")
        try await waitUntil { fixture.store.activeRequestCount == 0 }
        let source = try XCTUnwrap(fixture.store.visibleAnswers.first)

        fixture.store.requestVariation(.example, for: source)
        try await waitUntil { fixture.provider.requests.count == 2 }
        let variation = try XCTUnwrap(fixture.store.visibleAnswers.first)
        XCTAssertEqual(variation.parentAnswerID, source.id)
        XCTAssertEqual(variation.sourceTranscriptID, source.sourceTranscriptID)
        XCTAssertEqual(variation.questionRevision, source.questionRevision)
        XCTAssertTrue(fixture.provider.requests.last?.question.contains("пример") == true)
    }

    func testQueuedRequestKeepsPromptSnapshotFromEnqueueTime() async throws {
        let fixture = try SessionFixture { settings in
            settings.savePromptConfiguration(
                style: .concise,
                includesCodeWhenUseful: false,
                additionalInstructions: "Снимок номер один",
                for: .live
            )
        }
        defer { fixture.close() }
        fixture.store.submitManualQuestion("Первый вопрос?")
        fixture.store.submitManualQuestion("Второй вопрос?")
        fixture.store.submitManualQuestion("Третий вопрос?")
        try await waitUntil { fixture.provider.requests.count == 2 && fixture.store.pendingRequestCount == 1 }

        fixture.settings.savePromptConfiguration(
            style: .detailed,
            includesCodeWhenUseful: true,
            additionalInstructions: "Снимок номер два",
            for: .live
        )
        fixture.provider.complete(try XCTUnwrap(fixture.provider.requests.first?.id), text: "Готово")
        try await waitUntil { fixture.provider.requests.count == 3 }

        let queuedRequest = try XCTUnwrap(fixture.provider.requests.first { $0.question == "Третий вопрос?" })
        XCTAssertTrue(queuedRequest.systemPrompt.contains("Снимок номер один"))
        XCTAssertFalse(queuedRequest.systemPrompt.contains("Снимок номер два"))
    }

    func testSessionContextSnapshotDoesNotChangeAfterProfileEdit() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        let candidate = CandidateProfile(title: "Кандидат")
        candidate.skills = "Python"
        let job = JobProfile(title: "Первая вакансия")
        job.company = "Компания A"
        let profile = ContextProfile(title: "Python · junior")
        profile.candidateProfileID = candidate.id
        profile.jobProfileID = job.id
        fixture.context.insert(candidate)
        fixture.context.insert(job)
        fixture.context.insert(profile)
        try fixture.context.save()
        fixture.settings.selectedContextProfileID = profile.id

        fixture.store.submitManualQuestion("Первый вопрос?")
        try await waitUntil { fixture.provider.requests.count == 1 }
        let first = try XCTUnwrap(fixture.provider.requests.first)
        XCTAssertTrue(first.profileContext.contains("Компания A"))
        let firstSession = try XCTUnwrap(fixture.store.currentSession)
        let firstSnapshotID = try XCTUnwrap(firstSession.contextSnapshotID)

        job.company = "Компания B"
        job.revision += 1
        try fixture.context.save()
        fixture.store.submitManualQuestion("Второй вопрос?")
        try await waitUntil { fixture.provider.requests.count == 2 }
        XCTAssertTrue(fixture.provider.requests.last?.profileContext.contains("Компания A") == true)
        XCTAssertFalse(fixture.provider.requests.last?.profileContext.contains("Компания B") == true)
        let savedSnapshot = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<SessionContextSnapshot>()).first { $0.id == firstSnapshotID }
        )
        XCTAssertTrue(savedSnapshot.text.contains("Компания A"))

        fixture.store.endSession()
        fixture.store.submitManualQuestion("Третий вопрос?")
        try await waitUntil { fixture.provider.requests.count == 3 }
        XCTAssertTrue(fixture.provider.requests.last?.profileContext.contains("Компания B") == true)
        XCTAssertNotEqual(fixture.store.currentSession?.contextSnapshotID, firstSnapshotID)
        XCTAssertTrue(savedSnapshot.text.contains("Компания A"))
    }

    func testNoProfileStillStartsAndSendsNoReferenceContext() async throws {
        let fixture = try SessionFixture()
        defer { fixture.close() }
        XCTAssertNil(fixture.settings.selectedContextProfileID)
        fixture.store.submitManualQuestion("Работает без резюме?")
        try await waitUntil { fixture.provider.requests.count == 1 }
        XCTAssertEqual(fixture.provider.requests.first?.profileContext, "")
        XCTAssertNil(fixture.store.currentSession?.contextSnapshotID)
        XCTAssertNil(fixture.store.activeContextTitle)
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
    let settings: AppSettings

    init(
        configureSettings: (AppSettings) -> Void = { _ in },
        speechRecognizer: (any SpeechRecognizing)? = nil
    ) throws {
        let container = try PersistenceController.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let testContext = ModelContext(container)
        let testSuite = "SessionStoreTests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: testSuite)!
        let testProvider = SessionControlledProvider()
        let testSettings = AppSettings(defaults: testDefaults)
        configureSettings(testSettings)
        context = testContext
        suite = testSuite
        defaults = testDefaults
        provider = testProvider
        settings = testSettings
        store = SessionStore(
            modelContext: testContext,
            settings: testSettings,
            providerFactory: { _ in testProvider },
            speechRecognizer: speechRecognizer
        )
    }

    func close() {
        store.endSession()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class ControlledSpeechRecognizer: SpeechRecognizing {
    private(set) var state: SpeechRecognitionState = .idle
    var onStateChange: ((SpeechRecognitionState) -> Void)?
    var onTranscript: ((String, Bool, Double) -> Void)?
    var onUtteranceStarted: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() async throws {
        startCount += 1
        state = .starting
        onStateChange?(state)
        onUtteranceStarted?()
        state = .listening
        onStateChange?(state)
    }

    func stop() {
        stopCount += 1
        state = .stopping
        onStateChange?(state)
        state = .idle
        onStateChange?(state)
    }

    func finishCurrentUtterance() {}

    func emit(_ text: String, isFinal: Bool) {
        onTranscript?(text, isFinal, 1)
        if isFinal { onUtteranceStarted?() }
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
