import AppKit
import SwiftUI

@MainActor
@Observable
final class CountdownModel {
    var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

/// Click-through circle with the remaining seconds, centered on the selection.
final class CountdownHUD: NSPanel {
    private static let diameter: CGFloat = 160
    private let model: CountdownModel

    init(seconds: Int, centeredOn rect: CGRect, screenFrame: CGRect) {
        model = CountdownModel(remaining: seconds)
        let d = Self.diameter
        let x = min(max(rect.midX - d / 2, screenFrame.minX), screenFrame.maxX - d)
        let y = min(max(rect.midY - d / 2, screenFrame.minY), screenFrame.maxY - d)
        super.init(contentRect: NSRect(x: x.rounded(), y: y.rounded(), width: d, height: d),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay(level: .overlayPanel)
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: CountdownView(model: model))
    }

    var remaining: Int {
        get { model.remaining }
        set { withAnimation(.snappy) { model.remaining = newValue } }
    }
}

private struct CountdownView: View {
    let model: CountdownModel

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.55))
            Text("\(model.remaining)")
                .font(.system(size: 96, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: 160, height: 160)
    }
}
