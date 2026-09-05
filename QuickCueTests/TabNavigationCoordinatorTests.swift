import XCTest
@testable import QuickCue

final class TabNavigationCoordinatorTests: XCTestCase {
    func testEveryTabAndPolicyProducesDeterministicDecision() {
        for source in [AppTab.live, .conversation] {
          for target in AppTab.allCases where target != source {
            var ask = TabNavigationCoordinator(selectedTab: source)
            XCTAssertEqual(ask.request(target, whileListening: true, policy: .ask), .needsDecision(target))
            XCTAssertEqual(ask.selectedTab, source)
            ask.cancelPending()
            XCTAssertEqual(ask.selectedTab, source)

            var keep = TabNavigationCoordinator(selectedTab: source)
            XCTAssertEqual(
                keep.request(target, whileListening: true, policy: .continueWhileActive),
                .switched(target, shouldStop: false)
            )

            var stop = TabNavigationCoordinator(selectedTab: source)
            XCTAssertEqual(
                stop.request(target, whileListening: true, policy: .stopOnTabChange),
                .switched(target, shouldStop: true)
            )
          }
        }
    }

    func testPendingChoiceChangesTabOnlyAfterResolution() {
        var coordinator = TabNavigationCoordinator()
        XCTAssertEqual(
            coordinator.request(.history, whileListening: true, policy: .ask),
            .needsDecision(.history)
        )
        XCTAssertEqual(coordinator.selectedTab, .live)
        XCTAssertEqual(coordinator.resolvePending(continueListening: true), .switched(.history, shouldStop: false))
        XCTAssertEqual(coordinator.selectedTab, .history)
    }

    func testNoListeningNeverPrompts() {
        var coordinator = TabNavigationCoordinator()
        XCTAssertEqual(
            coordinator.request(.settings, whileListening: false, policy: .ask),
            .switched(.settings, shouldStop: false)
        )
    }
}
