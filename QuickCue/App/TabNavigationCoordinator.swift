import Foundation

enum AppTab: Hashable, CaseIterable {
    case live
    case conversation
    case camera
    case history
    case settings

    var title: String {
        switch self {
        case .live: "Эфир"
        case .conversation: "Диалог"
        case .camera: "Камера"
        case .history: "История"
        case .settings: "Настройки"
        }
    }
}

enum TabNavigationResult: Equatable {
    case unchanged
    case switched(AppTab, shouldStop: Bool)
    case needsDecision(AppTab)
}

struct TabNavigationCoordinator {
    private(set) var selectedTab: AppTab
    private(set) var pendingTab: AppTab?

    init(selectedTab: AppTab = .live) {
        self.selectedTab = selectedTab
    }

    mutating func request(
        _ target: AppTab,
        whileListening: Bool,
        policy: ListeningNavigationPolicy
    ) -> TabNavigationResult {
        guard target != selectedTab else { return .unchanged }
        guard whileListening else {
            selectedTab = target
            pendingTab = nil
            return .switched(target, shouldStop: false)
        }
        switch policy {
        case .ask:
            pendingTab = target
            return .needsDecision(target)
        case .continueWhileActive:
            selectedTab = target
            pendingTab = nil
            return .switched(target, shouldStop: false)
        case .stopOnTabChange:
            selectedTab = target
            pendingTab = nil
            return .switched(target, shouldStop: true)
        }
    }

    mutating func resolvePending(continueListening: Bool) -> TabNavigationResult {
        guard let target = pendingTab else { return .unchanged }
        selectedTab = target
        pendingTab = nil
        return .switched(target, shouldStop: !continueListening)
    }

    mutating func cancelPending() {
        pendingTab = nil
    }
}
