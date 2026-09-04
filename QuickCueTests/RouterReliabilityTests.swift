import XCTest
@testable import QuickCue

private actor AttemptCollector {
    private var attempts: [AIRequestAttempt] = []
    func append(_ attempt: AIRequestAttempt) { attempts.append(attempt) }
    func values() -> [AIRequestAttempt] { attempts }
}

private struct RouterStubProvider: AIProvider {
    enum Step: Sendable {
        case wait(UInt64)
        case event(AIStreamEvent)
        case fail
    }
    let kind: ProviderKind
    var modelName: String { "test-\(kind.rawValue)" }
    let capabilities = ProviderCapabilities(supportsText: true, supportsImages: false, supportsStreaming: true)
    let steps: [Step]

    func stream(request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in steps {
                        try Task.checkCancellation()
                        switch step {
                        case .wait(let milliseconds): try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                        case .event(let event): continuation.yield(event)
                        case .fail: throw AIProviderError.badResponse(503, "private upstream body")
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class RouterReliabilityTests: XCTestCase {
    func testPrimaryFailureStartsFallbackWithoutWaitingForDeadline() async throws {
        let reports = AttemptCollector()
        let start = Date.now
        var text = ""
        let stream = LatencyFallbackRouter().stream(
            request: AIRequest(question: "Вопрос", context: []),
            primary: RouterStubProvider(kind: .openAI, steps: [.fail]),
            fallback: RouterStubProvider(kind: .deepSeek, steps: [.event(.textDelta("Ответ")), .event(.completed)]),
            fallbackDelaySeconds: 30,
            onAttemptFinished: { await reports.append($0) }
        )
        for try await (_, event) in stream {
            if case .textDelta(let delta) = event { text += delta }
        }
        XCTAssertEqual(text, "Ответ")
        XCTAssertLessThan(Date.now.timeIntervalSince(start), 5)
        let attempts = await reports.values()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first?.outcome, .failed)
        XCTAssertEqual(attempts.last?.outcome, .succeeded)
        XCTAssertEqual(attempts.first?.errorCode, "http_503")
    }

    func testWhitespaceCannotWinAndLosingRequestIsRecordedAsCancelled() async throws {
        let reports = AttemptCollector()
        var text = ""
        for try await (provider, event) in LatencyFallbackRouter().stream(
            request: AIRequest(question: "Вопрос", context: []),
            primary: RouterStubProvider(kind: .openAI, steps: [.event(.textDelta(" \n")), .wait(30_000)]),
            fallback: RouterStubProvider(kind: .deepSeek, steps: [.event(.textDelta("Резерв")), .event(.completed)]),
            fallbackDelaySeconds: 0.02,
            onAttemptFinished: { await reports.append($0) }
        ) {
            XCTAssertEqual(provider, .builtIn(.deepSeek))
            if case .textDelta(let delta) = event { text += delta }
        }
        let attempts = await reports.values()
        XCTAssertEqual(text, "Резерв")
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first { $0.selection.kind == .openAI }?.outcome, .cancelled)
        XCTAssertNil(attempts.first { $0.selection.kind == .openAI }?.usage)
    }

    func testPartialWinnerFailureIsNotSilentlyReplaced() async {
        let reports = AttemptCollector()
        var text = ""
        do {
            for try await (_, event) in LatencyFallbackRouter().stream(
                request: AIRequest(question: "Вопрос", context: []),
                primary: RouterStubProvider(kind: .openAI, steps: [.event(.textDelta("Начало ответа")), .fail]),
                fallback: RouterStubProvider(kind: .deepSeek, steps: [.event(.textDelta("Другой ответ"))]),
                fallbackDelaySeconds: 30,
                onAttemptFinished: { await reports.append($0) }
            ) {
                if case .textDelta(let delta) = event { text += delta }
            }
            XCTFail("A partial winner's transport failure must remain visible")
        } catch {
            XCTAssertEqual(SafeErrorCode.classify(error), "http_503")
        }
        XCTAssertEqual(text, "Начало ответа")
        let attempts = await reports.values()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.outcome, .failed)
    }

    func testCompletedEventDoesNotHideLaterTransportFailure() async {
        var completedCount = 0
        do {
            for try await (_, event) in LatencyFallbackRouter().stream(
                request: AIRequest(question: "Вопрос", context: []),
                primary: RouterStubProvider(kind: .openAI, steps: [.event(.textDelta("Ответ")), .event(.completed), .fail]),
                fallback: nil, fallbackDelaySeconds: 0
            ) {
                if case .completed = event { completedCount += 1 }
            }
            XCTFail("Transport failure after a completion marker must throw")
        } catch { XCTAssertEqual(SafeErrorCode.classify(error), "http_503") }
        XCTAssertEqual(completedCount, 0)
    }

    func testUsageBeforeTextIsPreservedForWinner() async throws {
        let reports = AttemptCollector()
        var receivedUsage: TokenUsage?
        let expected = TokenUsage(inputTokens: 17, outputTokens: 8)
        for try await (_, event) in LatencyFallbackRouter().stream(
            request: AIRequest(question: "Вопрос", context: []),
            primary: RouterStubProvider(kind: .openAI, steps: [.event(.usage(expected)), .event(.textDelta("Ответ")), .event(.completed)]),
            fallback: nil, fallbackDelaySeconds: 0,
            onAttemptFinished: { await reports.append($0) }
        ) {
            if case .usage(let usage) = event { receivedUsage = usage }
        }
        XCTAssertEqual(receivedUsage, expected)
        let attempts = await reports.values()
        XCTAssertEqual(attempts.first?.usage, expected)
    }

    func testTextFollowedByBareEOFIsIncompleteAndNotSuccessful() async {
        let reports = AttemptCollector()
        var text = ""
        do {
            for try await (_, event) in LatencyFallbackRouter().stream(
                request: AIRequest(question: "Вопрос", context: []),
                primary: RouterStubProvider(kind: .openAI, steps: [.event(.textDelta("Частично"))]),
                fallback: nil, fallbackDelaySeconds: 0,
                onAttemptFinished: { await reports.append($0) }
            ) {
                if case .textDelta(let delta) = event { text += delta }
            }
            XCTFail("EOF without provider completion must not be reported as success")
        } catch { XCTAssertEqual(SafeErrorCode.classify(error), "incomplete_response") }
        XCTAssertEqual(text, "Частично")
        let attempts = await reports.values()
        XCTAssertEqual(attempts.first?.outcome, .failed)
    }

    func testSameProviderSelectionDoesNotLaunchDuplicateFallback() async throws {
        let reports = AttemptCollector()
        for try await _ in LatencyFallbackRouter().stream(
            request: AIRequest(question: "Вопрос", context: []),
            primary: RouterStubProvider(kind: .openAI, steps: [.wait(20), .event(.textDelta("Ответ")), .event(.completed)]),
            fallback: RouterStubProvider(kind: .openAI, steps: [.fail]),
            fallbackDelaySeconds: 0,
            onAttemptFinished: { await reports.append($0) }
        ) {}
        let attempts = await reports.values()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.outcome, .succeeded)
    }

    func testReportedUsageSurvivesPartialFailure() async {
        let reports = AttemptCollector()
        let usage = TokenUsage(inputTokens: 29, outputTokens: 11)
        do {
            for try await _ in LatencyFallbackRouter().stream(
                request: AIRequest(question: "Вопрос", context: []),
                primary: RouterStubProvider(kind: .openAI, steps: [.event(.textDelta("Ответ")), .event(.usage(usage)), .fail]),
                fallback: nil, fallbackDelaySeconds: 0,
                onAttemptFinished: { await reports.append($0) }
            ) {}
            XCTFail("Partial failure is not successful")
        } catch { XCTAssertEqual(SafeErrorCode.classify(error), "http_503") }
        let attempts = await reports.values()
        XCTAssertEqual(attempts.first?.usage, usage)
        XCTAssertEqual(attempts.first?.outcome, .failed)
    }

    func testBothFailuresFinishAndAccountForBothRequests() async {
        let reports = AttemptCollector()
        do {
            for try await _ in LatencyFallbackRouter().stream(
                request: AIRequest(question: "Вопрос", context: []),
                primary: RouterStubProvider(kind: .openAI, steps: [.fail]),
                fallback: RouterStubProvider(kind: .deepSeek, steps: [.fail]),
                fallbackDelaySeconds: 0,
                onAttemptFinished: { await reports.append($0) }
            ) {}
            XCTFail("Both providers failed")
        } catch { XCTAssertEqual(SafeErrorCode.classify(error), "http_503") }
        let attempts = await reports.values()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(attempts.allSatisfy { $0.outcome == .failed })
    }

    func testConsumerCancellationAccountsForStartedRequest() async {
        let started = expectation(description: "text received")
        let accounted = expectation(description: "cancelled attempt accounted")
        let task = Task {
            do {
                for try await _ in LatencyFallbackRouter().stream(
                    request: AIRequest(question: "Вопрос", context: []),
                    primary: RouterStubProvider(kind: .openAI, steps: [.event(.textDelta("Начало")), .wait(30_000)]),
                    fallback: nil, fallbackDelaySeconds: 0,
                    onAttemptFinished: { attempt in
                        XCTAssertEqual(attempt.outcome, .cancelled)
                        accounted.fulfill()
                    }
                ) { started.fulfill() }
            } catch { /* Cancellation is the expected result. */ }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await fulfillment(of: [accounted], timeout: 3)
        await task.value
    }

    func testErrorClassificationNeverContainsUpstreamText() {
        let code = SafeErrorCode.classify(AIProviderError.badResponse(401, "sensitive transcript and API key"))
        XCTAssertEqual(code, "http_401")
        XCTAssertEqual(SafeErrorCode.classify(AIProviderError.invalidConfiguration("secret URL")), "configuration")
    }
}
