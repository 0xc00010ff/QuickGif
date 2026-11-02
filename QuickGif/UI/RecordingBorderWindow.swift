import AppKit

/// Click-through frame drawn just outside the recorded region.
final class RecordingBorderWindow: NSWindow {
    private static let lineWidth: CGFloat = 2
    private let borderView = BorderView()

    init(around rect: CGRect) {
        let w = Self.lineWidth
        super.init(contentRect: rect.insetBy(dx: -w, dy: -w), styleMask: .borderless, backing: .buffered, defer: false)
        configureAsOverlay()
        ignoresMouseEvents = true
        borderView.lineWidth = w
        contentView = borderView
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    var isPaused = false {
        didSet { borderView.color = isPaused ? Self.pausedColor : Self.recordingColor }
    }

    private static let recordingColor = NSColor.systemRed.withAlphaComponent(0.85)
    private static let pausedColor = NSColor.systemOrange.withAlphaComponent(0.85)

    private final class BorderView: NSView {
        var lineWidth: CGFloat = 2
        var color = RecordingBorderWindow.recordingColor { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.clear.setFill()
            dirtyRect.fill(using: .copy)
            let path = NSBezierPath(rect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()
        }
    }
}
