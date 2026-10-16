import AppKit
import CoreImage
import ScreenCaptureKit

enum SingleFrameCaptureError: Error {
    case failed
    case deadlineExceeded(capture: Error?)
    case cleanupFailed(capture: Error?, stop: Error)
}

/// One complete frame on macOS 13, where SCScreenshotManager is unavailable. Each instance
/// captures once without audio. Success requires start and stop API acknowledgments.
/// The deadline covers start, frame and stop. A deadline error can leave cleanup pending;
/// this same helper retains the stream and stops it after an in-flight start settles.
@MainActor
final class SingleFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Operations {
        var start: (SCStream) async throws -> Void
        var stop: (SCStream) async throws -> Void
        static let system = Operations(start: { try await $0.startCapture() }, stop: { try await $0.stopCapture() })
    }

    enum State { case ready, capturing, stopping, stopped, cleanupPending, cleanupFailed }
    private(set) var state = State.ready
    private(set) var cleanupError: Error?
    private let operations: Operations
    private let deadlineNanoseconds: UInt64
    private var stream: SCStream?
    private var start: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var result: Result<CGImage, Error>?
    private var pending: CheckedContinuation<CGImage, Error>?
    private var timeout: Task<Void, Never>?

    init(operations: Operations = .system, deadlineNanoseconds: UInt64 = 8_000_000_000) {
        self.operations = operations
        self.deadlineNanoseconds = deadlineNanoseconds
        super.init()
    }

    func capture(filter: SCContentFilter, width: Int, height: Int, sourceRect: CGRect? = nil) async throws -> CGImage {
        try Task.checkCancellation()
        guard state == .ready, width > 0, height > 0 else { throw SingleFrameCaptureError.failed }
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = width
        config.height = height
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 1
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main) }
        catch { state = .stopped; throw error }
        self.stream = stream
        state = .capturing
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeout = Task { [weak self] in
                    guard let duration = self?.deadlineNanoseconds else { return }
                    do { try await Task.sleep(nanoseconds: duration) } catch { return }
                    self?.deadlineExpired()
                }
                start = Task {
                    do { try await self.operations.start(stream) }
                    catch { self.finish(.failure(error)) }
                }
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private var captureError: Error? {
        if case .failure(let error) = result { return error }
        return nil
    }

    private func complete(_ result: Result<CGImage, Error>) {
        guard let pending else { return }
        self.pending = nil
        timeout?.cancel(); timeout = nil
        pending.resume(with: result)
    }

    private func deadlineExpired() {
        guard pending != nil else { return }
        let error = SingleFrameCaptureError.deadlineExceeded(capture: captureError)
        finish(.failure(error))
        state = .cleanupPending
        complete(.failure(error))
    }

    private func finish(_ incoming: Result<CGImage, Error>) {
        guard stream != nil, state != .stopped, state != .cleanupFailed else { return }
        if result == nil { result = incoming }
        else if case .failure = incoming, pending != nil { result = incoming }
        guard cleanup == nil, let stream else { return }
        state = .stopping
        let start = start
        cleanup = Task {
            // ScreenCaptureKit's asynchronous start must settle before requesting stop.
            await start?.value
            self.start = nil
            do {
                try await self.operations.stop(stream)
                self.stream = nil
                self.state = .stopped
                self.complete(self.result ?? .failure(SingleFrameCaptureError.failed))
            } catch {
                self.cleanupError = error
                self.state = .cleanupFailed
                self.complete(.failure(SingleFrameCaptureError.cleanupFailed(capture: self.captureError, stop: error)))
            }
            self.cleanup = nil
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        // addStreamOutput explicitly delivers on the main queue.
        MainActor.assumeIsolated {
            guard self.stream === stream, state == .capturing, type == .screen, sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                      createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  status == SCFrameStatus.complete.rawValue,
                  let buffer = sampleBuffer.imageBuffer else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = CIContext().createCGImage(image, from: image.extent) else {
                finish(.failure(SingleFrameCaptureError.failed))
                return
            }
            finish(.success(cgImage))
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.finish(.failure(error))
        }
    }
}
