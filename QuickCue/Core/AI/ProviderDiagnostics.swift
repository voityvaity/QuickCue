import Foundation

/// User-facing diagnostics never include a gateway's response body.
enum ProviderFailure {
    static func category(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return "cancelled"
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .networkConnectionLost: return "offline"
            case .cannotFindHost, .dnsLookupFailed: return "host"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "tls"
            default: return "network"
            }
        }
        guard let error = error as? AIProviderError else { return "unknown" }
        switch error {
        case .missingCredential: return "credential_missing"
        case .invalidConfiguration: return "configuration"
        case .unsupportedImage: return "vision_unsupported"
        case .emptyResponse: return "empty_response"
        case .incompleteResponse: return "incomplete_response"
        case .badResponse(let code, _):
            switch code {
            case 200: return "stream_error"
            case 401: return "unauthorized"
            case 402: return "billing"
            case 403: return "forbidden"
            case 404: return "model_or_endpoint"
            case 429: return "rate_limit"
            case 500...599: return "server"
            default: return "http_\(code)"
            }
        }
    }

    static func message(for error: Error) -> String {
        if let providerError = error as? AIProviderError {
            return providerError.localizedDescription
        }
        switch category(for: error) {
        case "cancelled": return "Запрос отменён."
        case "timeout": return "Сервис не ответил вовремя. Проверьте сеть или попробуйте резервный AI."
        case "offline": return "Нет соединения с интернетом. Текст сохранён на iPhone."
        case "host": return "Адрес сервиса не найден. Проверьте Base URL."
        case "tls": return "Не удалось установить безопасное соединение с сервисом."
        default: return "Не удалось получить ответ. Проверьте подключение и повторите запрос."
        }
    }

    static func message(forHTTPStatus code: Int) -> String {
        switch code {
        case 200: "AI-сервис сообщил об ошибке внутри потока. Частичный ответ сохранён; повторите запрос или выберите резерв."
        case 401: "API-ключ не принят. Проверьте или замените ключ в настройках."
        case 402: "Сервис требует оплату. Проверьте баланс и привязку платёжного аккаунта."
        case 403: "Нет доступа. Проверьте права ключа, регион и платёжный аккаунт."
        case 404: "Модель или адрес API не найдены. Проверьте ID модели и Base URL."
        case 429: "Лимит сервиса временно достигнут. Подождите или выберите резервный AI."
        case 500...599: "Ошибка на стороне AI-сервиса (\(code)). Попробуйте позже или выберите резерв."
        default: "Сервис отклонил запрос (\(code)). Проверьте модель и настройки подключения."
        }
    }

    static func message(forCategory category: String?) -> String {
        switch category {
        case "stream_error": return message(forHTTPStatus: 200)
        case "unauthorized", "credential_missing": return message(forHTTPStatus: 401)
        case "billing": return message(forHTTPStatus: 402)
        case "forbidden": return message(forHTTPStatus: 403)
        case "model_or_endpoint": return message(forHTTPStatus: 404)
        case "rate_limit": return message(forHTTPStatus: 429)
        case "server": return message(forHTTPStatus: 503)
        case "timeout": return message(for: URLError(.timedOut))
        case "offline": return message(for: URLError(.notConnectedToInternet))
        case "host": return message(for: URLError(.cannotFindHost))
        case "tls": return message(for: URLError(.secureConnectionFailed))
        case "incomplete_response": return AIProviderError.incompleteResponse.localizedDescription
        case "empty_response": return AIProviderError.emptyResponse.localizedDescription
        case "cancelled": return "Проверка отменена."
        default: return "Проверьте ключ, ID модели, адрес сервиса и платёжный аккаунт."
        }
    }
}

@MainActor
enum ProviderConnectionChecker {
    static func check(
        selection: ProviderSelection,
        settings: AppSettings
    ) async -> ProviderConnectionReport {
        let client = ProviderRegistry(settings: settings).provider(selection, honorMockMode: false, snapshotCredentials: true)
        let model = client.modelName
        let revision = settings.configurationRevision(for: selection)
        var report = ProviderConnectionReport(
            state: .failed, modelName: model, checkedAt: .now,
            firstTokenMilliseconds: nil, totalMilliseconds: nil, errorCategory: nil
        )
        do {
            let result = try await verify(provider: client)
            try Task.checkCancellation()
            report.state = .verified
            report.firstTokenMilliseconds = result.firstTokenMilliseconds
            report.totalMilliseconds = result.totalMilliseconds
        } catch {
            report.errorCategory = ProviderFailure.category(for: error)
            if Task.isCancelled { report.state = .unverified }
        }
        // A form edit while the request was in flight must not verify the new configuration.
        if settings.modelName(for: selection) == model, settings.configurationRevision(for: selection) == revision {
            settings.setConnectionReport(report, for: selection)
        } else {
            report.state = .unverified
        }
        return report
    }

    struct Result: Sendable {
        let firstTokenMilliseconds: Int
        let totalMilliseconds: Int
    }

    static func verify(provider: any AIProvider, timeoutSeconds: Double = 15) async throws -> Result {
        let request = AIRequest(
            question: "Ответь одним словом: работает?", context: [], maxOutputTokens: 32
        )
        return try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                let clock = ContinuousClock()
                let started = clock.now
                var firstToken: Int?
                var completed = false
                for try await event in provider.stream(request: request) {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let text):
                        if firstToken == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            firstToken = milliseconds(started.duration(to: clock.now))
                        }
                    case .completed: completed = true
                    case .usage: break
                    }
                }
                try Task.checkCancellation()
                guard let firstToken else { throw AIProviderError.emptyResponse }
                guard completed else { throw AIProviderError.incompleteResponse }
                return Result(firstTokenMilliseconds: firstToken, totalMilliseconds: milliseconds(started.duration(to: clock.now)))
            }
            group.addTask {
                let seconds = timeoutSeconds.isFinite ? min(60, max(0.01, timeoutSeconds)) : 15
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AIProviderError.emptyResponse }
            return result
        }
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
