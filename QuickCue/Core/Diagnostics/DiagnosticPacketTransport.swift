import Foundation
import Network

protocol DiagnosticPacketTransport: Sendable {
    func send(packet: Data, host: String, port: UInt16) async throws -> Data
}

struct NWTCPDiagnosticPacketTransport: DiagnosticPacketTransport {
    let timeoutSeconds: Double

    init(timeoutSeconds: Double = 8) {
        self.timeoutSeconds = min(30, max(1, timeoutSeconds))
    }

    func send(packet: Data, host: String, port: UInt16) async throws -> Data {
        guard packet.count <= DiagnosticEnvelopeCrypto.maximumPacketBytes,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw DiagnosticsPairingError.payloadTooLarge
        }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await sendOnce(packet: packet, host: host, port: nwPort)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw DiagnosticsPairingError.connection
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw DiagnosticsPairingError.connection }
            return response
        }
    }

    private func sendOnce(packet: Data, host: String, port: NWEndpoint.Port) async throws -> Data {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let gate = NetworkContinuationGate(connection: connection)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        var framed = Data()
                        framed.appendNetworkUInt32(UInt32(packet.count))
                        framed.append(packet)
                        connection.send(content: framed, completion: .contentProcessed { error in
                            if error != nil { gate.fail(DiagnosticsPairingError.connection) }
                            else { Self.receiveLength(connection: connection, gate: gate) }
                        })
                    case .failed, .cancelled:
                        gate.fail(DiagnosticsPairingError.connection)
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue.global(qos: .utility))
            }
        } onCancel: {
            gate.fail(CancellationError())
        }
    }

    private static func receiveLength(connection: NWConnection, gate: NetworkContinuationGate) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
            guard error == nil, let data, data.count == 4 else {
                gate.fail(DiagnosticsPairingError.connection)
                return
            }
            let length = data.networkUInt32
            guard length > 0, length <= 64 * 1_024 else {
                gate.fail(DiagnosticsPairingError.receiverRejected)
                return
            }
            receiveBody(connection: connection, remaining: Int(length), accumulated: Data(), gate: gate)
        }
    }

    private static func receiveBody(
        connection: NWConnection, remaining: Int, accumulated: Data,
        gate: NetworkContinuationGate
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
            guard error == nil, let data, !data.isEmpty else {
                gate.fail(DiagnosticsPairingError.connection)
                return
            }
            var next = accumulated
            next.append(data)
            let left = remaining - data.count
            if left == 0 { gate.succeed(next) }
            else if left > 0 { receiveBody(connection: connection, remaining: left, accumulated: next, gate: gate) }
            else { gate.fail(DiagnosticsPairingError.receiverRejected) }
        }
    }
}

private final class NetworkContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?

    init(connection: NWConnection) { self.connection = connection }

    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let pendingResult {
            lock.unlock()
            continuation.resume(with: pendingResult)
            connection.cancel()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func succeed(_ data: Data) { finish(.success(data)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            connection.cancel()
        } else if pendingResult == nil {
            pendingResult = result
            lock.unlock()
            connection.cancel()
        } else {
            lock.unlock()
        }
    }
}

private extension Data {
    mutating func appendNetworkUInt32(_ value: UInt32) {
        var network = value.bigEndian
        Swift.withUnsafeBytes(of: &network) { append(contentsOf: $0) }
    }

    var networkUInt32: UInt32 {
        reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
