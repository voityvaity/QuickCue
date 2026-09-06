import CryptoKit
import Foundation
import SwiftData

struct UserBackupManifest: Codable, Equatable, Sendable {
    struct FileEntry: Codable, Equatable, Sendable {
        let name: String
        let byteCount: Int
        let sha256: String
    }

    let schemaVersion: Int
    let dataSchemaVersion: Int
    let createdAt: Date
    let appVersion: String
    let appBuild: String
    let files: [FileEntry]
}

struct UserBackupEntity: Codable, Equatable, Sendable {
    let type: String
    let id: UUID
    var strings: [String: String] = [:]
    var dates: [String: Date] = [:]
    var integers: [String: Int] = [:]
    var doubles: [String: Double] = [:]
    var booleans: [String: Bool] = [:]
    var uuids: [String: UUID] = [:]
    var blobs: [String: Data] = [:]
}

struct UserBackupPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let entities: [UserBackupEntity]
    let preparationPlans: [PreparationPlanDraft]
    /// QuickCue import documents: configuration metadata only, never values
    /// from Keychain and never local Keychain account identifiers.
    let customProviderProfiles: [String]
}

struct UserBackupPreview: Equatable, Sendable {
    let createdAt: Date
    let appVersion: String
    let objectCounts: [String: Int]
    let photoCount: Int
    let conflictCount: Int
    let newObjectCount: Int
    let preparationPlanCount: Int
    let providerProfileCount: Int
}

struct UserBackupStaging: Sendable {
    let payload: UserBackupPayload
    let photos: [String: Data]
    let preview: UserBackupPreview
}

struct UserBackupExport: Sendable {
    let fileURL: URL
    let preview: UserBackupPreview
}

struct UserBackupRestoreResult: Equatable, Sendable {
    let insertedObjects: Int
    let skippedConflicts: Int
    let restoredPhotos: Int
    let restoredPlans: Int
    let failedPlans: Int
    let restoredProviderProfiles: Int
}

enum UserBackupError: LocalizedError, Equatable {
    case payloadTooLarge
    case unsupportedVersion
    case invalidManifest
    case invalidPayload
    case unexpectedFile
    case missingFile
    case integrityFailure
    case missingRelationship
    case liveStoreUnchanged

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge: "Данных слишком много для одной безопасной копии. Уменьшите число фото и повторите."
        case .unsupportedVersion: "Эта копия создана более новой версией QuickCue. Текущая версия не будет менять живые данные."
        case .invalidManifest: "Манифест резервной копии повреждён. Живые данные не изменялись."
        case .invalidPayload: "Данные резервной копии повреждены или не прошли ограничения безопасности."
        case .unexpectedFile: "В архиве найден неподдерживаемый файл. Восстановление остановлено."
        case .missingFile: "В резервной копии отсутствует обязательный файл или фото."
        case .integrityFailure: "Контрольная сумма одного из файлов не совпала."
        case .missingRelationship: "В копии нарушены связи между объектами. Живые данные не изменялись."
        case .liveStoreUnchanged: "Восстановление не завершено. Живая база возвращена к прежнему состоянию."
        }
    }
}

@MainActor
enum UserDataBackupService {
    static let manifestName = "manifest.json"
    static let payloadName = "data.json"
    static let maximumPayloadBytes = 20 * 1_024 * 1_024
    static let maximumObjects = 50_000
    static let maximumPhotos = 200

    static func export(
        context: ModelContext,
        settings: AppSettings,
        directory: URL
    ) throws -> UserBackupExport {
        let entities = try exportEntities(context: context)
        guard entities.count <= maximumObjects else { throw UserBackupError.payloadTooLarge }
        let plans = PreparationPlanStore().plans
        let providerDocuments = settings.customProviders.compactMap { try? CustomProviderProfileCodec.encode($0) }
        let payload = UserBackupPayload(
            schemaVersion: 1,
            entities: entities,
            preparationPlans: plans,
            customProviderProfiles: providerDocuments
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadData = try encoder.encode(payload)
        guard payloadData.count <= maximumPayloadBytes else { throw UserBackupError.payloadTooLarge }

        let photoEntities = entities.filter { $0.type == "photo" }
        guard photoEntities.count <= maximumPhotos else { throw UserBackupError.payloadTooLarge }
        var photoEntries: [(String, Data)] = []
        for entity in photoEntities {
            guard let relativePath = entity.strings["relativePath"] else { throw UserBackupError.invalidPayload }
            let archiveName = try photoArchiveName(relativePath)
            let data = try Data(contentsOf: PhotoStore().url(for: relativePath), options: .mappedIfSafe)
            guard data.count <= StoreZipArchive.maximumEntryBytes else { throw UserBackupError.payloadTooLarge }
            photoEntries.append((archiveName, data))
        }

        let fileRows = [(payloadName, payloadData)] + photoEntries
        let manifest = UserBackupManifest(
            schemaVersion: 1,
            dataSchemaVersion: 10,
            createdAt: .now,
            appVersion: BuildIdentity.current.version,
            appBuild: BuildIdentity.current.build,
            files: fileRows.map { .init(name: $0.0, byteCount: $0.1.count, sha256: sha256($0.1)) }
        )
        let manifestData = try encoder.encode(manifest)
        let archive = try StoreZipArchive.make(entries: [(manifestName, manifestData)] + fileRows)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let oldFiles = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for old in oldFiles where old.lastPathComponent.hasPrefix("QuickCue-Backup-")
                && old.pathExtension == "quickcue-backup" {
                try? FileManager.default.removeItem(at: old)
            }
        }
        let fileURL = directory.appendingPathComponent("QuickCue-Backup-\(UUID().uuidString).quickcue-backup")
        try archive.write(to: fileURL, options: [.atomic, .completeFileProtection])
        return UserBackupExport(
            fileURL: fileURL,
            preview: preview(payload: payload, manifest: manifest, existingIDs: [:])
        )
    }

    static func stage(fileURL: URL, context: ModelContext) throws -> UserBackupStaging {
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= StoreZipArchive.maximumArchiveBytes else { throw UserBackupError.payloadTooLarge }
        let entries = try StoreZipArchive.read(Data(contentsOf: fileURL, options: .mappedIfSafe))
        guard let manifestData = entries[manifestName], manifestData.count <= 512_000 else {
            throw UserBackupError.invalidManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(UserBackupManifest.self, from: manifestData),
              manifest.schemaVersion == 1 else { throw UserBackupError.unsupportedVersion }
        guard (1...10).contains(manifest.dataSchemaVersion) else { throw UserBackupError.unsupportedVersion }
        guard manifest.files.count == Set(manifest.files.map(\.name)).count,
              manifest.files.allSatisfy({
                  $0.name == payloadName || ($0.name.hasPrefix("photos/") && $0.name.hasSuffix(".jpg"))
              }) else { throw UserBackupError.invalidManifest }
        let expectedNames = Set([manifestName] + manifest.files.map(\.name))
        guard expectedNames == Set(entries.keys) else { throw UserBackupError.unexpectedFile }
        for file in manifest.files {
            guard StoreZipArchive.isSafe(file.name), let data = entries[file.name], data.count == file.byteCount else {
                throw UserBackupError.missingFile
            }
            guard sha256(data) == file.sha256 else { throw UserBackupError.integrityFailure }
        }
        guard let payloadData = entries[payloadName], payloadData.count <= maximumPayloadBytes,
              let payload = try? decoder.decode(UserBackupPayload.self, from: payloadData),
              payload.schemaVersion == 1 else { throw UserBackupError.invalidPayload }
        try validate(payload: payload, entries: entries)
        let existing = try existingIDs(context: context)
        let photos = entries.filter { $0.key.hasPrefix("photos/") }
        return UserBackupStaging(
            payload: payload,
            photos: photos,
            preview: preview(payload: payload, manifest: manifest, existingIDs: existing)
        )
    }

    static func promote(
        _ staging: UserBackupStaging,
        context: ModelContext,
        settings: AppSettings
    ) throws -> UserBackupRestoreResult {
        let stagedEntries = [payloadName: Data()].merging(staging.photos) { current, _ in current }
        try validate(payload: staging.payload, entries: stagedEntries)
        let existing = try existingIDs(context: context)
        var inserted = 0
        var skipped = 0
        var writtenPhotoPaths: [String] = []
        do {
            for entity in orderedForRestore(staging.payload.entities) {
                let originalDeletedConflict = entity.type == "deleted"
                    && entity.uuids["originalID"].map {
                        existing["deletedOriginal", default: []].contains($0)
                            || existing["session", default: []].contains($0)
                    } == true
                if existing[entity.type, default: []].contains(entity.id) || originalDeletedConflict {
                    skipped += 1
                    continue
                }
                if entity.type == "photo", let relativePath = entity.strings["relativePath"] {
                    let archiveName = try photoArchiveName(relativePath)
                    guard let bytes = staging.photos[archiveName] else { throw UserBackupError.missingFile }
                    if try PhotoStore().restoreJPEG(bytes, relativePath: relativePath) { writtenPhotoPaths.append(relativePath) }
                }
                try insert(entity, into: context)
                inserted += 1
            }
            try context.save()
        } catch {
            context.rollback()
            for path in writtenPhotoPaths { try? PhotoStore().delete(relativePath: path) }
            throw UserBackupError.liveStoreUnchanged
        }

        let planStore = PreparationPlanStore()
        var restoredPlans = 0
        var failedPlans = 0
        for plan in staging.payload.preparationPlans where !planStore.plans.contains(where: { $0.id == plan.id }) {
            if planStore.save(plan) { restoredPlans += 1 } else { failedPlans += 1 }
        }
        var restoredProviders = 0
        var existingProviderDocuments = Set(settings.customProviders.compactMap { try? CustomProviderProfileCodec.encode($0) })
        for document in staging.payload.customProviderProfiles {
            guard let preview = try? CustomProviderProfileCodec.decode(document) else { continue }
            if existingProviderDocuments.insert(document).inserted {
                settings.createCustomProvider(preview.profile)
                settings.markConnectionUnverified(preview.profile.selection)
                restoredProviders += 1
            }
        }
        return .init(
            insertedObjects: inserted,
            skippedConflicts: skipped,
            restoredPhotos: writtenPhotoPaths.count,
            restoredPlans: restoredPlans,
            failedPlans: failedPlans,
            restoredProviderProfiles: restoredProviders
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func photoArchiveName(_ relativePath: String) throws -> String {
        let url = try PhotoStore().url(for: relativePath)
        return "photos/\(url.lastPathComponent)"
    }
}
