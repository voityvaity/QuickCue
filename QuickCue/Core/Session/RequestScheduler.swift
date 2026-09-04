import Foundation

/// One foreground, session-scoped queue for every user-visible AI request.
@MainActor
final class RequestScheduler {
    @MainActor
    final class Ticket {
        let id: UUID
        private(set) var isFinished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(id: UUID) { self.id = id }

        func wait() async {
            guard !isFinished else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        fileprivate func finish() {
            guard !isFinished else { return }
            isFinished = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private struct Item {
        let id: UUID
        let sessionID: UUID
        let ticket: Ticket
        let operation: @MainActor () async -> Void
        let onCancel: @MainActor () -> Void
    }

    private struct Running {
        let item: Item
        let task: Task<Void, Never>
    }

    private(set) var sessionID: UUID?
    private var pending: [Item] = []
    private var running: [UUID: Running] = [:]
    private var isCancellingAll = false
    let maximumConcurrentRequests: Int
    var onCountsChanged: ((_ active: Int, _ pending: Int) -> Void)?

    var activeCount: Int { running.count }
    var pendingCount: Int { pending.count }

    init(maximumConcurrentRequests: Int = 2) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    func activate(sessionID: UUID) {
        self.sessionID = nil
        cancelAll()
        self.sessionID = sessionID
    }

    @discardableResult
    func enqueue(
        id: UUID = UUID(),
        sessionID: UUID,
        operation: @escaping @MainActor () async -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) -> Ticket {
        let ticket = Ticket(id: id)
        guard !isCancellingAll, self.sessionID == sessionID,
              running[id] == nil, !pending.contains(where: { $0.id == id }) else {
            onCancel()
            ticket.finish()
            return ticket
        }
        pending.append(Item(id: id, sessionID: sessionID, ticket: ticket, operation: operation, onCancel: onCancel))
        drain()
        return ticket
    }

    func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let item = pending.remove(at: index)
            item.onCancel()
            item.ticket.finish()
        }
        if let job = running.removeValue(forKey: id) {
            job.task.cancel()
            job.item.onCancel()
            job.item.ticket.finish()
        }
        drain()
    }

    func cancelAll() {
        guard !isCancellingAll else { return }
        isCancellingAll = true
        // Empty both collections before cancellation callbacks can enqueue work.
        let queued = pending
        let active = Array(running.values)
        pending.removeAll()
        running.removeAll()
        queued.forEach { $0.onCancel(); $0.ticket.finish() }
        active.forEach { $0.task.cancel(); $0.item.onCancel(); $0.item.ticket.finish() }
        notifyCounts()
        isCancellingAll = false
    }

    func endSession() {
        sessionID = nil
        cancelAll()
    }

    private func drain() {
        while running.count < maximumConcurrentRequests, !pending.isEmpty {
            let item = pending.removeFirst()
            guard item.sessionID == sessionID else {
                item.onCancel()
                item.ticket.finish()
                continue
            }
            let task = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await item.operation()
                self?.finish(item)
            }
            running[item.id] = Running(item: item, task: task)
        }
        notifyCounts()
    }

    private func finish(_ item: Item) {
        // A cancelled task can resume late. It must not remove/restart another job.
        guard let active = running[item.id], active.item.ticket === item.ticket else { return }
        running[item.id] = nil
        item.ticket.finish()
        drain()
    }

    private func notifyCounts() { onCountsChanged?(activeCount, pendingCount) }
}
