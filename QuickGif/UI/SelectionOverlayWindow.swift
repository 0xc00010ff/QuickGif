import AppKit

/// Borderless, screen-sized window that hosts a `SelectionView`. One per display.
final class SelectionOverlayWindow: NSWindow {
    let targetScreen: NSScreen
    /// The screen's frame when the overlay was created (Cocoa global coordinates).
    let screenFrame: CGRect
    let selectionView: SelectionView

    init(screen: NSScreen) {
        targetScreen = screen
        screenFrame = screen.frame
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        configureAsOverlay()
        acceptsMouseMovedEvents = true
        contentView = selectionView
        initialFirstResponder = selectionView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }

    // Borderless windows must be allowed to cover the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Converts a rect in the selection view to Cocoa global coordinates.
    func globalRect(fromView rect: CGRect) -> CGRect {
        rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
    }
}
