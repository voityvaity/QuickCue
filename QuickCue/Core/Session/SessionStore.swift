import Combine
import Foundation
import SwiftData
import UIKit

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var isListening = false { didSet { updateIdleTimer() } }
    @Published private(set) var isConversationListening = false { didSet { updateIdleTimer() } }
    @Published private(set) var liveTranscript = ""
    @Published private(set) var conversationLiveTranscript = ""
    @Published private(set) var currentSession: SessionRecord?
    @Published private(set) var visibleAnswers: [AnswerRecord] = []
    @Published private(set) var visibleConversationMessages: [ConversationMessageRecord] = []
    @Published private(set) var activeRequestCount = 0
    @Published private(set) var pendingRequestCount = 0
    @Published var alertMessage: String?

    let speechRecognizer = SpeechRecognizer()
    let speakerAttributionExplanation: String

    private enum RecognitionMode: Equatable {
        case live
        case conversation
    }

    private struct QueuedQuestion {
        let prompt: String
        let displayQuestion: String
        let conversationMessage: ConversationMessageRecord?
    }

    private let modelContext: ModelContext
    private let settings: AppSettings
    private let detector = QuestionDetector()
    private let speakerAttributor: any SpeakerAttributing
    private let router = LatencyFallbackRouter()
    private let logger = LatencyLogger()
    private let ledger: UsageLedger
    private var recognitionMode: RecognitionMode?
    private var debounceTask: Task<Void, Never>?
    private var answerTasks: [UUID: Task<Void, Never>] = [:]
    private var queuedQuestions: [QueuedQuestion] = []
    private var recentQuestions: [String: Date] = [:]
    private var recentTranscripts: [String: Date] = [:]
    private var turns: [(Date, ConversationTurn)] = []

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        speakerAttributor: any SpeakerAttributing = SemanticSpeakerAttributor()
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.speakerAttributor = speakerAttributor
        self.speakerAttributionExplanation = speakerAttributor.explanation
        self.ledger = UsageLedger(modelContext: modelContext)

        speechRecognizer.onTranscript = { [weak self] text, isFinal, confidence in
            self?.receiveTranscript(text, isFinal: isFinal, confidence: confidence)
        }
        speechRecognizer.onFailure = { [weak self] error in
            guard let self else { return }
            self.isListening = false
            self.isConversationListening = false
            self.recognitionMode = nil
            self.alertMessage = "Распознавание остановилось: \(error.localizedDescription)"
        }
    }

    deinit {
        debounceTask?.cancel()
        answerTasks.values.forEach { $0.cancel() }
    }

    func toggleListening() {
        recognitionMode == .live ? stopListening() : startListening()
    }

    func startListening() {
        startRecognition(mode: .live)
    }

    func stopListening() {
        guard recognitionMode == .live else { return }
        stopCurrentRecognition(finalizePendingText: true)
    }

    func toggleConversationListening() {
        recognitionMode == .conversation ? stopConversationListening() : startConversationListening()
    }

    func startConversationListening() {
        startRecognition(mode: .conversation)
    }

    func stopConversationListening() {
        guard recognitionMode == .conversation else { return }
        stopCurrentRecognition(finalizePendingText: true)
    }

    func stopAllListening() {
        stopCurrentRecognition(finalizePendingText: true)
    }

    func endSession() {
        stopAllListening()
        currentSession?.endedAt = .now
        try? modelContext.save()
        currentSession = nil
        liveTranscript = ""
        conversationLiveTranscript = ""
        turns.removeAll()
        recentQuestions.removeAll()
        recentTranscripts.removeAll()
    }

    func endConversation() {
        endSession()
    }

    func submitManualQuestion(_ text: String) {
        if currentSession == nil { beginSession() }
        finalizeLiveCandidate(text, confidence: 1, force: true)
    }

    func answerPhoto(
        jpeg: Data,
        recognizedText: String,
        includeInConversation: Bool = false,
        photoRelativePath: String? = nil
    ) async -> AnswerRecord? {
        if currentSession == nil { beginSession() }
        guard let session = currentSession else { return nil }
        let question = recognizedText.isEmpty ? "Реши задачу на фотографии" : recognizedText
        var assistantMessage: ConversationMessageRecord?

        if includeInConversation {
            let photoMessage = ConversationMessageRecord(
                sessionID: session.id,
                speaker: .me,
                kind: .photo,
                text: recognizedText.isEmpty ? "Фото задачи" : recognizedText,
                photoRelativePath: photoRelativePath
            )
            modelContext.insert(photoMessage)
            visibleConversationMessages.append(photoMessage)
            assistantMessage = makeAssistantMessage(sessionID: session.id)
        }

        return await ask(
            prompt: question,
            displayQuestion: "Фото-задача",
            mode: .photo,
            imageJPEG: jpeg,
            conversationMessage: assistantMessage
        )
    }

    func registerPhoto() -> UUID {
        if currentSession == nil { beginSession() }
        guard let session = currentSession else { preconditionFailure("Session must exist") }
        session.photoCount += 1
        if session.photoCount >= settings.sessionPhotoLimit {
            alertMessage = "Мягкий лимит \(settings.sessionPhotoLimit) фотографий достигнут. Работа продолжается."
        }
        try? modelContext.save()
        return session.id
    }

    func retryAnswer(_ answer: AnswerRecord) {
        enqueueQuestion(prompt: answer.question, displayQuestion: answer.question)
    }

    func requestVariation(_ variation: AnswerVariation, for answer: AnswerRecord) {
        let prompt = "\(answer.question)\n\n\(variation.instruction)"
        enqueueQuestion(
            prompt: prompt,
            displayQuestion: "\(variation.title): \(answer.question)"
        )
    }

    func setFeedback(_ value: Int, for answer: AnswerRecord) {
        answer.feedback = answer.feedback == value ? 0 : value
        try? modelContext.save()
    }

    func setSpeaker(_ speaker: ConversationSpeaker, for message: ConversationMessageRecord) {
        guard speaker != .assistant else { return }
        message.speakerRaw = speaker.rawValue
        try? modelContext.save()
    }

    func requestAnswer(for message: ConversationMessageRecord) {
        guard message.kindRaw == ConversationMessageKind.speech.rawValue else { return }
        let assistantMessage = makeAssistantMessage(sessionID: message.sessionID)
        enqueueQuestion(
            prompt: message.text,
            displayQuestion: message.text,
            conversationMessage: assistantMessage
        )
    }

    private func startRecognition(mode: RecognitionMode) {
        if recognitionMode != nil { stopCurrentRecognition(finalizePendingText: true) }
        if currentSession == nil { beginSession() }
        recognitionMode = mode

        Task {
            do {
                try await speechRecognizer.start()
                switch mode {
                case .live: isListening = true
                case .conversation: isConversationListening = true
                }
            } catch {
                recognitionMode = nil
                isListening = false
                isConversationListening = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private func stopCurrentRecognition(finalizePendingText: Bool) {
        let stoppedMode = recognitionMode
        recognitionMode = nil
        speechRecognizer.stop()
        debounceTask?.cancel()
        isListening = false
        isConversationListening = false

        guard finalizePendingText else { return }
        switch stoppedMode {
        case .live where !liveTranscript.isEmpty:
            finalizeLiveCandidate(liveTranscript, confidence: 0)
        case .conversation where !conversationLiveTranscript.isEmpty:
            finalizeConversationCandidate(conversationLiveTranscript, confidence: 0)
        default:
            break
        }
    }

    private func beginSession() {
        let provider = settings.mockMode ? ProviderKind.mock : settings.primaryProvider
        let title = Date.now.formatted(date: .abbreviated, time: .shortened)
        let session = SessionRecord(title: title, provider: provider)
        modelContext.insert(session)
        currentSession = session
        visibleAnswers.removeAll()
        visibleConversationMessages.removeAll()
        try? modelContext.save()
    }

    private func receiveTranscript(_ text: String, isFinal: Bool, confidence: Double) {
        guard let recognitionMode else { return }
        debounceTask?.cancel()

        switch recognitionMode {
        case .live: liveTranscript = text
        case .conversation: conversationLiveTranscript = text
        }

        if isFinal {
            finalize(text, mode: recognitionMode, confidence: confidence)
        } else {
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                self?.finalize(text, mode: recognitionMode, confidence: confidence)
            }
        }
    }

    private func finalize(_ text: String, mode: RecognitionMode, confidence: Double) {
        switch mode {
        case .live: finalizeLiveCandidate(text, confidence: confidence)
        case .conversation: finalizeConversationCandidate(text, confidence: confidence)
        }
    }

    private func finalizeLiveCandidate(_ text: String, confidence: Double, force: Bool = false) {
        guard let session = currentSession else { return }
        let detection = detector.detect(text)
        guard registerTranscriptIfNew(
            detection: detection,
            confidence: confidence,
            sessionID: session.id,
            namespace: "live",
            forceQuestion: force
        ) else { return }

        turns.append((.now, ConversationTurn(role: "speaker", text: detection.normalizedText)))
        trimContext()
        liveTranscript = ""

        guard detection.isQuestion || force else { try? modelContext.save(); return }
        guard registerQuestionIfNew(detection.normalizedText) else { return }
        incrementQuestionCount(session)
        enqueueQuestion(prompt: detection.normalizedText, displayQuestion: detection.normalizedText)
    }

    private func finalizeConversationCandidate(_ text: String, confidence: Double) {
        guard let session = currentSession else { return }
        let detection = detector.detect(text)
        guard registerTranscriptIfNew(
            detection: detection,
            confidence: confidence,
            sessionID: session.id,
            namespace: "conversation",
            forceQuestion: false
        ) else { return }

        let previousSpeaker = visibleConversationMessages.reversed().compactMap {
            ConversationSpeaker(rawValue: $0.speakerRaw)
        }.first { $0 != .assistant }
        let speaker = speakerAttributor.classify(
            detection: detection,
            previousSpeaker: previousSpeaker
        )
        let message = ConversationMessageRecord(
            sessionID: session.id,
            speaker: speaker,
            kind: .speech,
            text: detection.normalizedText,
            confidence: confidence
        )
        modelContext.insert(message)
        visibleConversationMessages.append(message)
        conversationLiveTranscript = ""
        turns.append((.now, ConversationTurn(role: speaker.title, text: detection.normalizedText)))
        trimContext()

        guard speaker == .partner, detection.isQuestion else {
            try? modelContext.save()
            return
        }
        guard registerQuestionIfNew(detection.normalizedText) else { return }
        incrementQuestionCount(session)
        let assistantMessage = makeAssistantMessage(sessionID: session.id)
        enqueueQuestion(
            prompt: detection.normalizedText,
            displayQuestion: detection.normalizedText,
            conversationMessage: assistantMessage
        )
    }

    private func registerTranscriptIfNew(
        detection: QuestionDetection,
        confidence: Double,
        sessionID: UUID,
        namespace: String,
        forceQuestion: Bool
    ) -> Bool {
        guard !detection.normalizedText.isEmpty else { return false }
        let key = "\(namespace):\(detection.normalizedText.lowercased())"
        if let insertedAt = recentTranscripts[key], Date.now.timeIntervalSince(insertedAt) < 2 {
            return false
        }
        recentTranscripts[key] = .now
        modelContext.insert(TranscriptRecord(
            sessionID: sessionID,
            text: detection.normalizedText,
            confidence: confidence,
            isQuestion: detection.isQuestion || forceQuestion
        ))
        return true
    }

    private func registerQuestionIfNew(_ question: String) -> Bool {
        let key = question.lowercased()
        if let sentAt = recentQuestions[key], Date.now.timeIntervalSince(sentAt) < 8 {
            return false
        }
        recentQuestions[key] = .now
        return true
    }

    private func incrementQuestionCount(_ session: SessionRecord) {
        if session.questionCount >= settings.sessionQuestionLimit {
            alertMessage = "Мягкий лимит \(settings.sessionQuestionLimit) вопросов достигнут. Работа продолжается."
        }
        session.questionCount += 1
        try? modelContext.save()
    }

    private func makeAssistantMessage(sessionID: UUID) -> ConversationMessageRecord {
        let message = ConversationMessageRecord(
            sessionID: sessionID,
            speaker: .assistant,
            kind: .answer,
            text: "",
            status: answerTasks.count >= 2 ? .queued : .thinking
        )
        modelContext.insert(message)
        visibleConversationMessages.append(message)
        return message
    }

    private func enqueueQuestion(
        prompt: String,
        displayQuestion: String,
        conversationMessage: ConversationMessageRecord? = nil
    ) {
        let item = QueuedQuestion(
            prompt: prompt,
            displayQuestion: displayQuestion,
            conversationMessage: conversationMessage
        )
        if answerTasks.count >= 2 {
            queuedQuestions.append(item)
            pendingRequestCount = queuedQuestions.count
            conversationMessage?.statusRaw = AnswerStatus.queued.rawValue
            try? modelContext.save()
            return
        }
        startQuestionTask(item)
    }

    private func startQuestionTask(_ item: QueuedQuestion) {
        item.conversationMessage?.statusRaw = AnswerStatus.thinking.rawValue
        let taskID = UUID()
        answerTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            _ = await self.ask(
                prompt: item.prompt,
                displayQuestion: item.displayQuestion,
                mode: .concise,
                imageJPEG: nil,
                conversationMessage: item.conversationMessage
            )
            self.finishQuestionTask(taskID)
        }
    }

    private func finishQuestionTask(_ taskID: UUID) {
        answerTasks[taskID] = nil
        guard answerTasks.count < 2, !queuedQuestions.isEmpty else {
            pendingRequestCount = queuedQuestions.count
            return
        }
        let next = queuedQuestions.removeFirst()
        pendingRequestCount = queuedQuestions.count
        startQuestionTask(next)
    }

    private func ask(
        prompt: String,
        displayQuestion: String,
        mode: AnswerMode,
        imageJPEG: Data?,
        conversationMessage: ConversationMessageRecord?
    ) async -> AnswerRecord? {
        guard let session = currentSession else { return nil }
        activeRequestCount += 1
        defer { activeRequestCount -= 1 }

        let registry = ProviderRegistry(settings: settings)
        let primary = registry.provider(settings.primaryProvider)
        let fallback = settings.mockMode ? nil : registry.provider(settings.fallbackProvider)
        let record = AnswerRecord(
            sessionID: session.id,
            question: displayQuestion,
            provider: primary.kind,
            modelName: primary.modelName,
            requestKind: mode,
            status: .thinking
        )
        modelContext.insert(record)
        visibleAnswers.insert(record, at: 0)
        conversationMessage?.answerID = record.id

        let request = AIRequest(
            question: prompt,
            context: turns.map { $0.1 },
            mode: mode,
            imageJPEG: imageJPEG
        )
        let clock = ContinuousClock()
        let started = clock.now
        var firstTokenRecorded = false
        var usage = TokenUsage(inputTokens: 0, outputTokens: 0)

        do {
            for try await (winningKind, event) in router.stream(
                request: request,
                primary: primary,
                fallback: fallback,
                fallbackDelaySeconds: settings.fallbackDelaySeconds
            ) {
                switch event {
                case .textDelta(let delta):
                    if !firstTokenRecorded {
                        let elapsed = started.duration(to: clock.now).milliseconds
                        record.providerRaw = winningKind.rawValue
                        record.modelName = registry.provider(winningKind).modelName
                        record.firstTokenMilliseconds = elapsed
                        record.statusRaw = AnswerStatus.streaming.rawValue
                        conversationMessage?.statusRaw = AnswerStatus.streaming.rawValue
                        logger.firstToken(provider: winningKind, milliseconds: elapsed)
                        firstTokenRecorded = true
                    }
                    record.answer += delta
                    conversationMessage?.text += delta

                case .usage(let value):
                    usage = value
                    record.inputTokens = value.inputTokens
                    record.outputTokens = value.outputTokens

                case .completed:
                    let elapsed = started.duration(to: clock.now).milliseconds
                    record.totalMilliseconds = elapsed
                    record.statusRaw = AnswerStatus.completed.rawValue
                    conversationMessage?.statusRaw = AnswerStatus.completed.rawValue
                    logger.completed(provider: winningKind, milliseconds: elapsed)
                }
            }

            guard !record.answer.isEmpty else { throw AIProviderError.emptyResponse }
            record.statusRaw = AnswerStatus.completed.rawValue
            conversationMessage?.statusRaw = AnswerStatus.completed.rawValue
            turns.append((.now, ConversationTurn(role: "assistant", text: record.answer)))
            let provider = ProviderKind(rawValue: record.providerRaw) ?? .mock
            let cost = settings.estimatedCostRUB(for: usage, provider: provider)
            ledger.record(
                sessionID: session.id,
                provider: provider,
                kind: mode.rawValue,
                usage: usage,
                estimatedCostRUB: cost
            )
            session.estimatedCostRUB += cost
            warnForBudgetIfNeeded()
            try modelContext.save()
            return record
        } catch {
            record.statusRaw = AnswerStatus.failed.rawValue
            record.errorMessage = error.localizedDescription
            conversationMessage?.statusRaw = AnswerStatus.failed.rawValue
            conversationMessage?.kindRaw = ConversationMessageKind.error.rawValue
            conversationMessage?.text = error.localizedDescription
            alertMessage = error.localizedDescription
            logger.failed(provider: primary.kind, error: error)
            try? modelContext.save()
            return nil
        }
    }

    private func trimContext() {
        let cutoff = Date.now.addingTimeInterval(TimeInterval(-settings.contextMinutes * 60))
        turns.removeAll { $0.0 < cutoff }
    }

    private func warnForBudgetIfNeeded() {
        guard settings.monthlyBudgetRUB > 0 else { return }
        let fraction = ledger.monthlySpend() / settings.monthlyBudgetRUB
        if fraction >= 1 {
            alertMessage = "Оценочный месячный бюджет достигнут. Запросы не заблокированы; включите Mock или смените модель."
        } else if fraction >= 0.9 {
            alertMessage = "Использовано около 90% оценочного месячного бюджета."
        } else if fraction >= 0.7 {
            alertMessage = "Использовано около 70% оценочного месячного бюджета."
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isListening || isConversationListening
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = self.components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
