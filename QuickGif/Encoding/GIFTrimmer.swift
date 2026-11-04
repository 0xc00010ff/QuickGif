import CoreGraphics
import Foundation
import ImageIO

/// Frame timing of a GIF on disk, read with ImageIO.
struct GIFTimeline {
    let width: Int
    let height: Int
    /// How long each frame is shown, in seconds.
    let delays: [TimeInterval]
    /// `starts[i]` is when frame `i` appears; `starts[frameCount]` is the total duration.
    let starts: [TimeInterval]

    var frameCount: Int { delays.count }
    var duration: TimeInterval { starts[frameCount] }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw GIFTrimmer.TrimError.unreadable }
        try self.init(source: source)
    }

    init(source: CGImageSource) throws {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw GIFTrimmer.TrimError.unreadable }
        var delays: [TimeInterval] = []
        delays.reserveCapacity(count)
        var width = 0, height = 0
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            if i == 0 {
                width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
                height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            }
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
            let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
            let delay = unclamped > 0 ? unclamped : clamped
            // Browsers treat (near) zero delays as 0.1 s.
            delays.append(delay >= 0.01 ? delay : 0.1)
        }
        if width <= 0 || height <= 0, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            width = first.width
            height = first.height
        }
        guard width > 0, height > 0 else { throw GIFTrimmer.TrimError.unreadable }

        var starts = [TimeInterval](repeating: 0, count: count + 1)
        for i in 0..<count { starts[i + 1] = starts[i] + delays[i] }
        self.width = width
        self.height = height
        self.delays = delays
        self.starts = starts
    }

    /// Index of the frame on screen at `time` (clamped to the GIF).
    func frame(at time: TimeInterval) -> Int {
        // Largest i with starts[i] <= time.
        var lo = 0, hi = frameCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The frame boundary (0...frameCount) closest to `time`.
    func nearestBoundary(to time: TimeInterval) -> Int {
        let i = frame(at: time)
        return time - starts[i] < starts[i + 1] - time ? i : i + 1
    }
}

/// Cuts a GIF down to a range of its frames by re-encoding them.
enum GIFTrimmer {
    enum TrimError: Error, LocalizedError {
        case unreadable
        case badFrame(Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The recording could not be read."
            case .badFrame(let i): return "Frame \(i + 1) of the recording could not be decoded."
            }
        }
    }

    /// Re-encodes frames `range` of `source` into a new GIF at `output`, keeping their delays.
    /// Returns the new duration. Removes `output` on failure.
    @discardableResult
    static func trim(_ source: URL, timeline: GIFTimeline, frames range: ClosedRange<Int>, to output: URL,
                     progress: ((Double) -> Void)? = nil) throws -> TimeInterval {
        precondition(range.lowerBound >= 0 && range.upperBound < timeline.frameCount)
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw TrimError.unreadable }
        let renderer = try BGRARenderer(width: timeline.width, height: timeline.height)
        let encoder = try GIFEncoder(url: output, width: timeline.width, height: timeline.height)
        let origin = timeline.starts[range.lowerBound]
        let duration = timeline.starts[range.upperBound + 1] - origin
        do {
            for i in range {
                try autoreleasepool {
                    guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { throw TrimError.badFrame(i) }
                    try encoder.addFrame(renderer.render(image), at: timeline.starts[i] - origin)
                }
                progress?(Double(i - range.lowerBound + 1) / Double(range.count))
            }
            try encoder.finish(at: duration)
        } catch {
            try? encoder.finish(at: 0)
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return duration
    }

    /// Puts a reviewed recording at `destination` (or the next free name beside it) and removes `source`.
    /// With a `cut`, only those frames are kept (re-encoded); otherwise the file is moved as is.
    static func save(_ source: URL, to destination: URL, cut: (timeline: GIFTimeline, frames: ClosedRange<Int>)?,
                     untrimmedDuration: TimeInterval, progress: ((Double) -> Void)? = nil) throws -> SavedRecording {
        let fm = FileManager.default
        let saved: URL
        let duration: TimeInterval
        if let cut, cut.frames != 0...(cut.timeline.frameCount - 1) {
            // Encode next to the destination (same volume), then move into place in one step.
            let folder = destination.deletingLastPathComponent()
            let scratch = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                       appropriateFor: folder, create: true))
                ?? fm.temporaryDirectory.appendingPathComponent("QuickGif-\(UUID().uuidString)")
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            let trimmed = scratch.appendingPathComponent(destination.lastPathComponent)
            duration = try trim(source, timeline: cut.timeline, frames: cut.frames, to: trimmed, progress: progress)
            saved = destination.deduplicated()
            try fm.moveItem(at: trimmed, to: saved)
            try? fm.removeItem(at: source)
        } else {
            saved = destination.deduplicated()
            try fm.moveItem(at: source, to: saved)
            duration = cut?.timeline.duration ?? untrimmedDuration
            progress?(1)
        }
        let size = (try? fm.attributesOfItem(atPath: saved.path)[.size] as? Int) ?? 0
        return SavedRecording(url: saved, byteCount: size, duration: duration)
    }
}

/// Draws images into one reusable 32-bit BGRA bitmap (sRGB, premultiplied first,
/// little-endian), the layout `FrameBuffer` and the encoder expect.
final class BGRARenderer {
    let width: Int
    let height: Int
    private let context: CGContext
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: BGRARenderer.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw GIFTrimmer.TrimError.unreadable }
        context.interpolationQuality = .none
        self.width = width
        self.height = height
        self.context = context
    }

    func render(_ image: CGImage) -> FrameBuffer {
        // GIF pixel values are stored as is; tag them sRGB so drawing does no color conversion.
        let tagged = image.copy(colorSpace: BGRARenderer.sRGB) ?? image
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(rect)
        context.draw(tagged, in: rect)
        let bytesPerRow = context.bytesPerRow
        let data = Data(bytes: context.data!, count: bytesPerRow * height)
        return FrameBuffer(width: width, height: height, bytesPerRow: bytesPerRow, pixels: data)
    }
}
