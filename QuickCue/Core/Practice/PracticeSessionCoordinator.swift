import AVFoundation
import Foundation
import SwiftData

@MainActor
protocol PracticeSpeechPlaying: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String, completion: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class PracticeSpeechSynthesizer: NSObject, PracticeSpeechPlaying, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String, completion: @escaping @MainActor () -> Void) {
        stop()
        self.completion = completion
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        completion = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let callback = self.completion
            self.completion = nil
            callback?()
        }
    }
}

@MainActor
final class PracticeSessionCoordinator: ObservableObject {
    typealias Generator = (
        PracticeEvaluationRequest,
        @escaping @MainActor (String) -> Void
    ) async throws -> PracticeGenerationResult

    @Published private(set) var phase: PracticePhase = .ready
    @Published private(set) var session: PracticeSessionRecord?
    @Published private(set) var turn: PracticeTurnRecord?
    @Published private(set) var feedback: PracticeFeedbackRecord?
    @Published private(set) var streamedFeedback = ""
    @Published private(set) var isListening = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var comparison: PracticeAttemptComparison?
    @Published private(set) var selectedExampleStyle: PracticeExampleStyle = .standard
    @Published var draftAnswer = ""

    private let modelContext: ModelContext
    private let generator: Generator
    private let cancelRequest: (UUID) -> Void
    private let cancelSessionWork: (UUID) -> Void
    private let speechRecognizer: any SpeechRecognizing
    private let speechPlayer: any PracticeSpeechPlaying
    private var configuration: PracticeLaunchConfiguration?
    private var questions: [PracticeQuestionRecord] = []
    private var questionIndex = 0
    private var speakQuestions = false
    private var generationTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var presentationGeneration = UUID()
    private var activeRequestID: UUID?

    convenience init(
        modelContext: ModelContext,
        sessionStore: SessionStore,
        speechRecognizer: (any SpeechRecognizing)? = nil,
        speechPlayer: (any PracticeSpeechPlaying)? = nil
    ) {
        self.init(
            modelContext: modelContext,
            generator: { [weak sessionStore] request, onDelta in
                guard let sessionStore else { throw CancellationError() }
                return try await sessionStore.generatePracticeFeedback(request, onDelta: onDelta)
            },
            cancelRequest: { [weak sessionStore] in sessionStore?.cancelPracticeRequest($0) },
            cancelSessionWork: { [weak sessionStore] in sessionStore?.cancelPracticeSession($0) },
            speechRecognizer: speechRecognizer,
            speechPlayer: speechPlayer
        )
    }

    init(
        modelContext: ModelContext,
        generator: @escaping Generator,
        cancelRequest: @escaping (UUID) -> Void = { _ in },
        cancelSessionWork: @escaping (UUID) -> Void = { _ in },
        speechRecognizer: (any SpeechRecognizing)? = nil,
        speechPlayer: (any PracticeSpeechPlaying)? = nil
    ) {
        self.modelContext = modelContext
        self.generator = generator
        self.cancelRequest = cancelRequest
        self.cancelSessionWork = cancelSessionWork
        self.speechRecognizer = speechRecognizer ?? SpeechRecognizer()
        self.speechPlayer = speechPlayer ?? PracticeSpeechSynthesizer()
        bindSpeechCallbacks()
    }

    var progressTitle: String {
        guard let session else { return "" }
        let current = min(questionIndex + 1, max(1, session.requestedRounds))
        return "Вопрос \(current) из \(session.requestedRounds)"
    }

    var canSubmitAnswer: Bool {
        (phase == .listening || phase == .followUp)
            && !draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start(configuration: PracticeLaunchConfiguration, speakQuestions: Bool) {
        guard phase == .ready || phase == .finished else { return }
        resetTransientState()
        do {
            try QuestionBankService.seedIfNeeded(in: modelContext)
            let all = try modelContext.fetch(FetchDescriptor<PracticeQuestionRecord>())
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            let requested = Array(configuration.questionIDs.prefix(max(1, min(8, configuration.rounds))))
            let selected = requested.compactMap { byID[$0] }
            guard !selected.isEmpty else {
                errorMessage = "Выбранный вопрос не найден. Вернитесь в банк и выберите его снова."
                return
            }
            self.configuration = configuration
            self.questions = selected
            self.speakQuestions = speakQuestions
            questionIndex = 0
            let record = PracticeSessionRecord(
                mode: configuration.mode,
                interviewerRole: configuration.interviewerRole,
                difficulty: configuration.difficulty,
                requestedRounds: selected.count,
                maxDurationSeconds: max(60, min(60 * 60, configuration.maxDurationSeconds)),
                questionIDs: selected.map(\.id)
            )
            if let job = configuration.jobSnapshot {
                record.jobID = job.id
                record.jobRevision = job.revision
                record.jobTitle = job.title
                record.jobSnapshotText = job.referenceText
                record.isCompanySimulation = true
            }
            modelContext.insert(record)
            session = record
            try presentQuestion(selected[0], in: record)
            try modelContext.save()
            beginDurationLimit(seconds: record.maxDurationSeconds, sessionID: record.id)
        } catch {
            errorMessage = "Не удалось начать тренировку. Локальные данные не удалены."
            phase = .ready
        }
    }

    func toggleListening() {
        if isListening { stopListening() } else { startListening() }
    }

    func startListening() {
        guard phase == .listening || phase == .followUp, !isListening else { return }
        // Never let synthesized speech enter recognition as the user's answer.
        speechPlayer.stop()
        presentationGeneration = UUID()
        isListening = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await speechRecognizer.start()
                guard !Task.isCancelled, isListening else { return }
            } catch {
                guard !Task.isCancelled else { return }
                isListening = false
                errorMessage = (error as? SpeechError)?.localizedDescription
                    ?? "Не удалось включить микрофон. Введённый текст сохранён на экране."
            }
        }
    }

    func stopListening() {
        guard isListening || speechRecognizer.state != .idle else { return }
        speechRecognizer.stop()
        isListening = false
    }

    func skipQuestionSpeech() {
        guard phase == .asking, let turn else { return }
        presentationGeneration = UUID()
        speechPlayer.stop()
        turn.statusRaw = PracticeTurnStatus.listening.rawValue
        phase = .listening
        try? modelContext.save()
    }

    func cancelEvaluation() {
        guard phase == .evaluating, let turn else { return }
        cancelCurrentRequest(markAsCancelled: true)
        turn.statusRaw = PracticeTurnStatus.cancelled.rawValue
        phase = .feedback
        try? modelContext.save()
    }

    func submitAnswer() {
        guard canSubmitAnswer, let turn, let session, let configuration else { return }
        let cleaned = String(draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12_000))
        guard !cleaned.isEmpty else { return }
        stopListening()
        speechPlayer.stop()
        if phase == .followUp, let followUp = turn.followUpQuestion {
            turn.followUpAnswer = cleaned
            turn.answerText += "\n\nУточнение: \(followUp)\nОтвет: \(cleaned)"
            turn.answerRevision += 1
            markFeedbackStale(turnID: turn.id)
        } else if !turn.answerText.isEmpty, turn.answerText != cleaned {
            turn.answerText = cleaned
            turn.answerRevision += 1
            turn.answeredAt = .now
            markFeedbackStale(turnID: turn.id)
        } else {
            turn.answerText = cleaned
            turn.answeredAt = .now
        }
        draftAnswer = ""
        let allowFollowUp = turn.followUpQuestion == nil
        evaluate(turn: turn, session: session, allowFollowUp: allowFollowUp)
    }

    func skipFollowUp() {
        guard phase == .followUp, let turn, let session else { return }
        completeTurn(turn, session: session)
        phase = .feedback
        try? modelContext.save()
    }

    func retryEvaluation() {
        guard let turn, let session, !turn.answerText.isEmpty, phase == .feedback else { return }
        evaluate(turn: turn, session: session, allowFollowUp: false, exampleStyle: selectedExampleStyle)
    }

    func requestExample(style: PracticeExampleStyle) {
        guard phase == .feedback, let turn, let session, !turn.answerText.isEmpty else { return }
        selectedExampleStyle = style
        evaluate(turn: turn, session: session, allowFollowUp: false, exampleStyle: style)
    }

    func reviseAnswer() {
        guard phase == .feedback, let turn, !turn.answerText.isEmpty else { return }
        draftAnswer = turn.answerText
        turn.statusRaw = PracticeTurnStatus.listening.rawValue
        phase = .listening
    }

    func nextQuestion() {
        guard phase == .feedback, let session else { return }
        if questionIndex + 1 >= questions.count {
            finishSession()
            return
        }
        questionIndex += 1
        do {
            try presentQuestion(questions[questionIndex], in: session)
            try modelContext.save()
        } catch {
            errorMessage = "Не удалось открыть следующий вопрос. Завершите тренировку и повторите позже."
        }
    }

    func finishSession() {
        guard let session, session.endedAt == nil else { return }
        stopListening()
        speechPlayer.stop()
        cancelCurrentRequest(markAsCancelled: true)
        durationTask?.cancel()
        durationTask = nil
        let turns = fetchTurns(sessionID: session.id)
        let feedback = fetchFeedback(sessionID: session.id)
        let summary = PracticeSummaryBuilder.build(turns: turns, feedback: feedback)
        session.summaryText = summary.text
        session.nextExercisesData = (try? JSONEncoder().encode(summary.exercises)) ?? Data("[]".utf8)
        session.completedRounds = turns.filter { !$0.answerText.isEmpty }.count
        session.statusRaw = PracticeSessionStatus.completed.rawValue
        session.endedAt = .now
        session.updatedAt = .now
        if let turn {
            turn.statusRaw = turn.answerText.isEmpty
                ? PracticeTurnStatus.cancelled.rawValue
                : PracticeTurnStatus.completed.rawValue
        }
        try? modelContext.save()
        phase = .finished
    }

    func repeatSameQuestion() {
        guard let current = configuration, let questionID = turn?.questionID else { return }
        if session?.endedAt == nil { finishSession() }
        start(configuration: .init(
            mode: .quick,
            questionIDs: [questionID],
            interviewerRole: current.interviewerRole,
            difficulty: current.difficulty,
            rounds: 1,
            maxDurationSeconds: current.maxDurationSeconds,
            jobSnapshot: current.jobSnapshot
        ), speakQuestions: speakQuestions)
    }

    func handleAppInactive() {
        guard let session, session.endedAt == nil else { return }
        stopListening()
        speechPlayer.stop()
        cancelCurrentRequest(markAsCancelled: true)
        cancelSessionWork(session.id)
        durationTask?.cancel()
        durationTask = nil
        session.statusRaw = PracticeSessionStatus.interrupted.rawValue
        session.endedAt = .now
        session.updatedAt = .now
        if turn?.statusRaw == PracticeTurnStatus.evaluating.rawValue {
            turn?.statusRaw = PracticeTurnStatus.cancelled.rawValue
        }
        try? modelContext.save()
        errorMessage = "Тренировка остановлена в фоне. Ответ сохранён; автоматического возобновления нет."
        phase = .finished
    }

    func leaveScreen() {
        guard let session, session.endedAt == nil else {
            stopListening()
            speechPlayer.stop()
            return
        }
        stopListening()
        speechPlayer.stop()
        cancelCurrentRequest(markAsCancelled: true)
        cancelSessionWork(session.id)
        durationTask?.cancel()
        session.statusRaw = PracticeSessionStatus.cancelled.rawValue
        session.endedAt = .now
        session.updatedAt = .now
        try? modelContext.save()
    }

    private func bindSpeechCallbacks() {
        speechRecognizer.onTranscript = { [weak self] text, _, _ in
            guard let self, self.isListening,
                  self.phase == .listening || self.phase == .followUp else { return }
            self.draftAnswer = String(text.prefix(12_000))
        }
        speechRecognizer.onStateChange = { [weak self] state in
            guard let self else { return }
            if state == .idle { self.isListening = false }
        }
        speechRecognizer.onFailure = { [weak self] error in
            guard let self else { return }
            self.isListening = false
            self.errorMessage = (error as? SpeechError)?.localizedDescription
                ?? "Распознавание остановилось. Текст попытки сохранён."
        }
    }

    private func presentQuestion(_ question: PracticeQuestionRecord, in session: PracticeSessionRecord) throws {
        feedback = nil
        comparison = nil
        selectedExampleStyle = .standard
        streamedFeedback = ""
        draftAnswer = ""
        let next = PracticeTurnRecord(
            sessionID: session.id,
            question: question,
            orderIndex: questionIndex
        )
        modelContext.insert(next)
        turn = next
        try QuestionBankService.recordAttempt(questionID: question.id, in: modelContext)
        phase = .asking
        let generation = UUID()
        presentationGeneration = generation
        if speakQuestions {
            stopListening()
            speechPlayer.speak(question.text) { [weak self] in
                guard let self, self.presentationGeneration == generation,
                      self.session?.id == session.id, self.turn?.id == next.id else { return }
                next.statusRaw = PracticeTurnStatus.listening.rawValue
                self.phase = .listening
                try? self.modelContext.save()
            }
        } else {
            next.statusRaw = PracticeTurnStatus.listening.rawValue
            phase = .listening
        }
    }

    private func evaluate(
        turn: PracticeTurnRecord,
        session: PracticeSessionRecord,
        allowFollowUp: Bool,
        exampleStyle: PracticeExampleStyle = .standard
    ) {
        cancelCurrentRequest(markAsCancelled: false)
        let requestID = UUID()
        activeRequestID = requestID
        turn.requestID = requestID
        turn.statusRaw = PracticeTurnStatus.evaluating.rawValue
        phase = .evaluating
        selectedExampleStyle = exampleStyle
        streamedFeedback = ""
        errorMessage = nil
        let feedbackRecord = PracticeFeedbackRecord(
            sessionID: session.id,
            turnID: turn.id,
            answerRevision: turn.answerRevision,
            requestID: requestID
        )
        modelContext.insert(feedbackRecord)
        feedback = feedbackRecord
        try? modelContext.save()
        let input = PracticeEvaluationRequest(
            requestID: requestID,
            practiceSessionID: session.id,
            turnID: turn.id,
            question: turn.questionText,
            answer: turn.answerText,
            type: PracticeQuestionType(rawValue: turn.typeRaw) ?? .technical,
            allowFollowUp: allowFollowUp,
            exampleStyle: exampleStyle,
            jobSnapshot: configuration?.jobSnapshot
        )
        let expectedRevision = turn.answerRevision
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await generator(input) { [weak self] value in
                    guard let self, self.activeRequestID == requestID,
                          self.session?.id == session.id,
                          self.turn?.id == turn.id,
                          self.turn?.answerRevision == expectedRevision else { return }
                    self.streamedFeedback = String(value.prefix(20_000))
                    feedbackRecord.statusRaw = PracticeFeedbackStatus.streaming.rawValue
                }
                guard !Task.isCancelled, activeRequestID == requestID,
                      self.session?.id == session.id,
                      self.turn?.id == turn.id,
                      turn.answerRevision == expectedRevision else { return }
                let parsed = PracticeFeedbackParser.parse(
                    raw: result.text,
                    answer: turn.answerText,
                    allowFollowUp: allowFollowUp
                )
                apply(
                    parsed, result: result, exampleStyle: exampleStyle,
                    to: feedbackRecord, turn: turn, session: session
                )
                if let followUp = parsed.followUpQuestion, turn.followUpAnswer == nil {
                    turn.followUpQuestion = followUp
                    turn.statusRaw = PracticeTurnStatus.listening.rawValue
                    phase = .followUp
                } else {
                    completeTurn(turn, session: session)
                    phase = .feedback
                }
                activeRequestID = nil
                generationTask = nil
                try modelContext.save()
            } catch is CancellationError {
                guard activeRequestID == requestID else { return }
                feedbackRecord.statusRaw = PracticeFeedbackStatus.cancelled.rawValue
                turn.statusRaw = PracticeTurnStatus.cancelled.rawValue
                activeRequestID = nil
                generationTask = nil
                phase = .feedback
                try? modelContext.save()
            } catch {
                guard activeRequestID == requestID else { return }
                feedbackRecord.statusRaw = PracticeFeedbackStatus.failed.rawValue
                feedbackRecord.safeErrorCategory = ProviderFailure.category(for: error)
                turn.statusRaw = PracticeTurnStatus.failed.rawValue
                session.safeErrorCategory = feedbackRecord.safeErrorCategory
                activeRequestID = nil
                generationTask = nil
                phase = .feedback
                errorMessage = ProviderFailure.message(for: error)
                try? modelContext.save()
            }
        }
    }

    private func apply(
        _ parsed: ParsedPracticeFeedback,
        result: PracticeGenerationResult,
        exampleStyle: PracticeExampleStyle,
        to feedback: PracticeFeedbackRecord,
        turn: PracticeTurnRecord,
        session: PracticeSessionRecord
    ) {
        // Keep the last successful analysis visible until a replacement really succeeds.
        markFeedbackStale(turnID: turn.id, excluding: feedback.id)
        feedback.statusRaw = parsed.status.rawValue
        feedback.promptVersion = "\(result.promptVersion):\(exampleStyle.rawValue)"
        feedback.providerRaw = result.provider.rawValue
        feedback.modelName = result.modelName
        feedback.evidenceFragment = parsed.evidence
        feedback.strengthsData = (try? JSONEncoder().encode(parsed.strengths)) ?? Data("[]".utf8)
        feedback.improvementsData = (try? JSONEncoder().encode(parsed.improvements)) ?? Data("[]".utf8)
        feedback.exampleAnswer = parsed.exampleAnswer
        feedback.followUpQuestion = parsed.followUpQuestion
        feedback.accuracyScore = parsed.scores.accuracy
        feedback.completenessScore = parsed.scores.completeness
        feedback.structureScore = parsed.scores.structure
        feedback.examplesScore = parsed.scores.examples
        turn.providerRaw = result.provider.rawValue
        turn.modelName = result.modelName
        turn.promptVersion = feedback.promptVersion
        session.providerRaw = result.provider.rawValue
        session.modelName = result.modelName
        session.updatedAt = .now
        comparison = previousComparison(for: turn, current: feedback)
    }

    private func completeTurn(_ turn: PracticeTurnRecord, session: PracticeSessionRecord) {
        turn.statusRaw = PracticeTurnStatus.completed.rawValue
        session.completedRounds = fetchTurns(sessionID: session.id).filter {
            !$0.answerText.isEmpty && $0.id != turn.id
        }.count + (turn.answerText.isEmpty ? 0 : 1)
        session.updatedAt = .now
    }

    private func previousComparison(
        for turn: PracticeTurnRecord,
        current: PracticeFeedbackRecord
    ) -> PracticeAttemptComparison? {
        let matchingTurnIDs = Set((try? modelContext.fetch(FetchDescriptor<PracticeTurnRecord>()))?
            .filter { $0.questionID == turn.questionID && $0.id != turn.id }
            .map(\.id) ?? [])
        let previous = (try? modelContext.fetch(FetchDescriptor<PracticeFeedbackRecord>()))?
            .filter {
                matchingTurnIDs.contains($0.turnID) && !$0.isStale
                    && $0.statusRaw == PracticeFeedbackStatus.completed.rawValue
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        guard let previous else { return nil }
        return PracticeAttemptComparison.make(previous: previous, current: current)
    }

    private func markFeedbackStale(turnID: UUID, excluding feedbackID: UUID? = nil) {
        let records = (try? modelContext.fetch(FetchDescriptor<PracticeFeedbackRecord>())) ?? []
        records.filter { $0.turnID == turnID && $0.id != feedbackID && !$0.isStale }
            .forEach { $0.isStale = true }
    }

    private func cancelCurrentRequest(markAsCancelled: Bool) {
        generationTask?.cancel()
        generationTask = nil
        guard let requestID = activeRequestID else { return }
        cancelRequest(requestID)
        activeRequestID = nil
        if markAsCancelled,
           let feedback,
           feedback.statusRaw != PracticeFeedbackStatus.completed.rawValue,
           feedback.statusRaw != PracticeFeedbackStatus.partial.rawValue {
            feedback.statusRaw = PracticeFeedbackStatus.cancelled.rawValue
        }
    }

    private func beginDurationLimit(seconds: Int, sessionID: UUID) {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard let self, self.session?.id == sessionID, self.session?.endedAt == nil else { return }
            self.errorMessage = "Лимит тренировки завершён. Принятые ответы сохранены."
            self.finishSession()
        }
    }

    private func fetchTurns(sessionID: UUID) -> [PracticeTurnRecord] {
        ((try? modelContext.fetch(FetchDescriptor<PracticeTurnRecord>())) ?? [])
            .filter { $0.sessionID == sessionID }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    private func fetchFeedback(sessionID: UUID) -> [PracticeFeedbackRecord] {
        ((try? modelContext.fetch(FetchDescriptor<PracticeFeedbackRecord>())) ?? [])
            .filter { $0.sessionID == sessionID }
    }

    private func resetTransientState() {
        stopListening()
        speechPlayer.stop()
        cancelCurrentRequest(markAsCancelled: true)
        if let old = session, old.endedAt == nil {
            cancelSessionWork(old.id)
            old.statusRaw = PracticeSessionStatus.cancelled.rawValue
            old.endedAt = .now
            old.updatedAt = .now
        }
        durationTask?.cancel()
        durationTask = nil
        session = nil
        turn = nil
        feedback = nil
        comparison = nil
        selectedExampleStyle = .standard
        streamedFeedback = ""
        draftAnswer = ""
        errorMessage = nil
        phase = .ready
    }
}
