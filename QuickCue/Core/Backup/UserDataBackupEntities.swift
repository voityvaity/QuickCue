import Foundation
import SwiftData

extension UserDataBackupService {
    static func validate(payload: UserBackupPayload, entries: [String: Data]) throws {
        guard payload.schemaVersion == 1, payload.entities.count <= maximumObjects,
              payload.preparationPlans.count <= 50, payload.customProviderProfiles.count <= 100 else {
            throw UserBackupError.invalidPayload
        }
        let supportedTypes = Set([
            "session", "transcript", "answer", "message", "photo", "usage", "candidate", "job",
            "attachment", "context", "contextSnapshot", "question", "practiceSession", "practiceTurn",
            "practiceFeedback", "interview", "deleted",
        ])
        var seen: [String: Set<UUID>] = [:]
        var totalTextCharacters = 0
        for entity in payload.entities {
            let suppliedKeys = Set(entity.strings.keys)
                .union(entity.dates.keys).union(entity.integers.keys).union(entity.doubles.keys)
                .union(entity.booleans.keys).union(entity.uuids.keys).union(entity.blobs.keys)
            guard supportedTypes.contains(entity.type), seen[entity.type, default: []].insert(entity.id).inserted,
                  entity.strings.count <= 20, entity.dates.count <= 5, entity.integers.count <= 15,
                  entity.doubles.count <= 5, entity.booleans.count <= 6,
                  entity.uuids.count <= 8, entity.blobs.count <= 5,
                  suppliedKeys.isSubset(of: allowedFields[entity.type, default: []]) else {
                throw UserBackupError.invalidPayload
            }
            totalTextCharacters += entity.strings.values.reduce(0) { $0 + $1.count }
            guard totalTextCharacters <= 8_000_000,
                  entity.strings.values.allSatisfy({ $0.count <= 100_000 }),
                  entity.blobs.values.allSatisfy({ $0.count <= 1_000_000 }) else {
                throw UserBackupError.invalidPayload
            }
            try validateRequiredFields(entity)
        }
        let photoRows = payload.entities.filter { $0.type == "photo" }
        guard photoRows.count <= maximumPhotos else { throw UserBackupError.payloadTooLarge }
        let photoNames = try photoRows.map { try photoArchiveName($0.string("relativePath")) }
        guard Set(photoNames).count == photoNames.count else { throw UserBackupError.invalidPayload }
        let expectedPhotoNames = Set(photoNames)
        let actualPhotoNames = Set(entries.keys.filter { $0.hasPrefix("photos/") })
        guard expectedPhotoNames == actualPhotoNames else { throw UserBackupError.missingFile }
        for name in expectedPhotoNames {
            guard let bytes = entries[name], bytes.count <= StoreZipArchive.maximumEntryBytes,
                  bytes.starts(with: [0xFF, 0xD8]), Data(bytes.suffix(2)) == Data([0xFF, 0xD9]) else {
                throw UserBackupError.invalidPayload
            }
        }
        for document in payload.customProviderProfiles {
            guard document.utf8.count <= CustomProviderProfileCodec.maximumBytes,
                  (try? CustomProviderProfileCodec.decode(document)) != nil else {
                throw UserBackupError.invalidPayload
            }
        }
        guard Set(payload.preparationPlans.map(\.id)).count == payload.preparationPlans.count,
              payload.preparationPlans.allSatisfy({
            $0.text.count <= 40_000 && $0.jobSnapshot.promptText.count <= 60_000
        }) else { throw UserBackupError.invalidPayload }

        let ids = payload.entities.reduce(into: [String: Set<UUID>]()) { $0[$1.type, default: []].insert($1.id) }
        for entity in payload.entities {
            func require(_ key: String, type: String) throws {
                if let id = entity.uuids[key], !ids[type, default: []].contains(id) {
                    throw UserBackupError.missingRelationship
                }
            }
            switch entity.type {
            case "transcript", "answer", "message", "contextSnapshot": try require("sessionID", type: "session")
            case "photo", "usage":
                if entity.uuids["sessionID"] != nil { try require("sessionID", type: "session") }
            case "context":
                let attachmentIDs = try JSONDecoder().decode([UUID].self, from: entity.blob("selectedAttachmentIDsData"))
                guard attachmentIDs.allSatisfy({ ids["attachment", default: []].contains($0) }) else {
                    throw UserBackupError.missingRelationship
                }
            case "practiceSession":
                let questionIDs = try JSONDecoder().decode([UUID].self, from: entity.blob("questionIDsData"))
                guard questionIDs.allSatisfy({ ids["question", default: []].contains($0) }) else {
                    throw UserBackupError.missingRelationship
                }
            case "practiceTurn":
                try require("sessionID", type: "practiceSession"); try require("questionID", type: "question")
            case "practiceFeedback":
                try require("sessionID", type: "practiceSession"); try require("turnID", type: "practiceTurn")
            case "interview": break
            case "deleted":
                guard try entity.string("kindRaw") == "session",
                      ids["session", default: []].contains(try entity.uuid("originalID")) else {
                    throw UserBackupError.missingRelationship
                }
            default: break
            }
        }
    }

    static func orderedForRestore(_ entities: [UserBackupEntity]) -> [UserBackupEntity] {
        let order = [
            "candidate", "job", "attachment", "context", "session", "transcript", "answer", "message",
            "photo", "usage", "contextSnapshot", "question", "practiceSession", "practiceTurn",
            "practiceFeedback", "interview", "deleted",
        ]
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return entities.sorted {
            let left = ranks[$0.type, default: Int.max]
            let right = ranks[$1.type, default: Int.max]
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
    }

    private static func validateRequiredFields(_ entity: UserBackupEntity) throws {
        switch entity.type {
        case "session": _ = try entity.date("startedAt"); _ = try entity.string("title"); _ = try entity.string("providerRaw")
        case "transcript": _ = try entity.uuid("sessionID"); _ = try entity.date("createdAt"); _ = try entity.string("text")
        case "answer":
            _ = try entity.uuid("sessionID"); _ = try entity.date("createdAt"); _ = try entity.string("question")
            _ = try entity.string("answer"); _ = try entity.string("providerRaw"); _ = try entity.string("modelName")
        case "message":
            _ = try entity.uuid("sessionID"); _ = try entity.date("createdAt"); _ = try entity.string("text")
            guard ConversationSpeaker(rawValue: try entity.string("speakerRaw")) != nil,
                  ConversationMessageKind(rawValue: try entity.string("kindRaw")) != nil else { throw UserBackupError.invalidPayload }
        case "photo": _ = try entity.date("createdAt"); _ = try entity.string("relativePath"); _ = try entity.string("recognizedText")
        case "usage": _ = try entity.date("createdAt"); _ = try entity.string("providerRaw"); _ = try entity.string("requestKind")
        case "candidate": _ = try entity.string("title"); _ = try entity.date("createdAt"); _ = try entity.date("updatedAt")
        case "job": _ = try entity.string("title"); _ = try entity.date("createdAt"); _ = try entity.date("updatedAt")
        case "attachment": _ = try entity.string("title"); _ = try entity.string("kindRaw"); _ = try entity.string("extractedText")
        case "context": _ = try entity.string("title"); _ = try entity.blob("selectedAttachmentIDsData")
        case "contextSnapshot":
            _ = try entity.uuid("sessionID"); _ = try entity.uuid("contextProfileID"); _ = try entity.string("text")
        case "question":
            guard PracticeQuestionRole(rawValue: try entity.string("roleRaw")) != nil,
                  PracticeDifficulty(rawValue: try entity.string("difficultyRaw")) != nil,
                  PracticeQuestionType(rawValue: try entity.string("typeRaw")) != nil,
                  PracticeQuestionProvenance(rawValue: try entity.string("provenanceRaw")) != nil else {
                throw UserBackupError.invalidPayload
            }
        case "practiceSession":
            guard PracticeMode(rawValue: try entity.string("modeRaw")) != nil,
                  PracticeInterviewerRole(rawValue: try entity.string("interviewerRoleRaw")) != nil,
                  PracticeDifficulty(rawValue: try entity.string("difficultyRaw")) != nil else {
                throw UserBackupError.invalidPayload
            }
            _ = try entity.blob("questionIDsData")
        case "practiceTurn":
            _ = try entity.uuid("sessionID"); _ = try entity.uuid("questionID"); _ = try entity.string("questionText")
        case "practiceFeedback":
            _ = try entity.uuid("sessionID"); _ = try entity.uuid("turnID"); _ = try entity.uuid("requestID")
        case "interview":
            _ = try entity.date("scheduledAt"); _ = try entity.string("timeZoneIdentifier")
            guard TimeZone(identifier: try entity.string("timeZoneIdentifier")) != nil else { throw UserBackupError.invalidPayload }
        case "deleted": _ = try entity.uuid("originalID"); _ = try entity.date("deletedAt"); _ = try entity.date("purgeAfter")
        default: throw UserBackupError.invalidPayload
        }
    }

    private static let allowedFields: [String: Set<String>] = [
        "session": ["title", "providerRaw", "contextTitle", "startedAt", "endedAt", "questionCount", "photoCount", "estimatedCostRUB", "contextSnapshotID"],
        "transcript": ["sessionID", "createdAt", "text", "confidence", "isQuestion", "revision", "speechEngineRaw", "endpointDelayMilliseconds", "finalizationMilliseconds"],
        "answer": ["sessionID", "createdAt", "question", "answer", "providerRaw", "modelName", "firstTokenMilliseconds", "totalMilliseconds", "inputTokens", "outputTokens", "feedback", "requestKindRaw", "statusRaw", "errorMessage", "promptSnapshot", "promptVersion", "responseStyleRaw", "sourceTranscriptID", "sourceMessageID", "questionRevision", "parentAnswerID", "isStale", "isFavorite", "contextSnapshotID", "queueWaitMilliseconds", "speechEngineRaw", "speechEndpointDelayMilliseconds", "speechFinalizationMilliseconds"],
        "message": ["sessionID", "createdAt", "speakerRaw", "kindRaw", "text", "statusRaw", "confidence", "photoRelativePath", "answerID", "transcriptID", "revision", "speakerSourceRaw", "speakerConfidence", "speakerManuallyLocked", "diarizationLabelRaw"],
        "photo": ["sessionID", "createdAt", "relativePath", "recognizedText", "answerID"],
        "usage": ["createdAt", "sessionID", "providerRaw", "requestKind", "inputTokens", "outputTokens", "estimatedCostRUB", "requestID", "attemptID", "providerSelectionRaw", "modelName", "outcomeRaw", "usageSourceRaw", "costSourceRaw", "errorCode", "durationMilliseconds", "cachedInputTokens", "providerReportedCost", "costCurrencyCode", "pricingSnapshotDate", "pricingModelName"],
        "candidate": ["createdAt", "updatedAt", "title", "revision", "experience", "projects", "education", "skills", "achievements", "language", "level", "isDefault"],
        "job": ["createdAt", "updatedAt", "title", "revision", "company", "role", "vacancyText", "topics", "notes"],
        "attachment": ["createdAt", "updatedAt", "title", "revision", "kindRaw", "statusRaw", "extractedText", "sourceFilename", "sourceByteCount", "importWasTruncated"],
        "context": ["createdAt", "updatedAt", "title", "scenario", "revision", "candidateProfileID", "jobProfileID", "selectedAttachmentIDsData"],
        "contextSnapshot": ["sessionID", "createdAt", "contextProfileID", "contextProfileRevision", "candidateProfileID", "candidateRevision", "jobProfileID", "jobRevision", "attachmentRevisionsData", "title", "text", "wasTruncated", "originalCharacterCount"],
        "question": ["createdAt", "updatedAt", "text", "topic", "roleRaw", "difficultyRaw", "typeRaw", "provenanceRaw", "sourceLabel", "isFavorite", "attemptCount", "isCustom", "isArchived"],
        "practiceSession": ["createdAt", "updatedAt", "endedAt", "modeRaw", "statusRaw", "interviewerRoleRaw", "difficultyRaw", "requestedRounds", "completedRounds", "maxDurationSeconds", "questionIDsData", "jobID", "jobRevision", "jobTitle", "jobSnapshotText", "promptVersion", "rubricVersion", "providerRaw", "modelName", "summaryText", "nextExercisesData", "safeErrorCategory", "isCompanySimulation"],
        "practiceTurn": ["sessionID", "questionID", "createdAt", "answeredAt", "orderIndex", "questionText", "topic", "typeRaw", "difficultyRaw", "statusRaw", "answerText", "answerRevision", "followUpQuestion", "followUpAnswer", "requestID", "providerRaw", "modelName", "promptVersion", "rubricVersion"],
        "practiceFeedback": ["sessionID", "turnID", "createdAt", "answerRevision", "statusRaw", "rubricVersion", "promptVersion", "providerRaw", "modelName", "requestID", "evidenceFragment", "strengthsData", "improvementsData", "exampleAnswer", "followUpQuestion", "accuracyScore", "completenessScore", "structureScore", "examplesScore", "safeErrorCategory", "isStale"],
        "interview": ["createdAt", "updatedAt", "company", "role", "scheduledAt", "timeZoneIdentifier", "meetingURL", "notes", "jobID", "preparationPlanID"],
        "deleted": ["originalID", "kindRaw", "title", "deletedAt", "purgeAfter"],
    ]

    static func exportEntities(context: ModelContext) throws -> [UserBackupEntity] {
        var rows: [UserBackupEntity] = []
        for value in try context.fetch(FetchDescriptor<SessionRecord>()) {
            rows.append(.init(type: "session", id: value.id,
                strings: compact(["title": value.title, "providerRaw": value.providerRaw, "contextTitle": value.contextTitle]),
                dates: compact(["startedAt": value.startedAt, "endedAt": value.endedAt]),
                integers: ["questionCount": value.questionCount, "photoCount": value.photoCount],
                doubles: ["estimatedCostRUB": value.estimatedCostRUB],
                uuids: compact(["contextSnapshotID": value.contextSnapshotID])))
        }
        for value in try context.fetch(FetchDescriptor<TranscriptRecord>()) {
            rows.append(.init(type: "transcript", id: value.id,
                strings: compact(["text": value.text, "speechEngineRaw": value.speechEngineRaw]),
                dates: ["createdAt": value.createdAt],
                integers: compact(["revision": value.revision, "endpointDelayMilliseconds": value.endpointDelayMilliseconds, "finalizationMilliseconds": value.finalizationMilliseconds]),
                doubles: ["confidence": value.confidence], booleans: ["isQuestion": value.isQuestion],
                uuids: ["sessionID": value.sessionID]))
        }
        for value in try context.fetch(FetchDescriptor<AnswerRecord>()) {
            rows.append(.init(type: "answer", id: value.id,
                strings: compact([
                    "question": value.question, "answer": value.answer, "providerRaw": value.providerRaw,
                    "modelName": value.modelName, "requestKindRaw": value.requestKindRaw,
                    "statusRaw": value.statusRaw, "errorMessage": value.errorMessage,
                    "promptSnapshot": value.promptSnapshot, "promptVersion": value.promptVersion,
                    "responseStyleRaw": value.responseStyleRaw, "speechEngineRaw": value.speechEngineRaw,
                ]),
                dates: ["createdAt": value.createdAt],
                integers: compact([
                    "firstTokenMilliseconds": value.firstTokenMilliseconds, "totalMilliseconds": value.totalMilliseconds,
                    "inputTokens": value.inputTokens, "outputTokens": value.outputTokens, "feedback": value.feedback,
                    "questionRevision": value.questionRevision, "queueWaitMilliseconds": value.queueWaitMilliseconds,
                    "speechEndpointDelayMilliseconds": value.speechEndpointDelayMilliseconds,
                    "speechFinalizationMilliseconds": value.speechFinalizationMilliseconds,
                ]),
                booleans: ["isStale": value.isStale, "isFavorite": value.isFavorite],
                uuids: compact([
                    "sessionID": value.sessionID, "sourceTranscriptID": value.sourceTranscriptID,
                    "sourceMessageID": value.sourceMessageID, "parentAnswerID": value.parentAnswerID,
                    "contextSnapshotID": value.contextSnapshotID,
                ])))
        }
        for value in try context.fetch(FetchDescriptor<ConversationMessageRecord>()) {
            rows.append(.init(type: "message", id: value.id,
                strings: compact([
                    "speakerRaw": value.speakerRaw, "kindRaw": value.kindRaw, "text": value.text,
                    "statusRaw": value.statusRaw, "photoRelativePath": value.photoRelativePath,
                    "speakerSourceRaw": value.speakerSourceRaw, "diarizationLabelRaw": value.diarizationLabelRaw,
                ]), dates: ["createdAt": value.createdAt], integers: ["revision": value.revision],
                doubles: compact(["confidence": value.confidence, "speakerConfidence": value.speakerConfidence]),
                booleans: ["speakerManuallyLocked": value.speakerManuallyLocked],
                uuids: compact(["sessionID": value.sessionID, "answerID": value.answerID, "transcriptID": value.transcriptID])))
        }
        for value in try context.fetch(FetchDescriptor<PhotoRecord>()) {
            rows.append(.init(type: "photo", id: value.id,
                strings: ["relativePath": value.relativePath, "recognizedText": value.recognizedText],
                dates: ["createdAt": value.createdAt],
                uuids: compact(["sessionID": value.sessionID, "answerID": value.answerID])))
        }
        for value in try context.fetch(FetchDescriptor<UsageRecord>()) {
            rows.append(.init(type: "usage", id: value.id,
                strings: compact([
                    "providerRaw": value.providerRaw, "requestKind": value.requestKind,
                    "providerSelectionRaw": value.providerSelectionRaw, "modelName": value.modelName,
                    "outcomeRaw": value.outcomeRaw, "usageSourceRaw": value.usageSourceRaw,
                    "costSourceRaw": value.costSourceRaw, "errorCode": value.errorCode,
                    "costCurrencyCode": value.costCurrencyCode, "pricingModelName": value.pricingModelName,
                ]), dates: compact(["createdAt": value.createdAt, "pricingSnapshotDate": value.pricingSnapshotDate]),
                integers: compact([
                    "inputTokens": value.inputTokens, "outputTokens": value.outputTokens,
                    "durationMilliseconds": value.durationMilliseconds, "cachedInputTokens": value.cachedInputTokens,
                ]), doubles: compact([
                    "estimatedCostRUB": value.estimatedCostRUB, "providerReportedCost": value.providerReportedCost,
                ]), uuids: compact([
                    "sessionID": value.sessionID, "requestID": value.requestID, "attemptID": value.attemptID,
                ])))
        }
        for value in try context.fetch(FetchDescriptor<CandidateProfile>()) {
            rows.append(.init(type: "candidate", id: value.id,
                strings: ["title": value.title, "experience": value.experience, "projects": value.projects,
                          "education": value.education, "skills": value.skills, "achievements": value.achievements,
                          "language": value.language, "level": value.level],
                dates: ["createdAt": value.createdAt, "updatedAt": value.updatedAt],
                integers: ["revision": value.revision], booleans: ["isDefault": value.isDefault]))
        }
        for value in try context.fetch(FetchDescriptor<JobProfile>()) {
            rows.append(.init(type: "job", id: value.id,
                strings: ["title": value.title, "company": value.company, "role": value.role,
                          "vacancyText": value.vacancyText, "topics": value.topics, "notes": value.notes],
                dates: ["createdAt": value.createdAt, "updatedAt": value.updatedAt],
                integers: ["revision": value.revision]))
        }
        for value in try context.fetch(FetchDescriptor<AttachmentRecord>()) {
            rows.append(.init(type: "attachment", id: value.id,
                strings: compact([
                    "title": value.title, "kindRaw": value.kindRaw, "statusRaw": value.statusRaw,
                    "extractedText": value.extractedText, "sourceFilename": value.sourceFilename,
                ]), dates: ["createdAt": value.createdAt, "updatedAt": value.updatedAt],
                integers: ["revision": value.revision, "sourceByteCount": value.sourceByteCount],
                booleans: ["importWasTruncated": value.importWasTruncated]))
        }
        for value in try context.fetch(FetchDescriptor<ContextProfile>()) {
            rows.append(.init(type: "context", id: value.id,
                strings: ["title": value.title, "scenario": value.scenario],
                dates: ["createdAt": value.createdAt, "updatedAt": value.updatedAt],
                integers: ["revision": value.revision],
                uuids: compact(["candidateProfileID": value.candidateProfileID, "jobProfileID": value.jobProfileID]),
                blobs: ["selectedAttachmentIDsData": value.selectedAttachmentIDsData]))
        }
        for value in try context.fetch(FetchDescriptor<SessionContextSnapshot>()) {
            rows.append(.init(type: "contextSnapshot", id: value.id,
                strings: ["title": value.title, "text": value.text], dates: ["createdAt": value.createdAt],
                integers: compact([
                    "contextProfileRevision": value.contextProfileRevision, "candidateRevision": value.candidateRevision,
                    "jobRevision": value.jobRevision, "originalCharacterCount": value.originalCharacterCount,
                ]), booleans: ["wasTruncated": value.wasTruncated],
                uuids: compact([
                    "sessionID": value.sessionID, "contextProfileID": value.contextProfileID,
                    "candidateProfileID": value.candidateProfileID, "jobProfileID": value.jobProfileID,
                ]), blobs: ["attachmentRevisionsData": value.attachmentRevisionsData]))
        }
        for value in try context.fetch(FetchDescriptor<PracticeQuestionRecord>()) {
            rows.append(.init(type: "question", id: value.id,
                strings: ["text": value.text, "topic": value.topic, "roleRaw": value.roleRaw,
                          "difficultyRaw": value.difficultyRaw, "typeRaw": value.typeRaw,
                          "provenanceRaw": value.provenanceRaw, "sourceLabel": value.sourceLabel],
                dates: ["createdAt": value.createdAt, "updatedAt": value.updatedAt],
                integers: ["attemptCount": value.attemptCount],
                booleans: ["isFavorite": value.isFavorite, "isCustom": value.isCustom, "isArchived": value.isArchived]))
        }
        for value in try context.fetch(FetchDescriptor<PracticeSessionRecord>()) {
            rows.append(.init(type: "practiceSession", id: value.id,
                strings: compact([
                    "modeRaw": value.modeRaw, "statusRaw": value.statusRaw,
                    "interviewerRoleRaw": value.interviewerRoleRaw, "difficultyRaw": value.difficultyRaw,
                    "jobTitle": value.jobTitle, "jobSnapshotText": value.jobSnapshotText,
                    "promptVersion": value.promptVersion, "rubricVersion": value.rubricVersion,
                    "providerRaw": value.providerRaw, "modelName": value.modelName,
                    "summaryText": value.summaryText, "safeErrorCategory": value.safeErrorCategory,
                ]), dates: compact(["createdAt": value.createdAt, "updatedAt": value.updatedAt, "endedAt": value.endedAt]),
                integers: compact([
                    "requestedRounds": value.requestedRounds, "completedRounds": value.completedRounds,
                    "maxDurationSeconds": value.maxDurationSeconds, "jobRevision": value.jobRevision,
                ]), booleans: ["isCompanySimulation": value.isCompanySimulation],
                uuids: compact(["jobID": value.jobID]),
                blobs: ["questionIDsData": value.questionIDsData, "nextExercisesData": value.nextExercisesData]))
        }
        for value in try context.fetch(FetchDescriptor<PracticeTurnRecord>()) {
            rows.append(.init(type: "practiceTurn", id: value.id,
                strings: compact([
                    "questionText": value.questionText, "topic": value.topic, "typeRaw": value.typeRaw,
                    "difficultyRaw": value.difficultyRaw, "statusRaw": value.statusRaw,
                    "answerText": value.answerText, "followUpQuestion": value.followUpQuestion,
                    "followUpAnswer": value.followUpAnswer, "providerRaw": value.providerRaw,
                    "modelName": value.modelName, "promptVersion": value.promptVersion,
                    "rubricVersion": value.rubricVersion,
                ]), dates: compact(["createdAt": value.createdAt, "answeredAt": value.answeredAt]),
                integers: ["orderIndex": value.orderIndex, "answerRevision": value.answerRevision],
                uuids: compact([
                    "sessionID": value.sessionID, "questionID": value.questionID, "requestID": value.requestID,
                ])))
        }
        for value in try context.fetch(FetchDescriptor<PracticeFeedbackRecord>()) {
            rows.append(.init(type: "practiceFeedback", id: value.id,
                strings: compact([
                    "statusRaw": value.statusRaw, "rubricVersion": value.rubricVersion,
                    "promptVersion": value.promptVersion, "providerRaw": value.providerRaw,
                    "modelName": value.modelName, "evidenceFragment": value.evidenceFragment,
                    "exampleAnswer": value.exampleAnswer, "followUpQuestion": value.followUpQuestion,
                    "safeErrorCategory": value.safeErrorCategory,
                ]), dates: ["createdAt": value.createdAt], integers: compact([
                    "answerRevision": value.answerRevision, "accuracyScore": value.accuracyScore,
                    "completenessScore": value.completenessScore, "structureScore": value.structureScore,
                    "examplesScore": value.examplesScore,
                ]), booleans: ["isStale": value.isStale],
                uuids: ["sessionID": value.sessionID, "turnID": value.turnID, "requestID": value.requestID],
                blobs: ["strengthsData": value.strengthsData, "improvementsData": value.improvementsData]))
        }
        for value in try context.fetch(FetchDescriptor<InterviewEventRecord>()) {
            rows.append(.init(type: "interview", id: value.id,
                strings: compact([
                    "company": value.company, "role": value.role, "timeZoneIdentifier": value.timeZoneIdentifier,
                    "meetingURL": value.meetingURL, "notes": value.notes,
                ]), dates: ["createdAt": value.createdAt, "updatedAt": value.updatedAt, "scheduledAt": value.scheduledAt],
                uuids: compact(["jobID": value.jobID, "preparationPlanID": value.preparationPlanID])))
        }
        for value in try context.fetch(FetchDescriptor<DeletedItemRecord>()) {
            rows.append(.init(type: "deleted", id: value.id,
                strings: ["kindRaw": value.kindRaw, "title": value.title],
                dates: ["deletedAt": value.deletedAt, "purgeAfter": value.purgeAfter],
                uuids: ["originalID": value.originalID]))
        }
        return rows.sorted { $0.type == $1.type ? $0.id.uuidString < $1.id.uuidString : $0.type < $1.type }
    }

    static func existingIDs(context: ModelContext) throws -> [String: Set<UUID>] {
        let deleted = try context.fetch(FetchDescriptor<DeletedItemRecord>())
        return [
            "session": Set(try context.fetch(FetchDescriptor<SessionRecord>()).map(\.id)),
            "transcript": Set(try context.fetch(FetchDescriptor<TranscriptRecord>()).map(\.id)),
            "answer": Set(try context.fetch(FetchDescriptor<AnswerRecord>()).map(\.id)),
            "message": Set(try context.fetch(FetchDescriptor<ConversationMessageRecord>()).map(\.id)),
            "photo": Set(try context.fetch(FetchDescriptor<PhotoRecord>()).map(\.id)),
            "usage": Set(try context.fetch(FetchDescriptor<UsageRecord>()).map(\.id)),
            "candidate": Set(try context.fetch(FetchDescriptor<CandidateProfile>()).map(\.id)),
            "job": Set(try context.fetch(FetchDescriptor<JobProfile>()).map(\.id)),
            "attachment": Set(try context.fetch(FetchDescriptor<AttachmentRecord>()).map(\.id)),
            "context": Set(try context.fetch(FetchDescriptor<ContextProfile>()).map(\.id)),
            "contextSnapshot": Set(try context.fetch(FetchDescriptor<SessionContextSnapshot>()).map(\.id)),
            "question": Set(try context.fetch(FetchDescriptor<PracticeQuestionRecord>()).map(\.id)),
            "practiceSession": Set(try context.fetch(FetchDescriptor<PracticeSessionRecord>()).map(\.id)),
            "practiceTurn": Set(try context.fetch(FetchDescriptor<PracticeTurnRecord>()).map(\.id)),
            "practiceFeedback": Set(try context.fetch(FetchDescriptor<PracticeFeedbackRecord>()).map(\.id)),
            "interview": Set(try context.fetch(FetchDescriptor<InterviewEventRecord>()).map(\.id)),
            "deleted": Set(deleted.map(\.id)),
            "deletedOriginal": Set(deleted.map(\.originalID)),
        ]
    }

    static func preview(
        payload: UserBackupPayload,
        manifest: UserBackupManifest,
        existingIDs: [String: Set<UUID>]
    ) -> UserBackupPreview {
        let counts = Dictionary(grouping: payload.entities, by: \.type).mapValues(\.count)
        let conflicts = payload.entities.filter { entity in
            if existingIDs[entity.type, default: []].contains(entity.id) { return true }
            return entity.type == "deleted"
                && entity.uuids["originalID"].map {
                    existingIDs["deletedOriginal", default: []].contains($0)
                        || existingIDs["session", default: []].contains($0)
                } == true
        }.count
        return .init(
            createdAt: manifest.createdAt,
            appVersion: "\(manifest.appVersion) (\(manifest.appBuild))",
            objectCounts: counts,
            photoCount: counts["photo", default: 0],
            conflictCount: conflicts,
            newObjectCount: payload.entities.count - conflicts,
            preparationPlanCount: payload.preparationPlans.count,
            providerProfileCount: payload.customProviderProfiles.count
        )
    }

    static func insert(_ entity: UserBackupEntity, into context: ModelContext) throws {
        switch entity.type {
        case "candidate":
            let value = CandidateProfile(id: entity.id, title: try entity.string("title"))
            value.createdAt = try entity.date("createdAt"); value.updatedAt = try entity.date("updatedAt")
            value.revision = entity.integers["revision", default: 1]
            value.experience = entity.strings["experience", default: ""]; value.projects = entity.strings["projects", default: ""]
            value.education = entity.strings["education", default: ""]; value.skills = entity.strings["skills", default: ""]
            value.achievements = entity.strings["achievements", default: ""]; value.language = entity.strings["language", default: ""]
            value.level = entity.strings["level", default: ""]; value.isDefault = entity.booleans["isDefault", default: false]
            context.insert(value)
        case "job":
            let value = JobProfile(id: entity.id, title: try entity.string("title"))
            value.createdAt = try entity.date("createdAt"); value.updatedAt = try entity.date("updatedAt")
            value.revision = entity.integers["revision", default: 1]; value.company = entity.strings["company", default: ""]
            value.role = entity.strings["role", default: ""]; value.vacancyText = entity.strings["vacancyText", default: ""]
            value.topics = entity.strings["topics", default: ""]; value.notes = entity.strings["notes", default: ""]
            context.insert(value)
        case "attachment":
            let value = AttachmentRecord(
                id: entity.id, title: try entity.string("title"), kindRaw: try entity.string("kindRaw"),
                extractedText: try entity.string("extractedText"), sourceFilename: entity.strings["sourceFilename"],
                sourceByteCount: entity.integers["sourceByteCount", default: 0],
                importWasTruncated: entity.booleans["importWasTruncated", default: false]
            )
            value.createdAt = entity.dates["createdAt", default: .now]; value.updatedAt = entity.dates["updatedAt", default: .now]
            value.revision = entity.integers["revision", default: 1]; value.statusRaw = entity.strings["statusRaw", default: "ready"]
            context.insert(value)
        case "context":
            let value = ContextProfile(id: entity.id, title: try entity.string("title"))
            value.createdAt = entity.dates["createdAt", default: .now]; value.updatedAt = entity.dates["updatedAt", default: .now]
            value.scenario = entity.strings["scenario", default: ""]; value.revision = entity.integers["revision", default: 1]
            value.candidateProfileID = entity.uuids["candidateProfileID"]; value.jobProfileID = entity.uuids["jobProfileID"]
            value.selectedAttachmentIDsData = try entity.blob("selectedAttachmentIDsData")
            context.insert(value)
        case "session":
            let provider = ProviderKind(rawValue: try entity.string("providerRaw")) ?? .custom
            let value = SessionRecord(id: entity.id, startedAt: try entity.date("startedAt"), title: try entity.string("title"), provider: provider)
            value.endedAt = entity.dates["endedAt"]; value.providerRaw = try entity.string("providerRaw")
            value.questionCount = entity.integers["questionCount", default: 0]; value.photoCount = entity.integers["photoCount", default: 0]
            value.estimatedCostRUB = entity.doubles["estimatedCostRUB", default: 0]
            value.contextSnapshotID = entity.uuids["contextSnapshotID"]; value.contextTitle = entity.strings["contextTitle"]
            context.insert(value)
        case "transcript":
            let value = TranscriptRecord(
                sessionID: try entity.uuid("sessionID"), text: try entity.string("text"),
                confidence: entity.doubles["confidence", default: 0],
                isQuestion: entity.booleans["isQuestion", default: false]
            )
            value.id = entity.id; value.createdAt = try entity.date("createdAt"); value.revision = entity.integers["revision", default: 1]
            value.speechEngineRaw = entity.strings["speechEngineRaw"]
            value.endpointDelayMilliseconds = entity.integers["endpointDelayMilliseconds"]
            value.finalizationMilliseconds = entity.integers["finalizationMilliseconds"]
            context.insert(value)
        case "answer":
            let provider = ProviderKind(rawValue: try entity.string("providerRaw")) ?? .custom
            let mode = AnswerMode(rawValue: entity.strings["requestKindRaw", default: "concise"]) ?? .concise
            let status = AnswerStatus(rawValue: entity.strings["statusRaw", default: "completed"]) ?? .completed
            let value = AnswerRecord(
                id: entity.id, sessionID: try entity.uuid("sessionID"), question: try entity.string("question"),
                answer: try entity.string("answer"), provider: provider, modelName: try entity.string("modelName"),
                requestKind: mode, status: status,
                firstTokenMilliseconds: entity.integers["firstTokenMilliseconds", default: 0],
                totalMilliseconds: entity.integers["totalMilliseconds", default: 0]
            )
            value.createdAt = try entity.date("createdAt"); value.providerRaw = try entity.string("providerRaw")
            value.inputTokens = entity.integers["inputTokens", default: 0]; value.outputTokens = entity.integers["outputTokens", default: 0]
            value.feedback = entity.integers["feedback", default: 0]; value.requestKindRaw = entity.strings["requestKindRaw", default: "concise"]
            value.statusRaw = entity.strings["statusRaw", default: "completed"]; value.errorMessage = entity.strings["errorMessage"]
            value.promptSnapshot = entity.strings["promptSnapshot"]; value.promptVersion = entity.strings["promptVersion"]
            value.responseStyleRaw = entity.strings["responseStyleRaw"]; value.sourceTranscriptID = entity.uuids["sourceTranscriptID"]
            value.sourceMessageID = entity.uuids["sourceMessageID"]; value.questionRevision = entity.integers["questionRevision", default: 1]
            value.parentAnswerID = entity.uuids["parentAnswerID"]; value.isStale = entity.booleans["isStale", default: false]
            value.isFavorite = entity.booleans["isFavorite", default: false]; value.contextSnapshotID = entity.uuids["contextSnapshotID"]
            value.queueWaitMilliseconds = entity.integers["queueWaitMilliseconds"]; value.speechEngineRaw = entity.strings["speechEngineRaw"]
            value.speechEndpointDelayMilliseconds = entity.integers["speechEndpointDelayMilliseconds"]
            value.speechFinalizationMilliseconds = entity.integers["speechFinalizationMilliseconds"]
            context.insert(value)
        case "message":
            guard let speaker = ConversationSpeaker(rawValue: try entity.string("speakerRaw")),
                  let kind = ConversationMessageKind(rawValue: try entity.string("kindRaw")) else { throw UserBackupError.invalidPayload }
            let status = AnswerStatus(rawValue: entity.strings["statusRaw", default: "completed"]) ?? .completed
            let value = ConversationMessageRecord(
                sessionID: try entity.uuid("sessionID"), speaker: speaker, kind: kind,
                text: try entity.string("text"), status: status,
                confidence: entity.doubles["confidence", default: 0],
                photoRelativePath: entity.strings["photoRelativePath"], answerID: entity.uuids["answerID"],
                transcriptID: entity.uuids["transcriptID"]
            )
            value.id = entity.id; value.createdAt = try entity.date("createdAt"); value.revision = entity.integers["revision", default: 1]
            value.speakerSourceRaw = entity.strings["speakerSourceRaw"]; value.speakerConfidence = entity.doubles["speakerConfidence"]
            value.speakerManuallyLocked = entity.booleans["speakerManuallyLocked", default: false]
            value.diarizationLabelRaw = entity.strings["diarizationLabelRaw"]
            context.insert(value)
        case "photo":
            let value = PhotoRecord(sessionID: entity.uuids["sessionID"], relativePath: try entity.string("relativePath"),
                                    recognizedText: try entity.string("recognizedText"), answerID: entity.uuids["answerID"])
            value.id = entity.id; value.createdAt = try entity.date("createdAt"); context.insert(value)
        case "usage":
            let provider = ProviderKind(rawValue: try entity.string("providerRaw")) ?? .custom
            let value = UsageRecord(sessionID: entity.uuids["sessionID"], provider: provider, requestKind: try entity.string("requestKind"))
            value.id = entity.id; value.createdAt = try entity.date("createdAt"); value.providerRaw = try entity.string("providerRaw")
            value.inputTokens = entity.integers["inputTokens", default: 0]; value.outputTokens = entity.integers["outputTokens", default: 0]
            value.estimatedCostRUB = entity.doubles["estimatedCostRUB", default: 0]; value.requestID = entity.uuids["requestID"]
            value.attemptID = entity.uuids["attemptID"]; value.providerSelectionRaw = entity.strings["providerSelectionRaw"]
            value.modelName = entity.strings["modelName"]; value.outcomeRaw = entity.strings["outcomeRaw"]
            value.usageSourceRaw = entity.strings["usageSourceRaw"]; value.costSourceRaw = entity.strings["costSourceRaw"]
            value.errorCode = entity.strings["errorCode"]; value.durationMilliseconds = entity.integers["durationMilliseconds"]
            value.cachedInputTokens = entity.integers["cachedInputTokens"]
            value.providerReportedCost = entity.doubles["providerReportedCost"]; value.costCurrencyCode = entity.strings["costCurrencyCode"]
            value.pricingSnapshotDate = entity.dates["pricingSnapshotDate"]; value.pricingModelName = entity.strings["pricingModelName"]
            context.insert(value)
        case "contextSnapshot":
            let value = SessionContextSnapshot(
                id: entity.id, sessionID: try entity.uuid("sessionID"),
                contextProfileID: try entity.uuid("contextProfileID"),
                contextProfileRevision: entity.integers["contextProfileRevision", default: 1],
                title: entity.strings["title", default: "Контекст"], text: try entity.string("text")
            )
            value.createdAt = entity.dates["createdAt", default: .now]; value.candidateProfileID = entity.uuids["candidateProfileID"]
            value.candidateRevision = entity.integers["candidateRevision"]; value.jobProfileID = entity.uuids["jobProfileID"]
            value.jobRevision = entity.integers["jobRevision"]; value.attachmentRevisionsData = entity.blobs["attachmentRevisionsData", default: Data("{}".utf8)]
            value.wasTruncated = entity.booleans["wasTruncated", default: false]
            value.originalCharacterCount = entity.integers["originalCharacterCount", default: value.text.count]
            context.insert(value)
        case "question":
            guard let role = PracticeQuestionRole(rawValue: try entity.string("roleRaw")),
                  let difficulty = PracticeDifficulty(rawValue: try entity.string("difficultyRaw")),
                  let type = PracticeQuestionType(rawValue: try entity.string("typeRaw")),
                  let provenance = PracticeQuestionProvenance(rawValue: try entity.string("provenanceRaw")) else {
                throw UserBackupError.invalidPayload
            }
            let value = PracticeQuestionRecord(id: entity.id, text: try entity.string("text"),
                topic: entity.strings["topic", default: "Другое"], role: role, difficulty: difficulty,
                type: type, provenance: provenance, sourceLabel: entity.strings["sourceLabel", default: "Резервная копия"])
            value.createdAt = entity.dates["createdAt", default: .now]; value.updatedAt = entity.dates["updatedAt", default: .now]
            value.isFavorite = entity.booleans["isFavorite", default: false]; value.attemptCount = entity.integers["attemptCount", default: 0]
            value.isCustom = entity.booleans["isCustom", default: true]; value.isArchived = entity.booleans["isArchived", default: false]
            context.insert(value)
        case "practiceSession":
            guard let mode = PracticeMode(rawValue: try entity.string("modeRaw")),
                  let role = PracticeInterviewerRole(rawValue: try entity.string("interviewerRoleRaw")),
                  let difficulty = PracticeDifficulty(rawValue: try entity.string("difficultyRaw")),
                  let questionIDs = try? JSONDecoder().decode([UUID].self, from: try entity.blob("questionIDsData")) else {
                throw UserBackupError.invalidPayload
            }
            let value = PracticeSessionRecord(id: entity.id, mode: mode, interviewerRole: role, difficulty: difficulty,
                requestedRounds: entity.integers["requestedRounds", default: questionIDs.count],
                maxDurationSeconds: entity.integers["maxDurationSeconds", default: 900], questionIDs: questionIDs)
            value.createdAt = entity.dates["createdAt", default: .now]; value.updatedAt = entity.dates["updatedAt", default: .now]
            value.endedAt = entity.dates["endedAt"]; value.statusRaw = entity.strings["statusRaw", default: "interrupted"]
            value.completedRounds = entity.integers["completedRounds", default: 0]; value.questionIDsData = try entity.blob("questionIDsData")
            value.jobID = entity.uuids["jobID"]; value.jobRevision = entity.integers["jobRevision"]; value.jobTitle = entity.strings["jobTitle"]
            value.jobSnapshotText = entity.strings["jobSnapshotText"]; value.promptVersion = entity.strings["promptVersion", default: PracticePrompt.version]
            value.rubricVersion = entity.strings["rubricVersion", default: PracticeRubric.version]; value.providerRaw = entity.strings["providerRaw"]
            value.modelName = entity.strings["modelName"]; value.summaryText = entity.strings["summaryText", default: ""]
            value.nextExercisesData = entity.blobs["nextExercisesData", default: Data("[]".utf8)]
            value.safeErrorCategory = entity.strings["safeErrorCategory"]; value.isCompanySimulation = entity.booleans["isCompanySimulation", default: false]
            context.insert(value)
        case "practiceTurn":
            let questionID = try entity.uuid("questionID")
            var descriptor = FetchDescriptor<PracticeQuestionRecord>(predicate: #Predicate { $0.id == questionID })
            descriptor.fetchLimit = 1
            guard let question = try context.fetch(descriptor).first else { throw UserBackupError.missingRelationship }
            let value = PracticeTurnRecord(id: entity.id, sessionID: try entity.uuid("sessionID"), question: question,
                                           orderIndex: entity.integers["orderIndex", default: 0])
            value.questionID = questionID; value.createdAt = entity.dates["createdAt", default: .now]
            value.answeredAt = entity.dates["answeredAt"]; value.questionText = try entity.string("questionText")
            value.topic = entity.strings["topic", default: ""]; value.typeRaw = entity.strings["typeRaw", default: question.typeRaw]
            value.difficultyRaw = entity.strings["difficultyRaw", default: question.difficultyRaw]
            value.statusRaw = entity.strings["statusRaw", default: "cancelled"]; value.answerText = entity.strings["answerText", default: ""]
            value.answerRevision = entity.integers["answerRevision", default: 1]; value.followUpQuestion = entity.strings["followUpQuestion"]
            value.followUpAnswer = entity.strings["followUpAnswer"]; value.requestID = entity.uuids["requestID"]
            value.providerRaw = entity.strings["providerRaw"]; value.modelName = entity.strings["modelName"]
            value.promptVersion = entity.strings["promptVersion", default: PracticePrompt.version]
            value.rubricVersion = entity.strings["rubricVersion", default: PracticeRubric.version]
            context.insert(value)
        case "practiceFeedback":
            let value = PracticeFeedbackRecord(id: entity.id, sessionID: try entity.uuid("sessionID"), turnID: try entity.uuid("turnID"),
                                               answerRevision: entity.integers["answerRevision", default: 1], requestID: try entity.uuid("requestID"))
            value.createdAt = entity.dates["createdAt", default: .now]; value.statusRaw = entity.strings["statusRaw", default: "cancelled"]
            value.rubricVersion = entity.strings["rubricVersion", default: PracticeRubric.version]
            value.promptVersion = entity.strings["promptVersion", default: PracticePrompt.version]
            value.providerRaw = entity.strings["providerRaw"]; value.modelName = entity.strings["modelName"]
            value.evidenceFragment = entity.strings["evidenceFragment", default: ""]; value.strengthsData = entity.blobs["strengthsData", default: Data("[]".utf8)]
            value.improvementsData = entity.blobs["improvementsData", default: Data("[]".utf8)]
            value.exampleAnswer = entity.strings["exampleAnswer", default: ""]; value.followUpQuestion = entity.strings["followUpQuestion"]
            value.accuracyScore = entity.integers["accuracyScore"]; value.completenessScore = entity.integers["completenessScore"]
            value.structureScore = entity.integers["structureScore"]; value.examplesScore = entity.integers["examplesScore"]
            value.safeErrorCategory = entity.strings["safeErrorCategory"]; value.isStale = entity.booleans["isStale", default: false]
            context.insert(value)
        case "interview":
            let value = InterviewEventRecord(id: entity.id, company: entity.strings["company", default: ""],
                role: entity.strings["role", default: ""], scheduledAt: try entity.date("scheduledAt"),
                timeZoneIdentifier: try entity.string("timeZoneIdentifier"))
            value.createdAt = entity.dates["createdAt", default: .now]; value.updatedAt = entity.dates["updatedAt", default: .now]
            value.meetingURL = entity.strings["meetingURL"]; value.notes = entity.strings["notes", default: ""]
            value.jobID = entity.uuids["jobID"]; value.preparationPlanID = entity.uuids["preparationPlanID"]
            // System calendar and notification identifiers are deliberately device-local.
            context.insert(value)
        case "deleted":
            let value = DeletedItemRecord(id: entity.id, originalID: try entity.uuid("originalID"),
                kindRaw: try entity.string("kindRaw"), title: entity.strings["title", default: "Удалённая сессия"],
                deletedAt: try entity.date("deletedAt"), purgeAfter: try entity.date("purgeAfter"))
            context.insert(value)
        default: throw UserBackupError.invalidPayload
        }
    }
}

private extension UserBackupEntity {
    func string(_ key: String) throws -> String {
        guard let value = strings[key] else { throw UserBackupError.invalidPayload }
        return value
    }
    func date(_ key: String) throws -> Date {
        guard let value = dates[key] else { throw UserBackupError.invalidPayload }
        return value
    }
    func uuid(_ key: String) throws -> UUID {
        guard let value = uuids[key] else { throw UserBackupError.invalidPayload }
        return value
    }
    func blob(_ key: String) throws -> Data {
        guard let value = blobs[key] else { throw UserBackupError.invalidPayload }
        return value
    }
}

private func compact<Value>(_ values: [String: Value?]) -> [String: Value] {
    values.compactMapValues { $0 }
}
