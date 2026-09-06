import Foundation

enum ProfileAttachmentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case text
    case txt
    case pdf
    case photoOCR

    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: "Текст"
        case .txt: "TXT"
        case .pdf: "PDF"
        case .photoOCR: "Фото OCR"
        }
    }
}

struct ContextAttachmentRevision: Codable, Equatable, Sendable {
    let id: UUID
    let revision: Int
}

struct BuiltContextSnapshot: Codable, Equatable, Sendable {
    let contextProfileID: UUID
    let contextProfileRevision: Int
    let candidateProfileID: UUID?
    let candidateRevision: Int?
    let jobProfileID: UUID?
    let jobRevision: Int?
    let attachmentRevisions: [ContextAttachmentRevision]
    let title: String
    let text: String
    let wasTruncated: Bool
    let originalCharacterCount: Int
}

enum ContextSnapshotBuilder {
    static let maximumCharacters = 12_000
    static let maximumAttachments = 5
    static let maximumAttachmentCharacters = 6_000

    static func selectedAttachmentIDs(from profile: ContextProfile) -> [UUID] {
        (try? JSONDecoder().decode([UUID].self, from: profile.selectedAttachmentIDsData)) ?? []
    }

    static func encodeAttachmentIDs(_ ids: [UUID]) -> Data {
        (try? JSONEncoder().encode(Array(ids.prefix(maximumAttachments)))) ?? Data("[]".utf8)
    }

    static func build(
        profile: ContextProfile,
        candidate: CandidateProfile?,
        job: JobProfile?,
        attachments: [AttachmentRecord],
        maximumCharacters: Int = ContextSnapshotBuilder.maximumCharacters
    ) -> BuiltContextSnapshot {
        var sections: [String] = []
        append("Сценарий", profile.scenario, to: &sections)
        if let candidate {
            var fields: [String] = []
            append("Название", candidate.title, to: &fields)
            append("Уровень", candidate.level, to: &fields)
            append("Язык", candidate.language, to: &fields)
            append("Навыки", candidate.skills, to: &fields)
            append("Опыт", candidate.experience, to: &fields)
            append("Проекты", candidate.projects, to: &fields)
            append("Образование", candidate.education, to: &fields)
            append("Достижения", candidate.achievements, to: &fields)
            if !fields.isEmpty { sections.append("ПРОФИЛЬ КАНДИДАТА\n" + fields.joined(separator: "\n")) }
        }
        if let job {
            var fields: [String] = []
            append("Название", job.title, to: &fields)
            append("Компания", job.company, to: &fields)
            append("Роль", job.role, to: &fields)
            append("Темы и стек", job.topics, to: &fields)
            append("Вакансия", job.vacancyText, to: &fields)
            append("Заметки", job.notes, to: &fields)
            if !fields.isEmpty { sections.append("ВАКАНСИЯ\n" + fields.joined(separator: "\n")) }
        }
        for attachment in attachments.prefix(maximumAttachments) {
            let text = String(normalize(attachment.extractedText).prefix(maximumAttachmentCharacters))
            guard !text.isEmpty else { continue }
            sections.append("МАТЕРИАЛ: \(normalize(attachment.title))\n\(text)")
        }
        let complete = sections.joined(separator: "\n\n")
        let limit = max(0, maximumCharacters)
        let bounded = String(complete.prefix(limit))
        return BuiltContextSnapshot(
            contextProfileID: profile.id,
            contextProfileRevision: profile.revision,
            candidateProfileID: candidate?.id,
            candidateRevision: candidate?.revision,
            jobProfileID: job?.id,
            jobRevision: job?.revision,
            attachmentRevisions: attachments.prefix(maximumAttachments).map {
                ContextAttachmentRevision(id: $0.id, revision: $0.revision)
            },
            title: normalize(profile.title).isEmpty ? "Контекст" : normalize(profile.title),
            text: bounded,
            wasTruncated: bounded.count < complete.count,
            originalCharacterCount: complete.count
        )
    }

    private static func append(_ label: String, _ value: String, to result: inout [String]) {
        let value = normalize(value)
        if !value.isEmpty { result.append("\(label): \(value)") }
    }

    static func normalize(_ value: String) -> String {
        let normalizedLines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let allowed = normalizedLines.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar.value == 10 || scalar.value == 9
        }
        return String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
