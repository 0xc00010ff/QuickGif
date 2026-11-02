import Foundation

/// Streaming animated-GIF (GIF89a) writer.
///
/// Usage: create with the output URL and frame size, call `addFrame(_:at:)` for every
/// captured frame in increasing time order, then `finish(at:)`. Not thread-safe:
/// call every method from the same serial queue.
///
/// Timing model: a frame is displayed from its own `time` until the next frame's
/// `time`, so each frame is written once the next differing frame arrives (or at
/// `finish`). Identical consecutive frames are coalesced (the previous frame simply
/// stays on screen longer), so callers can feed frames at a fixed rate without
/// bloating the file. Delays are rounded to centiseconds with error carry, so the
/// total duration stays within 1 cs of the real one.
///
/// Each frame after the first stores only the rectangle that changed, with unchanged
/// pixels inside it written as transparent (disposal "do not dispose"). Colors are
/// exact whenever a sub-image has at most 255 distinct colors; otherwise they are
/// reduced with median cut. Output streams to disk frame by frame, so memory stays
/// flat regardless of recording length.
///
/// Hot loops use `while` and raw pointers on purpose: range-based `for` loops are
/// roughly 20x slower in unoptimized (Debug) builds.
final class GIFEncoder {
    struct Stats {
        var frameCount: Int = 0
        var bytesWritten: Int = 0
    }

    enum EncoderError: Error, LocalizedError {
        case frameSizeMismatch
        case cannotCreateFile
        case writeFailed
        case noFrames
        var errorDescription: String? {
            switch self {
            case .frameSizeMismatch: return "Frame size does not match the GIF size."
            case .cannotCreateFile: return "Could not create the GIF file."
            case .writeFailed: return "Writing the GIF failed."
            case .noFrames: return "No frames were recorded."
            }
        }
    }

    let url: URL
    let width: Int
    let height: Int
    let loopForever: Bool
    private(set) var stats = Stats()

    // Output
    private var handle: FileHandle?
    private var out: [UInt8] = []
    private var finished = false

    // Pixels, packed 0x00RRGGBB, `width` per row with no padding.
    private var canvas: [UInt32]      // last accepted frame: what the GIF currently shows
    private var incoming: [UInt32]    // frame being examined
    private var hasCanvas = false

    // The last accepted frame, already encoded, waiting for its duration.
    private var pendingImage: [UInt8] = []
    private var pendingTransparent = -1
    private var pendingTime: TimeInterval = 0
    private var hasPending = false
    private var previousInterval: TimeInterval?

    // Timing
    private var lastTime: TimeInterval?
    private var startTime: TimeInterval = 0
    private var emittedCs = 0

    // Global color table (set by the first frame). Index 0 is reserved for transparency
    // when `globalTransparent == 0`.
    private var globalMap = ColorMap(capacity: 1024)
    private var globalTransparent = -1

    // Working buffers, reused between frames.
    private var indices: [UInt8] = []
    private var lzwRaw: [UInt8] = []
    private var localMap = ColorMap(capacity: 1024)
    private var palette: [UInt32] = []
    private let lzw = LZWEncoder()
    private let quantizer = MedianCutQuantizer()

    init(url: URL, width: Int, height: Int, loopForever: Bool = true) throws {
        precondition(width > 0 && height > 0 && width <= 65535 && height <= 65535)
        self.url = url
        self.width = width
        self.height = height
        self.loopForever = loopForever
        canvas = [UInt32](repeating: 0, count: width * height)
        incoming = [UInt32](repeating: 0, count: width * height)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url)
        else { throw EncoderError.cannotCreateFile }
        handle = h
        out.reserveCapacity(1 << 16)
    }

    deinit {
        try? handle?.close()
    }

    func addFrame(_ frame: FrameBuffer, at time: TimeInterval) throws {
        guard !finished else { throw EncoderError.writeFailed }
        guard frame.width == width, frame.height == height else { throw EncoderError.frameSizeMismatch }

        var t = time
        if let last = lastTime, !(t > last) { t = last + 0.001 }
        lastTime = t

        loadPixels(frame)

        let rect: Rect
        if hasCanvas {
            guard let r = changedRect() else { return }   // identical: coalesce
            rect = r
        } else {
            rect = Rect(x: 0, y: 0, w: width, h: height)
            startTime = t
        }

        if hasPending {
            previousInterval = t - pendingTime
            try writePending(until: t)
        }

        encode(rect: rect, first: !hasCanvas)
        if out.count > 0 { try flush() }   // header on the first frame
        pendingTime = t
        hasPending = true

        swap(&canvas, &incoming)
        hasCanvas = true
    }

    func finish(at endTime: TimeInterval? = nil) throws {
        guard !finished else { return }
        finished = true
        guard hasPending else {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
            throw EncoderError.noFrames
        }
        var end: TimeInterval
        if let e = endTime, e > pendingTime {
            end = e
        } else {
            end = pendingTime + (previousInterval ?? 0.1)
        }
        if !(end > pendingTime) { end = pendingTime + 0.1 }
        try writePending(until: end)
        out.append(0x3B)
        try flush()
        do { try handle?.close() } catch { throw EncoderError.writeFailed }
        handle = nil
        hasPending = false
        pendingImage = []
    }

    // MARK: - Frame intake

    private struct Rect { var x, y, w, h: Int }

    private func loadPixels(_ frame: FrameBuffer) {
        let w = width, h = height, bpr = frame.bytesPerRow
        frame.pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let base = src.baseAddress!
            incoming.withUnsafeMutableBufferPointer { dst in
                let d = dst.baseAddress!
                var y = 0
                while y < h {
                    memcpy(d + y * w, base + y * bpr, w * 4)
                    y += 1
                }
                // Memory order B,G,R,A loads little-endian as 0xAARRGGBB; drop alpha.
                var i = 0
                let n = w * h
                while i < n {
                    d[i] &= 0x00FF_FFFF
                    i &+= 1
                }
            }
        }
    }

    /// Bounding rectangle of pixels that differ between `incoming` and `canvas`, or nil.
    private func changedRect() -> Rect? {
        let w = width, h = height
        return incoming.withUnsafeBufferPointer { a in
            canvas.withUnsafeBufferPointer { b in
                let pa = a.baseAddress!, pb = b.baseAddress!
                let rowBytes = w * 4
                var minY = 0
                while minY < h && memcmp(pa + minY * w, pb + minY * w, rowBytes) == 0 { minY += 1 }
                if minY == h { return nil }
                var maxY = minY
                var y = h - 1
                while y > minY {
                    if memcmp(pa + y * w, pb + y * w, rowBytes) != 0 { maxY = y; break }
                    y -= 1
                }
                var minX = w, maxX = -1
                y = minY
                while y <= maxY {
                    let ra = pa + y * w, rb = pb + y * w
                    y += 1
                    var x = 0
                    while x < minX {
                        if ra[x] != rb[x] { minX = x; break }
                        x += 1
                    }
                    x = w - 1
                    while x > maxX {
                        if ra[x] != rb[x] { maxX = x; break }
                        x -= 1
                    }
                }
                return Rect(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1)
            }
        }
    }

    // MARK: - Writing

    private func flush() throws {
        guard let handle else { throw EncoderError.writeFailed }
        do { try handle.write(contentsOf: out) } catch { throw EncoderError.writeFailed }
        stats.bytesWritten += out.count
        out.removeAll(keepingCapacity: true)
    }

    private func writePending(until end: TimeInterval) throws {
        // Error-carrying rounding against the absolute timeline.
        let target = Int(((end - startTime) * 100).rounded())
        let delay = min(65535, max(2, target - emittedCs))
        emittedCs += delay

        out.append(contentsOf: [0x21, 0xF9, 0x04])
        out.append(UInt8(1 << 2) | (pendingTransparent >= 0 ? 1 : 0))   // disposal 1: do not dispose
        appendLE16(delay)
        out.append(UInt8(max(0, pendingTransparent)))
        out.append(0x00)
        out.append(contentsOf: pendingImage)
        try flush()
        stats.frameCount += 1
    }

    private func appendLE16(_ v: Int, to buf: inout [UInt8]) {
        buf.append(UInt8(truncatingIfNeeded: v))
        buf.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    private func appendLE16(_ v: Int) { appendLE16(v, to: &out) }

    private static func tableBits(_ entries: Int) -> Int {
        var bits = 1
        while (1 << bits) < entries { bits += 1 }
        return bits
    }

    private static func appendTable(_ colors: [UInt32], bits: Int, to buf: inout [UInt8]) {
        let size = 1 << bits
        for i in 0..<size {
            let c = i < colors.count ? colors[i] : 0
            buf.append(UInt8(truncatingIfNeeded: c >> 16))
            buf.append(UInt8(truncatingIfNeeded: c >> 8))
            buf.append(UInt8(truncatingIfNeeded: c))
        }
    }

    // MARK: - Encoding one frame

    /// Encodes `incoming` restricted to `rect` into `pendingImage` (image descriptor,
    /// optional local table and LZW data). On the first frame also writes the file header.
    private func encode(rect: Rect, first: Bool) {
        let count = rect.w * rect.h
        if indices.count < count { indices = [UInt8](repeating: 0, count: count) }

        var useGlobal = false
        var transparent = -1

        // 1. Every changed color already in the global table.
        if !first, globalTransparent >= 0, mapWithGlobal(rect: rect) {
            useGlobal = true
            transparent = globalTransparent
        }

        // 2. Exact local palette. Index 0 is the transparent slot.
        if !useGlobal {
            if exactPalette(rect: rect, masked: !first, base: 1) {
                transparent = 0
            } else if first, exactPalette(rect: rect, masked: false, base: 0) {
                transparent = -1   // exactly 256 colors: no free slot
            } else {
                // 3. Too many colors: median cut to 255 with index 0 transparent.
                quantize(rect: rect, masked: !first)
                transparent = 0
            }
        }

        if first {
            writeHeader(globalColors: palette, transparent: transparent)
            useGlobal = true
            transparent = -1   // nothing is transparent in the first frame
        }

        pendingTransparent = transparent
        pendingImage.removeAll(keepingCapacity: true)
        pendingImage.append(0x2C)
        appendLE16(rect.x, to: &pendingImage)
        appendLE16(rect.y, to: &pendingImage)
        appendLE16(rect.w, to: &pendingImage)
        appendLE16(rect.h, to: &pendingImage)

        let bits: Int
        if useGlobal {
            bits = globalBits
            pendingImage.append(0x00)
        } else {
            bits = Self.tableBits(palette.count)
            pendingImage.append(0x80 | UInt8(bits - 1))
            Self.appendTable(palette, bits: bits, to: &pendingImage)
        }
        let minCodeSize = max(2, bits)
        pendingImage.append(UInt8(minCodeSize))

        let maxRaw = count * 2 + 64
        if lzwRaw.count < maxRaw { lzwRaw = [UInt8](repeating: 0, count: maxRaw) }
        let rawLen = indices.withUnsafeBufferPointer { idx in
            lzwRaw.withUnsafeMutableBufferPointer { raw in
                lzw.encode(idx.baseAddress!, count: count, minCodeSize: minCodeSize, into: raw.baseAddress!)
            }
        }
        lzwRaw.withUnsafeBufferPointer { raw in
            var pos = 0
            while pos < rawLen {
                let n = min(255, rawLen - pos)
                pendingImage.append(UInt8(n))
                pendingImage.append(contentsOf: UnsafeBufferPointer(rebasing: raw[pos..<(pos + n)]))
                pos += n
            }
        }
        pendingImage.append(0x00)
    }

    private var globalBits = 1

    private func writeHeader(globalColors: [UInt32], transparent: Int) {
        globalTransparent = transparent
        globalMap.clear()
        for (i, c) in globalColors.enumerated() where !(transparent == i) {
            globalMap.insert(c, UInt8(i))
        }
        globalBits = Self.tableBits(globalColors.count)

        out.append(contentsOf: Array("GIF89a".utf8))
        appendLE16(width)
        appendLE16(height)
        out.append(0x80 | (7 << 4) | UInt8(globalBits - 1))
        out.append(0)   // background color index
        out.append(0)   // pixel aspect ratio
        Self.appendTable(globalColors, bits: globalBits, to: &out)
        if loopForever {
            out.append(contentsOf: [0x21, 0xFF, 0x0B])
            out.append(contentsOf: Array("NETSCAPE2.0".utf8))
            out.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        }
        // Play once: no Netscape extension (a loop count of 1 makes some browsers play twice).
    }

    /// Maps the changed pixels of `rect` through the global table. False on any miss.
    private func mapWithGlobal(rect: Rect) -> Bool {
        let w = width
        let trans = UInt8(globalTransparent)
        return incoming.withUnsafeBufferPointer { cur in
            canvas.withUnsafeBufferPointer { prev in
                indices.withUnsafeMutableBufferPointer { idx in
                    globalMap.withPointers { keys, vals, mask in
                        let pc = cur.baseAddress!, pp = prev.baseAddress!, pi = idx.baseAddress!
                        var o = 0
                        var lastColor: UInt32 = 0xFFFF_FFFF
                        var lastIndex: UInt8 = 0
                        var y = rect.y
                        let yEnd = rect.y + rect.h, xEnd = rect.x + rect.w
                        while y < yEnd {
                            let rc = pc + y * w, rp = pp + y * w
                            y += 1
                            var x = rect.x
                            while x < xEnd {
                                let c = rc[x]
                                let unchanged = c == rp[x]
                                x &+= 1
                                if unchanged {
                                    pi[o] = trans
                                } else if c == lastColor {
                                    pi[o] = lastIndex
                                } else {
                                    guard let v = ColorMap.find(c, keys, vals, mask) else { return false }
                                    lastColor = c; lastIndex = v
                                    pi[o] = v
                                }
                                o &+= 1
                            }
                        }
                        return true
                    }
                }
            }
        }
    }

    /// Builds an exact palette (into `palette`, colors starting at index `base`) and
    /// indices. With `masked`, unchanged pixels become index 0. False when the colors
    /// do not fit in 256 - base entries.
    private func exactPalette(rect: Rect, masked: Bool, base: Int) -> Bool {
        let w = width
        let limit = 256 - base
        localMap.clear()
        palette.removeAll(keepingCapacity: true)
        if base == 1 { palette.append(0) }
        var colorCount = 0
        let ok: Bool = incoming.withUnsafeBufferPointer { cur in
            canvas.withUnsafeBufferPointer { prev in
                indices.withUnsafeMutableBufferPointer { idx in
                    localMap.withPointers { keys, vals, mask in
                        let pc = cur.baseAddress!, pp = prev.baseAddress!, pi = idx.baseAddress!
                        var o = 0
                        var lastColor: UInt32 = 0xFFFF_FFFF
                        var lastIndex: UInt8 = 0
                        var y = rect.y
                        let yEnd = rect.y + rect.h, xEnd = rect.x + rect.w
                        while y < yEnd {
                            let rc = pc + y * w, rp = pp + y * w
                            y += 1
                            var x = rect.x
                            while x < xEnd {
                                let c = rc[x]
                                let unchanged = masked && c == rp[x]
                                x &+= 1
                                if unchanged {
                                    pi[o] = 0
                                } else if c == lastColor {
                                    pi[o] = lastIndex
                                } else {
                                    var v: UInt8
                                    if let found = ColorMap.find(c, keys, vals, mask) {
                                        v = found
                                    } else {
                                        if colorCount == limit { return false }
                                        v = UInt8(colorCount + base)
                                        ColorMap.insert(c, v, keys, vals, mask)
                                        colorCount += 1
                                        palette.append(c)
                                    }
                                    lastColor = c; lastIndex = v
                                    pi[o] = v
                                }
                                o &+= 1
                            }
                        }
                        return true
                    }
                }
            }
        }
        if !ok { return false }
        if palette.isEmpty { palette.append(0) }
        return true
    }

    /// Median-cut reduction of the changed pixels of `rect` to 255 colors at indices 1...255.
    private func quantize(rect: Rect, masked: Bool) {
        palette.removeAll(keepingCapacity: true)
        palette.append(0)
        incoming.withUnsafeBufferPointer { cur in
            canvas.withUnsafeBufferPointer { prev in
                indices.withUnsafeMutableBufferPointer { idx in
                    quantizer.run(cur: cur.baseAddress!, prev: prev.baseAddress!, stride: width,
                                  x0: rect.x, y0: rect.y, w: rect.w, h: rect.h, masked: masked,
                                  maxColors: 255, palette: &palette, indices: idx.baseAddress!)
                }
            }
        }
    }
}

// MARK: - Color hash map (UInt32 color -> UInt8 index)

private struct ColorMap {
    private static let empty: UInt32 = 0xFFFF_FFFF
    private var keys: [UInt32]
    private var vals: [UInt8]
    private let mask: Int

    init(capacity: Int) {
        keys = [UInt32](repeating: Self.empty, count: capacity)
        vals = [UInt8](repeating: 0, count: capacity)
        mask = capacity - 1
    }

    mutating func clear() {
        keys.withUnsafeMutableBufferPointer { $0.update(repeating: Self.empty) }
    }

    mutating func insert(_ c: UInt32, _ v: UInt8) {
        let m = mask
        keys.withUnsafeMutableBufferPointer { k in
            vals.withUnsafeMutableBufferPointer { vv in
                Self.insert(c, v, k.baseAddress!, vv.baseAddress!, m)
            }
        }
    }

    mutating func withPointers<R>(_ body: (UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt8>, Int) -> R) -> R {
        let m = mask
        return keys.withUnsafeMutableBufferPointer { k in
            vals.withUnsafeMutableBufferPointer { v in body(k.baseAddress!, v.baseAddress!, m) }
        }
    }

    @inline(__always) static func slot(_ c: UInt32, _ mask: Int) -> Int {
        Int(truncatingIfNeeded: (c &* 0x9E37_79B1) >> 16) & mask
    }

    @inline(__always) static func find(_ c: UInt32, _ keys: UnsafeMutablePointer<UInt32>,
                                       _ vals: UnsafeMutablePointer<UInt8>, _ mask: Int) -> UInt8? {
        var s = slot(c, mask)
        while true {
            let k = keys[s]
            if k == c { return vals[s] }
            if k == empty { return nil }
            s = (s + 1) & mask
        }
    }

    @inline(__always) static func insert(_ c: UInt32, _ v: UInt8, _ keys: UnsafeMutablePointer<UInt32>,
                                         _ vals: UnsafeMutablePointer<UInt8>, _ mask: Int) {
        var s = slot(c, mask)
        while keys[s] != empty && keys[s] != c { s = (s + 1) & mask }
        keys[s] = c
        vals[s] = v
    }
}

// MARK: - Median cut

private final class MedianCutQuantizer {
    // Histogram at 5 bits per channel; 4 UInt32 per bucket: count, sum R, sum G, sum B.
    private var hist = [UInt32](repeating: 0, count: 32768 * 4)
    private var buckets: [Int32] = []
    // Palette index of the box each bucket ended up in, then the nearest palette
    // index to each bucket's mean color.
    private var boxOf = [UInt8](repeating: 0, count: 32768)

    private struct Box {
        var start: Int, end: Int
        var count: UInt64
        var lo: (Int, Int, Int), hi: (Int, Int, Int)
    }

    @inline(__always) private static func bucket(_ c: UInt32) -> Int {
        let r: UInt32 = (c >> 9) & 0x7C00
        let g: UInt32 = (c >> 6) & 0x03E0
        let b: UInt32 = (c >> 3) & 0x001F
        return Int(r | g | b)
    }

    /// Appends up to `maxColors` colors to `palette` (after its existing entries) and
    /// writes palette indices for the rect, with 0 for unchanged pixels when `masked`.
    func run(cur: UnsafePointer<UInt32>, prev: UnsafePointer<UInt32>, stride: Int,
             x0: Int, y0: Int, w: Int, h: Int, masked: Bool, maxColors: Int,
             palette: inout [UInt32], indices: UnsafeMutablePointer<UInt8>) {
        hist.withUnsafeMutableBufferPointer { hb in
            hb.update(repeating: 0)
            let p = hb.baseAddress!
            var y = y0
            let yEnd = y0 + h, xEnd = x0 + w
            while y < yEnd {
                let rc = cur + y * stride, rp = prev + y * stride
                y += 1
                var x = x0
                while x < xEnd {
                    let c = rc[x]
                    let unchanged = masked && c == rp[x]
                    x &+= 1
                    if unchanged { continue }
                    let br: UInt32 = (c >> 9) & 0x7C00
                    let bg: UInt32 = (c >> 6) & 0x03E0
                    let bb: UInt32 = (c >> 3) & 0x001F
                    let q = p + (Int(br | bg | bb) &<< 2)
                    q[0] &+= 1
                    q[1] &+= (c >> 16) & 0xFF
                    q[2] &+= (c >> 8) & 0xFF
                    q[3] &+= c & 0xFF
                }
            }
        }

        buckets.removeAll(keepingCapacity: true)
        hist.withUnsafeBufferPointer { hb in
            var i = 0
            while i < 32768 {
                if hb[i &<< 2] != 0 { buckets.append(Int32(i)) }
                i &+= 1
            }
        }

        var boxes: [Box] = []
        boxes.reserveCapacity(maxColors)
        if !buckets.isEmpty {
            boxes.append(makeBox(0, buckets.count))
            while boxes.count < maxColors {
                var best = -1
                var bestScore: Double = 0
                var i = 0
                while i < boxes.count {
                    let b = boxes[i]
                    if b.end - b.start > 1 {
                        let range = max(b.hi.0 - b.lo.0, b.hi.1 - b.lo.1, b.hi.2 - b.lo.2)
                        let score = Double(b.count) * Double(range + 1)
                        if score > bestScore { bestScore = score; best = i }
                    }
                    i += 1
                }
                if best < 0 { break }
                let (a, b) = split(boxes[best])
                boxes[best] = a
                boxes.append(b)
            }
        }

        let first = palette.count
        for b in boxes {
            var r: UInt64 = 0, g: UInt64 = 0, bl: UInt64 = 0
            let index = UInt8(palette.count)
            buckets.withUnsafeBufferPointer { bk in
                hist.withUnsafeBufferPointer { hb in
                    boxOf.withUnsafeMutableBufferPointer { bo in
                        var i = b.start
                        while i < b.end {
                            let k = Int(bk[i])
                            i &+= 1
                            r &+= UInt64(hb[k &<< 2 &+ 1]); g &+= UInt64(hb[k &<< 2 &+ 2]); bl &+= UInt64(hb[k &<< 2 &+ 3])
                            bo[k] = index
                        }
                    }
                }
            }
            let n = max(b.count, 1)
            let pr = UInt32((r + n / 2) / n), pg = UInt32((g + n / 2) / n), pb = UInt32((bl + n / 2) / n)
            palette.append(pr << 16 | pg << 8 | pb)
        }

        // New palette entries sorted by green for the nearest-color search.
        var order = Array(first..<palette.count)
        order.sort { (palette[$0] >> 8) & 0xFF < (palette[$1] >> 8) & 0xFF }
        var sr = [Int32](), sg = [Int32](), sb = [Int32](), si = [UInt8]()
        for i in order {
            let c = palette[i]
            sr.append(Int32((c >> 16) & 0xFF)); sg.append(Int32((c >> 8) & 0xFF)); sb.append(Int32(c & 0xFF))
            si.append(UInt8(i))
        }
        let pal = palette

        // Nearest palette color to each occupied bucket's mean color (seeded with the
        // bucket's median-cut box so the search prunes quickly), then map every pixel
        // through its bucket.
        boxOf.withUnsafeMutableBufferPointer { bo in
            hist.withUnsafeBufferPointer { hb in
                pal.withUnsafeBufferPointer { pp in
                    sr.withUnsafeBufferPointer { pr in
                        sg.withUnsafeBufferPointer { pg in
                            sb.withUnsafeBufferPointer { pb in
                                si.withUnsafeBufferPointer { pi in
                                    var bi = 0
                                    let bn = buckets.count
                                    while bi < bn {
                                        let k = Int(buckets[bi])
                                        bi &+= 1
                                        let n = hb[k &<< 2]
                                        let half = n / 2
                                        let mr = (hb[(k &<< 2) + 1] + half) / n
                                        let mg = (hb[(k &<< 2) + 2] + half) / n
                                        let mb = (hb[(k &<< 2) + 3] + half) / n
                                        let seed = bo[k]
                                        bo[k] = Self.nearest(mr << 16 | mg << 8 | mb, seed: seed,
                                                             seedColor: pp[Int(seed)], pr, pg, pb, pi)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let lut = UnsafePointer(bo.baseAddress!)
            var o = 0
            var y = y0
            let yEnd = y0 + h, xEnd = x0 + w
            while y < yEnd {
                let rc = cur + y * stride, rp = prev + y * stride
                y += 1
                var x = x0
                while x < xEnd {
                    let c = rc[x]
                    if masked && c == rp[x] {
                        indices[o] = 0
                    } else {
                        let br: UInt32 = (c >> 9) & 0x7C00
                        let bg: UInt32 = (c >> 6) & 0x03E0
                        let bb: UInt32 = (c >> 3) & 0x001F
                        indices[o] = lut[Int(br | bg | bb)]
                    }
                    x &+= 1
                    o &+= 1
                }
            }
        }
    }

    @inline(__always)
    private static func nearest(_ c: UInt32, seed: UInt8, seedColor: UInt32,
                                _ pr: UnsafeBufferPointer<Int32>, _ pg: UnsafeBufferPointer<Int32>,
                                _ pb: UnsafeBufferPointer<Int32>, _ pi: UnsafeBufferPointer<UInt8>) -> UInt8 {
        let r = Int32((c >> 16) & 0xFF), g = Int32((c >> 8) & 0xFF), b = Int32(c & 0xFF)
        let n = pg.count
        let sr = Int32((seedColor >> 16) & 0xFF) - r
        let sg = Int32((seedColor >> 8) & 0xFF) - g
        let sb = Int32(seedColor & 0xFF) - b
        var best = sr * sr + sg * sg + sb * sb
        var bestIndex = seed
        if best == 0 || n == 0 { return bestIndex }
        var lo = 0, hi = n
        while lo < hi {
            let mid = (lo + hi) >> 1
            if pg[mid] < g { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < n {
            let dg = pg[i] - g
            let dg2 = dg * dg
            if dg2 >= best { break }
            let dr = pr[i] - r, db = pb[i] - b
            let d = dr * dr + dg2 + db * db
            if d < best { best = d; bestIndex = pi[i] }
            i += 1
        }
        var j = lo - 1
        while j >= 0 {
            let dg = pg[j] - g
            let dg2 = dg * dg
            if dg2 >= best { break }
            let dr = pr[j] - r, db = pb[j] - b
            let d = dr * dr + dg2 + db * db
            if d < best { best = d; bestIndex = pi[j] }
            j -= 1
        }
        return bestIndex
    }

    @inline(__always) private static func components(_ k: Int32) -> (Int, Int, Int) {
        (Int(k >> 10) & 31, Int(k >> 5) & 31, Int(k) & 31)
    }

    private func makeBox(_ start: Int, _ end: Int) -> Box {
        var lo = (31, 31, 31), hi = (0, 0, 0)
        var n: UInt64 = 0
        buckets.withUnsafeBufferPointer { bk in
            hist.withUnsafeBufferPointer { hb in
                var i = start
                while i < end {
                    let k = bk[i]
                    i &+= 1
                    let (r, g, b) = Self.components(k)
                    lo = (min(lo.0, r), min(lo.1, g), min(lo.2, b))
                    hi = (max(hi.0, r), max(hi.1, g), max(hi.2, b))
                    n += UInt64(hb[Int(k) &<< 2])
                }
            }
        }
        return Box(start: start, end: end, count: n, lo: lo, hi: hi)
    }

    /// Splits a box at the pixel-weighted median of its longest axis (linear time).
    private func split(_ box: Box) -> (Box, Box) {
        let rr = box.hi.0 - box.lo.0, gr = box.hi.1 - box.lo.1, br = box.hi.2 - box.lo.2
        let shift: Int32
        let lo: Int, hi: Int
        if gr >= rr && gr >= br { shift = 5; lo = box.lo.1; hi = box.hi.1 }
        else if rr >= br { shift = 10; lo = box.lo.0; hi = box.hi.0 }
        else { shift = 0; lo = box.lo.2; hi = box.hi.2 }

        var cut = box.start
        buckets.withUnsafeMutableBufferPointer { bk in
            hist.withUnsafeBufferPointer { hb in
                var weight = [UInt64](repeating: 0, count: 32)
                var i = box.start
                while i < box.end {
                    let k = bk[i]
                    i &+= 1
                    weight[Int((k >> shift) & 31)] &+= UInt64(hb[Int(k) &<< 2])
                }
                // Smallest value v in lo..<hi whose cumulative weight reaches half.
                let half = box.count / 2
                var acc: UInt64 = 0
                var v = hi - 1
                for value in lo..<hi {
                    acc += weight[value]
                    if acc >= half { v = value; break }
                }
                // Partition: axis value <= v to the left. Both sides are non-empty
                // because lo <= v < hi.
                i = box.start
                var j = box.end - 1
                while i <= j {
                    if Int((bk[i] >> shift) & 31) <= v { i += 1 } else { bk.swapAt(i, j); j -= 1 }
                }
                cut = i
            }
        }
        return (makeBox(box.start, cut), makeBox(cut, box.end))
    }
}

// MARK: - LZW

/// Packs variable-width codes LSB-first.
private struct BitWriter {
    let out: UnsafeMutablePointer<UInt8>
    var count = 0
    var buffer: UInt64 = 0
    var bits: UInt64 = 0

    @inline(__always) mutating func put(_ code: Int, _ size: Int) {
        buffer |= UInt64(truncatingIfNeeded: code) << bits
        bits &+= UInt64(truncatingIfNeeded: size)
        while bits >= 8 {
            out[count] = UInt8(truncatingIfNeeded: buffer)
            count &+= 1
            buffer >>= 8
            bits &-= 8
        }
    }

    mutating func finish() {
        if bits > 0 {
            out[count] = UInt8(truncatingIfNeeded: buffer)
            count &+= 1
            buffer = 0
            bits = 0
        }
    }
}

/// GIF LZW: variable code size from minCodeSize + 1 up to 12 bits, a clear code
/// whenever the table fills, dictionary in an open-addressing hash of
/// (prefix code << 8 | byte) -> code.
private final class LZWEncoder {
    private static let tableBits: UInt32 = 13
    private static let tableSize = 1 << 13
    private var keys = [Int32](repeating: -1, count: tableSize)
    private var codes = [UInt16](repeating: 0, count: tableSize)

    /// Writes the raw (un-blocked) LZW code stream for `count` indices; returns its length.
    /// `outBuf` must hold at least `count * 2 + 64` bytes.
    func encode(_ input: UnsafePointer<UInt8>, count: Int, minCodeSize: Int, into outBuf: UnsafeMutablePointer<UInt8>) -> Int {
        keys.withUnsafeMutableBufferPointer { kb in
            codes.withUnsafeMutableBufferPointer { cb in
                let keys = kb.baseAddress!, codes = cb.baseAddress!
                let mask = Self.tableSize - 1
                let hashShift = 32 - Self.tableBits
                let clearCode = 1 << minCodeSize
                let eoiCode = clearCode + 1
                var codeSize = minCodeSize + 1
                var next = eoiCode + 1
                var writer = BitWriter(out: outBuf)
                var emittedSinceClear = false

                kb.update(repeating: -1)
                writer.put(clearCode, codeSize)
                guard count > 0 else {
                    writer.put(eoiCode, codeSize)
                    writer.finish()
                    return writer.count
                }

                var prefix = Int(input[0])
                var i = 1
                while i < count {
                    let k = Int(input[i])
                    i &+= 1
                    let key = Int32(truncatingIfNeeded: (prefix &<< 8) | k)
                    var s = Int(truncatingIfNeeded: (UInt32(bitPattern: key) &* 0x9E37_79B1) >> hashShift)
                    var found = false
                    while true {
                        let e = keys[s]
                        if e == key { prefix = Int(codes[s]); found = true; break }
                        if e < 0 { break }
                        s = (s &+ 1) & mask
                    }
                    if found { continue }

                    writer.put(prefix, codeSize)
                    emittedSinceClear = true
                    let code = next
                    keys[s] = key
                    codes[s] = UInt16(truncatingIfNeeded: code)
                    next &+= 1
                    if code >= (1 << codeSize) && codeSize < 12 { codeSize += 1 }
                    if code == 4095 {
                        writer.put(clearCode, codeSize)
                        kb.update(repeating: -1)
                        codeSize = minCodeSize + 1
                        next = eoiCode + 1
                        emittedSinceClear = false
                    }
                    prefix = k
                }
                writer.put(prefix, codeSize)
                // The decoder adds one more entry after reading the final code (unless it
                // was the first code after a clear), which can widen the code size.
                if emittedSinceClear && next >= (1 << codeSize) && codeSize < 12 { codeSize += 1 }
                writer.put(eoiCode, codeSize)
                writer.finish()
                return writer.count
            }
        }
    }
}
