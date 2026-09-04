import Foundation

struct BuildIdentity: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let revision: String

    static var current: Self { Self(info: Bundle.main.infoDictionary ?? [:]) }

    init(info: [String: Any]) {
        version = Self.numeric(info["CFBundleShortVersionString"] as? String)
        build = Self.numeric(info["CFBundleVersion"] as? String)
        let configuredRevision = info["QuickCueSourceRevision"] as? String
        let sha = (configuredRevision ?? "").lowercased()
        let validSHA = sha.count == 40 && sha.allSatisfy({ "0123456789abcdef".contains($0) })
        revision = validSHA ? sha : "unknown"
    }

    var revisionTitle: String { revision == "unknown" ? "Неизвестна (локальная сборка)" : String(revision.prefix(12)) }
    var diagnosticText: String { "QuickCue \(version) (\(build))\nrevision=\(revision)" }

    private static func numeric(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 32,
              value.allSatisfy({ "0123456789.".contains($0) }) else { return "unknown" }
        return value
    }
}
