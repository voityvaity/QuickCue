import XCTest
@testable import QuickCue

final class SpeakerAttributionTests: XCTestCase {
    private let attributor = SemanticSpeakerAttributor()
    private let detector = QuestionDetector()

    func testQuestionIsAttributedToPartner() {
        let role = attributor.classify(
            detection: detector.detect("Расскажите о вашем последнем проекте"),
            previousSpeaker: nil
        )
        XCTAssertEqual(role, .partner)
    }

    func testStatementAfterPartnerIsAttributedToOwner() {
        let role = attributor.classify(
            detection: detector.detect("Я разработал серверную часть на Python"),
            previousSpeaker: .partner
        )
        XCTAssertEqual(role, .me)
    }
}
