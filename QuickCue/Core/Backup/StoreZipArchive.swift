import Foundation

enum StoreZipArchiveError: LocalizedError, Equatable {
    case invalidArchive
    case unsafePath
    case unsupportedCompression
    case duplicateEntry
    case tooManyEntries
    case entryTooLarge
    case archiveTooLarge
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "Архив повреждён или имеет неподдерживаемую структуру. Живые данные не изменялись."
        case .unsafePath: "Архив содержит небезопасный путь. Восстановление остановлено."
        case .unsupportedCompression: "Архив создан неподдерживаемым способом. Используйте резервную копию QuickCue."
        case .duplicateEntry: "В архиве повторяется имя файла. Восстановление остановлено."
        case .tooManyEntries: "В архиве слишком много файлов."
        case .entryTooLarge: "Один из файлов архива превышает безопасный лимит."
        case .archiveTooLarge: "Резервная копия превышает безопасный лимит 100 МБ."
        case .checksumMismatch: "Контрольная сумма архива не совпала. Живые данные не изменялись."
        }
    }
}

/// Minimal ZIP STORE codec. Entries are never expanded to paths while being
/// validated, which removes the path-traversal extraction surface.
enum StoreZipArchive {
    static let maximumArchiveBytes = 100 * 1_024 * 1_024
    static let maximumEntryBytes = 20 * 1_024 * 1_024
    static let maximumEntries = 512

    static func make(entries: [(String, Data)]) throws -> Data {
        guard entries.count <= maximumEntries else { throw StoreZipArchiveError.tooManyEntries }
        guard Set(entries.map(\.0)).count == entries.count else { throw StoreZipArchiveError.duplicateEntry }
        var output = Data()
        var central: [(name: Data, crc: UInt32, size: UInt32, offset: UInt32)] = []
        for (nameString, contents) in entries {
            guard isSafe(nameString) else { throw StoreZipArchiveError.unsafePath }
            guard contents.count <= maximumEntryBytes else { throw StoreZipArchiveError.entryTooLarge }
            let name = Data(nameString.utf8)
            let crc = BackupCRC32.checksum(contents)
            guard let size = UInt32(exactly: contents.count), let offset = UInt32(exactly: output.count) else {
                throw StoreZipArchiveError.archiveTooLarge
            }
            output.appendLE(UInt32(0x04034B50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0x0800))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(crc)
            output.appendLE(size); output.appendLE(size); output.appendLE(UInt16(name.count)); output.appendLE(UInt16(0))
            output.append(name); output.append(contents)
            central.append((name, crc, size, offset))
            guard output.count <= maximumArchiveBytes else { throw StoreZipArchiveError.archiveTooLarge }
        }
        guard let centralOffset = UInt32(exactly: output.count) else { throw StoreZipArchiveError.archiveTooLarge }
        for item in central {
            output.appendLE(UInt32(0x02014B50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0x0800))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(item.crc)
            output.appendLE(item.size); output.appendLE(item.size); output.appendLE(UInt16(item.name.count)); output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt32(0)); output.appendLE(item.offset)
            output.append(item.name)
        }
        guard let centralSize = UInt32(exactly: output.count - Int(centralOffset)) else {
            throw StoreZipArchiveError.archiveTooLarge
        }
        output.appendLE(UInt32(0x06054B50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
        output.appendLE(UInt16(central.count)); output.appendLE(UInt16(central.count)); output.appendLE(centralSize)
        output.appendLE(centralOffset); output.appendLE(UInt16(0))
        guard output.count <= maximumArchiveBytes else { throw StoreZipArchiveError.archiveTooLarge }
        return output
    }

    static func read(_ data: Data) throws -> [String: Data] {
        guard data.count <= maximumArchiveBytes else { throw StoreZipArchiveError.archiveTooLarge }
        var cursor = 0
        var result: [String: Data] = [:]
        var localOffsets: [String: Int] = [:]
        while cursor + 4 <= data.count {
            let signature: UInt32 = try data.readLE(at: cursor)
            if signature == 0x02014B50 || signature == 0x06054B50 { break }
            guard signature == 0x04034B50, cursor + 30 <= data.count else {
                throw StoreZipArchiveError.invalidArchive
            }
            let flags: UInt16 = try data.readLE(at: cursor + 6)
            let method: UInt16 = try data.readLE(at: cursor + 8)
            let expectedCRC: UInt32 = try data.readLE(at: cursor + 14)
            let compressed: UInt32 = try data.readLE(at: cursor + 18)
            let uncompressed: UInt32 = try data.readLE(at: cursor + 22)
            let nameLength: UInt16 = try data.readLE(at: cursor + 26)
            let extraLength: UInt16 = try data.readLE(at: cursor + 28)
            guard flags == 0x0800, method == 0, compressed == uncompressed else {
                throw StoreZipArchiveError.unsupportedCompression
            }
            guard Int(uncompressed) <= maximumEntryBytes else { throw StoreZipArchiveError.entryTooLarge }
            let nameStart = cursor + 30
            let contentsStart = nameStart + Int(nameLength) + Int(extraLength)
            let contentsEnd = contentsStart + Int(uncompressed)
            guard nameStart <= data.count, contentsStart <= data.count, contentsEnd <= data.count,
                  let name = String(data: Data(data[nameStart..<(nameStart + Int(nameLength))]), encoding: .utf8),
                  isSafe(name) else { throw StoreZipArchiveError.unsafePath }
            guard result[name] == nil else { throw StoreZipArchiveError.duplicateEntry }
            let contents = Data(data[contentsStart..<contentsEnd])
            guard BackupCRC32.checksum(contents) == expectedCRC else { throw StoreZipArchiveError.checksumMismatch }
            result[name] = contents
            localOffsets[name] = cursor
            guard result.count <= maximumEntries else { throw StoreZipArchiveError.tooManyEntries }
            cursor = contentsEnd
        }
        guard !result.isEmpty else {
            throw StoreZipArchiveError.invalidArchive
        }
        let centralStart = cursor
        var centralNames = Set<String>()
        for _ in 0..<result.count {
            guard cursor + 46 <= data.count else { throw StoreZipArchiveError.invalidArchive }
            let signature: UInt32 = try data.readLE(at: cursor)
            let flags: UInt16 = try data.readLE(at: cursor + 8)
            let method: UInt16 = try data.readLE(at: cursor + 10)
            let expectedCRC: UInt32 = try data.readLE(at: cursor + 16)
            let compressedSize: UInt32 = try data.readLE(at: cursor + 20)
            let uncompressedSize: UInt32 = try data.readLE(at: cursor + 24)
            let nameLength: UInt16 = try data.readLE(at: cursor + 28)
            let extraLength: UInt16 = try data.readLE(at: cursor + 30)
            let commentLength: UInt16 = try data.readLE(at: cursor + 32)
            let localOffset: UInt32 = try data.readLE(at: cursor + 42)
            let nameStart = cursor + 46
            let end = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard signature == 0x02014B50, flags == 0x0800, method == 0, end <= data.count,
                  let name = String(data: Data(data[nameStart..<(nameStart + Int(nameLength))]), encoding: .utf8),
                  isSafe(name), compressedSize == uncompressedSize,
                  let contents = result[name], contents.count == Int(uncompressedSize),
                  BackupCRC32.checksum(contents) == expectedCRC,
                  localOffsets[name] == Int(localOffset),
                  centralNames.insert(name).inserted else { throw StoreZipArchiveError.invalidArchive }
            cursor = end
        }
        let centralSize = cursor - centralStart
        let endSignature: UInt32 = try data.readLE(at: cursor)
        let diskNumber: UInt16 = try data.readLE(at: cursor + 4)
        let centralDiskNumber: UInt16 = try data.readLE(at: cursor + 6)
        let entriesOnDisk: UInt16 = try data.readLE(at: cursor + 8)
        let totalEntries: UInt16 = try data.readLE(at: cursor + 10)
        let recordedCentralSize: UInt32 = try data.readLE(at: cursor + 12)
        let recordedCentralOffset: UInt32 = try data.readLE(at: cursor + 16)
        let commentLength: UInt16 = try data.readLE(at: cursor + 20)
        guard cursor + 22 == data.count,
              endSignature == 0x06054B50,
              diskNumber == 0, centralDiskNumber == 0,
              entriesOnDisk == UInt16(result.count), totalEntries == UInt16(result.count),
              recordedCentralSize == UInt32(centralSize),
              recordedCentralOffset == UInt32(centralStart), commentLength == 0,
              centralNames == Set(result.keys) else { throw StoreZipArchiveError.invalidArchive }
        return result
    }

    static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 180, !name.hasPrefix("/"), !name.hasPrefix("\\"),
              !name.contains("\\"), !name.contains(":"), !name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum BackupCRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 { value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(at offset: Int) throws -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { throw StoreZipArchiveError.invalidArchive }
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { target in
            _ = copyBytes(to: target, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }
}
