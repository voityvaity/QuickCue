import CryptoKit
import Foundation

struct DiagnosticsSnapshot: Sendable {
    let events: [DiagnosticEvent]
    let droppedEvents: Int
    let storedBytes: Int
}

struct DiagnosticsExport: Sendable {
    let exportID: UUID
    let fileURL: URL
    let eventCount: Int
}

struct DiagnosticsManifest: Codable, Equatable, Sendable {
    struct FileEntry: Codable, Equatable, Sendable {
        let name: String
        let byteCount: Int
        let sha256: String
    }

    let schemaVersion: Int
    let exportID: UUID
    let createdAt: Date
    let files: [FileEntry]
}

struct DiagnosticsSummary: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let exportID: UUID
    let eventCount: Int
    let droppedEvents: Int
    let buildCounts: [String: Int]
    let errorCounts: [String: Int]
    let latency: Latency

    struct Latency: Codable, Equatable, Sendable {
        let sampleCount: Int
        let p50Milliseconds: Int?
        let p95Milliseconds: Int?
    }
}

enum DiagnosticsArchiveError: LocalizedError {
    case encoding
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .encoding: "Не удалось подготовить безопасный диагностический отчёт."
        case .archiveTooLarge: "Диагностический отчёт превысил безопасный лимит 12 МБ. Удалите старые события и повторите экспорт."
        }
    }
}

enum DiagnosticsArchiveBuilder {
    static let allowedEntryNames = ["manifest.json", "events.jsonl", "summary.json"]
    static let maximumArchiveBytes = 12 * 1_024 * 1_024

    static func build(snapshot: DiagnosticsSnapshot, directory: URL) throws -> DiagnosticsExport {
        let exportID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let lines = try snapshot.events.map { try encoder.encode($0) }
        var eventBytes = Data()
        for line in lines {
            eventBytes.append(line)
            eventBytes.append(0x0A)
        }

        let durations = snapshot.events.compactMap(\.durationMilliseconds).sorted()
        let summary = DiagnosticsSummary(
            schemaVersion: 1,
            exportID: exportID,
            eventCount: snapshot.events.count,
            droppedEvents: snapshot.droppedEvents,
            buildCounts: Dictionary(grouping: snapshot.events, by: { "\($0.appVersion) (\($0.appBuild))" })
                .mapValues(\.count),
            errorCounts: Dictionary(grouping: snapshot.events.compactMap(\.error), by: \.rawValue)
                .mapValues(\.count),
            latency: .init(
                sampleCount: durations.count,
                p50Milliseconds: percentile(0.50, values: durations),
                p95Milliseconds: percentile(0.95, values: durations)
            )
        )
        let summaryBytes = try encoder.encode(summary)
        let manifest = DiagnosticsManifest(
            schemaVersion: 1,
            exportID: exportID,
            createdAt: .now,
            files: [
                .init(name: "events.jsonl", byteCount: eventBytes.count, sha256: sha256(eventBytes)),
                .init(name: "summary.json", byteCount: summaryBytes.count, sha256: sha256(summaryBytes)),
            ]
        )
        let manifestBytes = try encoder.encode(manifest)
        let archive = ZipStoreArchive.make(entries: [
            ("manifest.json", manifestBytes),
            ("events.jsonl", eventBytes),
            ("summary.json", summaryBytes),
        ])
        guard archive.count <= maximumArchiveBytes else { throw DiagnosticsArchiveError.archiveTooLarge }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("QuickCue-\(exportID.uuidString).quickcue-diagnostics")
        try archive.write(to: fileURL, options: .atomic)
        return DiagnosticsExport(exportID: exportID, fileURL: fileURL, eventCount: snapshot.events.count)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func percentile(_ value: Double, values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let index = min(values.count - 1, max(0, Int(ceil(value * Double(values.count))) - 1))
        return values[index]
    }
}

/// A minimal ZIP writer using the uncompressed STORE method. Entry names are
/// compile-time constants; callers cannot add paths or executable files.
private enum ZipStoreArchive {
    private struct CentralEntry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func make(entries: [(String, Data)]) -> Data {
        var output = Data()
        var central: [CentralEntry] = []

        for (nameString, contents) in entries {
            precondition(DiagnosticsArchiveBuilder.allowedEntryNames.contains(nameString))
            let name = Data(nameString.utf8)
            let crc = CRC32.checksum(contents)
            let size = UInt32(contents.count)
            let offset = UInt32(output.count)
            output.appendLittleEndian(UInt32(0x04034B50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0x0800))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(crc)
            output.appendLittleEndian(size)
            output.appendLittleEndian(size)
            output.appendLittleEndian(UInt16(name.count))
            output.appendLittleEndian(UInt16(0))
            output.append(name)
            output.append(contents)
            central.append(.init(name: name, crc: crc, size: size, offset: offset))
        }

        let centralOffset = UInt32(output.count)
        for entry in central {
            output.appendLittleEndian(UInt32(0x02014B50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0x0800))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(entry.crc)
            output.appendLittleEndian(entry.size)
            output.appendLittleEndian(entry.size)
            output.appendLittleEndian(UInt16(entry.name.count))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt32(0))
            output.appendLittleEndian(entry.offset)
            output.append(entry.name)
        }
        let centralSize = UInt32(output.count) - centralOffset
        output.appendLittleEndian(UInt32(0x06054B50))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(central.count))
        output.appendLittleEndian(UInt16(central.count))
        output.appendLittleEndian(centralSize)
        output.appendLittleEndian(centralOffset)
        output.appendLittleEndian(UInt16(0))
        return output
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
