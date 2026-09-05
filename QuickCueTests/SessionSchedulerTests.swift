import XCTest
@testable import QuickCue

@MainActor
final class SessionSchedulerTests: XCTestCase {
    func testEveryRequestSharesConcurrencyLimit() async {
        let scheduler = RequestScheduler(maximumConcurrentRequests: 2)
        let session = UUID()
        scheduler.activate(sessionID: session)
        let firstGate = SchedulerTestGate()
        let secondGate = SchedulerTestGate()
        var started: [String] = []
        let first = scheduler.enqueue(sessionID: session) { started.append("manual"); await firstGate.wait() }
        let second = scheduler.enqueue(sessionID: session) { started.append("photo"); await secondGate.wait() }
        let third = scheduler.enqueue(sessionID: session) { started.append("variation") }
        XCTAssertEqual(scheduler.activeCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)
        await Task.yield()
        XCTAssertEqual(Set(started), ["manual", "photo"])
        firstGate.release()
        await first.wait()
        await third.wait()
        XCTAssertTrue(started.contains("variation"))
        secondGate.release()
        await second.wait()
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testEndCancelsQueueAndLateCompletionCannotStartIt() async {
        let scheduler = RequestScheduler(maximumConcurrentRequests: 1)
        let oldSession = UUID()
        scheduler.activate(sessionID: oldSession)
        let gate = SchedulerTestGate()
        var cancelled = 0
        var queuedStarted = false
        let active = scheduler.enqueue(sessionID: oldSession, operation: { await gate.wait() }, onCancel: { cancelled += 1 })
        let queued = scheduler.enqueue(sessionID: oldSession, operation: { queuedStarted = true }, onCancel: { cancelled += 1 })
        await Task.yield()
        scheduler.endSession()
        await active.wait()
        await queued.wait()
        XCTAssertEqual(cancelled, 2)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)
        scheduler.activate(sessionID: UUID())
        gate.release()
        await Task.yield()
        XCTAssertFalse(queuedStarted)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testWrongSessionIsRejectedBeforeStarting() async {
        let scheduler = RequestScheduler()
        scheduler.activate(sessionID: UUID())
        var started = false
        var cancelled = false
        let ticket = scheduler.enqueue(sessionID: UUID(), operation: { started = true }, onCancel: { cancelled = true })
        await ticket.wait()
        XCTAssertTrue(cancelled)
        XCTAssertFalse(started)
    }

    func testCancellingQueuedRequestDoesNotCancelActiveRequest() async {
        let scheduler = RequestScheduler(maximumConcurrentRequests: 1)
        let session = UUID()
        scheduler.activate(sessionID: session)
        let gate = SchedulerTestGate()
        var secondStarted = false
        let first = scheduler.enqueue(sessionID: session) { await gate.wait() }
        let second = scheduler.enqueue(sessionID: session) { secondStarted = true }
        scheduler.cancel(second.id)
        await second.wait()
        XCTAssertEqual(scheduler.activeCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
        gate.release()
        await first.wait()
        XCTAssertFalse(secondStarted)
    }

    func testCancelAllRejectsWorkEnqueuedFromCancellationCallback() async {
        let scheduler = RequestScheduler(maximumConcurrentRequests: 1)
        let session = UUID()
        scheduler.activate(sessionID: session)
        var replacementStarted = false
        var replacementCancelled = false
        let ticket = scheduler.enqueue(sessionID: session, operation: {}, onCancel: {
            scheduler.enqueue(sessionID: session, operation: { replacementStarted = true }, onCancel: { replacementCancelled = true })
        })
        scheduler.cancelAll()
        await ticket.wait()
        await Task.yield()
        XCTAssertTrue(replacementCancelled)
        XCTAssertFalse(replacementStarted)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)
        // Cancelling is not ending: a later explicit foreground action can still run.
        var resumed = false
        let next = scheduler.enqueue(sessionID: session) { resumed = true }
        await next.wait()
        XCTAssertTrue(resumed)
    }

    func testLateCompletionWithReusedIDCannotFinishNewJob() async {
        let scheduler = RequestScheduler(maximumConcurrentRequests: 1)
        let session = UUID()
        let sharedID = UUID()
        let oldGate = SchedulerTestGate()
        let newGate = SchedulerTestGate()
        scheduler.activate(sessionID: session)
        let old = scheduler.enqueue(id: sharedID, sessionID: session) { await oldGate.wait() }
        await Task.yield()
        scheduler.cancel(sharedID)
        await old.wait()
        let next = scheduler.enqueue(id: sharedID, sessionID: session) { await newGate.wait() }
        await Task.yield()
        oldGate.release()
        await Task.yield()
        XCTAssertFalse(next.isFinished)
        XCTAssertEqual(scheduler.activeCount, 1)
        newGate.release()
        await next.wait()
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testSetupAndSessionWorkShareLimitButSessionEndKeepsSetup() async {
        let scheduler = RequestScheduler(maximumConcurrentRequests: 1)
        let session = UUID()
        let setupID = UUID()
        let gate = SchedulerTestGate()
        scheduler.activate(sessionID: session)
        var setupStarted = false
        let answer = scheduler.enqueue(sessionID: session) { await gate.wait() }
        let setup = scheduler.enqueueSetup(setupID: setupID) { setupStarted = true }
        await Task.yield()
        XCTAssertEqual(scheduler.activeCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.endSession()
        await answer.wait()
        await setup.wait()
        XCTAssertTrue(setupStarted)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testInactiveStyleCancelAllCancelsSetupAndSessionOwners() async {
        let scheduler = RequestScheduler(maximumConcurrentRequests: 1)
        let session = UUID()
        scheduler.activate(sessionID: session)
        let gate = SchedulerTestGate()
        var cancelled = 0
        let answer = scheduler.enqueue(sessionID: session, operation: { await gate.wait() }, onCancel: { cancelled += 1 })
        let setup = scheduler.enqueueSetup(setupID: UUID(), operation: {}, onCancel: { cancelled += 1 })
        scheduler.cancelAll()
        await answer.wait()
        await setup.wait()
        XCTAssertEqual(cancelled, 2)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }
}

@MainActor
private final class SchedulerTestGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
