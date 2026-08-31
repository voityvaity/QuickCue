import Combine
import Foundation
import SwiftData

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var liveTranscript = ""
    @Published private(set) var currentSession: SessionRecord?
    @Published private(set) var visibleAnswers: [AnswerRecord] = []
    @Published private(set) var activeRequestCount = 0
    @Published var alertMessage: String?

    let speechRecognizer = SpeechRecognizer()

    private let modelContext: ModelContext
    private let settings: AppSettings
    private let detector = QuestionDetector()
    private let router = LatencyFallbackRouter()
    private let logger = LatencyLogger()
    private let ledger: UsageLedger
    private var debounceTask: Task<Void, Never>?
    private var answerTasks: [UUID: Task<Void, Never>] = [:]
    private var recentQuestions: [String: Date] = [:]
    private var turns: [(Date, ConversationTurn)] = []

    init(modelContext: ModelContext, settings: AppSettings) {
        self.modelContext = modelContext
        self.settings = settings
        self.ledger = UsageLedger(modelContext: modelContext)
        speechRecognizer.onTranscript = { [weak self] text, isFinal, confidence in
            self?.receiveTranscript(text, isFinal: isFinal, confidence: confidence)
        }
    }

    deinit {
        debounceTask?.cancel()
        answerTasks.values.forEach { $0.cancel() }
    }

    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    func startListening() {
        if currentSession == nil { beginSession() }
        Task {
            do {
                try await speechRecognizer.start()
                isListening = true
            } catch { alertMessage = error.localizedDescription }
        }
    }

    func stopListening() {
        speechRecognizer.stop()
        isListening = false
        debounceTask?.cancel()
        if !liveTranscript.isEmpty { finalizeCandidate(liveTranscript, confidence: 0) }
    }

    func endSession() {
        stopListening()
        currentSession?.endedAt = .now
        try? modelContext.save()
        currentSession = nil
        liveTranscript = ""
        turns.removeAll()
        recentQuestions.removeAll()
    }

    func submitManualQuestion(_ text: String) {
        if currentSession == nil { beginSession() }
        finalizeCandidate(text, confidence: 1, force: true)
    }

    func answerPhoto(jpeg: Data, recognizedText: String) async -> AnswerRecord? {
        if currentSession == nil { beginSession() }
        let question = recognizedText.isEmpty ? "Реши задачу на фотографии" : recognizedText
        return await ask(question: question, mode: .photo, imageJPEG: jpeg)
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

    private func beginSession() {
        let provider = settings.mockMode ? ProviderKind.mock : settings.primaryProvider
        let title = Date.now.formatted(date: .abbreviated, time: .shortened)
        let session = SessionRecord(title: title, provider: provider)
        modelContext.insert(session)
        currentSession = session
        try? modelContext.save()
    }

    private func receiveTranscript(_ text: String, isFinal: Bool, confidence: Double) {
        liveTranscript = text
        debounceTask?.cancel()
        if isFinal {
            finalizeCandidate(text, confidence: confidence)
        } else {
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                self?.finalizeCandidate(text, confidence: confidence)
            }
        }
    }

    private func finalizeCandidate(_ text: String, confidence: Double, force: Bool = false) {
        guard let session = currentSession else { return }
        let detection = detector.detect(text)
        guard !detection.normalizedText.isEmpty else { return }

        let transcript = TranscriptRecord(
            sessionID: session.id,
            text: detection.normalizedText,
            confidence: confidence,
            isQuestion: detection.isQuestion || force
        )
        modelContext.insert(transcript)
        turns.append((.now, ConversationTurn(role: "speaker", text: detection.normalizedText)))
        trimContext()
        liveTranscript = ""

        guard detection.isQuestion || force else { try? modelContext.save(); return }
        let key = detection.normalizedText.lowercased()
        if let sentAt = recentQuestions[key], Date.now.timeIntervalSince(sentAt) < 8 { return }
        recentQuestions[key] = .now

        if session.questionCount >= settings.sessionQuestionLimit {
            alertMessage = "Мягкий лимит \(settings.sessionQuestionLimit) вопросов достигнут. Работа продолжается."
        }
        session.questionCount += 1
        try? modelContext.save()

        guard activeRequestCount < 2 else {
            alertMessage = "Уже выполняются два запроса. Новый вопрос сохранён в истории без отправки."
            return
        }
        let taskID = UUID()
        answerTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            _ = await self.ask(question: detection.normalizedText, mode: .concise, imageJPEG: nil)
            self.answerTasks[taskID] = nil
        }
    }

    private func ask(question: String, mode: AnswerMode, imageJPEG: Data?) async -> AnswerRecord? {
        guard let session = currentSession else { return nil }
        activeRequestCount += 1
        defer { activeRequestCount -= 1 }

        let request = AIRequest(
            question: question,
            context: turns.map { $0.1 },
            mode: mode,
            imageJPEG: imageJPEG
        )
        let registry = ProviderRegistry(settings: settings)
        let primary = registry.provider(settings.primaryProvider)
        let fallback = settings.mockMode ? nil : registry.provider(settings.fallbackProvider)
        let clock = ContinuousClock()
        let started = clock.now
        var record: AnswerRecord?
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
                    if record == nil {
                        let model = registry.provider(winningKind).modelName
                        let newRecord = AnswerRecord(
                            sessionID: session.id,
                            question: question,
                            provider: winningKind,
                            modelName: model
                        )
                        modelContext.insert(newRecord)
                        visibleAnswers.insert(newRecord, at: 0)
                        record = newRecord
                    }
                    if !firstTokenRecorded {
                        let elapsed = started.duration(to: clock.now).milliseconds
                        record?.firstTokenMilliseconds = elapsed
                        logger.firstToken(provider: winningKind, milliseconds: elapsed)
                        firstTokenRecorded = true
                    }
                    record?.answer += delta
                case .usage(let value):
                    usage = value
                    record?.inputTokens = value.inputTokens
                    record?.outputTokens = value.outputTokens
                case .completed:
                    let elapsed = started.duration(to: clock.now).milliseconds
                    record?.totalMilliseconds = elapsed
                    logger.completed(provider: winningKind, milliseconds: elapsed)
                }
            }
            guard let record else { throw AIProviderError.emptyResponse }
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
            alertMessage = error.localizedDescription
            logger.failed(provider: primary.kind, error: error)
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
}

private extension Duration {
    var milliseconds: Int {
        let components = self.components
        return Int(components.seconds * 1_000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
