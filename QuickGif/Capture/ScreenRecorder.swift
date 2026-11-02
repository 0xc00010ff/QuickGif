import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import os

/// Captures a screen region with ScreenCaptureKit and delivers frames as `FrameBuffer`s.
///
/// Frames arrive on a private serial background queue via `onFrame`. The time passed
/// with each frame is the frame's presentation time in host-clock seconds (the same
/// clock as `CACurrentMediaTime()`), so callers can relate it to their own timestamps.
///
/// ScreenCaptureKit only delivers a new frame when the captured content changes, so
/// frames can be sparse while the screen is idle. Every delivered frame has exactly
/// the configured pixel size (`region.pixelSize(for: scale)`).
/// QuickGif's own windows are excluded from the capture.
final class ScreenRecorder {
    enum RecorderError: Error, LocalizedError {
        case permissionDenied
        case displayNotFound
        case alreadyStarted
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen Recording permission is required."
            case .displayNotFound: return "The selected display is no longer available."
            case .alreadyStarted: return "Recording has already started."
            }
        }
    }

    let region: CaptureRegion
    let fps: Int
    let scale: CaptureScale
    /// Called on a background serial queue for every complete frame.
    var onFrame: ((FrameBuffer, TimeInterval) -> Void)?
    /// Called on the main queue if the stream stops unexpectedly (display disconnected, permission revoked…).
    var onError: ((Error) -> Void)?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "QuickGif", category: "ScreenRecorder")

    private let outputQueue = DispatchQueue(label: "QuickGif.ScreenRecorder.output", qos: .userInitiated)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var stream: SCStream?
    private var output: StreamOutput?
    private var started = false
    private var stopped = false
    private var errorReported = false
    private var loggedSizeMismatch = false

    init(region: CaptureRegion, fps: Int, scale: CaptureScale) {
        self.region = region
        self.fps = fps
        self.scale = scale
    }

    /// Starts capturing. Throws if permission is missing or the display is gone.
    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw RecorderError.permissionDenied }
        let wasStarted = lock.withLock { () -> Bool in
            defer { started = true }
            return started
        }
        guard !wasStarted else { throw RecorderError.alreadyStarted }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw RecorderError.permissionDenied }
            throw error
        }
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw RecorderError.displayNotFound
        }

        let filter: SCContentFilter
        if let bundleID = Bundle.main.bundleIdentifier,
           let ownApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
            filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let size = region.pixelSize(for: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = region.rectInDisplayCoordinates
        config.width = size.width
        config.height = size.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = false
        config.backgroundColor = .black
        // Render from the full backing-resolution framebuffer; a 1x capture of a Retina
        // display is then an exact 2:1 downscale (smooth, no point-sampling artifacts).
        config.captureResolution = .best
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.shouldBeOpaque = true

        let output = StreamOutput(recorder: self, width: size.width, height: size.height)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)

        let stoppedEarly = lock.withLock { () -> Bool in
            if !stopped {
                self.stream = stream
                self.output = output
            }
            return stopped
        }
        if stoppedEarly { output.release(); return }

        do {
            try await stream.startCapture()
        } catch {
            teardown()
            if !CGPreflightScreenCaptureAccess() { throw RecorderError.permissionDenied }
            throw error
        }
        // stop() raced with startCapture(); make sure the stream does not keep running.
        if isStopped {
            try? await stream.stopCapture()
            outputQueue.sync {}
            teardown()
        }
    }

    /// Stops capturing. Safe to call more than once. No frames are delivered after this returns.
    func stop() async {
        let (alreadyStopped, stream) = lock.withLock { () -> (Bool, SCStream?) in
            defer { stopped = true }
            return (stopped, self.stream)
        }
        guard !alreadyStopped else { return }

        if let stream {
            // Errors here mean the stream already stopped (or never started); nothing to do.
            try? await stream.stopCapture()
        }
        // Barrier: any frame handler that began before `stopped` was set finishes now;
        // later handlers see `stopped` and return without calling `onFrame`.
        outputQueue.sync {}
        teardown()
    }

    // MARK: - Private

    /// Drops the stream and breaks the recorder <-> output reference cycle.
    private func teardown() {
        let (stream, output) = lock.withLock { () -> (SCStream?, StreamOutput?) in
            stopped = true
            defer { self.stream = nil; self.output = nil }
            return (self.stream, self.output)
        }
        if let stream, let output {
            try? stream.removeStreamOutput(output, type: .screen)
        }
        output?.release()
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    /// Runs on `outputQueue`.
    fileprivate func handle(_ sampleBuffer: CMSampleBuffer, width: Int, height: Int) {
        guard !isStopped, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let frame: FrameBuffer? = {
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
            let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

            if srcWidth == width && srcHeight == height {
                let data = Data(bytes: base, count: srcBytesPerRow * srcHeight)
                return FrameBuffer(width: width, height: height, bytesPerRow: srcBytesPerRow, pixels: data)
            }

            let shouldLog = lock.withLock { () -> Bool in
                defer { loggedSizeMismatch = true }
                return !loggedSizeMismatch
            }
            if shouldLog {
                Self.logger.notice("Captured buffer is \(srcWidth)x\(srcHeight), expected \(width)x\(height); cropping/padding to the configured size")
            }

            // Copy the overlapping area into an exactly-sized buffer, padded with opaque black.
            let dstBytesPerRow = width * 4
            var data = Data(count: dstBytesPerRow * height)
            let copyRows = min(height, srcHeight)
            let copyBytes = min(width, srcWidth) * 4
            data.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let d = dst.bindMemory(to: UInt32.self)
                d.initialize(repeating: UInt32(0xFF00_0000).littleEndian) // B=0 G=0 R=0 A=255
                guard let dstBase = dst.baseAddress else { return }
                for y in 0..<copyRows {
                    memcpy(dstBase + y * dstBytesPerRow, base + y * srcBytesPerRow, copyBytes)
                }
            }
            return FrameBuffer(width: width, height: height, bytesPerRow: dstBytesPerRow, pixels: data)
        }()

        guard let frame, !isStopped else { return }
        onFrame?(frame, time)
    }

    fileprivate func streamDidStop(with error: Error) {
        let shouldReport = lock.withLock { () -> Bool in
            defer { errorReported = true }
            return !errorReported && !stopped
        }
        guard shouldReport else { return }
        DispatchQueue.main.async { [self] in
            onError?(error)
            // The stream is dead; release it and break the retain cycle.
            outputQueue.async { self.teardown() }
        }
    }
}

/// Receives ScreenCaptureKit callbacks. Holds the recorder strongly while capturing so
/// the recorder stays alive even if the caller drops its reference; `release()` breaks
/// that cycle on stop or failure.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: ScreenRecorder?
    private let width: Int
    private let height: Int

    init(recorder: ScreenRecorder, width: Int, height: Int) {
        self.recorder = recorder
        self.width = width
        self.height = height
    }

    func release() {
        lock.withLock { recorder = nil }
    }

    private var current: ScreenRecorder? {
        lock.withLock { recorder }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        current?.handle(sampleBuffer, width: width, height: height)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        current?.streamDidStop(with: error)
    }
}
