import Foundation

final class StreamRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var winner: ProviderSelection?
    private var failures = 0

    func shouldForward(provider: ProviderSelection, event: AIStreamEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if winner == nil, case .textDelta = event { winner = provider }
        return winner == provider
    }

    func isWinner(_ provider: ProviderSelection) -> Bool {
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
    ) -> AsyncThrowingStream<(ProviderSelection, AIStreamEvent), Error> {
        guard let fallback, fallback.selection != primary.selection else {
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

    private func single(request: AIRequest, provider: any AIProvider) -> AsyncThrowingStream<(ProviderSelection, AIStreamEvent), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in provider.stream(request: request) {
                        continuation.yield((provider.selection, event))
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
        continuation: AsyncThrowingStream<(ProviderSelection, AIStreamEvent), Error>.Continuation
    ) -> Task<Void, Never> {
        Task { await consumeInline(request, provider: provider, gate: gate, continuation: continuation) }
    }

    private func consumeInline(
        _ request: AIRequest,
        provider: any AIProvider,
        gate: StreamRaceGate,
        continuation: AsyncThrowingStream<(ProviderSelection, AIStreamEvent), Error>.Continuation
    ) async {
        do {
            for try await event in provider.stream(request: request) {
                if gate.shouldForward(provider: provider.selection, event: event) {
                    continuation.yield((provider.selection, event))
                    if case .completed = event { continuation.finish() }
                }
            }
            if gate.isWinner(provider.selection) {
                continuation.finish()
            } else if gate.registerFailure() {
                continuation.finish(throwing: AIProviderError.emptyResponse)
            }
        } catch {
            if gate.isWinner(provider.selection) || gate.registerFailure() {
                continuation.finish(throwing: error)
            }
        }
    }
}
