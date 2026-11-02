import AppKit

/// Screen Recording (TCC) permission helpers.
enum ScreenCapturePermission {
    /// True when the app may capture the screen. Does not prompt.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (once per app identity). Returns the current grant state;
    /// a newly granted permission usually requires relaunching the app.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    /// Opens System Settings → Privacy & Security → Screen & System Audio Recording.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
