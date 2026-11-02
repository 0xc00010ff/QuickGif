import Foundation

/// One captured frame as 32-bit BGRA pixels.
///
/// Byte order in memory is B, G, R, A (this is `kCVPixelFormatType_32BGRA`, the
/// format ScreenCaptureKit delivers). Alpha is opaque for screen content.
/// `pixels.count` is at least `bytesPerRow * height`; rows may have padding, so
/// always index with `y * bytesPerRow + x * 4`.
struct FrameBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: Data

    init(width: Int, height: Int, bytesPerRow: Int, pixels: Data) {
        precondition(bytesPerRow >= width * 4)
        precondition(pixels.count >= bytesPerRow * height)
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }
}
