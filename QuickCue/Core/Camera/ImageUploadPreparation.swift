import UIKit

enum ImageUploadPreparation {
    /// The original remains in PhotoStore; only this bounded copy goes to the API.
    static func prepare(jpeg: Data) throws -> Data {
        guard let image = UIImage(data: jpeg), image.size.width > 0, image.size.height > 0 else {
            throw AIProviderError.invalidConfiguration("Не удалось подготовить фото. Переснимите задачу.")
        }
        let scale = min(1, 1_600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.85, 0.7, 0.55] {
            if let data = resized.jpegData(compressionQuality: quality), data.count <= 1_500_000 {
                return data
            }
        }
        throw AIProviderError.invalidConfiguration("Фото слишком большое для быстрой отправки. Обрежьте лишнее или снимите ближе.")
    }
}
