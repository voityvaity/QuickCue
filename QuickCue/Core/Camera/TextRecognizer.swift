import Foundation
import Vision

struct TextRecognizer: Sendable {
    func recognize(jpeg: Data) async throws -> String {
        try await recognize(
            jpeg: jpeg,
            languages: ["ru-RU", "en-US"],
            usesLanguageCorrection: true
        )
    }

    func recognizeSecret(jpeg: Data) async throws -> String {
        try await recognize(
            jpeg: jpeg,
            languages: ["en-US"],
            usesLanguageCorrection: false
        )
    }

    private func recognize(
        jpeg: Data,
        languages: [String],
        usesLanguageCorrection: Bool
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let text = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n") ?? ""
                continuation.resume(returning: text)
            }
            request.recognitionLanguages = languages
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = usesLanguageCorrection
            let handler = VNImageRequestHandler(data: jpeg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

