import Foundation

struct PhotoStore: Sendable {
    private let fileManager = FileManager.default

    func saveJPEG(_ data: Data) throws -> String {
        let root = try photosDirectory()
        let name = "\(UUID().uuidString).jpg"
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return "Photos/\(name)"
    }

    func url(for relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Photos",
              !parts[1].contains("\\"), parts[1].hasSuffix(".jpg"),
              UUID(uuidString: String(parts[1].dropLast(4))) != nil else {
            throw PhotoStoreError.invalidPath
        }
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(relativePath)
    }

    func delete(relativePath: String) throws {
        let target = try url(for: relativePath)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
    }

    /// Restores only a validated QuickCue photo path. Existing live files are
    /// never overwritten; the caller can then treat the record as a conflict.
    @discardableResult
    func restoreJPEG(_ data: Data, relativePath: String) throws -> Bool {
        guard data.count <= 20 * 1_024 * 1_024,
              data.starts(with: [0xFF, 0xD8]), Data(data.suffix(2)) == Data([0xFF, 0xD9]) else {
            throw PhotoStoreError.invalidJPEG
        }
        let target = try url(for: relativePath)
        if fileManager.fileExists(atPath: target.path) {
            guard (try? Data(contentsOf: target, options: .mappedIfSafe)) == data else {
                throw PhotoStoreError.conflictingPhoto
            }
            return false
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic, .completeFileProtection])
        return true
    }

    private func photosDirectory() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Photos", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum PhotoStoreError: LocalizedError {
    case invalidPath
    case invalidJPEG
    case conflictingPhoto
    var errorDescription: String? {
        switch self {
        case .invalidPath: "Некорректная ссылка на локальное фото. Файл не изменён."
        case .invalidJPEG: "Файл в резервной копии не является допустимым JPEG."
        case .conflictingPhoto: "На iPhone уже есть другое фото с таким идентификатором. Оно не перезаписано."
        }
    }
}

