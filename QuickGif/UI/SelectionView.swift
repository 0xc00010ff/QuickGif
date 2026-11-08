import AppKit
import SwiftUI

@MainActor
protocol SelectionViewDelegate: AnyObject {
    /// The user started drawing a brand-new rectangle on this view's screen.
    func selectionViewDidBeginSelection(_ view: SelectionView)
    /// `selection` was created, moved, resized or discarded.
    func selectionViewDidChange(_ view: SelectionView)
    /// A plain click (no drag) anywhere on the overlay; the delegate starts if a selection exists.
    func selectionViewDidRequestStart(_ view: SelectionView)
}

/// Full-screen veil with a cut-out selection, Cmd-Shift-4 style.
/// Coordinates are the view's own (origin bottom-left of its screen, y up).
final class SelectionView: NSView {
    enum Mode { case selecting, countdown }

    weak var delegate: SelectionViewDelegate?

    var mode: Mode = .selecting {
        didSet {
            guard mode != oldValue else { return }
            drag = nil
            needsDisplay = true
            dirtyAreas = decorationAreas()
            updateHint()
        }
    }

    var showsHint = true {
        didSet { if showsHint != oldValue { refresh() } }
    }

    var selection: CGRect? {
        didSet { if selection != oldValue { refresh() } }
    }

    /// True while a brand-new rectangle is being dragged out.
    var isDrawingNewSelection: Bool {
        if case .creating(_, true)? = drag { return true }
        return false
    }

    private static let minimumSize: CGFloat = 16
    private static let handleSize: CGFloat = 7
    private static let veilColor = NSColor.white.withAlphaComponent(0.2)
    private static let pillColor = NSColor.black.withAlphaComponent(0.72)

    private enum Drag {
        case creating(anchor: NSPoint, started: Bool)
        case moving(start: NSPoint, original: CGRect, moved: Bool)
        case resizing(handle: Handle, start: NSPoint, original: CGRect)
    }

    private var drag: Drag?
    private var cursorPoint: NSPoint = .zero
    /// What was last drawn outside the plain veil, so it can be invalidated precisely.
    private var dirtyAreas: [NSRect] = []
    /// Centered prompt with the Select Entire Screen button; a real view so the button is clickable.
    private let hintView: FirstMouseHostingView<SelectionHintView>

    override init(frame: NSRect) {
        hintView = FirstMouseHostingView(rootView: SelectionHintView())
        super.init(frame: frame)
        hintView.rootView = SelectionHintView(onSelectEntireScreen: { [weak self] in self?.selectEntireScreen() })
        addSubview(hintView)
        positionHint()
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionHint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Whole screen

    /// Selects this screen's full bounds (the hint button, the panel button, Edit > Select All).
    func selectEntireScreen() {
        guard mode == .selecting else { return }
        drag = nil
        delegate?.selectionViewDidBeginSelection(self)
        selection = bounds
        delegate?.selectionViewDidChange(self)
        if let window { updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    override func selectAll(_ sender: Any?) { selectEntireScreen() }

    /// Discards the selection, back to the empty prompt.
    func clearSelection() {
        guard mode == .selecting, selection != nil else { return }
        drag = nil
        selection = nil
        delegate?.selectionViewDidChange(self)
        if let window { updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard mode == .selecting else { return }
        let p = clamped(convert(event.locationInWindow, from: nil))
        cursorPoint = p
        if let s = selection, let handle = Handle.at(p, in: s) {
            drag = .resizing(handle: handle, start: p, original: s)
        } else if let s = selection, s.contains(p) {
            drag = .moving(start: p, original: s, moved: false)
        } else {
            drag = .creating(anchor: p, started: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = clamped(convert(event.locationInWindow, from: nil))
        cursorPoint = p

        switch drag {
        case .creating(let anchor, let started):
            if !started {
                guard hypot(p.x - anchor.x, p.y - anchor.y) >= 2 else { return }
                self.drag = .creating(anchor: anchor, started: true)
                delegate?.selectionViewDidBeginSelection(self)
            }
            selection = NSRect(x: min(anchor.x, p.x).rounded(), y: min(anchor.y, p.y).rounded(),
                               width: abs(p.x - anchor.x).rounded(), height: abs(p.y - anchor.y).rounded())

        case .moving(let start, let original, let moved):
            let dx = p.x - start.x, dy = p.y - start.y
            if !moved {
                guard hypot(dx, dy) >= 3 else { return }
                self.drag = .moving(start: start, original: original, moved: true)
            }
            NSCursor.closedHand.set()
            var r = original.offsetBy(dx: dx.rounded(), dy: dy.rounded())
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
            selection = r

        case .resizing(let handle, let start, let original):
            selection = handle.resize(original, dx: (p.x - start.x).rounded(), dy: (p.y - start.y).rounded(),
                                      within: bounds, minimum: Self.minimumSize)
        }
        refresh() // the size label follows the cursor even when the rect is unchanged
        delegate?.selectionViewDidChange(self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .creating(_, let started):
            guard started else {
                // A plain click anywhere starts recording once a selection exists.
                delegate?.selectionViewDidRequestStart(self)
                return
            }
            if let s = selection, s.width < Self.minimumSize || s.height < Self.minimumSize {
                selection = nil
            }
        case .moving(_, _, let moved):
            if !moved {
                delegate?.selectionViewDidRequestStart(self)
                return
            }
        case .resizing:
            break
        }
        refresh()
        updateCursor(at: convert(event.locationInWindow, from: nil))
        delegate?.selectionViewDidChange(self)
    }

    // MARK: Cursor

    // The cursor follows the pointer through the tracking area (it works when the overlay
    // is not key, unlike cursor rects): crosshair only where a drag draws a new box.

    /// Sets the cursor for wherever the pointer is now.
    func refreshCursor() {
        guard let window else { return }
        updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at p: NSPoint) {
        guard mode == .selecting, drag == nil else { return }
        if !hintView.isHidden, hintView.frame.contains(p) {
            NSCursor.arrow.set()
        } else if let s = selection, let handle = Handle.at(p, in: s) {
            handle.cursor.set()
        } else if let s = selection, s.contains(p) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        if mode == .selecting {
            let veil = NSBezierPath(rect: bounds)
            if let s = selection { veil.appendRect(s) }
            veil.windingRule = .evenOdd
            Self.veilColor.setFill()
            veil.fill()
        }

        if let s = selection {
            drawBorder(s)
            if mode == .selecting, !isDrawingNewSelection { drawHandles(s) }
        }
        if let label = sizeLabelLayout() { label.draw() }
    }

    private func drawBorder(_ r: CGRect) {
        // Two-tone hairline reads on both light and dark content.
        let outer = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        outer.lineWidth = 1
        NSColor.white.withAlphaComponent(0.95).setStroke()
        outer.stroke()
        let inner = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        inner.lineWidth = 1
        NSColor.black.withAlphaComponent(0.5).setStroke()
        inner.stroke()
    }

    private func drawHandles(_ r: CGRect) {
        for handle in Handle.all {
            let c = handle.point(in: r)
            let size = Self.handleSize
            let square = NSRect(x: (c.x - size / 2).rounded(), y: (c.y - size / 2).rounded(), width: size, height: size)
            NSColor.white.setFill()
            square.fill()
            let outline = NSBezierPath(rect: square.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            NSColor.black.withAlphaComponent(0.55).setStroke()
            outline.stroke()
        }
    }

    // MARK: Labels

    private struct Pill {
        var frame: NSRect
        var lines: [NSAttributedString]
        var radius: CGFloat
        static let padding = NSSize(width: 12, height: 6)

        init(lines: [NSAttributedString], radius: CGFloat) {
            self.lines = lines
            self.radius = radius
            let width = lines.map { $0.size().width }.max() ?? 0
            let height = lines.reduce(0) { $0 + $1.size().height }
            frame = NSRect(x: 0, y: 0, width: ceil(width + Self.padding.width * 2), height: ceil(height + Self.padding.height * 2))
        }

        func draw() {
            SelectionView.pillColor.setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            var y = frame.maxY - Self.padding.height
            for line in lines {
                let size = line.size()
                y -= size.height
                line.draw(at: NSPoint(x: frame.midX - size.width / 2, y: y))
            }
        }
    }

    private func updateHint() {
        hintView.isHidden = !(mode == .selecting && showsHint && selection == nil)
    }

    private func positionHint() {
        let size = hintView.fittingSize
        hintView.frame = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                                width: ceil(size.width), height: ceil(size.height))
    }

    private func sizeLabelLayout() -> Pill? {
        guard let s = selection, let drag else { return nil }
        switch drag {
        case .creating(_, true), .resizing: break
        default: return nil
        }
        let text = NSAttributedString(string: "\(Int(s.width)) × \(Int(s.height))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ])
        var pill = Pill(lines: [text], radius: 5)
        let size = pill.frame.size
        // Below-right of the cursor, flipped to stay on screen.
        var x = cursorPoint.x + 14
        var y = cursorPoint.y - 14 - size.height
        if x + size.width > bounds.maxX { x = cursorPoint.x - 14 - size.width }
        if y < bounds.minY { y = cursorPoint.y + 14 }
        pill.frame.origin = NSPoint(x: x.rounded(), y: y.rounded())
        return pill
    }

    // MARK: Invalidation

    private func decorationAreas() -> [NSRect] {
        var areas: [NSRect] = []
        if let s = selection {
            let pad = Self.handleSize + 2
            areas.append(s.insetBy(dx: -pad, dy: -pad))
        }
        if let label = sizeLabelLayout() { areas.append(label.frame.insetBy(dx: -1, dy: -1)) }
        return areas
    }

    /// Redraws only what changed: the old and new selection/label areas.
    private func refresh() {
        updateHint()
        let areas = decorationAreas()
        for rect in dirtyAreas + areas { setNeedsDisplay(rect) }
        dirtyAreas = areas
    }

    private func clamped(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }
}

/// One of the eight resize handles. `x`/`y` are -1 (min edge), 0 (middle) or 1 (max edge).
private struct Handle {
    let x: Int
    let y: Int

    static let all: [Handle] = [
        Handle(x: -1, y: -1), Handle(x: 1, y: -1), Handle(x: -1, y: 1), Handle(x: 1, y: 1),
        Handle(x: 0, y: -1), Handle(x: 0, y: 1), Handle(x: -1, y: 0), Handle(x: 1, y: 0),
    ]

    @MainActor
    static func at(_ p: NSPoint, in r: CGRect) -> Handle? {
        let hit: CGFloat = 14
        return all.first { h in
            let c = h.point(in: r)
            return NSRect(x: c.x - hit / 2, y: c.y - hit / 2, width: hit, height: hit).contains(p)
        }
    }

    func point(in r: CGRect) -> NSPoint {
        NSPoint(x: x < 0 ? r.minX : (x == 0 ? r.midX : r.maxX),
                y: y < 0 ? r.minY : (y == 0 ? r.midY : r.maxY))
    }

    func resize(_ o: CGRect, dx: CGFloat, dy: CGFloat, within bounds: CGRect, minimum: CGFloat) -> CGRect {
        var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
        if x < 0 { minX = min(max(o.minX + dx, bounds.minX), maxX - minimum) }
        if x > 0 { maxX = max(min(o.maxX + dx, bounds.maxX), minX + minimum) }
        if y < 0 { minY = min(max(o.minY + dy, bounds.minY), maxY - minimum) }
        if y > 0 { maxY = max(min(o.maxY + dy, bounds.maxY), minY + minimum) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    @MainActor
    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (x, y) {
            case (-1, -1): position = .bottomLeft
            case (1, -1): position = .bottomRight
            case (-1, 1): position = .topLeft
            case (1, 1): position = .topRight
            case (0, -1): position = .bottom
            case (0, 1): position = .top
            case (-1, 0): position = .left
            default: position = .right
            }
            return .frameResize(position: position, directions: .all)
        }
        if x == 0 { return .resizeUpDown }
        if y == 0 { return .resizeLeftRight }
        return .crosshair
    }
}
