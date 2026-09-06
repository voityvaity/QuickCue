import CryptoKit
import Foundation
import XCTest
@testable import QuickCue

final class DiagnosticsPairingTests: XCTestCase {
    func testInvitationRejectsPublicHostAndExpiredCode() throws {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(try DiagnosticsPairingInvitation.parse(
            code(
                host: "example.com", expiresAt: now.addingTimeInterval(600),
                publicKey: privateKey.publicKey.rawRepresentation
            ),
            now: now
        ))
        XCTAssertThrowsError(try DiagnosticsPairingInvitation.parse(
            code(
                host: "127.0.0.1", expiresAt: now.addingTimeInterval(600),
                publicKey: privateKey.publicKey.rawRepresentation
            ),
            now: now
        ))
        XCTAssertThrowsError(try DiagnosticsPairingInvitation.parse(
            code(
                host: "192.168.1.5", expiresAt: now.addingTimeInterval(-1),
                publicKey: privateKey.publicKey.rawRepresentation
            ),
            now: now
        ))
    }

    func testEnvelopeRoundTripsWithReceiverKeyAndContainsNoPlaintextPayload() throws {
        let receiver = P256.KeyAgreement.PrivateKey()
        let receiverID = UUID()
        let payload = PairingPayload(
            schemaVersion: 1,
            pairID: UUID(),
            oneTimeSecret: Data(repeating: 7, count: 32).base64URLEncodedString(),
            deliverySecret: Data(repeating: 9, count: 32).base64URLEncodedString()
        )
        let packetData = try DiagnosticEnvelopeCrypto.seal(
            payload,
            kind: .pair,
            receiverID: receiverID,
            receiverPublicKey: receiver.publicKey.rawRepresentation.base64URLEncodedString()
        )
        XCTAssertFalse(String(decoding: packetData, as: UTF8.self).contains(payload.deliverySecret))
        let packet = try JSONDecoder().decode(SealedDiagnosticPacket.self, from: packetData)
        let ephemeral = try P256.KeyAgreement.PublicKey(
            rawRepresentation: try XCTUnwrap(Data(base64URL: packet.ephemeralPublicKey))
        )
        let shared = try receiver.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(receiverID.uuidString.lowercased().utf8),
            sharedInfo: Data("QuickCue-pair-v1".utf8),
            outputByteCount: 32
        )
        let box = try ChaChaPoly.SealedBox(combined: try XCTUnwrap(Data(base64URL: packet.sealedPayload)))
        let decoded = try JSONDecoder().decode(PairingPayload.self, from: ChaChaPoly.open(box, using: key))
        XCTAssertEqual(decoded, payload)
    }

    @MainActor
    func testPairingDoesNotEnableAutomaticDeliveryAndRevokeDeletesSecret() async throws {
        let defaultsName = "DiagnosticsPairingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = AppSettings(defaults: defaults)
        let receiver = P256.KeyAgreement.PrivateKey()
        let receiverID = UUID()
        let pairID = UUID()
        let secret = Data(repeating: 13, count: 32)
        let transport = PairingAckTransport(
            receiverID: receiverID, pairID: pairID, secret: secret,
            receiverPrivateKey: receiver
        )
        let secrets = MemorySecretStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsPairingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = DiagnosticsDeliveryController(
            settings: settings,
            recorder: DiagnosticsRecorder(directory: directory.appendingPathComponent("events")),
            transport: transport,
            secretStore: secrets,
            deliveryQueue: DiagnosticsDeliveryQueue(directory: directory.appendingPathComponent("queue")),
            randomBytes: { _ in secret },
            pairIDGenerator: { pairID }
        )
        let now = Date.now
        settings.automaticDiagnosticsDeliveryEnabled = true
        try await controller.pair(using: code(
            receiverID: receiverID,
            host: "192.168.1.5",
            expiresAt: now.addingTimeInterval(600),
            publicKey: receiver.publicKey.rawRepresentation
        ))
        XCTAssertNotNil(settings.diagnosticsPairingProfile)
        XCTAssertFalse(settings.automaticDiagnosticsDeliveryEnabled)
        let callsAfterPair = await transport.calls
        XCTAssertEqual(callsAfterPair, 1)

        controller.sessionEnded()
        await Task.yield()
        let callsAfterSession = await transport.calls
        XCTAssertEqual(callsAfterSession, 1, "No diagnostic network call is allowed while opt-in is off")

        let account = try XCTUnwrap(settings.diagnosticsPairingProfile?.keychainAccount)
        XCTAssertNotNil(try secrets.read(account: account))
        controller.revoke()
        XCTAssertNil(settings.diagnosticsPairingProfile)
        XCTAssertNil(try secrets.read(account: account))
    }

    @MainActor
    func testOptInDeliversEncryptedReportAndRemovesItFromQueue() async throws {
        let fixture = try makeController(reportBehavior: .succeed)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.controller.pair(using: fixture.code)
        fixture.controller.setAutomaticDelivery(true)
        fixture.recorder.record(.scheduler(active: 1, pending: 2))
        fixture.controller.sessionEnded()

        try await waitUntil {
            let calls = await fixture.transport.calls
            return calls >= 2 && fixture.controller.pendingCount == 0
        }
        let archiveBytes = await fixture.transport.receivedArchiveBytes
        XCTAssertGreaterThan(archiveBytes, 0)
        if case .delivered = fixture.controller.state {} else {
            XCTFail("Expected a cryptographically acknowledged delivery")
        }
    }

    @MainActor
    func testUnavailableReceiverLeavesOneBoundedQueuedReport() async throws {
        let fixture = try makeController(reportBehavior: .failConnection)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.controller.pair(using: fixture.code)
        fixture.controller.setAutomaticDelivery(true)
        fixture.controller.sessionEnded()

        try await waitUntil {
            let calls = await fixture.transport.calls
            return calls >= 2 && fixture.controller.pendingCount == 1
        }
        XCTAssertEqual(fixture.controller.state, .unavailable)
        XCTAssertNotNil(fixture.controller.nextRetryAt)
    }

    @MainActor
    func testBackgroundCancelsInFlightPairingWithoutSavingRecipient() async throws {
        let defaultsName = "DiagnosticsPairingCancellationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = AppSettings(defaults: defaults)
        let receiver = P256.KeyAgreement.PrivateKey()
        let receiverID = UUID()
        let pairID = UUID()
        let secret = Data(repeating: 23, count: 32)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsPairingCancellationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = PairingAckTransport(
            receiverID: receiverID, pairID: pairID, secret: secret,
            receiverPrivateKey: receiver, pairDelayNanoseconds: 5_000_000_000
        )
        let controller = DiagnosticsDeliveryController(
            settings: settings,
            recorder: DiagnosticsRecorder(directory: directory.appendingPathComponent("events")),
            transport: transport,
            secretStore: MemorySecretStore(),
            deliveryQueue: DiagnosticsDeliveryQueue(directory: directory.appendingPathComponent("queue")),
            randomBytes: { _ in secret },
            pairIDGenerator: { pairID }
        )
        let task = Task {
            try await controller.pair(using: code(
                receiverID: receiverID, host: "192.168.1.5",
                expiresAt: .now.addingTimeInterval(600),
                publicKey: receiver.publicKey.rawRepresentation
            ))
        }
        try await waitUntil { await transport.calls == 1 }
        controller.appBecameInactive()
        do {
            try await task.value
            XCTFail("Pairing should be cancelled in background")
        } catch is CancellationError {}
        XCTAssertNil(settings.diagnosticsPairingProfile)
        XCTAssertEqual(controller.state, .idle)
    }

    @MainActor
    private func makeController(reportBehavior: PairingAckTransport.ReportBehavior) throws -> ControllerFixture {
        let defaultsName = "DiagnosticsDeliveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let settings = AppSettings(defaults: defaults)
        let receiver = P256.KeyAgreement.PrivateKey()
        let receiverID = UUID()
        let pairID = UUID()
        let secret = Data(repeating: 19, count: 32)
        let transport = PairingAckTransport(
            receiverID: receiverID, pairID: pairID, secret: secret,
            receiverPrivateKey: receiver, reportBehavior: reportBehavior
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsDeliveryTests-\(UUID().uuidString)")
        let recorder = DiagnosticsRecorder(directory: directory.appendingPathComponent("events"))
        let controller = DiagnosticsDeliveryController(
            settings: settings,
            recorder: recorder,
            transport: transport,
            secretStore: MemorySecretStore(),
            deliveryQueue: DiagnosticsDeliveryQueue(directory: directory.appendingPathComponent("queue")),
            randomBytes: { _ in secret },
            pairIDGenerator: { pairID }
        )
        return ControllerFixture(
            controller: controller,
            recorder: recorder,
            transport: transport,
            defaults: defaults,
            defaultsName: defaultsName,
            directory: directory,
            code: try code(
                receiverID: receiverID,
                host: "192.168.1.5",
                expiresAt: .now.addingTimeInterval(600),
                publicKey: receiver.publicKey.rawRepresentation
            )
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date.now < deadline else { throw DiagnosticsPairingError.connection }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func code(
        receiverID: UUID = UUID(),
        host: String,
        expiresAt: Date,
        publicKey: Data
    ) throws -> String {
        let invitation = DiagnosticsPairingInvitation(
            schemaVersion: 1,
            receiverID: receiverID,
            host: host,
            port: 43117,
            publicKey: publicKey.base64URLEncodedString(),
            oneTimeSecret: Data(repeating: 3, count: 32).base64URLEncodedString(),
            expiresAt: expiresAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return "quickcue-pair:" + (try encoder.encode(invitation)).base64URLEncodedString()
    }
}

@MainActor
private struct ControllerFixture {
    let controller: DiagnosticsDeliveryController
    let recorder: DiagnosticsRecorder
    let transport: PairingAckTransport
    let defaults: UserDefaults
    let defaultsName: String
    let directory: URL
    let code: String
}

private actor PairingAckTransport: DiagnosticPacketTransport {
    enum ReportBehavior: Equatable, Sendable { case succeed, failConnection }

    let receiverID: UUID
    let pairID: UUID
    let secret: Data
    let receiverPrivateKey: P256.KeyAgreement.PrivateKey
    let reportBehavior: ReportBehavior
    let pairDelayNanoseconds: UInt64
    private(set) var calls = 0
    private(set) var receivedArchiveBytes = 0

    init(
        receiverID: UUID, pairID: UUID, secret: Data,
        receiverPrivateKey: P256.KeyAgreement.PrivateKey,
        reportBehavior: ReportBehavior = .succeed,
        pairDelayNanoseconds: UInt64 = 0
    ) {
        self.receiverID = receiverID
        self.pairID = pairID
        self.secret = secret
        self.receiverPrivateKey = receiverPrivateKey
        self.reportBehavior = reportBehavior
        self.pairDelayNanoseconds = pairDelayNanoseconds
    }

    func send(packet: Data, host: String, port: UInt16) async throws -> Data {
        calls += 1
        let envelope = try JSONDecoder().decode(SealedDiagnosticPacket.self, from: packet)
        guard envelope.receiverID == receiverID else { throw DiagnosticsPairingError.receiverRejected }
        let plaintext = try open(envelope)
        let status: String
        let referenceID: UUID
        switch envelope.kind {
        case .pair:
            if pairDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: pairDelayNanoseconds)
            }
            let payload = try JSONDecoder().decode(PairingPayload.self, from: plaintext)
            guard payload.pairID == pairID,
                  Data(base64URL: payload.deliverySecret) == secret else {
                throw DiagnosticsPairingError.receiverRejected
            }
            status = "paired"
            referenceID = payload.pairID
        case .report:
            if reportBehavior == .failConnection { throw DiagnosticsPairingError.connection }
            let payload = try JSONDecoder().decode(DiagnosticReportPayload.self, from: plaintext)
            guard payload.pairID == pairID,
                  Data(base64URL: payload.deliverySecret) == secret else {
                throw DiagnosticsPairingError.receiverRejected
            }
            receivedArchiveBytes = payload.archive.count
            status = "stored"
            referenceID = payload.exportID
        }
        let acknowledgement = DiagnosticReceiverAcknowledgement(
            schemaVersion: 1,
            status: status,
            receiverID: receiverID,
            referenceID: referenceID,
            authenticationCode: DiagnosticEnvelopeCrypto.authenticationCode(
                secret: secret, status: status, receiverID: receiverID, referenceID: referenceID
            )
        )
        return try JSONEncoder().encode(acknowledgement)
    }

    private func open(_ packet: SealedDiagnosticPacket) throws -> Data {
        let ephemeral = try P256.KeyAgreement.PublicKey(
            rawRepresentation: try XCTUnwrap(Data(base64URL: packet.ephemeralPublicKey))
        )
        let shared = try receiverPrivateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(receiverID.uuidString.lowercased().utf8),
            sharedInfo: Data("QuickCue-\(packet.kind.rawValue)-v1".utf8),
            outputByteCount: 32
        )
        let box = try ChaChaPoly.SealedBox(
            combined: try XCTUnwrap(Data(base64URL: packet.sealedPayload))
        )
        return try ChaChaPoly.open(box, using: key)
    }
}

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = value
    }

    func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}
