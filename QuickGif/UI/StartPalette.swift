import AppKit
import SwiftUI

/// Floating start toolbar, like the ⌘⇧5 screenshot bar. The Dock icon opens it, so the
/// page can be set up before the selection overlay takes over the screen. It floats above
/// other apps while they are used; clicking it activates QuickGif so the overlay gets the keyboard.
final class StartPalette: NSPanel {
    var onSelectArea: () -> Void = {}
    var onEntireScreen: () -> Void = {}
    var onClose: () -> Void = {}

    private static let autosaveName = "QuickGif.StartPalette"

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)

        let view = StartPaletteView(
            selectArea: { [weak self] in self?.onSelectArea() },
            entireScreen: { [weak self] in self?.onEntireScreen() },
            close: { [weak self] in self?.onClose() }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        contentView = hosting
        setContentSize(hosting.fittingSize)

        // Where the user last dragged it; otherwise bottom center, above the Dock.
        if !setFrameUsingName(Self.autosaveName) { placeDefault() }
        setFrameAutosaveName(Self.autosaveName)
    }

    override var canBecomeKey: Bool { true }

    /// Esc closes the palette.
    override func cancelOperation(_ sender: Any?) { onClose() }

    func present() {
        // A saved spot on a display that is gone would leave it unreachable.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { placeDefault() }
        orderFrontRegardless()
        makeKey()
    }

    private func placeDefault() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: (area.midX - frame.width / 2).rounded(), y: (area.minY + 72).rounded()))
    }
}

private struct StartPaletteView: View {
    let selectArea: () -> Void
    let entireScreen: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            .padding(.trailing, 4)

            Divider().frame(height: 40).overlay(Color.white.opacity(0.15))

            PaletteButton(title: "Select Area", symbol: "rectangle.dashed", action: selectArea)
                .help("Drag a box around what to record")
            PaletteButton(title: "Entire Screen", symbol: "display", action: entireScreen)
                .help("Record the whole screen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(VisualEffectBackground(material: .hudWindow, cornerRadius: 14))
    }
}

private struct PaletteButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: 92, height: 54)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PaletteButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

private struct PaletteButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0))
            )
    }
}
