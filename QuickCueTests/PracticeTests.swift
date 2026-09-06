import SwiftData
import XCTest
@testable import QuickCue

@MainActor
final class PracticeTests: XCTestCase {
    func testFeedbackParserRequiresRealEvidenceAndHandlesMalformedJSON() {
        let answer = "Декоратор оборачивает функцию и добавляет поведение. Например, можно измерить время."
        let valid = """
        {"evidence":"Декоратор оборачивает функцию","strengths":["Есть определение"],"improvements":["Добавить код"],"exampleAnswer":"Пример","followUpQuestion":"А как сохранить метаданные?","scores":{"accuracy":4,"completeness":3,"structure":4,"examples":2}}
        """
        let parsed = PracticeFeedbackParser.parse(raw: valid, answer: answer, allowFollowUp: true)
        XCTAssertEqual(parsed.status, .completed)
        XCTAssertEqual(parsed.evidence, "Декоратор оборачивает функцию")
        XCTAssertEqual(parsed.followUpQuestion, "А как сохранить метаданные?")
        XCTAssertEqual(parsed.scores.accuracy, 4)

        let invented = valid.replacingOccurrences(of: "Декоратор оборачивает функцию", with: "Я руководил командой")
        let protected = PracticeFeedbackParser.parse(raw: invented, answer: answer, allowFollowUp: false)
        XCTAssertTrue(answer.localizedCaseInsensitiveContains(protected.evidence))
        XCTAssertNil(protected.followUpQuestion)

        let malformed = PracticeFeedbackParser.parse(raw: "обычный неполный ответ", answer: answer, allowFollowUp: true)
        XCTAssertEqual(malformed.status, .partial)
        XCTAssertFalse(malformed.improvements.isEmpty)
        XCTAssertTrue(answer.localizedCaseInsensitiveContains(malformed.evidence))
    }

    func testComparableAttemptsRequireSameRubricAndKnownScores() {
        let previous = feedbackRecord(scores: (3, 2, nil, 2))
        let current = feedbackRecord(scores: (4, 2, nil, 4))
        let comparison = PracticeAttemptComparison.make(previous: previous, current: current)
        XCTAssertEqual(comparison?.deltas["accuracy"], 1)
        XCTAssertEqual(comparison?.deltas["completeness"], 0)
        XCTAssertNil(comparison?.deltas["structure"])
        previous.rubricVersion = "old-rubric"
        let incompatible = PracticeAttemptComparison.make(previous: previous, current: current)
        XCTAssertTrue(incompatible?.deltas.isEmpty == true)
        XCTAssertNotNil(incompatible?.notice)
    }

    func testStartIsOfflineAndKeepsQuestionIdentity() throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let question = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeQuestionRecord>()).first)
        var generationCount = 0
        let speech = PracticeSpeechRecognizerStub()
        let player = PracticeSpeechPlayerStub()
        let coordinator = PracticeSessionCoordinator(
            modelContext: context,
            generator: { _, _ in generationCount += 1; return Self.validResult() },
            speechRecognizer: speech,
            speechPlayer: player
        )

        coordinator.start(configuration: .quick(questionID: question.id), speakQuestions: false)
        XCTAssertEqual(coordinator.phase, .listening)
        XCTAssertEqual(coordinator.turn?.questionID, question.id)
        XCTAssertEqual(question.attemptCount, 1)
        XCTAssertEqual(generationCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeTurnRecord>()), 1)
    }

    func testJobSnapshotDoesNotChangeWhenProfileIsEditedMidRound() {
        let job = JobProfile(title: "Backend")
        job.company = "Company A"
        job.vacancyText = "Python"
        let snapshot = PracticeJobSnapshot(job: job)
        job.company = "Company B"
        job.vacancyText = "Go"
        job.revision += 1
        XCTAssertEqual(snapshot.company, "Company A")
        XCTAssertTrue(snapshot.referenceText.contains("Python"))
        XCTAssertFalse(snapshot.referenceText.contains("Company B"))
        XCTAssertEqual(snapshot.revision, 1)
    }

    func testQuickPracticeFollowUpPersistsAnswerAndTwoRevisions() async throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let question = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeQuestionRecord>()).first)
        var generationCount = 0
        let coordinator = PracticeSessionCoordinator(
            modelContext: context,
            generator: { request, _ in
                generationCount += 1
                return Self.validResult(followUp: request.allowFollowUp ? "Приведите пример" : nil)
            },
            speechRecognizer: PracticeSpeechRecognizerStub(),
            speechPlayer: PracticeSpeechPlayerStub()
        )
        coordinator.start(configuration: .quick(questionID: question.id), speakQuestions: false)
        coordinator.draftAnswer = "Первый содержательный ответ"
        coordinator.submitAnswer()
        await waitUntil { coordinator.phase == .followUp }
        XCTAssertEqual(coordinator.turn?.answerText, "Первый содержательный ответ")
        coordinator.draftAnswer = "Вот конкретный пример"
        coordinator.submitAnswer()
        await waitUntil { coordinator.phase == .feedback }

        XCTAssertEqual(generationCount, 2)
        XCTAssertEqual(coordinator.turn?.questionID, question.id)
        XCTAssertEqual(coordinator.turn?.answerRevision, 2)
        XCTAssertTrue(coordinator.turn?.answerText.contains("Вот конкретный пример") == true)
        let records = try context.fetch(FetchDescriptor<PracticeFeedbackRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.filter(\.isStale).count, 1)
        coordinator.finishSession()
        XCTAssertEqual(coordinator.session?.statusRaw, PracticeSessionStatus.completed.rawValue)
    }

    func testProviderFailurePreservesAcceptedAttemptForManualRetry() async throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let question = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeQuestionRecord>()).first)
        let coordinator = PracticeSessionCoordinator(
            modelContext: context,
            generator: { _, _ in throw AIProviderError.emptyResponse },
            speechRecognizer: PracticeSpeechRecognizerStub(),
            speechPlayer: PracticeSpeechPlayerStub()
        )
        coordinator.start(configuration: .quick(questionID: question.id), speakQuestions: false)
        coordinator.draftAnswer = "Этот текст нельзя потерять"
        coordinator.submitAnswer()
        await waitUntil { coordinator.phase == .feedback }
        XCTAssertEqual(coordinator.turn?.answerText, "Этот текст нельзя потерять")
        XCTAssertEqual(coordinator.turn?.statusRaw, PracticeTurnStatus.failed.rawValue)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeTurnRecord>()), 1)
    }

    func testFailedReplacementKeepsPreviousSuccessfulFeedbackCurrent() async throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let question = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeQuestionRecord>()).first)
        var requestCount = 0
        let coordinator = PracticeSessionCoordinator(
            modelContext: context,
            generator: { _, _ in
                requestCount += 1
                if requestCount == 1 { return Self.validResult(followUp: nil) }
                throw AIProviderError.emptyResponse
            },
            speechRecognizer: PracticeSpeechRecognizerStub(),
            speechPlayer: PracticeSpeechPlayerStub()
        )
        coordinator.start(configuration: .quick(questionID: question.id), speakQuestions: false)
        coordinator.draftAnswer = "Первый содержательный ответ"
        coordinator.submitAnswer()
        await waitUntil { coordinator.phase == .feedback }
        let firstID = try XCTUnwrap(coordinator.feedback?.id)

        coordinator.requestExample(style: .conciseBullets)
        await waitUntil { coordinator.phase == .feedback && requestCount == 2 }

        let feedback = try context.fetch(FetchDescriptor<PracticeFeedbackRecord>())
        XCTAssertEqual(feedback.first { $0.id == firstID }?.isStale, false)
        XCTAssertEqual(feedback.filter { !$0.isStale && $0.statusRaw == PracticeFeedbackStatus.completed.rawValue }.count, 1)
        XCTAssertEqual(feedback.filter { $0.statusRaw == PracticeFeedbackStatus.failed.rawValue }.count, 1)
    }

    func testTTSKeepsMicrophoneOffUntilPlaybackEndsOrIsSkipped() throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let question = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeQuestionRecord>()).first)
        let speech = PracticeSpeechRecognizerStub()
        let player = PracticeSpeechPlayerStub()
        let coordinator = PracticeSessionCoordinator(
            modelContext: context,
            generator: { _, _ in Self.validResult() },
            speechRecognizer: speech,
            speechPlayer: player
        )
        coordinator.start(configuration: .quick(questionID: question.id), speakQuestions: true)
        XCTAssertEqual(coordinator.phase, .asking)
        XCTAssertEqual(speech.startCount, 0)
        XCTAssertTrue(player.isSpeaking)
        coordinator.skipQuestionSpeech()
        XCTAssertEqual(coordinator.phase, .listening)
        XCTAssertFalse(player.isSpeaking)
        XCTAssertEqual(speech.startCount, 0)
    }

    func testFullInterviewEndsAfterBoundedRoundsAndBuildsHonestSummary() async throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let questions = Array(try context.fetch(FetchDescriptor<PracticeQuestionRecord>()).prefix(3))
        let configuration = PracticeLaunchConfiguration(
            mode: .full,
            questionIDs: questions.map(\.id),
            interviewerRole: .engineer,
            difficulty: .medium,
            rounds: 3,
            maxDurationSeconds: 600,
            jobSnapshot: nil
        )
        let coordinator = PracticeSessionCoordinator(
            modelContext: context,
            generator: { _, _ in Self.validResult(followUp: nil) },
            speechRecognizer: PracticeSpeechRecognizerStub(),
            speechPlayer: PracticeSpeechPlayerStub()
        )
        coordinator.start(configuration: configuration, speakQuestions: false)
        for index in 0..<3 {
            coordinator.draftAnswer = "Ответ номер \(index + 1) с примером"
            coordinator.submitAnswer()
            await waitUntil { coordinator.phase == .feedback }
            if index < 2 { coordinator.nextQuestion() }
        }
        coordinator.nextQuestion()
        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(coordinator.session?.completedRounds, 3)
        XCTAssertTrue(coordinator.session?.summaryText.contains("Завершено ответов: 3") == true)
        XCTAssertLessThanOrEqual(coordinator.session?.nextExercises.count ?? 0, 3)
    }

    func testBackgroundStopsListeningAndDoesNotAutoResume() async throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let question = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeQuestionRecord>()).first)
        let speech = PracticeSpeechRecognizerStub()
        let coordinator = PracticeSessionCoordinator(
            modelContext: context,
            generator: { _, _ in Self.validResult() },
            speechRecognizer: speech,
            speechPlayer: PracticeSpeechPlayerStub()
        )
        coordinator.start(configuration: .quick(questionID: question.id), speakQuestions: false)
        coordinator.startListening()
        await waitUntil { speech.startCount == 1 }
        XCTAssertTrue(coordinator.isListening)
        coordinator.handleAppInactive()
        XCTAssertFalse(coordinator.isListening)
        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(coordinator.session?.statusRaw, PracticeSessionStatus.interrupted.rawValue)
        XCTAssertEqual(speech.stopCount, 1)
    }

    func testLateProviderCallbackCannotPublishAfterPracticeFinishes() async throws {
        let context = try makeContext()
        try QuestionBankService.seedIfNeeded(in: context)
        let question = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeQuestionRecord>()).first)
        let probe = PracticeGeneratorProbe()
        let coordinator = PracticeSessionCoordinator(
            modelContext: context,
            generator: { request, onDelta in
                try await probe.generate(request: request, onDelta: onDelta)
            },
            speechRecognizer: PracticeSpeechRecognizerStub(),
            speechPlayer: PracticeSpeechPlayerStub()
        )
        coordinator.start(configuration: .quick(questionID: question.id), speakQuestions: false)
        coordinator.draftAnswer = "Сохранённый ответ"
        coordinator.submitAnswer()
        await waitUntil { probe.hasPendingRequest }
        let feedbackID = try XCTUnwrap(coordinator.feedback?.id)

        coordinator.finishSession()
        probe.emit("поздний фрагмент")
        probe.complete(with: Self.validResult(followUp: nil))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(coordinator.streamedFeedback, "")
        XCTAssertNotNil(coordinator.session?.endedAt)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeFeedbackRecord>()).first { $0.id == feedbackID })
        XCTAssertEqual(record.statusRaw, PracticeFeedbackStatus.cancelled.rawValue)
        XCTAssertTrue(record.evidenceFragment.isEmpty)
    }

    private static func validResult(followUp: String? = "Почему?") -> PracticeGenerationResult {
        let object: [String: Any] = [
            "evidence": "Первый содержательный ответ",
            "strengths": ["Есть прямая мысль"],
            "improvements": ["Добавить пример"],
            "exampleAnswer": "Сильный пример без выдуманного опыта",
            "followUpQuestion": followUp.map { $0 as Any } ?? NSNull(),
            "scores": ["accuracy": 4, "completeness": 3, "structure": 4, "examples": 3],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("Static practice fixture must be valid JSON")
        }
        return PracticeGenerationResult(
            text: text,
            provider: .builtIn(.mock),
            modelName: "mock-practice",
            promptVersion: PracticePrompt.version
        )
    }

    private func feedbackRecord(scores: (Int?, Int?, Int?, Int?)) -> PracticeFeedbackRecord {
        let value = PracticeFeedbackRecord(
            sessionID: UUID(), turnID: UUID(), answerRevision: 1, requestID: UUID()
        )
        value.accuracyScore = scores.0
        value.completenessScore = scores.1
        value.structureScore = scores.2
        value.examplesScore = scores.3
        value.statusRaw = PracticeFeedbackStatus.completed.rawValue
        return value
    }

    private func makeContext() throws -> ModelContext {
        let container = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for practice state", file: file, line: line)
    }
}

@MainActor
private final class PracticeGeneratorProbe {
    private var continuation: CheckedContinuation<PracticeGenerationResult, Error>?
    private var onDelta: (@MainActor (String) -> Void)?

    var hasPendingRequest: Bool { continuation != nil }

    func generate(
        request: PracticeEvaluationRequest,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> PracticeGenerationResult {
        _ = request
        self.onDelta = onDelta
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ text: String) { onDelta?(text) }

    func complete(with result: PracticeGenerationResult) {
        let pending = continuation
        continuation = nil
        onDelta = nil
        pending?.resume(returning: result)
    }
}

@MainActor
private final class PracticeSpeechRecognizerStub: SpeechRecognizing {
    private(set) var state: SpeechRecognitionState = .idle
    var onStateChange: ((SpeechRecognitionState) -> Void)?
    var onTranscript: ((String, Bool, Double) -> Void)?
    var onUtteranceStarted: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() async throws {
        startCount += 1
        state = .listening
        onStateChange?(.listening)
    }

    func stop() {
        stopCount += 1
        state = .idle
        onStateChange?(.idle)
    }

    func finishCurrentUtterance() {}
}

@MainActor
private final class PracticeSpeechPlayerStub: PracticeSpeechPlaying {
    private(set) var isSpeaking = false
    private var completion: (@MainActor () -> Void)?

    func speak(_ text: String, completion: @escaping @MainActor () -> Void) {
        isSpeaking = true
        self.completion = completion
    }

    func stop() {
        isSpeaking = false
        completion = nil
    }

    func finish() {
        isSpeaking = false
        let callback = completion
        completion = nil
        callback?()
    }
}
