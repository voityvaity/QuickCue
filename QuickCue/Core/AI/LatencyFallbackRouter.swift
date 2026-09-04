import Foundation

enum AIRequestAttemptOutcome: String, Sendable {
    case succeeded
    case failed
    case cancelled
}

/// No request text, credentials or upstream error bodies are retained here.
struct AIRequestAttempt: Sendable {
    let attemptID: UUID
    let requestID: UUID
    let selection: ProviderSelection
    let modelName: String
    let startedAt: Date
    let endedAt: Date
    let outcome: AIRequestAttemptOutcome
    let usage: TokenUsage?
    let inputCharacterCount: Int
    let outputCharacterCount: Int
    let hasImage: Bool
    let errorCode: String?

    var durationMilliseconds: Int { max(0, Int(endedAt.timeIntervalSince(startedAt) * 1_000)) }
}

struct LatencyFallbackRouter: Sendable {
    private enum Signal: Sendable {
        case fallbackDeadline
        case event(ProviderSelection, AIStreamEvent)
        case ended(ProviderSelection, AIRequestAttemptOutcome, Error?)
    }

    func stream(
        request: AIRequest,
        primary: any AIProvider,
        fallback: (any AIProvider)?,
        fallbackDelaySeconds: Double,
        onAttemptFinished: @escaping @Sendable (AIRequestAttempt) async -> Void = { _ in }
    ) -> AsyncThrowingStream<(ProviderSelection, AIStreamEvent), Error> {
        let reserve = fallback?.selection == primary.selection ? nil : fallback
        return AsyncThrowingStream { continuation in
            let task = Task {
                let (signals, signalContinuation) = AsyncStream<Signal>.makeStream()
                var attempts: [ProviderSelection: Task<Void, Never>] = [:]
                var ended: Set<ProviderSelection> = []
                var buffered: [ProviderSelection: [AIStreamEvent]] = [:]
                var winner: ProviderSelection?
                var terminalError: Error?
                var succeeded = false

                attempts[primary.selection] = consume(
                    request, provider: primary, signals: signalContinuation,
                    onAttemptFinished: onAttemptFinished
                )
                let timer = Task {
                    guard reserve != nil else { return }
                    do {
                        let delay = fallbackDelaySeconds.isFinite ? max(0, min(60, fallbackDelaySeconds)) : 1.5
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        try Task.checkCancellation()
                        signalContinuation.yield(.fallbackDeadline)
                    } catch { /* Cancellation means the primary already won or the request ended. */ }
                }

                eventLoop: for await signal in signals {
                    if Task.isCancelled { break }
                    switch signal {
                    case .fallbackDeadline:
                        if winner == nil, let reserve, attempts[reserve.selection] == nil {
                            attempts[reserve.selection] = consume(
                                request, provider: reserve, signals: signalContinuation,
                                onAttemptFinished: onAttemptFinished
                            )
                        }
                    case .event(let provider, let event):
                        if winner == nil {
                            if case .textDelta(let delta) = event,
                               !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                winner = provider
                                timer.cancel()
                                for (selection, attempt) in attempts where selection != provider { attempt.cancel() }
                                for pending in buffered[provider] ?? [] { continuation.yield((provider, pending)) }
                                buffered.removeAll()
                            } else {
                                // Usage may arrive before text. A whitespace-only chunk never wins the race.
                                if case .completed = event { continue }
                                buffered[provider, default: []].append(event)
                                continue
                            }
                        }
                        if winner == provider {
                            // Completion is forwarded only after the transport has ended successfully.
                            if case .completed = event { continue }
                            continuation.yield((provider, event))
                        }
                    case .ended(let provider, let outcome, let error):
                        ended.insert(provider)
                        if winner == provider {
                            succeeded = outcome == .succeeded
                            terminalError = error
                            break eventLoop
                        }
                        if winner != nil { continue }
                        terminalError = error ?? AIProviderError.emptyResponse
                        if provider == primary.selection, let reserve, attempts[reserve.selection] == nil {
                            // An explicit error/empty response need not wait out the latency deadline.
                            timer.cancel()
                            attempts[reserve.selection] = consume(
                                request, provider: reserve, signals: signalContinuation,
                                onAttemptFinished: onAttemptFinished
                            )
                        }
                        if ended.count == attempts.count { break eventLoop }
                    }
                }

                timer.cancel()
                for attempt in attempts.values { attempt.cancel() }
                // Finish only after accounting has observed every actually started attempt, including losers.
                for attempt in attempts.values { await attempt.value }
                signalContinuation.finish()
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else if succeeded, let winner {
                    continuation.yield((winner, .completed))
                    continuation.finish()
                } else {
                    // Already emitted winner text remains visible; callers can offer an explicit retry.
                    continuation.finish(throwing: terminalError ?? AIProviderError.emptyResponse)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consume(
        _ request: AIRequest,
        provider: any AIProvider,
        signals: AsyncStream<Signal>.Continuation,
        onAttemptFinished: @escaping @Sendable (AIRequestAttempt) async -> Void
    ) -> Task<Void, Never> {
        Task {
            guard !Task.isCancelled else { return }
            let attemptID = UUID()
            let startedAt = Date.now
            var usage: TokenUsage?
            var outputCharacterCount = 0
            var hasText = false
            var receivedCompletion = false
            var outcome: AIRequestAttemptOutcome = .succeeded
            var failure: Error?
            do {
                for try await event in provider.stream(request: request) {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        outputCharacterCount += delta.count
                        hasText = hasText || !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    case .usage(let value): usage = value
                    case .completed: receivedCompletion = true
                    }
                    signals.yield(.event(provider.selection, event))
                }
                try Task.checkCancellation()
                if !hasText { throw AIProviderError.emptyResponse }
                if !receivedCompletion { throw AIProviderError.incompleteResponse }
            } catch {
                outcome = Task.isCancelled || error is CancellationError ? .cancelled : .failed
                failure = outcome == .cancelled ? CancellationError() : error
            }
            let attempt = AIRequestAttempt(
                attemptID: attemptID, requestID: request.id, selection: provider.selection,
                modelName: provider.modelName, startedAt: startedAt, endedAt: .now,
                outcome: outcome, usage: usage,
                inputCharacterCount: PromptFactory.userText(for: request).count + PromptFactory.systemText(for: request).count,
                outputCharacterCount: outputCharacterCount, hasImage: request.imageJPEG != nil,
                errorCode: failure.map(SafeErrorCode.classify)
            )
            await onAttemptFinished(attempt)
            signals.yield(.ended(provider.selection, outcome, failure))
        }
    }
}
