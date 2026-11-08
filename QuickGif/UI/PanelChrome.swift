import AppKit
import SwiftUI

extension NSWindow.Level {
    /// Just above the screen-saver-level selection overlays, so clicking an overlay
    /// (which reorders it within its level) can never bury the options panel.
    static let overlayPanel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
}

extension NSWindow {
    /// Shared setup for QuickGif's transparent, always-on-top windows.
    func configureAsOverlay(level: NSWindow.Level = .screenSaver) {
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}

/// Hosting view that takes the first click even when its window is not key,
/// so buttons in non-activating panels respond immediately. It also shows the normal
/// arrow over itself: the selection crosshair belongs to the overlay alone.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    private var arrowArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let arrowArea { removeTrackingArea(arrowArea) }
        // `.activeAlways`: these panels are usually not key, where cursor rects don't apply.
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        arrowArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

/// Behind-window blur with rounded corners. A mask image (rather than a layer
/// corner radius) keeps the blur and the window shadow following the shape.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.maskImage = .roundedMask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension NSImage {
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

enum DurationText {
    /// "0:07", "12:34".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "3.4 s" for short clips, otherwise "1:05".
    static func summary(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: "%.1f s", seconds) : clock(seconds)
    }
}
