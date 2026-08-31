import Foundation

final class StreamRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var winner: ProviderKind?
    private var failures = 0

    func shouldForward(provider: ProviderKind, event: AIStreamEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if winner == nil, case .textDelta = event { winner = provider }
        return winner == provider
    }

    func isWinner(_ provider: ProviderKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return winner == provider
    }

    func registerFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        failures += 1
        return winner == nil && failures >= 2
    }
}

struct LatencyFallbackRouter: Sendable {
    func stream(
        request: AIRequest,
        primary: any AIProvider,
        fallback: (any AIProvider)?,
        fallbackDelaySeconds: Double
    ) -> AsyncThrowingStream<(ProviderKind, AIStreamEvent), Error> {
        guard let fallback, fallback.kind != primary.kind else {
            return single(request: request, provider: primary)
        }

        return AsyncThrowingStream { continuation in
            let gate = StreamRaceGate()
            let primaryTask = consume(request, provider: primary, gate: gate, continuation: continuation)
            let fallbackTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0.1, fallbackDelaySeconds) * 1_000_000_000))
                    if Task.isCancelled { return }
                    await consumeInline(request, provider: fallback, gate: gate, continuation: continuation)
                } catch is CancellationError {
                    return
                } catch {
                    if gate.registerFailure() { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in
                primaryTask.cancel()
                fallbackTask.cancel()
            }
        }
    }

    private func single(request: AIRequest, provider: any AIProvider) -> AsyncThrowingStream<(ProviderKind, AIStreamEvent), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in provider.stream(request: request) {
                        continuation.yield((provider.kind, event))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consume(
        _ request: AIRequest,
        provider: any AIProvider,
        gate: StreamRaceGate,
        continuation: AsyncThrowingStream<(ProviderKind, AIStreamEvent), Error>.Continuation
    ) -> Task<Void, Never> {
        Task { await consumeInline(request, provider: provider, gate: gate, continuation: continuation) }
    }

    private func consumeInline(
        _ request: AIRequest,
        provider: any AIProvider,
        gate: StreamRaceGate,
        continuation: AsyncThrowingStream<(ProviderKind, AIStreamEvent), Error>.Continuation
    ) async {
        do {
            for try await event in provider.stream(request: request) {
                if gate.shouldForward(provider: provider.kind, event: event) {
                    continuation.yield((provider.kind, event))
                    if case .completed = event { continuation.finish() }
                }
            }
            if gate.isWinner(provider.kind) {
                continuation.finish()
            } else if gate.registerFailure() {
                continuation.finish(throwing: AIProviderError.emptyResponse)
            }
        } catch {
            if gate.isWinner(provider.kind) || gate.registerFailure() {
                continuation.finish(throwing: error)
            }
        }
    }
}
