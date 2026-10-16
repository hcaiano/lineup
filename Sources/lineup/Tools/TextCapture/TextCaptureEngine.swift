import AppKit
import TextCaptureCore
import Vision

enum TextCaptureError: Error, Equatable {
    case captureFailed
    case displayChanged
    case permissionDenied
    case languagesUnavailable
}

enum TextCaptureRecognition {
    /// The caller keeps the request so disabling the tool can cancel Vision's pending work.
    static func request() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let languages = CaptureText.languages(available: try request.supportedRecognitionLanguages())
        guard languages.missing.isEmpty else { throw TextCaptureError.languagesUnavailable }
        request.recognitionLanguages = languages.selected
        return request
    }

    static func recognize(_ image: CGImage, request: VNRecognizeTextRequest) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                return CaptureText.readingOrder((request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedLine(text: candidate.string, bounds: observation.boundingBox)
                })
            }.value
        } onCancel: {
            request.cancel()
        }
    }
}
