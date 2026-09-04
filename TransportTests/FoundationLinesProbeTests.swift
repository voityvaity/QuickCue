import Foundation
import XCTest

final class FoundationLinesProbeTests: XCTestCase {
    func testRecordDarwinLinesBehaviorWithoutAssumingHypothesis() async throws {
        let source = AsyncStream<UInt8> { continuation in
            for byte in Data("data: A\n\ndata: B\n\n".utf8) { continuation.yield(byte) }
            continuation.finish()
        }
        var lines: [String] = []
        for try await line in source.lines { lines.append(line) }
        let preservesBoundaries = lines.contains("")
        let report = "Darwin Foundation .lines: \(String(data: try JSONEncoder().encode(lines), encoding: .utf8)!)\nblank_lines_preserved=\(preservesBoundaries)"
        print(report) // Synthetic A/B only, never a live response.
        XCTAssertEqual(lines.filter { !$0.isEmpty }, ["data: A", "data: B"])
        // Both results are evidence. Do not encode our unverified hypothesis as a passing test.
    }
}
