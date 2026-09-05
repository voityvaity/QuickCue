import Foundation

protocol SpeakerAttributing: Sendable {
    var explanation: String { get }
    func classify(
        detection: QuestionDetection,
        previousSpeaker: ConversationSpeaker?
    ) -> ConversationSpeaker
}

/// iOS speech-to-text returns words, not a stable speaker identity. The MVP makes a
/// transparent semantic guess: questions are usually the interlocutor and answers
/// are usually the owner. Every speech bubble remains manually correctable.
struct SemanticSpeakerAttributor: SpeakerAttributing {
    let explanation = "Роли пока определяются по смыслу фразы. Нажмите на метку, чтобы исправить говорящего."

    func classify(
        detection: QuestionDetection,
        previousSpeaker: ConversationSpeaker?
    ) -> ConversationSpeaker {
        if detection.isQuestion { return .partner }
        if previousSpeaker == .partner { return .me }
        return .me
    }
}

enum SpeakerAttributionSource: String, Codable, Sendable {
    case semantic
    case manual
    case hybrid

    var title: String {
        switch self {
        case .semantic: "Предположение по смыслу"
        case .manual: "Назначено вручную"
        case .hybrid: "Экспериментальная метка голоса"
        }
    }
}

enum DiarizationSpeakerLabel: String, Codable, CaseIterable, Sendable {
    case speakerA
    case speakerB
    case unknown

    var title: String {
        switch self {
        case .speakerA: "Speaker A"
        case .speakerB: "Speaker B"
        case .unknown: "Не определён"
        }
    }
}

struct SpeakerLabelMapping: Equatable, Sendable {
    private var assignments: [DiarizationSpeakerLabel: ConversationSpeaker] = [:]

    mutating func bind(_ label: DiarizationSpeakerLabel, to speaker: ConversationSpeaker) {
        guard label != .unknown, speaker == .me || speaker == .partner else { return }
        if let existingLabel = assignments.first(where: { $0.value == speaker })?.key {
            assignments[existingLabel] = nil
        }
        assignments[label] = speaker
    }

    func speaker(for label: DiarizationSpeakerLabel) -> ConversationSpeaker? {
        assignments[label]
    }

    mutating func clear() { assignments.removeAll() }
}

enum HybridSpeakerAssignment {
    static let minimumConfidence = 0.65

    /// `nil` means a manual correction owns the message and must not be replaced.
    static func resolve(
        label: DiarizationSpeakerLabel,
        confidence: Double,
        mapping: SpeakerLabelMapping,
        manuallyLocked: Bool
    ) -> ConversationSpeaker? {
        guard !manuallyLocked else { return nil }
        guard confidence >= minimumConfidence,
              let speaker = mapping.speaker(for: label) else { return .unknown }
        return speaker
    }
}

/// Short-lived PCM bytes for a future diarization adapter. This type has no file
/// or network API; the session owner must clear it on stop/background/end.
struct EphemeralDiarizationBuffer: Sendable {
    let maximumBytes: Int
    private(set) var bytes = Data()

    init(maximumBytes: Int = 1_048_576) {
        self.maximumBytes = max(1, maximumBytes)
    }

    var count: Int { bytes.count }

    mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        bytes.append(chunk)
        if bytes.count > maximumBytes {
            bytes = Data(bytes.suffix(maximumBytes))
        }
    }

    mutating func clear() {
        bytes.removeAll(keepingCapacity: false)
    }
}

enum AnswerVariation {
    case concise
    case example
    case detailed
    case alternative

    var title: String {
        switch self {
        case .concise: "Короче"
        case .example: "Пример"
        case .detailed: "Подробнее"
        case .alternative: "Другой ответ"
        }
    }

    var instruction: String {
        switch self {
        case .concise: "Ответь ещё короче: максимум три коротких тезиса."
        case .example: "Дай один конкретный практический пример к ответу. Не повторяй весь ответ."
        case .detailed: "Раскрой ответ подробнее, сохраняя ясную структуру."
        case .alternative: "Сформулируй другой самостоятельный ответ на тот же вопрос, не копируя предыдущий текст."
        }
    }
}
