import UIKit
import XCTest
@testable import QuickCue

@MainActor
final class ImageUploadPreparationTests: XCTestCase {
    func testUploadCopyIsBoundedWithoutMutatingOriginal() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let originalSnapshot = original
        let upload = try ImageUploadPreparation.prepare(jpeg: original)
        let decoded = try XCTUnwrap(UIImage(data: upload))
        XCTAssertLessThanOrEqual(upload.count, 1_500_000)
        XCTAssertEqual(decoded.size.width, 1600, accuracy: 1)
        XCTAssertEqual(decoded.size.height, 800, accuracy: 1)
        XCTAssertEqual(original, originalSnapshot)
        XCTAssertEqual(try XCTUnwrap(UIImage(data: original)).size.width, 2400, accuracy: 1)
    }

    func testInvalidPhotoFailsBeforeSending() {
        XCTAssertThrowsError(try ImageUploadPreparation.prepare(jpeg: Data([0, 1, 2])))
    }
}
