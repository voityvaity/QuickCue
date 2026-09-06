import Foundation

enum SyncReadinessStatus: String, Codable, Sendable {
    case deferred
    case needsSignedBuild
    case needsDeviceValidation
    case readyForOptIn
}

struct SyncReadinessReport: Equatable, Sendable {
    let status: SyncReadinessStatus
    let cloudKitEntitlementCompiled: Bool
    let signedCapabilityVerified: Bool
    let twoDeviceTestVerified: Bool
    let localBackupAvailable: Bool

    var missingRequirements: [String] {
        var values: [String] = []
        if !cloudKitEntitlementCompiled { values.append("iCloud + CloudKit capability и отдельный контейнер QuickCue") }
        if !signedCapabilityVerified { values.append("подписанная сборка с подходящей Apple Team и provisioning profile") }
        if !twoDeviceTestVerified { values.append("два доступных устройства/аккаунт для conflict и offline-проверки") }
        return values
    }
}

enum SyncReadinessEvaluator {
    /// This target intentionally has no iCloud entitlement. Enabling the flag
    /// without the entitlement and device evidence must not make the UI claim
    /// that sync is ready.
    static func current(
        signedCapabilityVerified: Bool = false,
        twoDeviceTestVerified: Bool = false
    ) -> SyncReadinessReport {
        #if QUICKCUE_ICLOUD_SYNC_ENABLED
        let entitlementCompiled = true
        #else
        let entitlementCompiled = false
        #endif
        let status: SyncReadinessStatus
        if !entitlementCompiled {
            status = .deferred
        } else if !signedCapabilityVerified {
            status = .needsSignedBuild
        } else if !twoDeviceTestVerified {
            status = .needsDeviceValidation
        } else {
            status = .readyForOptIn
        }
        return .init(
            status: status,
            cloudKitEntitlementCompiled: entitlementCompiled,
            signedCapabilityVerified: signedCapabilityVerified,
            twoDeviceTestVerified: twoDeviceTestVerified,
            localBackupAvailable: true
        )
    }

    static let futureDataDisclosure = [
        "история разговоров и ответы",
        "профили, вакансии и вложения",
        "фотографии, расписание и тренировки",
    ]

    static let alwaysExcluded = [
        "API-ключи и значения секретных заголовков",
        "аудио",
        "локальная диагностическая очередь",
    ]
}
