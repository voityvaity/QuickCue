import Combine
import Foundation
import SwiftData
import UIKit

@MainActor
final class SessionStore: ObservableObject {
    struct ConfirmedTranscript: Identifiable, Equatable {
        let id: UUID
        let sessionID: UUID
        let text: String
    }

    @Published private(set) var isListening = false { didSet { updateIdleTimer() } }
    @Published private(set) var isConversationListening = false { didSet { updateIdleTimer() } }
    @Published private(set) var listeningPhase: SpeechRecognitionState = .idle
    @Published private(set) var liveTranscript = ""
    @Published private(set) var conversationLiveTranscript = ""
    @Published private(set) var currentSession: SessionRecord?
    @Published private(set) var visibleAnswers: [AnswerRecord] = []
    @Published private(set) var visibleConversationMessages: [ConversationMessageRecord] = []
    @Published private(set) var activeRequestCount = 0
    @Published private(set) var pendingRequestCount = 0
    @Published private(set) var latestConfirmedTranscript: ConfirmedTranscript?
    @Published var alertMessage: String?

    let speakerAttributionExplanation: String

    private enum RecognitionMode: Equatable {
        case live
        case conversation
    }

    private struct ContextEntry {
        let id: UUID
        let date: Date
        var turn: ConversationTurn
    }

    private let modelContext: ModelContext
    private let settings: AppSettings
    private let detector = QuestionDetector()
    private let speakerAttributor: any SpeakerAttributing
    private let router = LatencyFallbackRouter()
    private let logger = LatencyLogger()
    private let ledger: UsageLedger
    private let scheduler = RequestScheduler()
    private let providerFactory: ((ProviderSelection) -> any AIProvider)?
    private let speechRecognizer: any SpeechRecognizing
    private var recognitionMode: RecognitionMode?
    private var recognitionGeneration = UUID()
    private var startTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var assembler = TranscriptAssembler()
    private var isForeground = true
    private var recentQuestions: [String: Date] = [:]
    private var recentTranscripts: [String: Date] = [:]
    private var turns: [ContextEntry] = []

    /// Internal for deterministic context tests; never logged or exported automatically.
    var contextTurns: [ConversationTurn] { turns.map(\.turn) }

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        speakerAttributor: any SpeakerAttributing = SemanticSpeakerAttributor(),
        providerFactory: ((ProviderSelection) -> any AIProvider)? = nil,
        speechRecognizer: (any SpeechRecognizing)? = nil
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.speakerAttributor = speakerAttributor
        self.speakerAttributionExplanation = speakerAttributor.explanation
        self.ledger = UsageLedger(modelContext: modelContext)
        self.providerFactory = providerFactory
        self.speechRecognizer = speechRecognizer ?? SpeechRecognizer()
        scheduler.onCountsChanged = { [weak self] active, pending in
            self?.activeRequestCount = active
            self?.pendingRequestCount = pending
        }

        self.speechRecognizer.onTranscript = { [weak self] text, isFinal, confidence in
            self?.receiveTranscript(text, isFinal: isFinal, confidence: confidence)
        }
        self.speechRecognizer.onStateChange = { [weak self] phase in
            self?.listeningPhase = phase
        }
        self.speechRecognizer.onUtteranceStarted = { [weak self] in self?.assembler.beginUtterance() }
        self.speechRecognizer.onFailure = { [weak self] error in
            guard let self else { return }
            self.stopCurrentRecognition()
            self.alertMessage = (error as? SpeechError)?.localizedDescription
                ?? "Распознавание остановилось. Проверьте микрофон и снова нажмите «Слушать»."
        }
    }

    deinit {
        debounceTask?.cancel()
        startTask?.cancel()
    }

    func toggleListening() {
        recognitionMode == .live ? stopListening() : startListening()
    }

    func startListening() {
        startRecognition(mode: .live)
    }

    func stopListening() {
        guard recognitionMode == .live else { return }
        stopCurrentRecognition()
    }

    func toggleConversationListening() {
        recognitionMode == .conversation ? stopConversationListening() : startConversationListening()
    }

    func startConversationListening() {
        startRecognition(mode: .conversation)
    }

    func stopConversationListening() {
        guard recognitionMode == .conversation else { return }
        stopCurrentRecognition()
    }

    func stopAllListening() {
        stopCurrentRecognition()
    }

    @discardableResult
    func pauseForSensitiveInput() -> Bool {
        guard listeningPhase != .idle || recognitionMode != nil else { return false }
        stopCurrentRecognition()
        return true
    }

    var listeningStatusTitle: String {
        switch listeningPhase {
        case .idle: "Микрофон выключен"
        case .starting: "Включаю микрофон…"
        case .listening: recognitionMode == .conversation ? "Слушаю диалог" : "Слушаю эфир"
        case .stopping: "Останавливаю микрофон…"
        }
    }

    func handleSceneBecameInactive() {
        isForeground = false
        stopAllListening()
        cancelActiveRequests()
    }

    func handleSceneBecameActive() { isForeground = true }

    func cancelActiveRequests() { scheduler.cancelAll() }

    func cancelAnswer(_ answer: AnswerRecord) { scheduler.cancel(answer.id) }

    /// Runs a paid-capable setup probe through the same application queue as answers.
    /// Its usage row has no session ID, so it never creates a fake conversation.
    func checkProviderConnection(_ selection: ProviderSelection) async -> ProviderConnectionReport {
        await ProviderConnectionChecker.check(selection: selection, settings: settings) { [weak self] provider, requestID in
            guard let self else { throw CancellationError() }
            return try await self.verifySetupProvider(provider, requestID: requestID)
        }
    }

    func verifySetupProvider(
        _ provider: any AIProvider,
        requestID: UUID
    ) async throws -> ProviderConnectionChecker.Result {
        guard isForeground else { throw CancellationError() }
        let box = SetupVerificationBox()
        let setupID = UUID()
        let ticket = scheduler.enqueueSetup(id: requestID, setupID: setupID) { [weak self] in
            guard let self else {
                box.result = .failure(CancellationError())
                return
            }
            let startedAt = Date.now
            do {
                let result = try await ProviderConnectionChecker.verify(provider: provider, requestID: requestID)
                let attempt = AIRequestAttempt(
                    attemptID: UUID(), requestID: requestID, selection: provider.selection,
                    modelName: provider.modelName, startedAt: startedAt, endedAt: .now,
                    outcome: .succeeded, usage: result.usage,
                    inputCharacterCount: result.inputCharacterCount,
                    outputCharacterCount: result.outputCharacterCount,
                    hasImage: false, errorCode: nil
                )
                _ = self.ledger.recordAttempt(
                    attempt, sessionID: nil, requestKind: "connection_test", settings: self.settings
                )
                box.result = .success(result)
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                let attempt = AIRequestAttempt(
                    attemptID: UUID(), requestID: requestID, selection: provider.selection,
                    modelName: provider.modelName, startedAt: startedAt, endedAt: .now,
                    outcome: cancelled ? .cancelled : .failed, usage: nil,
                    inputCharacterCount: 0, outputCharacterCount: 0, hasImage: false,
                    errorCode: SafeErrorCode.classify(error)
                )
                _ = self.ledger.recordAttempt(
                    attempt, sessionID: nil, requestKind: "connection_test", settings: self.settings
                )
                box.result = .failure(cancelled ? CancellationError() : error)
            }
        } onCancel: {
            if box.result == nil { box.result = .failure(CancellationError()) }
        }

        return try await withTaskCancellationHandler {
            await ticket.wait()
            try Task.checkCancellation()
            guard let result = box.result else { throw CancellationError() }
            return try result.get()
        } onCancel: {
            Task { @MainActor [weak self] in self?.scheduler.cancel(requestID) }
        }
    }

    func endSession() {
        stopAllListening()
        scheduler.endSession()
        currentSession?.endedAt = .now
        try? modelContext.save()
        currentSession = nil
        liveTranscript = ""
        conversationLiveTranscript = ""
        turns.removeAll()
        recentQuestions.removeAll()
        recentTranscripts.removeAll()
        visibleAnswers.removeAll()
        visibleConversationMessages.removeAll()
        latestConfirmedTranscript = nil
    }

    func endConversation() {
        endSession()
    }

    func submitManualQuestion(_ text: String) {
        guard isForeground else { return }
        if currentSession == nil { beginSession() }
        finalizeLiveCandidate(text, confidence: 1, force: true)
    }

    func submitConversationText(_ text: String) {
        guard isForeground else { return }
        if currentSession == nil { beginSession() }
        finalizeConversationCandidate(text, confidence: 1, manual: true)
    }

    func answerLatestConfirmedTranscript() {
        guard isForeground, let candidate = latestConfirmedTranscript,
              currentSession?.id == candidate.sessionID, let session = currentSession else { return }
        incrementQuestionCount(session)
        enqueueQuestion(prompt: candidate.text, displayQuestion: candidate.text)
    }

    func answerPhoto(
        jpeg: Data,
        recognizedText: String,
        includeInConversation: Bool = false,
        photoRelativePath: String? = nil,
        expectedSessionID: UUID? = nil
    ) async -> AnswerRecord? {
        guard isForeground, !Task.isCancelled else { return nil }
        // Capture/OCR can complete after End or after another session has started.
        // Such work belongs to its capture session, never to the current one by accident.
        if let expectedSessionID, currentSession?.id != expectedSessionID { return nil }
        if currentSession == nil { beginSession() }
        guard let session = currentSession else { return nil }
        let photoProvider = providerFactory?(settings.primaryProvider)
            ?? ProviderRegistry(settings: settings).provider(settings.primaryProvider)
        if !photoProvider.capabilities.supportsImages,
           recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = "Текст на фото не найден. Переснимите, введите условие вручную или выберите AI с поддержкой изображений."
            return nil
        }
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
            turns.append(ContextEntry(id: photoMessage.id, date: .now, turn: ConversationTurn(role: ConversationSpeaker.me.title, text: photoMessage.text)))
            trimContext()
            assistantMessage = makeAssistantMessage(sessionID: session.id)
        }

        let scheduled = enqueueQuestion(
            prompt: question,
            displayQuestion: question,
            mode: .photo,
            imageJPEG: jpeg,
            conversationMessage: assistantMessage
        )
        guard let (record, ticket) = scheduled else { return nil }
        let requestID = record.id
        return await withTaskCancellationHandler {
            await ticket.wait()
            guard !Task.isCancelled, record.modelContext != nil, !record.isDeleted,
                  currentSession?.id == record.sessionID else { return nil }
            return record.statusRaw == AnswerStatus.cancelled.rawValue ? nil : record
        } onCancel: {
            Task { @MainActor [weak self] in self?.scheduler.cancel(requestID) }
        }
    }

    func preparePhotoSession() -> UUID? {
        guard isForeground else { return nil }
        if currentSession == nil { beginSession() }
        return currentSession?.id
    }

    @discardableResult
    func registerPhoto(sessionID: UUID) -> Bool {
        guard isForeground, let session = currentSession, session.id == sessionID,
              session.endedAt == nil else { return false }
        session.photoCount += 1
        if session.photoCount == settings.sessionPhotoLimit {
            alertMessage = "Мягкий лимит \(settings.sessionPhotoLimit) фотографий достигнут. Работа продолжается."
        }
        try? modelContext.save()
        return true
    }

    func retryAnswer(_ answer: AnswerRecord) {
        guard isForeground, currentSession?.id == answer.sessionID else { return }
        guard answer.requestKindRaw != AnswerMode.photo.rawValue else {
            alertMessage = "Для повторного анализа фото откройте «Камеру» и отправьте снимок ещё раз."
            return
        }
        enqueueQuestion(prompt: answer.question, displayQuestion: answer.question)
    }

    func requestVariation(_ variation: AnswerVariation, for answer: AnswerRecord) {
        guard isForeground, currentSession?.id == answer.sessionID else { return }
        guard answer.requestKindRaw != AnswerMode.photo.rawValue else {
            alertMessage = "Для уточнения решения по фото откройте «Камеру» и отправьте снимок ещё раз."
            return
        }
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
        guard speaker != .assistant, message.kindRaw == ConversationMessageKind.speech.rawValue,
              message.speakerRaw != ConversationSpeaker.assistant.rawValue else { return }
        message.speakerRaw = speaker.rawValue
        if let index = turns.firstIndex(where: { $0.id == message.id }) {
            turns[index].turn = ConversationTurn(role: speaker.title, text: message.text)
        }
        try? modelContext.save()
    }

    func requestAnswer(for message: ConversationMessageRecord) {
        guard isForeground, currentSession?.id == message.sessionID,
              message.kindRaw == ConversationMessageKind.speech.rawValue else { return }
        let assistantMessage = makeAssistantMessage(sessionID: message.sessionID)
        enqueueQuestion(
            prompt: message.text,
            displayQuestion: message.text,
            conversationMessage: assistantMessage
        )
    }

    private func startRecognition(mode: RecognitionMode) {
        guard isForeground else { return }
        if recognitionMode == mode, listeningPhase != .idle { return }
        if recognitionMode != nil { stopCurrentRecognition() }
        if currentSession == nil { beginSession() }
        recognitionMode = mode
        let generation = UUID()
        recognitionGeneration = generation
        // Starting also displays an active stop control while permission UI is pending.
        isListening = mode == .live
        isConversationListening = mode == .conversation
        listeningPhase = .starting
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await speechRecognizer.start()
                guard recognitionGeneration == generation, !Task.isCancelled else { return }
                startTask = nil
            } catch {
                guard recognitionGeneration == generation, !Task.isCancelled else { return }
                startTask = nil
                recognitionMode = nil
                listeningPhase = .idle
                isListening = false
                isConversationListening = false
                alertMessage = (error as? SpeechError)?.localizedDescription
                    ?? "Не удалось включить микрофон. Попробуйте снова."
            }
        }
    }

    private func stopCurrentRecognition() {
        guard recognitionMode != nil || listeningPhase != .idle else { return }
        recognitionGeneration = UUID()
        startTask?.cancel()
        startTask = nil
        recognitionMode = nil
        speechRecognizer.stop()
        debounceTask?.cancel()
        debounceTask = nil
        assembler.discard()
        isListening = false
        isConversationListening = false

        liveTranscript = ""
        conversationLiveTranscript = ""
    }

    private func beginSession() {
        let provider = settings.mockMode ? ProviderKind.mock : settings.primaryProvider.kind
        let title = Date.now.formatted(date: .abbreviated, time: .shortened)
        let session = SessionRecord(title: title, provider: provider)
        modelContext.insert(session)
        currentSession = session
        scheduler.activate(sessionID: session.id)
        turns.removeAll()
        visibleAnswers.removeAll()
        visibleConversationMessages.removeAll()
        try? modelContext.save()
    }

    private func receiveTranscript(_ text: String, isFinal: Bool, confidence: Double) {
        guard isForeground, let recognitionMode else { return }

        switch recognitionMode {
        case .live: liveTranscript = text
        case .conversation: conversationLiveTranscript = text
        }

        let previousPartial = assembler.partialText
        if let confirmed = assembler.receive(text, isFinal: isFinal) {
            debounceTask?.cancel()
            debounceTask = nil
            finalize(confirmed, mode: recognitionMode, confidence: confidence)
        } else {
            guard !isFinal, !assembler.partialText.isEmpty else {
                debounceTask?.cancel()
                debounceTask = nil
                return
            }
            // A confidence-only revision is not new speech and must not postpone
            // the endpoint indefinitely when the recognizer repeats a hypothesis.
            if previousPartial == assembler.partialText, debounceTask != nil { return }
            debounceTask?.cancel()
            let generation = recognitionGeneration
            let delay = assembler.endpointDelayNanoseconds
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self, self.recognitionGeneration == generation else { return }
                self.speechRecognizer.finishCurrentUtterance()
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
        guard let transcript = registerTranscriptIfNew(
            detection: detection,
            confidence: confidence,
            sessionID: session.id,
            namespace: "live",
            forceQuestion: force
        ) else { return }

        turns.append(ContextEntry(id: transcript.id, date: .now, turn: ConversationTurn(role: "speaker", text: detection.normalizedText)))
        trimContext()
        liveTranscript = ""
        latestConfirmedTranscript = ConfirmedTranscript(
            id: transcript.id,
            sessionID: session.id,
            text: detection.normalizedText
        )

        guard force || settings.answerTriggerPolicy == .automatic else {
            try? modelContext.save()
            return
        }
        guard detection.isQuestion || force else { try? modelContext.save(); return }
        guard registerQuestionIfNew(detection.normalizedText) else { return }
        incrementQuestionCount(session)
        enqueueQuestion(prompt: detection.normalizedText, displayQuestion: detection.normalizedText)
    }

    private func finalizeConversationCandidate(_ text: String, confidence: Double, manual: Bool = false) {
        guard let session = currentSession else { return }
        let detection = detector.detect(text)
        guard let _ = registerTranscriptIfNew(
            detection: detection,
            confidence: confidence,
            sessionID: session.id,
            namespace: "conversation",
            forceQuestion: manual
        ) else { return }

        let previousSpeaker = visibleConversationMessages.reversed().compactMap {
            ConversationSpeaker(rawValue: $0.speakerRaw)
        }.first { $0 != .assistant }
        let speaker: ConversationSpeaker = manual ? .me : speakerAttributor.classify(
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
        turns.append(ContextEntry(id: message.id, date: .now, turn: ConversationTurn(role: speaker.title, text: detection.normalizedText)))
        trimContext()
        guard manual || (settings.answerTriggerPolicy == .automatic && speaker == .partner && detection.isQuestion) else {
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
    ) -> TranscriptRecord? {
        guard !detection.normalizedText.isEmpty else { return nil }
        let key = "\(namespace):\(detection.normalizedText.lowercased())"
        if let insertedAt = recentTranscripts[key], Date.now.timeIntervalSince(insertedAt) < 2 {
            return nil
        }
        recentTranscripts[key] = .now
        recentTranscripts = recentTranscripts.filter { Date.now.timeIntervalSince($0.value) < 2 }
        let transcript = TranscriptRecord(
            sessionID: sessionID,
            text: detection.normalizedText,
            confidence: confidence,
            isQuestion: detection.isQuestion || forceQuestion
        )
        modelContext.insert(transcript)
        return transcript
    }

    private func registerQuestionIfNew(_ question: String) -> Bool {
        let key = question.lowercased()
        if let sentAt = recentQuestions[key], Date.now.timeIntervalSince(sentAt) < 8 {
            return false
        }
        recentQuestions[key] = .now
        recentQuestions = recentQuestions.filter { Date.now.timeIntervalSince($0.value) < 8 }
        return true
    }

    private func incrementQuestionCount(_ session: SessionRecord) {
        session.questionCount += 1
        if session.questionCount == settings.sessionQuestionLimit {
            alertMessage = "Мягкий лимит \(settings.sessionQuestionLimit) вопросов достигнут. Работа продолжается."
        }
        try? modelContext.save()
    }

    private func makeAssistantMessage(sessionID: UUID) -> ConversationMessageRecord {
        let message = ConversationMessageRecord(
            sessionID: sessionID,
            speaker: .assistant,
            kind: .answer,
            text: "",
            status: scheduler.activeCount >= 2 ? .queued : .thinking
        )
        modelContext.insert(message)
        visibleConversationMessages.append(message)
        return message
    }

    @discardableResult
    private func enqueueQuestion(
        prompt: String,
        displayQuestion: String,
        mode: AnswerMode = .concise,
        imageJPEG: Data? = nil,
        conversationMessage: ConversationMessageRecord? = nil
    ) -> (AnswerRecord, RequestScheduler.Ticket)? {
        guard isForeground, let session = currentSession, session.endedAt == nil else { return nil }
        let registry = ProviderRegistry(settings: settings)
        let primary = providerFactory?(settings.primaryProvider) ?? registry.provider(settings.primaryProvider, snapshotCredentials: true)
        let reserve = settings.mockMode || !settings.latencyFallbackEnabled
            ? nil
            : (providerFactory?(settings.fallbackProvider) ?? registry.provider(settings.fallbackProvider, snapshotCredentials: true))
        // A vision request may not silently turn into OCR-only on fallback.
        let upload = primary.capabilities.supportsImages ? imageJPEG : nil
        let fallback = upload != nil && reserve?.capabilities.supportsImages != true ? nil : reserve
        let profile: PromptProfileKind = mode == .photo ? .photo : (conversationMessage == nil ? .live : .conversation)
        let promptSnapshot = settings.prompt(for: profile)
        let record = AnswerRecord(
            sessionID: session.id,
            question: displayQuestion,
            provider: primary.kind,
            modelName: primary.modelName,
            requestKind: mode,
            status: .queued
        )
        record.providerRaw = primary.selection.rawValue
        record.promptSnapshot = promptSnapshot
        record.promptVersion = "\(profile.rawValue):v1"
        modelContext.insert(record)
        visibleAnswers.insert(record, at: 0)
        conversationMessage?.answerID = record.id
        conversationMessage?.statusRaw = AnswerStatus.queued.rawValue
        let fallbackDelay = settings.fallbackDelaySeconds
        let ticket = scheduler.enqueue(id: record.id, sessionID: session.id) { [weak self] in
            guard let self else { return }
            await self.ask(
                session: session, record: record, prompt: prompt, mode: mode, imageJPEG: upload,
                primary: primary, fallback: fallback, fallbackDelay: fallbackDelay,
                systemPrompt: promptSnapshot, conversationMessage: conversationMessage
            )
        } onCancel: { [weak self] in
            self?.markCancelled(record, conversationMessage: conversationMessage)
        }
        try? modelContext.save()
        return (record, ticket)
    }

    private func ask(
        session: SessionRecord,
        record: AnswerRecord,
        prompt: String,
        mode: AnswerMode,
        imageJPEG: Data?,
        primary: any AIProvider,
        fallback: (any AIProvider)?,
        fallbackDelay: Double,
        systemPrompt: String,
        conversationMessage: ConversationMessageRecord?
    ) async {
        guard canPublish(record) else { return }
        record.statusRaw = AnswerStatus.thinking.rawValue
        conversationMessage?.statusRaw = AnswerStatus.thinking.rawValue
        trimContext()
        let request = AIRequest(
            id: record.id,
            question: prompt,
            context: contextTurns,
            mode: mode,
            imageJPEG: imageJPEG,
            systemPrompt: systemPrompt
        )
        let clock = ContinuousClock()
        let started = clock.now
        var firstTokenRecorded = false
        var completed = false
        let ledger = self.ledger
        let settings = self.settings
        do {
            for try await (winningProvider, event) in router.stream(
                request: request,
                primary: primary,
                fallback: fallback,
                fallbackDelaySeconds: fallbackDelay,
                onAttemptFinished: { attempt in
                    await MainActor.run {
                        // History deletion is stronger than late billing updates. Ended but
                        // retained sessions may still be charged; removed ones must stay removed.
                        guard let context = session.modelContext, !session.isDeleted else { return }
                        let row = ledger.recordAttempt(attempt, sessionID: session.id, requestKind: mode.rawValue, settings: settings)
                        // Billing belongs to the original session even after the user ends it.
                        session.estimatedCostRUB += row.estimatedCostRUB
                        try? context.save()
                    }
                }
            ) {
                guard canPublish(record) else { throw CancellationError() }
                switch event {
                case .textDelta(let delta):
                    if !firstTokenRecorded {
                        let elapsed = started.duration(to: clock.now).milliseconds
                        record.providerRaw = winningProvider.rawValue
                        record.modelName = winningProvider == primary.selection ? primary.modelName : (fallback?.modelName ?? primary.modelName)
                        record.firstTokenMilliseconds = elapsed
                        record.statusRaw = AnswerStatus.streaming.rawValue
                        conversationMessage?.statusRaw = AnswerStatus.streaming.rawValue
                        logger.firstToken(provider: winningProvider.kind, milliseconds: elapsed, requestID: record.id)
                        firstTokenRecorded = true
                    }
                    record.answer += delta
                    conversationMessage?.text += delta

                case .usage(let value):
                    record.inputTokens = value.inputTokens
                    record.outputTokens = value.outputTokens

                case .completed:
                    let elapsed = started.duration(to: clock.now).milliseconds
                    record.totalMilliseconds = elapsed
                    completed = true
                    logger.completed(provider: winningProvider.kind, milliseconds: elapsed, requestID: record.id)
                }
            }

            guard canPublish(record) else { throw CancellationError() }
            guard completed, !record.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIProviderError.emptyResponse }
            record.statusRaw = AnswerStatus.completed.rawValue
            conversationMessage?.statusRaw = AnswerStatus.completed.rawValue
            turns.append(ContextEntry(id: record.id, date: .now, turn: ConversationTurn(role: "assistant", text: record.answer)))
            warnForBudgetIfNeeded()
            try modelContext.save()
        } catch {
            guard canPublish(record), !(error is CancellationError) else {
                markCancelled(record, conversationMessage: conversationMessage)
                return
            }
            let message = ProviderFailure.message(for: error)
            record.statusRaw = AnswerStatus.failed.rawValue
            record.errorMessage = message
            conversationMessage?.statusRaw = AnswerStatus.failed.rawValue
            // Keep useful partial text visible; the status carries the error separately.
            if conversationMessage?.text.isEmpty == true { conversationMessage?.text = message }
            alertMessage = message
            logger.failed(provider: primary.kind, error: error, requestID: record.id)
            try? modelContext.save()
        }
    }

    private func canPublish(_ record: AnswerRecord) -> Bool {
        guard !Task.isCancelled, isForeground,
              record.modelContext != nil, !record.isDeleted,
              let session = currentSession, session.modelContext != nil, !session.isDeleted else { return false }
        return session.id == record.sessionID && session.endedAt == nil
            && record.statusRaw != AnswerStatus.cancelled.rawValue
    }

    private func markCancelled(_ record: AnswerRecord, conversationMessage: ConversationMessageRecord?) {
        guard record.modelContext != nil, !record.isDeleted,
              record.statusRaw != AnswerStatus.completed.rawValue,
              record.statusRaw != AnswerStatus.failed.rawValue else { return }
        record.statusRaw = AnswerStatus.cancelled.rawValue
        record.errorMessage = "Запрос отменён. Частичный ответ сохранён, если он уже появился."
        conversationMessage?.statusRaw = AnswerStatus.cancelled.rawValue
        if conversationMessage?.text.isEmpty == true { conversationMessage?.text = "Запрос отменён" }
        try? modelContext.save()
    }

    private func trimContext() {
        let cutoff = Date.now.addingTimeInterval(TimeInterval(-settings.contextMinutes * 60))
        turns.removeAll { $0.date < cutoff }
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

@MainActor
private final class SetupVerificationBox {
    var result: Result<ProviderConnectionChecker.Result, Error>?
}

private extension Duration {
    var milliseconds: Int {
        let components = self.components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
