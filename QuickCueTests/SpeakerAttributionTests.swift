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

    func testManualLockWinsOverLateHybridLabel() {
        var mapping = SpeakerLabelMapping()
        mapping.bind(.speakerA, to: .partner)
        XCTAssertNil(HybridSpeakerAssignment.resolve(
            label: .speakerA, confidence: 0.99, mapping: mapping, manuallyLocked: true
        ))
    }

    func testAmbiguousOrUnmappedHybridLabelRemainsUnknown() {
        var mapping = SpeakerLabelMapping()
        mapping.bind(.speakerA, to: .partner)
        XCTAssertEqual(HybridSpeakerAssignment.resolve(
            label: .speakerA, confidence: 0.4, mapping: mapping, manuallyLocked: false
        ), .unknown)
        XCTAssertEqual(HybridSpeakerAssignment.resolve(
            label: .speakerB, confidence: 0.99, mapping: mapping, manuallyLocked: false
        ), .unknown)
    }

    func testRebindingLabelDoesNotRewriteAnotherChunkAsTheSamePerson() {
        var mapping = SpeakerLabelMapping()
        mapping.bind(.speakerA, to: .me)
        mapping.bind(.speakerB, to: .partner)
        mapping.bind(.speakerA, to: .partner)
        XCTAssertEqual(mapping.speaker(for: .speakerA), .partner)
        XCTAssertNil(mapping.speaker(for: .speakerB))
    }

    func testEphemeralBufferIsBoundedAndCanBeErased() {
        var buffer = EphemeralDiarizationBuffer(maximumBytes: 4)
        buffer.append(Data([1, 2, 3]))
        buffer.append(Data([4, 5, 6]))
        XCTAssertEqual(buffer.bytes, Data([3, 4, 5, 6]))
        buffer.clear()
        XCTAssertEqual(buffer.count, 0)
    }
}
