import AppKit
import CoreImage
import ScreenCaptureKit
import TextCaptureCore
import Vision

enum TextCaptureError: Error, Equatable {
    case captureFailed
    case displayChanged
    case permissionDenied
    case languagesUnavailable
}

/// One complete frame, also on macOS 13 where SCScreenshotManager is unavailable. The stream
/// has no audio and is stopped on completion, cancellation, error, or timeout.
@MainActor
final class TextCaptureFrame: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var timeout: Task<Void, Never>?

    func capture(display: SCDisplay, region: CaptureRegion, excluding windows: [SCWindow]) async throws -> CGImage {
        try Task.checkCancellation()
        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        config.width = region.pixelWidth
        config.height = region.pixelHeight
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 1
        let filter = SCContentFilter(display: display, excludingWindows: windows)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                    self?.finish(.failure(TextCaptureError.captureFailed))
                }
                Task {
                    do { try await stream.startCapture() }
                    catch { self.finish(.failure(error)) }
                    // Cancellation can arrive before the asynchronous start completes.
                    if self.continuation == nil { try? await stream.stopCapture() }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<CGImage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        stream?.stopCapture()
        stream = nil
        continuation.resume(with: result)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        // addStreamOutput explicitly delivers on the main queue.
        MainActor.assumeIsolated {
            guard continuation != nil, type == .screen, sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                      createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  status == SCFrameStatus.complete.rawValue,
                  let buffer = sampleBuffer.imageBuffer else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = CIContext().createCGImage(image, from: image.extent) else {
                finish(.failure(TextCaptureError.captureFailed))
                return
            }
            finish(.success(cgImage))
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }
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
