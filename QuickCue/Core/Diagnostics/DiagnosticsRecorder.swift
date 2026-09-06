import Foundation

struct DiagnosticsRecorderConfiguration: Sendable {
    var maximumStoredBytes = 10 * 1_024 * 1_024
    var retentionSeconds: TimeInterval = 7 * 24 * 60 * 60
    var maximumPendingWrites = 128
    var maximumEventBytes = 64 * 1_024
}

/// Content-free, bounded diagnostics. The public write API accepts only a
/// `DiagnosticEvent`; conversation strings, OCR, prompts, URLs and secrets have
/// no field through which they could enter the journal.
final class DiagnosticsRecorder: @unchecked Sendable {
    static let shared = DiagnosticsRecorder()

    private let configuration: DiagnosticsRecorderConfiguration
    private let eventsURL: URL
    private let exportsDirectory: URL
    private let queue = DispatchQueue(label: "ru.quickcue.diagnostics", qos: .utility)
    private let stateLock = NSLock()
    private var pendingWrites = 0
    private var droppedEvents = 0

    init(
        directory: URL? = nil,
        configuration: DiagnosticsRecorderConfiguration = .init()
    ) {
        let root = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("QuickCue/Diagnostics", isDirectory: true)
        self.configuration = configuration
        self.eventsURL = root.appendingPathComponent("events-v1.jsonl")
        self.exportsDirectory = root.appendingPathComponent("Exports", isDirectory: true)
    }

    func record(_ event: DiagnosticEvent) {
        stateLock.lock()
        guard pendingWrites < configuration.maximumPendingWrites else {
            droppedEvents += 1
            stateLock.unlock()
            return
        }
        pendingWrites += 1
        stateLock.unlock()

        queue.async { [self] in
            defer {
                stateLock.lock()
                pendingWrites -= 1
                stateLock.unlock()
            }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let encoded = try encoder.encode(event)
                guard encoded.count <= configuration.maximumEventBytes else {
                    stateLock.lock()
                    droppedEvents += 1
                    stateLock.unlock()
                    return
                }
                try FileManager.default.createDirectory(
                    at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                var line = encoded
                line.append(0x0A)
                if FileManager.default.fileExists(atPath: eventsURL.path) {
                    let handle = try FileHandle(forWritingTo: eventsURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: eventsURL, options: .atomic)
                }
                try prune(now: event.occurredAt)
            } catch {
                stateLock.lock()
                droppedEvents += 1
                stateLock.unlock()
            }
        }
    }

    func snapshot() async -> DiagnosticsSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let events = (try? readEvents()) ?? []
                stateLock.lock()
                let dropped = droppedEvents
                stateLock.unlock()
                let bytes = (try? eventsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                continuation.resume(returning: DiagnosticsSnapshot(
                    events: events, droppedEvents: dropped, storedBytes: bytes
                ))
            }
        }
    }

    func export() async throws -> DiagnosticsExport {
        let snapshot = await snapshot()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
                    for old in (try? FileManager.default.contentsOfDirectory(
                        at: exportsDirectory, includingPropertiesForKeys: nil
                    )) ?? [] {
                        try? FileManager.default.removeItem(at: old)
                    }
                    continuation.resume(returning: try DiagnosticsArchiveBuilder.build(
                        snapshot: snapshot, directory: exportsDirectory
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deleteAll() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                try? FileManager.default.removeItem(at: eventsURL)
                try? FileManager.default.removeItem(at: exportsDirectory)
                stateLock.lock()
                droppedEvents = 0
                stateLock.unlock()
                continuation.resume()
            }
        }
    }

    private func readEvents() throws -> [DiagnosticEvent] {
        guard FileManager.default.fileExists(atPath: eventsURL.path) else { return [] }
        let data = try Data(contentsOf: eventsURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DiagnosticEvent.self, from: Data($0)) }
    }

    private func prune(now: Date) throws {
        let size = (try? eventsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let storedEvents = try readEvents()
        let events = storedEvents.filter {
            now.timeIntervalSince($0.occurredAt) <= configuration.retentionSeconds
        }
        guard size > configuration.maximumStoredBytes || events.count != storedEvents.count else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var kept: [Data] = []
        var total = 0
        for event in events.reversed() {
            var line = try encoder.encode(event)
            line.append(0x0A)
            guard total + line.count <= configuration.maximumStoredBytes else { break }
            kept.append(line)
            total += line.count
        }
        var output = Data()
        kept.reversed().forEach { output.append($0) }
        if output.isEmpty { try? FileManager.default.removeItem(at: eventsURL) }
        else { try output.write(to: eventsURL, options: .atomic) }
    }
}
