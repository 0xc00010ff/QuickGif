import Foundation
import QuartzCore

struct SavedRecording {
    let url: URL
    let byteCount: Int
    let duration: TimeInterval
}

enum RecordingOutcome {
    case saved(SavedRecording)
    case nothingRecorded
    case failed(Error)
}

/// Turns captured frames into a GIF.
///
/// Frames arrive on the recorder's capture queue, pause/stop come from the main
/// thread, and the encoder lives on its own serial queue. The recording clock
/// (time zero, pauses, stop) is shared state, so it sits behind a lock.
/// All times are host-clock seconds (`CACurrentMediaTime()`), the same clock as
/// frame presentation times.
final class RecordingPipeline: @unchecked Sendable {
    let url: URL
    private let limit: TimeInterval?
    private let queue: DispatchQueue

    // Encoder queue only.
    private let encoder: GIFEncoder
    private var encoderError: Error?

    // Guarded by `lock`.
    private let lock = NSLock()
    private var startHostTime: TimeInterval?
    private var firstPTS: TimeInterval?
    private var pausedTotal: TimeInterval = 0
    private var pauseStartedAt: TimeInterval?
    private var resumedAt: TimeInterval = -.infinity
    private var stopElapsed: TimeInterval?
    private var lastFrameTime: TimeInterval = -.infinity

    init(url: URL, width: Int, height: Int, limit: TimeInterval?) throws {
        let queue = DispatchQueue(label: "QuickGif.encoder", qos: .userInitiated)
        var made: Result<GIFEncoder, Error>?
        queue.sync { made = Result { try GIFEncoder(url: url, width: width, height: height) } }
        self.encoder = try made!.get()
        self.queue = queue
        self.url = url
        self.limit = limit
    }

    /// Frames presented before `hostTime` are dropped (the recorder may already be
    /// running during the last second of a countdown). Until this is called, every frame is dropped.
    func begin(at hostTime: TimeInterval) {
        lock.withLock { startHostTime = hostTime }
    }

    /// Recorder callback, on the capture queue.
    func append(_ frame: FrameBuffer, at pts: TimeInterval) {
        lock.lock()
        guard let start = startHostTime, pts >= start, pts >= resumedAt,
              pauseStartedAt.map({ pts < $0 }) ?? true,
              !(stopElapsed != nil && firstPTS == nil)
        else { lock.unlock(); return }

        if firstPTS == nil { firstPTS = pts }
        let time = pts - firstPTS! - pausedTotal
        let pastStop = stopElapsed.map { time > $0 } ?? false
        let pastLimit = limit.map { time >= $0 } ?? false
        guard time > lastFrameTime, !pastStop, !pastLimit else { lock.unlock(); return }
        lastFrameTime = time
        lock.unlock()

        queue.async { [self] in
            guard encoderError == nil else { return }
            do { try encoder.addFrame(frame, at: time) } catch { encoderError = error }
        }
    }

    func setPaused(_ paused: Bool, now: TimeInterval = CACurrentMediaTime()) {
        lock.withLock {
            if paused {
                if pauseStartedAt == nil { pauseStartedAt = now }
            } else if let began = pauseStartedAt {
                // A pause before the first frame does not shift the timeline: time zero is still ahead.
                if firstPTS != nil { pausedTotal += now - began }
                pauseStartedAt = nil
                resumedAt = now
            }
        }
    }

    /// Recording time so far, excluding pauses; 0 until the first frame arrives.
    func elapsed(now: TimeInterval = CACurrentMediaTime()) -> TimeInterval {
        lock.withLock { unlockedElapsed(now: now) }
    }

    /// Freezes the clock and drops frames after this instant. Returns the final duration.
    func stop(now: TimeInterval = CACurrentMediaTime()) -> TimeInterval {
        lock.withLock {
            var elapsed = unlockedElapsed(now: now)
            if let limit { elapsed = min(elapsed, limit) }
            stopElapsed = elapsed
            return elapsed
        }
    }

    /// Call after the recorder has stopped delivering frames.
    func finish(at end: TimeInterval) async -> RecordingOutcome {
        let lastTime = lock.withLock { lastFrameTime }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: finishOnQueue(end: max(end, lastTime)))
            }
        }
    }

    /// Abandons the recording and removes any partial file.
    func discard() {
        lock.withLock { stopElapsed = 0 }
        queue.async { [self] in
            try? encoder.finish(at: 0)
            removeOutput()
        }
    }

    private func unlockedElapsed(now: TimeInterval) -> TimeInterval {
        if let stopElapsed { return stopElapsed }
        guard let firstPTS else { return 0 }
        let end = pauseStartedAt ?? now
        return max(0, end - firstPTS - pausedTotal)
    }

    private func finishOnQueue(end: TimeInterval) -> RecordingOutcome {
        if let encoderError {
            try? encoder.finish(at: end)
            removeOutput()
            return .failed(encoderError)
        }
        // The encoder holds the last frame until it knows how long it is shown, so the
        // frame count is only meaningful after `finish`.
        do {
            try encoder.finish(at: end)
        } catch {
            removeOutput()
            return encoder.stats.frameCount == 0 ? .nothingRecorded : .failed(error)
        }
        guard encoder.stats.frameCount > 0 else {
            removeOutput()
            return .nothingRecorded
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? encoder.stats.bytesWritten
        return .saved(SavedRecording(url: url, byteCount: size, duration: end))
    }

    private func removeOutput() {
        try? FileManager.default.removeItem(at: url)
    }
}
