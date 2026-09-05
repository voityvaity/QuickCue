import Foundation
import PDFKit

struct ImportedProfileDocument: Equatable, Sendable {
    let kind: ProfileAttachmentKind
    let text: String
    let filename: String
    let byteCount: Int
    let wasTruncated: Bool
}

enum ProfileDocumentImportError: LocalizedError, Equatable {
    case oversized(maximumMegabytes: Int)
    case unsupportedFormat(String)
    case unreadableText
    case invalidPDF
    case tooManyPages(maximum: Int)
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .oversized(let maximum): "Файл больше \(maximum) МБ. Скопируйте нужный фрагмент или уменьшите файл."
        case .unsupportedFormat(let value):
            value == "docx"
                ? "DOCX пока не поддерживается. Сохраните документ как PDF/TXT или вставьте текст."
                : "Формат .\(value.isEmpty ? "неизвестный" : value) не поддерживается. Выберите PDF/TXT или вставьте текст."
        case .unreadableText: "TXT не удалось прочитать как UTF-8. Сохраните его в UTF-8 или вставьте текст."
        case .invalidPDF: "PDF повреждён, зашифрован или недоступен для локального чтения."
        case .tooManyPages(let maximum): "В PDF больше \(maximum) страниц. Оставьте только нужные страницы."
        case .emptyDocument: "В документе не найден текст. Для скана используйте распознавание по фото."
        }
    }
}

enum ProfileDocumentImporter {
    static let maximumBytes = 5 * 1_024 * 1_024
    static let maximumPDFPages = 40
    static let maximumExtractedCharacters = 30_000

    static func extract(from url: URL) throws -> ImportedProfileDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumBytes else { throw ProfileDocumentImportError.oversized(maximumMegabytes: 5) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try extract(data: data, fileExtension: url.pathExtension, filename: url.lastPathComponent)
    }

    static func extract(data: Data, fileExtension: String, filename: String = "Материал") throws -> ImportedProfileDocument {
        guard data.count <= maximumBytes else { throw ProfileDocumentImportError.oversized(maximumMegabytes: 5) }
        let ext = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let kind: ProfileAttachmentKind
        let rawText: String
        switch ext {
        case "txt":
            kind = .txt
            guard let value = String(data: data, encoding: .utf8) else { throw ProfileDocumentImportError.unreadableText }
            rawText = value.replacingOccurrences(of: "\u{FEFF}", with: "")
        case "pdf":
            kind = .pdf
            guard let document = PDFDocument(data: data), !document.isEncrypted else {
                throw ProfileDocumentImportError.invalidPDF
            }
            guard document.pageCount <= maximumPDFPages else {
                throw ProfileDocumentImportError.tooManyPages(maximum: maximumPDFPages)
            }
            rawText = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        default:
            throw ProfileDocumentImportError.unsupportedFormat(ext)
        }
        let normalized = ContextSnapshotBuilder.normalize(rawText)
        guard !normalized.isEmpty else { throw ProfileDocumentImportError.emptyDocument }
        let bounded = String(normalized.prefix(maximumExtractedCharacters))
        return ImportedProfileDocument(
            kind: kind,
            text: bounded,
            filename: filename,
            byteCount: data.count,
            wasTruncated: bounded.count < normalized.count
        )
    }
}
