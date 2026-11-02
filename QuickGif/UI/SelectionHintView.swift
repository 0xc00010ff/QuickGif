import SwiftUI

/// The prompt in the middle of each screen before anything is selected.
struct SelectionHintView: View {
    var onSelectEntireScreen: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            Text("Drag to select an area to record")
                .font(.system(size: 13, weight: .medium))
            Button(action: onSelectEntireScreen) {
                Label("Select Entire Screen", systemImage: "display")
                    .padding(.horizontal, 2)
            }
            .help("Select this whole screen (⌘A)")
            Text("Esc to cancel")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
