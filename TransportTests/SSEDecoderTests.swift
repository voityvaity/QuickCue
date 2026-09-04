import Foundation
import XCTest
@testable import QuickCueTransport

final class SSEDecoderTests: XCTestCase {
    func testEmptyLinesSeparateEventsAndPreserveDataWhitespace() throws {
        var decoder = SSEDecoder()
        let events = try decoder.consume(Data("data:  A \n\ndata:B\n\n".utf8))
        XCTAssertEqual(events.map(\.data), [" A ", "B"])
        try decoder.finish()
    }

    func testLFCRLFAndCRHaveIdenticalFraming() throws {
        for ending in ["\n", "\r\n", "\r"] {
            var decoder = SSEDecoder()
            let wire = ["event: token", "data: Привет", "data: мир", "", "data: next", "", ""].joined(separator: ending)
            let events = try decoder.consume(Data(wire.utf8))
            XCTAssertEqual(events.map(\.data), ["Привет\nмир", "next"])
            XCTAssertEqual(events.map(\.event), ["token", nil])
            try decoder.finish()
        }
    }

    func testEveryByteSplitIncludingBOMUTF8AndCRLF() throws {
        let wire = Data("\u{feff}: heartbeat\r\ndata: Привет 🌍\r\n\r\ndata: [DONE]\r\n\r\n".utf8)
        for split in 0...wire.count {
            var decoder = SSEDecoder()
            let events = try decoder.consume(wire.prefix(split)) + decoder.consume(wire.dropFirst(split))
            XCTAssertEqual(events.map(\.data), ["Привет 🌍", "[DONE]"], "split \(split)")
            try decoder.finish()
        }
        var decoder = SSEDecoder()
        var events: [SSEMessage] = []
        for byte in wire { events += try decoder.consume(Data([byte])) }
        XCTAssertEqual(events.map(\.data), ["Привет 🌍", "[DONE]"])
        try decoder.finish()
    }

    func testCommentsUnknownFieldsAndEmptyEventsDoNotGenerateText() throws {
        var decoder = SSEDecoder()
        let events = try decoder.consume(Data(": keep-alive\n\nid: 7\nretry: 100\n\nevent: unused\n\ndata: yes\n\n".utf8))
        XCTAssertEqual(events.map(\.data), ["yes"])
        XCTAssertNil(events.first?.event)
        try decoder.finish()
    }

    func testBareDataFieldIsAnEmptyEvent() throws {
        var decoder = SSEDecoder()
        XCTAssertEqual(try decoder.consume(Data("data\n\n".utf8)).map(\.data), [""])
        try decoder.finish()
    }

    func testEOFNeverDispatchesUnterminatedData() throws {
        for suffix in ["data: partial", "data: partial\n", "event: pending\n"] {
            var decoder = SSEDecoder()
            XCTAssertTrue(try decoder.consume(Data(suffix.utf8)).isEmpty)
            XCTAssertThrowsError(try decoder.finish()) { error in
                XCTAssertEqual(error as? SSETransportFailure, .truncatedEvent)
            }
        }
    }

    func testMalformedUTF8FailsWithoutLeakingPayload() {
        var decoder = SSEDecoder()
        XCTAssertThrowsError(try decoder.consume(Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0xff, 0x0a]))) { error in
            XCTAssertEqual(error as? SSETransportFailure, .invalidUTF8)
        }
    }

    func testOversizedLineAndAccumulatedEventAreBounded() throws {
        var line = SSEDecoder(maxEventBytes: 16)
        XCTAssertThrowsError(try line.consume(Data(repeating: 65, count: 17)))
        var event = SSEDecoder(maxEventBytes: 25)
        XCTAssertThrowsError(try event.consume(Data("data: first\ndata: second\ndata: third\n\n".utf8)))
    }

    func testSyntheticDeepSeekWireKeepsTextUsageAndDoneSeparate() throws {
        let payloads = [
            #"{"choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"content":"Да"},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":76,"completion_tokens":3}}"#,
            "[DONE]",
        ]
        // Synthetic fixture, not saved private upstream content.
        let wire = payloads.map { "data: \($0)\n\n" }.joined()
        var decoder = SSEDecoder()
        XCTAssertEqual(try decoder.consume(Data(wire.utf8)).map(\.data), payloads)
        try decoder.finish()
    }
}
