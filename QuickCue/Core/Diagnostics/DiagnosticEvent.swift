import Foundation
import UIKit

enum DiagnosticProvider: String, Codable, CaseIterable, Sendable {
    case mock
    case openAI
    case deepSeek
    case anthropic
    case xAI
    case yandexGPT
    case custom

    init(_ selection: ProviderSelection) {
        self = selection.customID == nil ? DiagnosticProvider(selection.kind) : .custom
    }

    init(_ kind: ProviderKind) {
        self = switch kind {
        case .mock: .mock
        case .openAI: .openAI
        case .deepSeek: .deepSeek
        case .anthropic: .anthropic
        case .xAI: .xAI
        case .yandexGPT: .yandexGPT
        case .custom: .custom
        }
    }
}

enum DiagnosticEventKind: String, Codable, CaseIterable, Sendable {
    case schedulerCounts
    case sessionStarted
    case sessionEnded
    case requestQueued
    case requestStarted
    case firstToken
    case requestAttemptFinished
    case requestFinished
    case requestCancelled
    case speechPhase
    case speechFinalized
    case cameraCaptured
    case speakerCorrected
    case deliveryQueued
    case deliverySucceeded
    case deliveryFailed
    case pairingSucceeded
    case pairingRevoked
}

enum DiagnosticPhase: String, Codable, Sendable {
    case idle
    case starting
    case listening
    case stopping
    case queued
    case active
}

enum DiagnosticFinishCategory: String, Codable, Sendable {
    case complete
    case partial
    case failed
    case cancelled
}

enum DiagnosticErrorCategory: String, Codable, Sendable {
    case none
    case cancelled
    case timeout
    case offline
    case host
    case tls
    case credentialMissing
    case unauthorized
    case billing
    case forbidden
    case modelOrEndpoint
    case rateLimit
    case server
    case invalidFormat
    case sizeLimit
    case incompleteResponse
    case emptyResponse
    case unsupportedImage
    case configuration
    case storage
    case unknown

    init(safeCode: String?) {
        self = switch safeCode {
        case nil: .none
        case "cancelled": .cancelled
        case "timeout", "http_408": .timeout
        case "offline", "network": .offline
        case "host", "host_unreachable": .host
        case "tls": .tls
        case "credential_missing", "missing_credential": .credentialMissing
        case "unauthorized", "http_401": .unauthorized
        case "billing", "http_402": .billing
        case "forbidden", "http_403", "policy_block": .forbidden
        case "model_or_endpoint", "http_404": .modelOrEndpoint
        case "rate_limit", "http_429": .rateLimit
        case "server", "http_500", "http_502", "http_503", "http_504": .server
        case "invalid_http", "content_type", "invalid_utf8", "stream_error",
             "malformed_event", "unsupported_output", "unsupported_termination": .invalidFormat
        case "event_too_large", "stream_too_large", "consumer_too_slow": .sizeLimit
        case "incomplete_response", "premature_eof", "output_limit", "resource_interruption": .incompleteResponse
        case "empty_response", "reasoning_only": .emptyResponse
        case "vision_unsupported", "unsupported_image": .unsupportedImage
        case "configuration": .configuration
        case "credential_storage", "setup_commit": .storage
        default: .unknown
        }
    }
}

enum DiagnosticUsageProvenance: String, Codable, Sendable {
    case reported
    case estimated
    case unknown
    case freeMock
    case notSent
}

enum DiagnosticCancelReason: String, Codable, Sendable {
    case user
    case sessionEnded
    case background
    case timeout
    case replaced
    case unknown
}

struct DiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let occurredAt: Date
    let appVersion: String
    let appBuild: String
    let sourceRevision: String
    let osVersion: String
    let deviceFamily: String
    let kind: DiagnosticEventKind
    let sessionID: UUID?
    let requestID: UUID?
    let provider: DiagnosticProvider?
    let phase: DiagnosticPhase?
    let durationMilliseconds: Int?
    let activeCount: Int?
    let pendingCount: Int?
    let finish: DiagnosticFinishCategory?
    let error: DiagnosticErrorCategory?
    let usageProvenance: DiagnosticUsageProvenance?
    let inputTokens: Int?
    let outputTokens: Int?
    let knownCostRUB: Double?
    let cancelReason: DiagnosticCancelReason?
    let manualCorrectionCount: Int?

    private init(
        id: UUID = UUID(), occurredAt: Date = .now, kind: DiagnosticEventKind,
        sessionID: UUID? = nil, requestID: UUID? = nil, provider: DiagnosticProvider? = nil,
        phase: DiagnosticPhase? = nil, durationMilliseconds: Int? = nil,
        activeCount: Int? = nil, pendingCount: Int? = nil,
        finish: DiagnosticFinishCategory? = nil, error: DiagnosticErrorCategory? = nil,
        usageProvenance: DiagnosticUsageProvenance? = nil,
        inputTokens: Int? = nil, outputTokens: Int? = nil, knownCostRUB: Double? = nil,
        cancelReason: DiagnosticCancelReason? = nil, manualCorrectionCount: Int? = nil
    ) {
        let build = BuildIdentity.current
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.occurredAt = occurredAt
        self.appVersion = build.version
        self.appBuild = build.build
        self.sourceRevision = build.revision
        self.osVersion = UIDevice.current.systemVersion
        self.deviceFamily = UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "other-iOS"
        self.kind = kind
        self.sessionID = sessionID
        self.requestID = requestID
        self.provider = provider
        self.phase = phase
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.activeCount = activeCount.map { max(0, $0) }
        self.pendingCount = pendingCount.map { max(0, $0) }
        self.finish = finish
        self.error = error
        self.usageProvenance = usageProvenance
        self.inputTokens = inputTokens.map { max(0, $0) }
        self.outputTokens = outputTokens.map { max(0, $0) }
        self.knownCostRUB = knownCostRUB.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.cancelReason = cancelReason
        self.manualCorrectionCount = manualCorrectionCount.map { max(0, $0) }
    }

    static func scheduler(active: Int, pending: Int) -> Self {
        Self(kind: .schedulerCounts, activeCount: active, pendingCount: pending)
    }

    static func session(_ kind: DiagnosticEventKind, id: UUID) -> Self {
        precondition(kind == .sessionStarted || kind == .sessionEnded)
        return Self(kind: kind, sessionID: id)
    }

    static func request(
        _ kind: DiagnosticEventKind, sessionID: UUID?, requestID: UUID,
        provider: ProviderSelection? = nil, durationMilliseconds: Int? = nil,
        finish: DiagnosticFinishCategory? = nil, errorCode: String? = nil,
        cancelReason: DiagnosticCancelReason? = nil
    ) -> Self {
        Self(
            kind: kind, sessionID: sessionID, requestID: requestID,
            provider: provider.map(DiagnosticProvider.init), durationMilliseconds: durationMilliseconds,
            finish: finish,
            error: errorCode.map { DiagnosticErrorCategory(safeCode: $0) },
            cancelReason: cancelReason
        )
    }

    static func attempt(
        sessionID: UUID?, requestID: UUID, provider: ProviderSelection,
        durationMilliseconds: Int, finish: DiagnosticFinishCategory,
        errorCode: String?, usageProvenance: DiagnosticUsageProvenance,
        inputTokens: Int?, outputTokens: Int?, knownCostRUB: Double?
    ) -> Self {
        Self(
            kind: .requestAttemptFinished, sessionID: sessionID, requestID: requestID,
            provider: DiagnosticProvider(provider), durationMilliseconds: durationMilliseconds,
            finish: finish, error: DiagnosticErrorCategory(safeCode: errorCode),
            usageProvenance: usageProvenance, inputTokens: inputTokens,
            outputTokens: outputTokens, knownCostRUB: knownCostRUB
        )
    }

    static func speech(phase: SpeechRecognitionState, sessionID: UUID?) -> Self {
        let safePhase: DiagnosticPhase = switch phase {
        case .idle: .idle
        case .starting: .starting
        case .listening: .listening
        case .stopping: .stopping
        }
        return Self(kind: .speechPhase, sessionID: sessionID, phase: safePhase)
    }

    static func speechFinalized(sessionID: UUID?, durationMilliseconds: Int?) -> Self {
        Self(kind: .speechFinalized, sessionID: sessionID, durationMilliseconds: durationMilliseconds)
    }

    static func cameraCaptured(sessionID: UUID?) -> Self {
        Self(kind: .cameraCaptured, sessionID: sessionID)
    }

    static func speakerCorrected(sessionID: UUID?) -> Self {
        Self(kind: .speakerCorrected, sessionID: sessionID, manualCorrectionCount: 1)
    }

    static func delivery(
        _ kind: DiagnosticEventKind, error: DiagnosticErrorCategory? = nil
    ) -> Self {
        precondition([.deliveryQueued, .deliverySucceeded, .deliveryFailed, .pairingSucceeded, .pairingRevoked].contains(kind))
        return Self(kind: kind, error: error)
    }
}
