import Combine
import Darwin
import Foundation
import UIKit

enum SpeechTestCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    case quiet
    case backgroundNoise
    case technicalVocabulary

    var id: String { rawValue }
    var title: String {
        switch self {
        case .quiet: "Тихая комната"
        case .backgroundNoise: "Фоновый шум"
        case .technicalVocabulary: "Технические термины"
        }
    }
}

struct SpeechEvaluationCase: Identifiable, Equatable, Sendable {
    let id: Int
    let phrase: String
    let expectsQuestion: Bool
}

enum SpeechEvaluationCatalog {
    static let cases: [SpeechEvaluationCase] = {
        let questions = [
            "Что такое декоратор", "Как работает actor", "Почему возникает deadlock",
            "Зачем нужен индекс", "Где хранится контекст", "Когда вызывается deinit",
            "Какая сложность поиска", "Какие типы коллекций доступны", "Сколько памяти нужно",
            "Можно ли изменить tuple", "Нужно ли закрывать соединение", "В чем разница между list и tuple",
            "В чём отличие потока от процесса", "Каким образом работает отмена", "Чем отличается struct от class",
            "Верно ли что словарь сохраняет порядок", "Есть ли ограничение размера", "Расскажите о проекте",
            "Объясните устройство event loop", "Напишите функцию поиска", "Решите задачу с массивом",
            "Найдите ошибку в коде", "Сравните два алгоритма", "Опишите работу индекса",
            "Назовите принципы SOLID", "Приведите пример замыкания", "Перечислите уровни изоляции",
            "Можете объяснить этот подход", "Скажите как работает очередь", "Этот код потокобезопасен",
        ]
        let statements = [
            "Я думаю что это работает", "Мне кажется ответ правильный", "Я использовал Python на проекте",
            "У нас был небольшой сервис", "Мы работали командой из трёх человек", "Это зависит от размера данных",
            "Сначала я написал тесты", "Потом добавил индекс", "Проблема оказалась в сети",
            "Этот подход занимает меньше памяти", "Я не помню точный синтаксис", "Можно перейти к следующей теме",
            "Спасибо за объяснение", "Да я согласен с этим", "Результат был сохранён локально",
            "Что касается базы данных мы выбрали PostgreSQL", "Как оказалось это не ошибка",
            "Как я уже говорил мы использовали очередь", "Как мы договорились встреча начнётся позже",
            "Мы обсуждали как работает декоратор",
        ]
        return questions.enumerated().map {
            SpeechEvaluationCase(id: $0.offset, phrase: $0.element, expectsQuestion: true)
        } + statements.enumerated().map {
            SpeechEvaluationCase(id: questions.count + $0.offset, phrase: $0.element, expectsQuestion: false)
        }
    }()
}

struct SpeechEvaluationSample: Codable, Equatable, Sendable {
    let caseID: Int
    let expectedText: String
    let recognizedText: String
    let expectedQuestion: Bool
    let detectedQuestion: Bool
    let confidence: Double
    let endpointDelayMilliseconds: Int?
    let finalizationMilliseconds: Int?
    var duplicateEvents: Int
}

struct SpeechEvaluationReport: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let appVersion: String
    let appBuild: String
    let revision: String
    let operatingSystem: String
    let deviceFamily: String
    let engine: String
    let locale: String
    let condition: SpeechTestCondition
    let samples: [SpeechEvaluationSample]
}

struct SpeechEvaluationSummary: Equatable, Sendable {
    let sampleCount: Int
    let precision: Double
    let recall: Double
    let duplicateEvents: Int
    let finalizationP50Milliseconds: Int?
    let finalizationP95Milliseconds: Int?

    init(report: SpeechEvaluationReport) {
        sampleCount = report.samples.count
        let truePositive = report.samples.filter { $0.expectedQuestion && $0.detectedQuestion }.count
        let falsePositive = report.samples.filter { !$0.expectedQuestion && $0.detectedQuestion }.count
        let falseNegative = report.samples.filter { $0.expectedQuestion && !$0.detectedQuestion }.count
        precision = Double(truePositive) / Double(max(1, truePositive + falsePositive))
        recall = Double(truePositive) / Double(max(1, truePositive + falseNegative))
        duplicateEvents = report.samples.reduce(0) { $0 + $1.duplicateEvents }
        let finalization = report.samples.compactMap(\.finalizationMilliseconds).sorted()
        finalizationP50Milliseconds = Self.percentile(finalization, fraction: 0.50)
        finalizationP95Milliseconds = Self.percentile(finalization, fraction: 0.95)
    }

    static func percentile(_ values: [Int], fraction: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let bounded = min(max(fraction, 0), 1)
        let index = max(0, Int(ceil(bounded * Double(values.count))) - 1)
        return values[index]
    }
}

@MainActor
final class SpeechBenchmarkArchive {
    private static let key = "speech.benchmarkReports.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [SpeechEvaluationReport] {
        guard let data = defaults.data(forKey: Self.key),
              let reports = try? JSONDecoder().decode([SpeechEvaluationReport].self, from: data) else {
            return []
        }
        return Array(reports.prefix(5))
    }

    func save(_ report: SpeechEvaluationReport) {
        let reports = Array(([report] + load().filter { $0.id != report.id }).prefix(5))
        if let data = try? JSONEncoder().encode(reports) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func removeAll() {
        defaults.removeObject(forKey: Self.key)
    }
}

@MainActor
final class SpeechBenchmarkRunner: ObservableObject {
    @Published private(set) var currentIndex = 0
    @Published private(set) var recognizedText = ""
    @Published private(set) var samples: [SpeechEvaluationSample] = []
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedReports: [SpeechEvaluationReport]
    @Published var condition: SpeechTestCondition = .quiet

    var currentCase: SpeechEvaluationCase? {
        guard currentIndex < SpeechEvaluationCatalog.cases.count else { return nil }
        return SpeechEvaluationCatalog.cases[currentIndex]
    }

    private let recognizer: any SpeechRecognizing
    private let archive: SpeechBenchmarkArchive
    private var assembler = TranscriptAssembler()
    private var startTask: Task<Void, Never>?
    private var endpointTask: Task<Void, Never>?
    private var endpointRequestedAt: Date?
    private var endpointDelayMilliseconds: Int?
    private var generation = UUID()
    private var lastCompletedText: String?
    private var lastCompletedAt: Date?
    private var completedReportID: UUID?

    init(
        recognizer: (any SpeechRecognizing)? = nil,
        defaults: UserDefaults = .standard
    ) {
        let reportArchive = SpeechBenchmarkArchive(defaults: defaults)
        self.recognizer = recognizer ?? SpeechRecognizer()
        self.archive = reportArchive
        self.savedReports = reportArchive.load()
        self.recognizer.onTranscript = { [weak self] text, isFinal, confidence in
            self?.receive(text, isFinal: isFinal, confidence: confidence)
        }
        self.recognizer.onFailure = { [weak self] error in
            guard let self else { return }
            self.isRecording = false
            self.errorMessage = error.localizedDescription
        }
    }

    func startCurrent() {
        guard currentCase != nil, !isRecording else { return }
        stopRecognition()
        generation = UUID()
        assembler.beginUtterance()
        recognizedText = ""
        endpointRequestedAt = nil
        endpointDelayMilliseconds = nil
        errorMessage = nil
        isRecording = true
        let operation = generation
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recognizer.start()
            } catch {
                guard operation == generation, !Task.isCancelled else { return }
                isRecording = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelCurrent() {
        generation = UUID()
        stopRecognition()
        recognizedText = ""
        isRecording = false
        errorMessage = nil
    }

    func resetRun() {
        cancelCurrent()
        currentIndex = 0
        samples = []
        lastCompletedText = nil
        lastCompletedAt = nil
        completedReportID = nil
        errorMessage = nil
    }

    func clearSavedReports() {
        archive.removeAll()
        savedReports = []
    }

    private func receive(_ text: String, isFinal: Bool, confidence: Double) {
        guard isRecording, let item = currentCase else {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if isFinal,
               !normalized.isEmpty,
               let lastCompletedText,
               normalized == lastCompletedText,
               let completedAt = lastCompletedAt,
               Date.now.timeIntervalSince(completedAt) < 1.5,
                !samples.isEmpty {
                samples[samples.index(before: samples.endIndex)].duplicateEvents += 1
                if currentIndex == SpeechEvaluationCatalog.cases.count { finishReport() }
            }
            return
        }
        recognizedText = text
        if let confirmed = assembler.receive(text, isFinal: isFinal) {
            endpointTask?.cancel()
            let finalization = endpointRequestedAt.map {
                max(0, Int(Date.now.timeIntervalSince($0) * 1_000))
            }
            let detected = QuestionDetector().detect(confirmed).isQuestion
            samples.append(SpeechEvaluationSample(
                caseID: item.id,
                expectedText: item.phrase,
                recognizedText: confirmed,
                expectedQuestion: item.expectsQuestion,
                detectedQuestion: detected,
                confidence: confidence,
                endpointDelayMilliseconds: endpointDelayMilliseconds,
                finalizationMilliseconds: finalization,
                duplicateEvents: 0
            ))
            lastCompletedText = confirmed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            lastCompletedAt = .now
            stopRecognition()
            isRecording = false
            currentIndex += 1
            if currentIndex == SpeechEvaluationCatalog.cases.count {
                finishReport()
            }
            return
        }
        guard !isFinal, !assembler.partialText.isEmpty else { return }
        endpointTask?.cancel()
        let operation = generation
        let delay = assembler.endpointDelayNanoseconds
        endpointTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.generation == operation, self.isRecording else { return }
            self.endpointRequestedAt = .now
            self.endpointDelayMilliseconds = Int(delay / 1_000_000)
            self.recognizer.finishCurrentUtterance()
        }
    }

    private func finishReport() {
        let identity = BuildIdentity.current
        let reportID = completedReportID ?? UUID()
        completedReportID = reportID
        let report = SpeechEvaluationReport(
            id: reportID, createdAt: .now,
            appVersion: identity.version, appBuild: identity.build, revision: identity.revision,
            operatingSystem: UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
            deviceFamily: "\(UIDevice.current.model) · \(SpeechDeviceIdentity.hardwareIdentifier)",
            engine: "SFSpeechRecognizer", locale: "ru_RU", condition: condition,
            samples: samples
        )
        archive.save(report)
        savedReports = archive.load()
    }

    private func stopRecognition() {
        startTask?.cancel()
        startTask = nil
        endpointTask?.cancel()
        endpointTask = nil
        recognizer.stop()
    }
}

private enum SpeechDeviceIdentity {
    static var hardwareIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}
