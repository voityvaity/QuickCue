import Foundation
import Network
import XCTest
@testable import QuickCueTransport

/// Darwin-only real TCP + Foundation tests. No URLProtocol, streamFactory, key or paid API.
final class URLSessionLoopbackTests: XCTestCase {
    func testFirstEventArrivesBeforeEOFAndFragmentedTail() async throws {
        let server = try LoopbackServer(prefix: Self.headers + "data: Привет\r\n\r\n")
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let first = expectation(description: "first text before releasing EOF")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = SSETransport(session: session, allowsInsecureLoopback: true, timeoutSeconds: 3)
        let request = URLRequest(url: try server.url())
        let consumer = Task { () throws -> [String] in
            var values: [String] = []
            for try await event in transport.stream(request) {
                values.append(event.data)
                if values.count == 1 { first.fulfill() }
            }
            return values
        }
        defer { consumer.cancel() }
        await fulfillment(of: [first], timeout: 2)
        server.release(tail: Data("data: 🌍\r\n\r\ndata: [DONE]\r\n\r\n".utf8), byteByByte: true)
        let values = try await consumer.value
        XCTAssertEqual(values, ["Привет", "🌍", "[DONE]"])
    }

    func testFoundationLinesBaselineOverRealURLSession() async throws {
        let server = try LoopbackServer(prefix: Self.headers + "data: A\n\ndata: B\n\n", closeAfterPrefix: true)
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, _) = try await session.bytes(from: server.url())
        defer { bytes.task.cancel() }
        var lines: [String] = []
        for try await line in bytes.lines { lines.append(line) }
        // Deliberately report rather than assume whether Darwin preserves blank lines.
        print("FOUNDATION_NETWORK_LINES blanks=\(lines.filter(\.isEmpty).count) total=\(lines.count)")
        XCTAssertEqual(lines.filter { !$0.isEmpty }, ["data: A", "data: B"])
    }

    func testCancellationClosesSocketBeforeHeaders() async throws {
        let server = try LoopbackServer(prefix: "")
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = SSETransport(session: session, allowsInsecureLoopback: true, timeoutSeconds: 3)
        let consumer = Task {
            for try await _ in transport.stream(URLRequest(url: try server.url())) {
                try Task.checkCancellation()
            }
        }

        // The fixture fulfills `received` before it writes response headers.
        await fulfillment(of: [server.received], timeout: 2)
        consumer.cancel()
        _ = await consumer.result
        await fulfillment(of: [server.disconnected], timeout: 2)
    }

    func testCancellationClosesSocketAfterFirstEvent() async throws {
        let server = try LoopbackServer(prefix: Self.headers + "data: A\n\n")
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = SSETransport(session: session, allowsInsecureLoopback: true, timeoutSeconds: 3)
        let firstEvent = expectation(description: "production transport delivered first SSE event")
        let consumer = Task {
            for try await event in transport.stream(URLRequest(url: try server.url())) {
                XCTAssertEqual(event.data, "A")
                firstEvent.fulfill()
                try Task.checkCancellation()
            }
        }

        // Do not infer client delivery from the server-side send. Cancellation
        // happens only after the production AsyncSequence yielded the event.
        await fulfillment(of: [firstEvent], timeout: 2)
        consumer.cancel()
        _ = await consumer.result
        await fulfillment(of: [server.disconnected], timeout: 2)
    }

    func testEarlyConsumerExitClosesSocket() async throws {
        let server = try LoopbackServer(prefix: Self.headers + "data: A\n\n")
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = SSETransport(session: session, allowsInsecureLoopback: true, timeoutSeconds: 3)
        for try await event in transport.stream(URLRequest(url: try server.url())) {
            XCTAssertEqual(event.data, "A")
            break
        }
        await fulfillment(of: [server.disconnected], timeout: 2)
    }

    func testHTTPErrorMIMEAndTruncatedEOFAreExplicit() async throws {
        let fixtures: [(String, SSETransportFailure)] = [
            ("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\nPRIVATE_BODY", .httpStatus(401)),
            ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}", .unexpectedContentType),
            (Self.headers + "data: truncated\n", .truncatedEvent),
        ]
        for (wire, expected) in fixtures {
            let server = try LoopbackServer(prefix: wire, closeAfterPrefix: true)
            defer { server.stop() }
            await fulfillment(of: [server.ready], timeout: 3)
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let transport = SSETransport(session: session, allowsInsecureLoopback: true, timeoutSeconds: 3)
            do {
                for try await _ in transport.stream(URLRequest(url: try server.url())) {}
                XCTFail("Expected a typed transport error")
            } catch {
                XCTAssertEqual(error as? SSETransportFailure, expected)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE_BODY"))
            }
        }
    }

    func testCrossOriginRedirectCannotReceiveSecretHeaders() async throws {
        let destination = try LoopbackServer(prefix: Self.headers, expectNoRequest: true)
        defer { destination.stop() }
        await fulfillment(of: [destination.ready], timeout: 3)
        let redirect = "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(try destination.url().absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let origin = try LoopbackServer(prefix: redirect, closeAfterPrefix: true)
        defer { origin.stop() }
        await fulfillment(of: [origin.ready], timeout: 3)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = SSETransport(session: session, allowsInsecureLoopback: true, timeoutSeconds: 2)
        var request = URLRequest(url: try origin.url())
        request.setValue("fixture-secret", forHTTPHeaderField: "x-custom-secret")
        do {
            for try await _ in transport.stream(request) {}
            XCTFail("Redirect should be rejected")
        } catch { XCTAssertEqual(error as? SSETransportFailure, .httpStatus(307)) }
        await fulfillment(of: [destination.received], timeout: 0.2)
    }

    func testDeadlineCancelsStalledConnection() async throws {
        let server = try LoopbackServer(prefix: Self.headers + ": heartbeat\n\n")
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = SSETransport(session: session, allowsInsecureLoopback: true, timeoutSeconds: 0.2)
        do {
            for try await _ in transport.stream(URLRequest(url: try server.url())) {}
            XCTFail("Expected bounded deadline")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        await fulfillment(of: [server.disconnected], timeout: 2)
    }

    func testHTTPIsDisabledByDefault() async {
        do {
            for try await _ in SSETransport().stream(URLRequest(url: URL(string: "http://127.0.0.1:1/")!)) {}
            XCTFail("Production configuration must require HTTPS")
        } catch { XCTAssertEqual(error as? SSETransportFailure, .invalidURL) }
    }

    func testTotalByteLimitStopsOtherwiseValidStream() async throws {
        let server = try LoopbackServer(prefix: Self.headers + "data: first\n\ndata: second\n\n", closeAfterPrefix: true)
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = SSETransport(session: session, allowsInsecureLoopback: true, timeoutSeconds: 3, maxStreamBytes: 8)
        do {
            for try await _ in transport.stream(URLRequest(url: try server.url())) {}
            XCTFail("Expected byte limit")
        } catch { XCTAssertEqual(error as? SSETransportFailure, .streamTooLarge) }
    }

    private static let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nConnection: close\r\n\r\n"
}

/// All mutable connection state lives on one queue; bound to loopback, never LAN.
private final class LoopbackServer: @unchecked Sendable {
    let ready = XCTestExpectation(description: "loopback listening")
    let received = XCTestExpectation(description: "loopback received request")
    let disconnected = XCTestExpectation(description: "client disconnected")
    private let queue = DispatchQueue(label: "QuickCue.loopback.fixture")
    private let listener: NWListener
    private let prefix: Data
    private let closeAfterPrefix: Bool
    private var connections: [NWConnection] = []

    init(prefix: String, closeAfterPrefix: Bool = false, expectNoRequest: Bool = false) throws {
        self.prefix = Data(prefix.utf8)
        self.closeAfterPrefix = closeAfterPrefix
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        received.isInverted = expectNoRequest
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.read(connection, headers: Data(), responded: false)
        }
        listener.start(queue: queue)
    }

    func url() throws -> URL {
        guard let port = listener.port else { throw URLError(.cannotConnectToHost) }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/stream")!
    }

    private func read(_ connection: NWConnection, headers: Data, responded: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = headers
            var didRespond = responded
            if !responded, let data {
                buffer.append(data)
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    didRespond = true
                    self.received.fulfill()
                    connection.send(content: self.prefix, completion: .contentProcessed { [weak self] _ in
                        if self?.closeAfterPrefix == true { connection.cancel() }
                    })
                } else if buffer.count > 65_536 { connection.cancel(); return }
            }
            if complete || error != nil { self.disconnected.fulfill(); return }
            self.read(connection, headers: didRespond ? Data() : buffer, responded: didRespond)
        }
    }

    func release(tail: Data, byteByByte: Bool = false) {
        queue.async { [self] in
            for connection in connections {
                let chunks = byteByByte ? tail.map { Data([$0]) } : [tail]
                send(chunks, at: 0, on: connection)
            }
        }
    }

    private func send(_ chunks: [Data], at index: Int, on connection: NWConnection) {
        guard index < chunks.count else { connection.cancel(); return }
        connection.send(content: chunks[index], completion: .contentProcessed { [weak self] error in
            guard error == nil else { connection.cancel(); return }
            self?.send(chunks, at: index + 1, on: connection)
        })
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}
