import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let session = SessionController()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()
        session.showPalette()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if session.state == .idle || session.state == .reviewing { session.showPalette() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let mustWait = session.prepareForTermination {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return mustWait ? .terminateLater : .terminateNow
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if session.isRecording {
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording(_:)), keyEquivalent: "").target = self
        } else if session.state == .reviewing {
            menu.addItem(withTitle: "Show Review", action: #selector(newRecording(_:)), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Select Area", action: #selector(selectArea(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Entire Screen", action: #selector(entireScreen(_:)), keyEquivalent: "").target = self
        }
        return menu
    }

    // MARK: Actions

    /// Shows the start palette, or brings the review window forward while one is open.
    @objc private func newRecording(_ sender: Any?) {
        session.showPalette()
    }

    @objc private func selectArea(_ sender: Any?) {
        session.beginSelection()
    }

    @objc private func entireScreen(_ sender: Any?) {
        session.beginSelection(entireScreen: true)
    }

    @objc private func stopRecording(_ sender: Any?) {
        session.stopRecording()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(stopRecording(_:)): return session.isRecording
        case #selector(newRecording(_:)): return session.state == .idle || session.state == .reviewing
        case #selector(selectArea(_:)), #selector(entireScreen(_:)): return session.state == .idle
        default: return true
        }
    }

    // MARK: Menu

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "QuickGif")
        app.addItem(withTitle: "About QuickGif", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit QuickGif", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Recording", action: #selector(newRecording(_:)), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Stop Recording", action: #selector(stopRecording(_:)), keyEquivalent: ".").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: file)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu: window)
        NSApp.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
