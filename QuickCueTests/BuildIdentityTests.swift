import XCTest
@testable import QuickCue

final class BuildIdentityTests: XCTestCase {
    func testMissingOrUnexpandedRevisionIsUnknown() {
        let fixtures: [[String: Any]] = [[:], ["QuickCueSourceRevision": "$(QUICKCUE_SOURCE_REVISION)"], ["QuickCueSourceRevision": "PRIVATE_INPUT"]]
        for info in fixtures {
            let identity = BuildIdentity(info: info)
            XCTAssertEqual(identity.revision, "unknown")
            XCTAssertFalse(identity.diagnosticText.contains("PRIVATE_INPUT"))
        }
    }

    func testExactRevisionAndVersionArePreserved() {
        let sha = String(repeating: "a", count: 40)
        let identity = BuildIdentity(info: ["CFBundleShortVersionString": "0.3.1", "CFBundleVersion": "4", "QuickCueSourceRevision": sha])
        XCTAssertEqual(identity.revision, sha)
        XCTAssertEqual(identity.version, "0.3.1")
        XCTAssertEqual(identity.build, "4")
    }

    func testLegacyConnectionReportStillDecodes() throws {
        let data = Data(#"{"state":"failed","modelName":"fixture","errorCategory":"empty_response"}"#.utf8)
        let report = try JSONDecoder().decode(ProviderConnectionReport.self, from: data)
        XCTAssertNil(report.buildIdentity)
        XCTAssertNil(report.requestID)
    }

    func testDiagnosticExportExcludesArbitraryFields() {
        let report = ProviderConnectionReport(state: .failed, modelName: "PRIVATE_MODEL", checkedAt: nil,
                                              firstTokenMilliseconds: nil, totalMilliseconds: nil,
                                              errorCategory: "PRIVATE_ERROR")
        let text = report.diagnosticSummary(provider: .custom)
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertTrue(text.contains("error=unknown"))
        XCTAssertTrue(text.contains("revision=unknown"))
    }
}
