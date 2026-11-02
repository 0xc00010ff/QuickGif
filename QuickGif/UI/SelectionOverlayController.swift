import AppKit

/// Owns the per-screen selection overlays and the options panel for one selection session.
@MainActor
final class SelectionOverlayController: SelectionViewDelegate {
    /// Called when the user asks to record the current selection.
    var onStart: ((CaptureRegion, StartDelay) -> Void)?

    private var windows: [SelectionOverlayWindow] = []
    private let model = OptionsModel()
    private let panel: OptionsPanel
    /// The view that currently holds the selection (at most one screen has one).
    private weak var activeView: SelectionView?

    init() {
        panel = OptionsPanel(model: model)
        model.onStart = { [weak self] delay in self?.requestStart(delay) }
        model.onChooseFolder = { [weak self] in
            // Let the menu finish tracking before running a modal panel.
            Task { @MainActor in self?.chooseFolder() }
        }
    }

    var currentRegion: CaptureRegion? {
        guard let view = activeView, let rect = view.selection,
              let window = view.window as? SelectionOverlayWindow else { return nil }
        return CaptureRegion(rect: window.globalRect(fromView: rect), screen: window.targetScreen)
    }

    func show() {
        windows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen)
            window.selectionView.delegate = self
            return window
        }
        windows.forEach { $0.orderFrontRegardless() }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { NSMouseInRect(mouse, $0.screenFrame, false) } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
        for window in windows {
            window.selectionView.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        windows = []
    }

    func owns(_ window: NSWindow) -> Bool {
        window === panel || windows.contains { $0 === window }
    }

    @discardableResult
    func endEditing() -> Bool { panel.endEditing() }

    /// Countdown: clear screen, only the selection border remains, clicks pass through.
    func enterCountdown() {
        panel.endEditing()
        panel.orderOut(nil)
        for window in windows {
            window.ignoresMouseEvents = true
            window.selectionView.mode = .countdown
        }
    }

    func exitCountdown() {
        for window in windows {
            window.ignoresMouseEvents = false
            window.selectionView.mode = .selecting
        }
        NSApp.activate()
        (activeView?.window ?? windows.first)?.makeKeyAndOrderFront(nil)
        updatePanel()
    }

    // MARK: SelectionViewDelegate

    func selectionViewDidBeginSelection(_ view: SelectionView) {
        for window in windows {
            if window.selectionView !== view { window.selectionView.selection = nil }
            window.selectionView.showsHint = false
        }
        activeView = view
        panel.orderOut(nil)
    }

    func selectionViewDidChange(_ view: SelectionView) {
        if view === activeView, view.selection == nil {
            activeView = nil
            windows.forEach { $0.selectionView.showsHint = true }
        }
        updatePanel()
    }

    func selectionViewDidRequestStart(_ view: SelectionView) {
        requestStart(.now)
    }

    // MARK: Private

    private func requestStart(_ delay: StartDelay) {
        guard let region = currentRegion else { return }
        panel.endEditing()
        onStart?(region, delay)
    }

    private func updatePanel() {
        let region = currentRegion
        model.region = region
        guard let region, let view = activeView, !view.isDrawingNewSelection else {
            panel.orderOut(nil)
            return
        }
        panel.place(near: region.rect, on: region.screenFrame)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func chooseFolder() {
        guard !windows.isEmpty else { return }
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose"
        openPanel.message = "Choose where QuickGif saves recordings."
        openPanel.directoryURL = Preferences.shared.options.saveDirectory

        // The overlays sit at screen-saver level and would cover the open panel.
        panel.orderOut(nil)
        windows.forEach { $0.orderOut(nil) }
        if openPanel.runModal() == .OK, let url = openPanel.url {
            Preferences.shared.options.saveDirectory = url
        }
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderFrontRegardless() }
        NSApp.activate()
        (activeView?.window ?? windows.first)?.makeKeyAndOrderFront(nil)
        updatePanel()
    }
}
