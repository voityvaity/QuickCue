import Combine
import Foundation
import Security

enum DiagnosticsDeliveryState: Equatable {
    case idle
    case pairing
    case paired
    case preparing
    case sending
    case delivered(Date)
    case unavailable
    case rejected

    var title: String {
        switch self {
        case .idle: "Не привязан"
        case .pairing: "Проверяю привязку…"
        case .paired: "ПК привязан"
        case .preparing: "Готовлю отчёт…"
        case .sending: "Отправляю на ПК…"
        case .delivered(let date): "Доставлено \(date.formatted(date: .omitted, time: .shortened))"
        case .unavailable: "ПК сейчас недоступен"
        case .rejected: "Привязку нужно обновить"
        }
    }
}

struct PendingDiagnosticDelivery: Sendable {
    let exportID: UUID
    let fileURL: URL
}

actor DiagnosticsDeliveryQueue {
    private let directory: URL
    private let maximumItems: Int

    init(directory: URL? = nil, maximumItems: Int = 3) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("QuickCue/DiagnosticDeliveryQueue", isDirectory: true)
        self.maximumItems = max(1, maximumItems)
    }

    func enqueue(_ export: DiagnosticsExport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(export.exportID.uuidString).pending")
        let bytes = try Data(contentsOf: export.fileURL, options: .mappedIfSafe)
        guard bytes.count <= DiagnosticsArchiveBuilder.maximumArchiveBytes else {
            throw DiagnosticsPairingError.payloadTooLarge
        }
        try bytes.write(to: destination, options: .atomic)
        let existing = pending()
        if existing.count > maximumItems {
            for old in existing.prefix(existing.count - maximumItems) {
                try? FileManager.default.removeItem(at: old.fileURL)
            }
        }
    }

    func pending() -> [PendingDiagnosticDelivery] {
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).filter { $0.pathExtension == "pending" }
        return urls.compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return PendingDiagnosticDelivery(exportID: id, fileURL: url)
        }.sorted {
            let left = (try? $0.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    func remove(_ item: PendingDiagnosticDelivery) {
        try? FileManager.default.removeItem(at: item.fileURL)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func count() -> Int { pending().count }
}

@MainActor
final class DiagnosticsDeliveryController: ObservableObject {
    @Published private(set) var state: DiagnosticsDeliveryState = .idle
    @Published private(set) var pendingCount = 0
    @Published private(set) var nextRetryAt: Date?

    private let settings: AppSettings
    private let recorder: DiagnosticsRecorder
    private let transport: any DiagnosticPacketTransport
    private let secretStore: any SecretStore
    private let deliveryQueue: DiagnosticsDeliveryQueue
    private let randomBytes: @Sendable (Int) throws -> Data
    private let pairIDGenerator: @Sendable () -> UUID
    private var operation: Task<Void, Never>?
    private var pairingOperation: Task<Void, Error>?
    private var generation = UUID()

    init(
        settings: AppSettings,
        recorder: DiagnosticsRecorder = .shared,
        transport: any DiagnosticPacketTransport = NWTCPDiagnosticPacketTransport(),
        secretStore: any SecretStore = KeychainStore(),
        deliveryQueue: DiagnosticsDeliveryQueue = .init(),
        randomBytes: @escaping @Sendable (Int) throws -> Data = DiagnosticsDeliveryController.randomBytes,
        pairIDGenerator: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.settings = settings
        self.recorder = recorder
        self.transport = transport
        self.secretStore = secretStore
        self.deliveryQueue = deliveryQueue
        self.randomBytes = randomBytes
        self.pairIDGenerator = pairIDGenerator
        self.state = settings.diagnosticsPairingProfile == nil ? .idle : .paired
        Task { pendingCount = await deliveryQueue.count() }
    }

    func pair(using code: String) async throws {
        operation?.cancel()
        pairingOperation?.cancel()
        let currentGeneration = UUID()
        generation = currentGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performPair(using: code, currentGeneration: currentGeneration)
        }
        pairingOperation = task
        defer {
            if generation == currentGeneration { pairingOperation = nil }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performPair(using code: String, currentGeneration: UUID) async throws {
        state = .pairing
        defer {
            if state == .pairing {
                state = settings.diagnosticsPairingProfile == nil ? .idle : .paired
            }
        }
        let invitation = try DiagnosticsPairingInvitation.parse(code)
        let pairID = pairIDGenerator()
        let deliverySecret = try randomBytes(32)
        let payload = PairingPayload(
            schemaVersion: 1,
            pairID: pairID,
            oneTimeSecret: invitation.oneTimeSecret,
            deliverySecret: deliverySecret.base64URLEncodedString()
        )
        let packet = try DiagnosticEnvelopeCrypto.seal(
            payload, kind: .pair, receiverID: invitation.receiverID,
            receiverPublicKey: invitation.publicKey
        )
        let response = try await transport.send(packet: packet, host: invitation.host, port: invitation.port)
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        let acknowledgement = try JSONDecoder().decode(DiagnosticReceiverAcknowledgement.self, from: response)
        guard DiagnosticEnvelopeCrypto.verify(
            acknowledgement,
            expectedStatus: "paired",
            receiverID: invitation.receiverID,
            referenceID: pairID,
            secret: deliverySecret
        ) else {
            state = .rejected
            throw DiagnosticsPairingError.invalidAcknowledgement
        }
        let profile = DiagnosticsPairingProfile(
            schemaVersion: 1,
            receiverID: invitation.receiverID,
            pairID: pairID,
            host: invitation.host,
            port: invitation.port,
            publicKey: invitation.publicKey,
            fingerprint: try DiagnosticEnvelopeCrypto.fingerprint(publicKey: invitation.publicKey),
            pairedAt: .now
        )
        try secretStore.save(deliverySecret.base64URLEncodedString(), account: profile.keychainAccount)
        // A QR can identify a different recipient. Pairing never inherits the
        // previous recipient's automatic-delivery consent.
        settings.automaticDiagnosticsDeliveryEnabled = false
        let oldProfile = settings.diagnosticsPairingProfile
        settings.saveDiagnosticsPairing(profile)
        if let oldProfile, oldProfile.keychainAccount != profile.keychainAccount {
            try? secretStore.delete(account: oldProfile.keychainAccount)
        }
        state = .paired
        recorder.record(.delivery(.pairingSucceeded))
    }

    func setAutomaticDelivery(_ enabled: Bool) {
        guard settings.diagnosticsPairingProfile != nil else {
            settings.automaticDiagnosticsDeliveryEnabled = false
            return
        }
        settings.automaticDiagnosticsDeliveryEnabled = enabled
        if enabled { flushQueuedWhenActive() }
    }

    func sessionEnded() {
        guard settings.automaticDiagnosticsDeliveryEnabled else { return }
        operation?.cancel()
        operation = Task { [weak self] in await self?.queueCurrentReportAndFlush() }
    }

    func appBecameActive() {
        flushQueuedWhenActive()
    }

    func appBecameInactive() {
        generation = UUID()
        pairingOperation?.cancel()
        pairingOperation = nil
        operation?.cancel()
        operation = nil
        if state == .pairing {
            state = settings.diagnosticsPairingProfile == nil ? .idle : .paired
        }
    }

    func flushQueuedWhenActive() {
        guard settings.automaticDiagnosticsDeliveryEnabled,
              nextRetryAt.map({ $0 <= .now }) ?? true else { return }
        operation?.cancel()
        operation = Task { [weak self] in await self?.flush() }
    }

    func revoke() {
        generation = UUID()
        pairingOperation?.cancel()
        pairingOperation = nil
        operation?.cancel()
        operation = nil
        if let profile = settings.diagnosticsPairingProfile {
            try? secretStore.delete(account: profile.keychainAccount)
        }
        settings.clearDiagnosticsPairing()
        state = .idle
        nextRetryAt = nil
        recorder.record(.delivery(.pairingRevoked))
    }

    func deleteQueuedReports() async {
        await deliveryQueue.removeAll()
        pendingCount = 0
    }

    private func queueCurrentReportAndFlush() async {
        guard settings.automaticDiagnosticsDeliveryEnabled else { return }
        state = .preparing
        do {
            let export = try await recorder.export()
            try await deliveryQueue.enqueue(export)
            pendingCount = await deliveryQueue.count()
            recorder.record(.delivery(.deliveryQueued))
            await flush()
        } catch is CancellationError {
            state = settings.diagnosticsPairingProfile == nil ? .idle : .paired
        } catch {
            state = .unavailable
            nextRetryAt = .now.addingTimeInterval(60)
        }
    }

    private func flush() async {
        guard settings.automaticDiagnosticsDeliveryEnabled,
              let profile = settings.diagnosticsPairingProfile else { return }
        guard let secretText = try? secretStore.read(account: profile.keychainAccount),
              let secret = Data(base64URL: secretText), secret.count == 32 else {
            state = .rejected
            settings.automaticDiagnosticsDeliveryEnabled = false
            return
        }
        let items = await deliveryQueue.pending()
        pendingCount = items.count
        guard !items.isEmpty else { state = .paired; return }
        state = .sending
        for item in items.prefix(3) {
            do {
                try Task.checkCancellation()
                let archive = try Data(contentsOf: item.fileURL, options: .mappedIfSafe)
                let payload = DiagnosticReportPayload(
                    schemaVersion: 1,
                    pairID: profile.pairID,
                    deliverySecret: secretText,
                    exportID: item.exportID,
                    archive: archive
                )
                let packet = try DiagnosticEnvelopeCrypto.seal(
                    payload, kind: .report, receiverID: profile.receiverID,
                    receiverPublicKey: profile.publicKey
                )
                let response = try await transport.send(packet: packet, host: profile.host, port: profile.port)
                let acknowledgement = try JSONDecoder().decode(DiagnosticReceiverAcknowledgement.self, from: response)
                guard DiagnosticEnvelopeCrypto.verify(
                    acknowledgement,
                    expectedStatus: "stored",
                    receiverID: profile.receiverID,
                    referenceID: item.exportID,
                    secret: secret
                ) else { throw DiagnosticsPairingError.invalidAcknowledgement }
                await deliveryQueue.remove(item)
                pendingCount = await deliveryQueue.count()
                state = .delivered(.now)
                nextRetryAt = nil
                recorder.record(.delivery(.deliverySucceeded))
            } catch is CancellationError {
                return
            } catch let error as DiagnosticsPairingError {
                state = error == .receiverRejected || error == .invalidAcknowledgement ? .rejected : .unavailable
                nextRetryAt = .now.addingTimeInterval(60)
                recorder.record(.delivery(.deliveryFailed, error: error == .connection ? .offline : .unknown))
                return
            } catch {
                state = .unavailable
                nextRetryAt = .now.addingTimeInterval(60)
                recorder.record(.delivery(.deliveryFailed, error: .unknown))
                return
            }
        }
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw DiagnosticsPairingError.encryption }
        return bytes
    }
}
