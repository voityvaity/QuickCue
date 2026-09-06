import CryptoKit
import Foundation

struct DiagnosticsPairingInvitation: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let receiverID: UUID
    let host: String
    let port: UInt16
    let publicKey: String
    let oneTimeSecret: String
    let expiresAt: Date

    static func parse(_ code: String, now: Date = .now) throws -> Self {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmed.hasPrefix("quickcue-pair:")
            ? String(trimmed.dropFirst("quickcue-pair:".count))
            : trimmed
        guard let data = Data(base64URL: encoded), data.count <= 4_096 else {
            throw DiagnosticsPairingError.invalidCode
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let invitation: Self
        do { invitation = try decoder.decode(Self.self, from: data) }
        catch { throw DiagnosticsPairingError.invalidCode }
        let publicKeyData = Data(base64URL: invitation.publicKey)
        guard invitation.schemaVersion == 1,
              invitation.expiresAt > now,
              invitation.expiresAt.timeIntervalSince(now) <= 20 * 60,
              Self.isPrivateLANHost(invitation.host),
              invitation.port > 0,
              publicKeyData.flatMap({ try? P256.KeyAgreement.PublicKey(x963Representation: $0) }) != nil,
              (16...64).contains(Data(base64URL: invitation.oneTimeSecret)?.count ?? 0)
        else { throw DiagnosticsPairingError.invalidCode }
        return invitation
    }

    private static func isPrivateLANHost(_ host: String) -> Bool {
        guard host.count <= 253, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return false }
        if host.lowercased().hasSuffix(".local") { return true }
        let numbers = host.split(separator: ".").compactMap { UInt8($0) }
        guard numbers.count == 4 else { return false }
        return numbers[0] == 10
            || (numbers[0] == 192 && numbers[1] == 168)
            || (numbers[0] == 172 && (16...31).contains(numbers[1]))
    }
}

struct DiagnosticsPairingProfile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let receiverID: UUID
    let pairID: UUID
    let host: String
    let port: UInt16
    let publicKey: String
    let fingerprint: String
    let pairedAt: Date

    var keychainAccount: String { "diagnostics-pair.\(receiverID.uuidString).\(pairID.uuidString)" }
}

enum DiagnosticPacketKind: String, Codable, Sendable {
    case pair
    case report
}

struct SealedDiagnosticPacket: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: DiagnosticPacketKind
    let receiverID: UUID
    let ephemeralPublicKey: String
    let sealedPayload: String
}

struct PairingPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let pairID: UUID
    let oneTimeSecret: String
    let deliverySecret: String
}

struct DiagnosticReportPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let pairID: UUID
    let deliverySecret: String
    let exportID: UUID
    let archive: Data
}

struct DiagnosticReceiverAcknowledgement: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let status: String
    let receiverID: UUID
    let referenceID: UUID
    let authenticationCode: String
}

enum DiagnosticsPairingError: LocalizedError, Equatable {
    case invalidCode
    case expired
    case encryption
    case connection
    case receiverRejected
    case invalidAcknowledgement
    case missingPair
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidCode: "Код привязки повреждён, просрочен или ведёт не в локальную сеть. Создайте новый код на ПК."
        case .expired: "Одноразовый код привязки истёк. Создайте новый код на ПК."
        case .encryption: "Не удалось зашифровать диагностический пакет."
        case .connection: "ПК недоступен. QuickCue продолжит работать, а отчёт останется в локальной очереди."
        case .receiverRejected: "Приёмник на ПК отклонил пакет. Проверьте привязку."
        case .invalidAcknowledgement: "Ответ ПК не прошёл криптографическую проверку; отчёт не считается доставленным."
        case .missingPair: "Привязка неполная. Отзовите её и подключите ПК заново."
        case .payloadTooLarge: "Диагностический пакет превысил безопасный лимит."
        }
    }
}

enum DiagnosticEnvelopeCrypto {
    static let maximumPacketBytes = 20 * 1_024 * 1_024

    static func seal<T: Encodable>(
        _ payload: T,
        kind: DiagnosticPacketKind,
        receiverID: UUID,
        receiverPublicKey: String
    ) throws -> Data {
        guard let publicBytes = Data(base64URL: receiverPublicKey) else {
            throw DiagnosticsPairingError.encryption
        }
        let receiverKey = try P256.KeyAgreement.PublicKey(x963Representation: publicBytes)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: receiverKey)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(receiverID.uuidString.lowercased().utf8),
            sharedInfo: Data("QuickCue-\(kind.rawValue)-v1".utf8),
            outputByteCount: 32
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(payload)
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        let combined = sealed.combined
        let packet = SealedDiagnosticPacket(
            schemaVersion: 1,
            kind: kind,
            receiverID: receiverID,
            ephemeralPublicKey: ephemeral.publicKey.x963Representation.base64URLEncodedString(),
            sealedPayload: combined.base64URLEncodedString()
        )
        let data = try encoder.encode(packet)
        guard data.count <= maximumPacketBytes else { throw DiagnosticsPairingError.payloadTooLarge }
        return data
    }

    static func fingerprint(publicKey: String) throws -> String {
        guard let data = Data(base64URL: publicKey) else { throw DiagnosticsPairingError.invalidCode }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func authenticationCode(
        secret: Data, status: String, receiverID: UUID, referenceID: UUID
    ) -> String {
        let message = Data("v1|\(status)|\(receiverID.uuidString.lowercased())|\(referenceID.uuidString.lowercased())".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
            .base64URLEncodedString()
    }

    static func verify(
        _ acknowledgement: DiagnosticReceiverAcknowledgement,
        expectedStatus: String,
        receiverID: UUID,
        referenceID: UUID,
        secret: Data
    ) -> Bool {
        guard acknowledgement.schemaVersion == 1,
              acknowledgement.status == expectedStatus,
              acknowledgement.receiverID == receiverID,
              acknowledgement.referenceID == referenceID,
              let supplied = Data(base64URL: acknowledgement.authenticationCode)
        else { return false }
        let message = Data("v1|\(expectedStatus)|\(receiverID.uuidString.lowercased())|\(referenceID.uuidString.lowercased())".utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(
            supplied, authenticating: message, using: SymmetricKey(data: secret)
        )
    }
}

extension Data {
    init?(base64URL value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
