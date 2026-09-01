import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRunning = false
    @Published private(set) var authorizationDenied = false

    var onTranscript: ((String, Bool, Double) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru_RU"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskGeneration: UUID?

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        let granted = speech == .authorized && microphone
        authorizationDenied = !granted
        return granted
    }

    func start() async throws {
        guard !isRunning else { return }
        guard await requestPermissions() else { throw SpeechError.permissionDenied }
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = false }
        self.request = request

        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true

        let generation = UUID()
        taskGeneration = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                guard self.taskGeneration == generation else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    let confidence = Double(result.bestTranscription.segments.last?.confidence ?? 0)
                    self.transcript = text
                    self.onTranscript?(text, result.isFinal, confidence)
                    if result.isFinal, self.isRunning {
                        self.stop()
                        try? await self.start()
                        return
                    }
                }
                if let error {
                    self.stop()
                    self.onFailure?(error)
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        taskGeneration = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum SpeechError: LocalizedError {
    case permissionDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Разрешите доступ к микрофону и распознаванию речи в Настройках iPhone."
        case .unavailable: "Русское распознавание речи сейчас недоступно."
        }
    }
}
