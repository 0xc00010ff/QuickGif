import AppKit
import SwiftUI

/// Small notice at the bottom-right of a screen that fades away on its own.
final class ToastPanel: NSPanel {
    enum Content {
        case saved(SavedRecording)
        case message(title: String, detail: String)
    }

    var onDismiss: (() -> Void)?
    private var dismissTimer: Timer?
    private let lifetime: TimeInterval
    private var isDismissing = false

    init(_ content: Content) {
        if case .saved = content { lifetime = 6 } else { lifetime = 3.5 }
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay(level: .statusBar)
        hasShadow = true
        hidesOnDeactivate = false

        let view = ToastView(
            content: content,
            onOpen: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.dismiss(animated: true)
            },
            onReveal: { [weak self] url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
                self?.dismiss(animated: true)
            },
            onHover: { [weak self] hovering in
                // Keep it up while the pointer is on it.
                if hovering { self?.dismissTimer?.invalidate() } else { self?.scheduleDismiss() }
            },
            onClose: { [weak self] in self?.dismiss(animated: true) }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    func show(on screen: NSScreen?) {
        let area = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let margin: CGFloat = 20
        setFrameOrigin(NSPoint(x: area.maxX - frame.width - margin, y: area.minY + margin))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 1
        }
        scheduleDismiss()
    }

    func dismiss(animated: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        dismissTimer?.invalidate()
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            orderOut(nil)
            close()
            onDismiss?()
        }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { finish() }
        })
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: true) }
        }
    }
}

private struct ToastView: View {
    let content: ToastPanel.Content
    let onOpen: (URL) -> Void
    let onReveal: (URL) -> Void
    let onHover: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        Group {
            switch content {
            case .saved(let recording): saved(recording)
            case .message(let title, let detail): message(title: title, detail: detail)
            }
        }
        .padding(12)
        .frame(width: 380)
        .background(VisualEffectBackground(material: .popover, cornerRadius: 12))
        .onHover(perform: onHover)
    }

    private func saved(_ recording: SavedRecording) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: recording.url.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Saved").fontWeight(.semibold).fixedSize()
                        Text(recording.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(recording.byteCount), countStyle: .file)) · \(DurationText.summary(recording.duration))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen(recording.url) }
            .help("Open \(recording.url.lastPathComponent)")

            Button("Show in Finder") { onReveal(recording.url) }
            closeButton
        }
    }

    private func message(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            closeButton
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}
