import AppKit
import SwiftUI

/// Shown instead of the selection overlay while Screen Recording access is missing.
final class PermissionWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Screen Recording Access"
        isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: PermissionView())
        contentView = hosting
        setContentSize(hosting.fittingSize)
        center()
    }
}

private struct PermissionView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 8) {
                Text("QuickGif needs Screen Recording access")
                    .font(.headline)
                Text("To record an area of your screen, allow QuickGif in System Settings under Privacy & Security › Screen & System Audio Recording.")
                Text("After allowing access, quit and reopen QuickGif.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                    Button("Open System Settings") { ScreenCapturePermission.openSystemSettings() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
    }
}
