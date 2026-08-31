import Foundation
import os

struct LatencyLogger: Sendable {
    private let logger = Logger(subsystem: "ru.quickcue.app", category: "latency")

    func firstToken(provider: ProviderKind, milliseconds: Int) {
        logger.info("first_token provider=\(provider.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public)")
    }

    func completed(provider: ProviderKind, milliseconds: Int) {
        logger.info("completed provider=\(provider.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public)")
    }

    func failed(provider: ProviderKind, error: Error) {
        logger.error("failed provider=\(provider.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
    }
}

