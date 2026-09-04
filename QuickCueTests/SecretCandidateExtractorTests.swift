import XCTest
@testable import QuickCue

final class SecretCandidateExtractorTests: XCTestCase {
    func testPrefersKnownKeyPrefix() {
        let expected = "sk-test_1234567890AB"
        let text = "Документация abcdef1234567890abcdef\nAPI key: \(expected)"

        XCTAssertEqual(SecretCandidateExtractor.bestCandidate(in: text), expected)
    }

    func testRejoinsSpacesOnLikelyKeyLine() {
        let text = "API_KEY: AQVN 1234567890 ABCDEFGHIJ"

        XCTAssertEqual(
            SecretCandidateExtractor.bestCandidate(in: text),
            "AQVN1234567890ABCDEFGHIJ"
        )
    }

    func testRejectsURL() {
        XCTAssertNil(
            SecretCandidateExtractor.bestCandidate(in: "https://gateway.example/v1/chat/completions")
        )
    }
}
