import AppKit
import SwiftUI

@MainActor
@Observable
final class RecordingControlsModel {
    var elapsed: TimeInterval = 0
    var isPaused = false
    let limit: TimeInterval?
    @ObservationIgnored var onTogglePause: () -> Void = {}
    @ObservationIgnored var onStop: () -> Void = {}

    init(limit: TimeInterval?) { self.limit = limit }
}

/// Pause/Stop bar. Non-activating and never key, so clicking it leaves the recorded app focused.
final class RecordingControlsPanel: NSPanel {
    init(model: RecordingControlsModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay()
        hasShadow = true
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        let hosting = FirstMouseHostingView(rootView: RecordingControlsView(model: model))
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    /// Right-aligned 8 pt below the region; above if that leaves the screen; else inside its bottom-right corner.
    func place(near rect: CGRect, on screenFrame: CGRect) {
        let size = frame.size
        let gap: CGFloat = 8
        var x = rect.maxX - size.width
        var y = rect.minY - gap - size.height
        if y < screenFrame.minY {
            y = rect.maxY + gap
            if y + size.height > screenFrame.maxY {
                x = rect.maxX - gap - size.width
                y = rect.minY + gap
            }
        }
        x = min(max(x, screenFrame.minX), screenFrame.maxX - size.width)
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}

private struct RecordingControlsView: View {
    let model: RecordingControlsModel

    var body: some View {
        HStack(spacing: 12) {
            RecordingDot(isPaused: model.isPaused)
            VStack(alignment: .leading, spacing: 4) {
                Text(timeText)
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if let limit = model.limit {
                    ProgressLine(fraction: min(model.elapsed / limit, 1))
                }
            }
            .frame(minWidth: model.limit == nil ? 44 : 96, alignment: .leading)

            Button(action: model.onTogglePause) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(CircleButtonStyle(fill: .white.opacity(0.16)))
            .help(model.isPaused ? "Resume recording" : "Pause recording")

            Button(action: model.onStop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(CircleButtonStyle(fill: .red))
            .help("Stop and save")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(VisualEffectBackground(material: .hudWindow, cornerRadius: 16))
    }

    private var timeText: String {
        guard let limit = model.limit else { return DurationText.clock(model.elapsed) }
        return "\(DurationText.clock(model.elapsed)) / \(DurationText.clock(limit))"
    }
}

private struct RecordingDot: View {
    let isPaused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { context in
            let lit = isPaused || Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            Circle()
                .fill(isPaused ? Color.gray : Color.red)
                .frame(width: 10, height: 10)
                .opacity(lit ? 1 : 0.25)
                .animation(.easeInOut(duration: 0.3), value: lit)
        }
    }
}

private struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.2))
            .frame(height: 2)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                }
            }
    }
}

private struct CircleButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(Circle().fill(fill))
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
