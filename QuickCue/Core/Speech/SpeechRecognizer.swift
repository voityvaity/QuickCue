import AVFoundation
import Combine
import Foundation
import Speech

enum SpeechRecognitionState: String, Equatable {
    case idle, starting, listening, stopping
}

/// A generation invalidates permission requests and callbacks after Stop.
struct SpeechLifecycle {
    private(set) var state: SpeechRecognitionState = .idle
    private(set) var generation = UUID()

    mutating func beginStart() -> UUID {
        generation = UUID()
        state = .starting
        return generation
    }

    func isCurrent(_ candidate: UUID) -> Bool {
        generation == candidate && (state == .starting || state == .listening)
    }

    mutating func didStart(_ candidate: UUID) {
        guard isCurrent(candidate) else { return }
        state = .listening
    }

    mutating func beginStop() {
        generation = UUID()
        state = .stopping
    }

    mutating func didStop() { state = .idle }
}

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var state: SpeechRecognitionState = .idle
    @Published private(set) var authorizationDenied = false
    var isRunning: Bool { state == .listening }

    var onTranscript: ((String, Bool, Double) -> Void)?
    var onUtteranceStarted: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru_RU"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskGeneration: UUID?
    private var lifecycle = SpeechLifecycle()
    private var tapInstalled = false
    private var awaitingFinal = false
    private var finalTimeoutTask: Task<Void, Never>?
    private var notifications: Set<AnyCancellable> = []

    init() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { @Sendable [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor [weak self] in self?.stopWithFailure(SpeechError.interrupted) }
            }.store(in: &notifications)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { @Sendable [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                Task { @MainActor [weak self] in self?.stopWithFailure(SpeechError.audioInputUnavailable) }
            }.store(in: &notifications)
    }

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        // Do not open another permission dialog after the user has already stopped.
        guard !Task.isCancelled else { return false }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        let granted = speech == .authorized && microphone
        authorizationDenied = !granted
        return granted
    }

    func start() async throws {
        guard state == .idle else { return }
        let generation = lifecycle.beginStart()
        state = lifecycle.state
        do {
            let granted = await requestPermissions()
            guard lifecycle.isCurrent(generation), !Task.isCancelled else { throw CancellationError() }
            guard granted else { throw SpeechError.permissionDenied }
            guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try startAudioTask(recognizer: recognizer, lifecycleGeneration: generation)
            lifecycle.didStart(generation)
            state = lifecycle.state
        } catch {
            if lifecycle.isCurrent(generation) { stop() }
            throw error
        }
    }

    /// Requests an authoritative final result; a partial hypothesis is never submitted itself.
    func finishCurrentUtterance() {
        guard state == .listening, !awaitingFinal, task != nil else { return }
        awaitingFinal = true
        stopAudioInput()
        request?.endAudio()
        task?.finish()
        let generation = taskGeneration
        finalTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.taskGeneration == generation, self.awaitingFinal else { return }
            self.stopWithFailure(SpeechError.finalResultTimedOut)
        }
    }

    func stop() {
        lifecycle.beginStop()
        state = lifecycle.state
        tearDownRecognition()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcript = ""
        lifecycle.didStop()
        state = lifecycle.state
    }

    private func startAudioTask(recognizer: SFSpeechRecognizer, lifecycleGeneration: UUID) throws {
        guard lifecycle.isCurrent(lifecycleGeneration) else { throw CancellationError() }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Keep the known ru-RU runtime path until SpeechAnalyzer has passed the device A/B gate.
        self.request = request
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.audioInputUnavailable }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()

        transcript = ""
        awaitingFinal = false
        let generation = UUID()
        taskGeneration = generation
        onUtteranceStarted?()
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // Do not send Apple's non-Sendable result object between executors.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let confidence = Double(result?.bestTranscription.segments.last?.confidence ?? 0)
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle.isCurrent(lifecycleGeneration), self.taskGeneration == generation else { return }
                if let text {
                    self.transcript = text
                    self.onTranscript?(text, isFinal, confidence)
                    if isFinal {
                        guard self.lifecycle.isCurrent(lifecycleGeneration), self.taskGeneration == generation else { return }
                        self.tearDownRecognition()
                        guard self.lifecycle.isCurrent(lifecycleGeneration) else { return }
                        do {
                            guard let recognizer = self.recognizer else { throw SpeechError.unavailable }
                            try self.startAudioTask(recognizer: recognizer, lifecycleGeneration: lifecycleGeneration)
                        } catch { self.stopWithFailure(error) }
                        return
                    }
                }
                if let error { self.stopWithFailure(error) }
            }
        }
    }

    private func stopAudioInput() {
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func tearDownRecognition() {
        // Invalidate first: cancellation can synchronously schedule a recognizer callback.
        taskGeneration = nil
        finalTimeoutTask?.cancel()
        finalTimeoutTask = nil
        stopAudioInput()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        awaitingFinal = false
    }

    private func stopWithFailure(_ error: Error) {
        guard state != .idle else { return }
        stop()
        onFailure?(error)
    }
}

enum SpeechError: LocalizedError {
    case permissionDenied
    case unavailable
    case interrupted
    case audioInputUnavailable
    case finalResultTimedOut

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Разрешите доступ к микрофону и распознаванию речи в Настройках iPhone."
        case .unavailable: "Русское распознавание речи сейчас недоступно."
        case .interrupted: "Микрофон остановлен из-за звонка или другого аудиоприложения. Нажмите «Слушать» для продолжения."
        case .audioInputUnavailable: "Аудиоустройство отключено. Проверьте микрофон и снова нажмите «Слушать»."
        case .finalResultTimedOut: "Распознаватель не завершил фразу вовремя. Нажмите «Слушать» для продолжения."
        }
    }
}
