import CoreGraphics
import Foundation
import ImageIO

/// Decodes preview frames and strip thumbnails of a GIF on background queues.
///
/// Frames are made on demand and kept in a small cache (bounded by memory), so a long
/// recording is never decoded into memory whole. Requests replace each other: while
/// scrubbing, only the latest wanted frames get decoded.
final class ReviewFrameSource: @unchecked Sendable {
    /// Called on the main thread when a requested frame is ready.
    var onFrame: (@MainActor (Int, CGImage) -> Void)?

    private let url: URL
    private let source: CGImageSource
    private let maxPixelSize: Int
    private let capacity: Int
    private let queue = DispatchQueue(label: "QuickGif.review.frames", qos: .userInitiated)

    // Guarded by `lock`.
    private let lock = NSLock()
    private var cache: [Int: CGImage] = [:]
    private var recent: [Int] = []          // least recently used first
    private var wanted: [Int] = []
    private var draining = false

    /// `maxPixelSize` is the longest side preview frames need; larger frames are scaled down.
    init?(url: URL, timeline: GIFTimeline, maxPixelSize: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        self.url = url
        self.source = source
        let longest = max(timeline.width, timeline.height)
        self.maxPixelSize = min(longest, max(64, maxPixelSize))
        let scale = Double(self.maxPixelSize) / Double(longest)
        let frameBytes = max(1, Double(timeline.width * timeline.height * 4) * scale * scale)
        capacity = min(24, max(3, Int(160_000_000 / frameBytes)))
    }

    func cachedImage(at index: Int) -> CGImage? {
        lock.withLock {
            guard let image = cache[index] else { return nil }
            touch(index)
            return image
        }
    }

    /// Decodes `indices` in order (skipping cached ones), replacing any earlier request.
    func request(_ indices: [Int]) {
        let start: Bool = lock.withLock {
            wanted = indices.filter { cache[$0] == nil }
            guard !wanted.isEmpty, !draining else { return false }
            draining = true
            return true
        }
        if start { queue.async { [self] in drain() } }
    }

    /// Makes one thumbnail, at most `pixelHeight` tall, per frame index, off the main thread.
    func thumbnails(of indices: [Int], pixelHeight: Int, completion: @escaping @MainActor ([CGImage]) -> Void) {
        let url = self.url
        DispatchQueue.global(qos: .utility).async {
            // A separate source, so thumbnails never wait behind (or delay) preview frames.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return }
            var images: [CGImage] = []
            for index in indices {
                autoreleasepool {
                    guard let full = CGImageSourceCreateImageAtIndex(source, index, nil) else { return }
                    let scale = min(1, Double(pixelHeight) / Double(full.height))
                    if let image = Self.scaled(full, by: scale) { images.append(image) }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(images) } }
        }
    }

    // MARK: Decoding queue

    private func drain() {
        while true {
            let next: Int? = lock.withLock {
                while let first = wanted.first {
                    wanted.removeFirst()
                    if cache[first] == nil { return first }
                }
                draining = false
                return nil
            }
            guard let index = next else { return }
            guard let image = autoreleasepool(invoking: { decode(index) }) else { continue }
            lock.withLock {
                cache[index] = image
                touch(index)
                while recent.count > capacity { cache[recent.removeFirst()] = nil }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onFrame?(index, image) }
            }
        }
    }

    private func decode(_ index: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let full = CGImageSourceCreateImageAtIndex(source, index, options) else { return nil }
        let longest = max(full.width, full.height)
        guard longest > maxPixelSize else { return full }
        return Self.scaled(full, by: Double(maxPixelSize) / Double(longest))
    }

    /// Lock held.
    private func touch(_ index: Int) {
        if let i = recent.firstIndex(of: index) { recent.remove(at: i) }
        recent.append(index)
    }

    private static func scaled(_ image: CGImage, by scale: Double) -> CGImage? {
        guard scale < 1 else { return image }
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
