import XCTest
@testable import QuickCue

final class DiagnosticsTests: XCTestCase {
    func testEventEncodingHasStrictAllowlistAndNoContentFields() throws {
        let event = DiagnosticEvent.request(
            .requestFinished,
            sessionID: UUID(),
            requestID: UUID(),
            provider: .custom(UUID()),
            durationMilliseconds: 321,
            finish: .complete,
            errorCode: nil
        )
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["provider"] as? String, "custom")
        XCTAssertNil(object["question"])
        XCTAssertNil(object["answer"])
        XCTAssertNil(object["prompt"])
        XCTAssertNil(object["url"])
        XCTAssertNil(object["headers"])
        XCTAssertNil(object["ocr"])
    }

    func testRecorderDropsOverflowInsteadOfBlockingAndKeepsBoundedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticsRecorder(
            directory: directory,
            configuration: .init(
                maximumStoredBytes: 2_000,
                retentionSeconds: 3600,
                maximumPendingWrites: 2,
                maximumEventBytes: 64 * 1_024
            )
        )
        for _ in 0..<200 {
            recorder.record(.scheduler(active: 2, pending: 5))
        }
        let snapshot = await recorder.snapshot()
        XCTAssertLessThanOrEqual(snapshot.storedBytes, 2_000)
        XCTAssertGreaterThan(snapshot.droppedEvents, 0)
    }

    func testRecorderPrunesExpiredEventsWhenAppending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(DiagnosticEvent.scheduler(active: 1, pending: 0)))
                as? [String: Any]
        )
        object["occurredAt"] = "1970-01-01T00:00:00Z"
        var expiredLine = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        expiredLine.append(0x0A)
        try expiredLine.write(to: directory.appendingPathComponent("events-v1.jsonl"), options: .atomic)

        let recorder = DiagnosticsRecorder(
            directory: directory,
            configuration: .init(
                maximumStoredBytes: 64 * 1_024,
                retentionSeconds: 60,
                maximumPendingWrites: 8,
                maximumEventBytes: 64 * 1_024
            )
        )
        recorder.record(.scheduler(active: 0, pending: 1))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.activeCount, 0)
        XCTAssertEqual(snapshot.events.first?.pendingCount, 1)
    }

    func testArchiveContainsOnlyThreeFixedFilesAndNoCanaryContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticsRecorder(directory: directory)
        recorder.record(.request(
            .requestFinished, sessionID: UUID(), requestID: UUID(),
            provider: .builtIn(.deepSeek), durationMilliseconds: 500,
            finish: .failed, errorCode: "timeout"
        ))
        let exported = try await recorder.export()
        let bytes = try Data(contentsOf: exported.fileURL)
        let raw = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(raw.contains("manifest.json"))
        XCTAssertTrue(raw.contains("events.jsonl"))
        XCTAssertTrue(raw.contains("summary.json"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("api-key"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("prompt"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("question"))
    }

    func testSafeErrorMappingNeverExportsDynamicHTTPText() throws {
        let event = DiagnosticEvent.request(
            .requestFinished, sessionID: nil, requestID: UUID(),
            finish: .failed, errorCode: "http_418"
        )
        XCTAssertEqual(event.error, .unknown)
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(text.contains("418"))
    }

    func testKnownSafeTransportCodesMapToStableCategories() {
        XCTAssertEqual(eventError("http_401"), .unauthorized)
        XCTAssertEqual(eventError("http_429"), .rateLimit)
        XCTAssertEqual(eventError("host_unreachable"), .host)
        XCTAssertEqual(eventError("output_limit"), .incompleteResponse)
        XCTAssertEqual(eventError("malformed_event"), .invalidFormat)
    }

    private func eventError(_ code: String) -> DiagnosticErrorCategory? {
        DiagnosticEvent.request(
            .requestFinished, sessionID: nil, requestID: UUID(),
            finish: .failed, errorCode: code
        ).error
    }
}
