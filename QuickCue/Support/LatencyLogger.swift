import Foundation
import os

struct LatencyLogger: Sendable {
    private let logger = Logger(subsystem: "ru.quickcue.app", category: "latency")

    func firstToken(provider: ProviderKind, milliseconds: Int, requestID: UUID? = nil) {
        logger.info("first_token request=\(requestID?.uuidString ?? "none", privacy: .public) provider=\(provider.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public)")
    }

    func completed(provider: ProviderKind, milliseconds: Int, requestID: UUID? = nil) {
        logger.info("completed request=\(requestID?.uuidString ?? "none", privacy: .public) provider=\(provider.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public)")
    }

    func failed(provider: ProviderKind, error: Error, requestID: UUID? = nil) {
        logger.error("failed request=\(requestID?.uuidString ?? "none", privacy: .public) provider=\(provider.rawValue, privacy: .public) code=\(SafeErrorCode.classify(error), privacy: .public)")
    }
}

/// An allow-listed classification: never forwards URLs, request bodies or localizedDescription.
enum SafeErrorCode {
    static func classify(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return "cancelled"
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .networkConnectionLost: return "offline"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "host_unreachable"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "tls"
            default: return "network"
            }
        }
        guard let providerError = error as? AIProviderError else { return "internal" }
        switch providerError {
        case .missingCredential: return "missing_credential"
        case .invalidConfiguration: return "configuration"
        case .unsupportedImage: return "unsupported_image"
        case .emptyResponse: return "empty_response"
        case .incompleteResponse: return "incomplete_response"
        case .badResponse(let status, _): return status == 200 ? "stream_error" : "http_\(status)"
        }
    }
}

