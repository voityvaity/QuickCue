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

