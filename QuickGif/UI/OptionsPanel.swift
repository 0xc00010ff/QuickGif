import AppKit
import SwiftUI

/// State the options panel shows that does not live in `Preferences`.
@MainActor
@Observable
final class OptionsModel {
    var region: CaptureRegion?
    @ObservationIgnored var onStart: (StartDelay) -> Void = { _ in }
    @ObservationIgnored var onChooseFolder: () -> Void = {}
}

/// Borderless panel under the selection. It can become key so its text fields work,
/// but only when a control needs it, so the overlay keeps keyboard focus otherwise.
final class OptionsPanel: NSPanel {
    init(model: OptionsModel) {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        configureAsOverlay(level: .overlayPanel)
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        let hosting = FirstMouseHostingView(rootView: OptionsView(model: model, prefs: Preferences.shared))
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    /// Ends text editing if a field is active. Returns whether one was.
    @discardableResult
    func endEditing() -> Bool {
        guard firstResponder is NSText else { return false }
        makeFirstResponder(nil)
        return true
    }

    /// Centered under `rect` (12 pt gap); above it if that leaves the screen; inside its bottom otherwise.
    func place(near rect: CGRect, on screenFrame: CGRect) {
        let size = frame.size
        let gap: CGFloat = 12, margin: CGFloat = 8
        let x = min(max(rect.midX - size.width / 2, screenFrame.minX + margin), screenFrame.maxX - size.width - margin)
        var y = rect.minY - gap - size.height
        if y < screenFrame.minY + margin {
            y = rect.maxY + gap
            if y + size.height > screenFrame.maxY - margin { y = rect.minY + gap }
        }
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}

private enum TimerChoice: Hashable {
    case preset(MaxDuration)
    case custom
}

struct OptionsView: View {
    let model: OptionsModel
    @Bindable var prefs: Preferences

    private static let customSecondsKey = "QuickGif.CustomTimerSeconds"
    @AppStorage(OptionsView.customSecondsKey) private var customSeconds = 45
    @State private var customSelected: Bool
    @State private var customText: String
    @FocusState private var customFocused: Bool

    init(model: OptionsModel, prefs: Preferences) {
        self.model = model
        self.prefs = prefs
        let duration = prefs.options.maxDuration
        let remembered = UserDefaults.standard.object(forKey: OptionsView.customSecondsKey) as? Int ?? 45
        _customSelected = State(initialValue: !duration.isPreset)
        _customText = State(initialValue: String(duration.isPreset ? remembered : duration.seconds ?? remembered))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            startRow
            Divider()
            timerRow
            outputRow
            formatRow
        }
        .padding(16)
        .frame(width: 500)
        .background(VisualEffectBackground(material: .popover, cornerRadius: 12))
    }

    private var startRow: some View {
        HStack(spacing: 8) {
            Button { model.onStart(.now) } label: {
                Label("Record", systemImage: "record.circle")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .help("Start recording now (Return)")

            Spacer(minLength: 16)

            Text("Delay").foregroundStyle(.secondary)
            ForEach(StartDelay.allCases.filter { $0 != .now }) { delay in
                Button(delay.label) { model.onStart(delay) }
                    .help("Start recording in \(delay.rawValue) seconds")
            }
        }
    }

    private var timerRow: some View {
        HStack(spacing: 8) {
            rowLabel("Timer")
            Picker("Timer", selection: timerChoice) {
                ForEach(MaxDuration.presets, id: \.self) { Text($0.label).tag(TimerChoice.preset($0)) }
                Text("Custom").tag(TimerChoice.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Stop recording automatically")

            if customSelected {
                TextField("Seconds", text: $customText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .focused($customFocused)
                    .onChange(of: customText) { applyCustomText() }
                    .onChange(of: customFocused) { if !customFocused { customText = String(customSeconds) } }
                Text("sec").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var outputRow: some View {
        HStack(spacing: 8) {
            rowLabel("Save to")
            Menu {
                ForEach(Self.standardFolders, id: \.self) { url in
                    Button { prefs.options.saveDirectory = url } label: { folderLabel(url) }
                }
                Divider()
                Button("Choose…") { model.onChooseFolder() }
            } label: {
                folderLabel(prefs.options.saveDirectory)
            }
            .fixedSize()
            .help(prefs.options.saveDirectory.path)

            Text("Name").foregroundStyle(.secondary).padding(.leading, 8)
            TextField(RecordingOptions.autoFileName(), text: $prefs.options.fileName)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            Text(".gif").foregroundStyle(.secondary)
        }
    }

    private var formatRow: some View {
        HStack(spacing: 8) {
            rowLabel("FPS")
            Picker("FPS", selection: $prefs.options.fps) {
                ForEach(RecordingOptions.fpsChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Frames per second")

            Text("Size").foregroundStyle(.secondary).padding(.leading, 8)
            Picker("Size", selection: $prefs.options.scale) {
                ForEach(CaptureScale.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("1x keeps files small; Retina captures every pixel")

            Spacer()

            if let region = model.region {
                let size = region.pixelSize(for: prefs.options.scale)
                Text("\(size.width) × \(size.height) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    private var timerChoice: Binding<TimerChoice> {
        Binding(
            get: { customSelected ? .custom : .preset(prefs.options.maxDuration) },
            set: { choice in
                switch choice {
                case .preset(let duration):
                    customSelected = false
                    prefs.options.maxDuration = duration
                case .custom:
                    customSelected = true
                    customText = String(customSeconds)
                    prefs.options.maxDuration = .seconds(customSeconds)
                }
            }
        )
    }

    /// Applies the typed value live (clamped), so Return can start right away.
    private func applyCustomText() {
        guard let value = Int(customText.trimmingCharacters(in: .whitespaces)), value > 0 else { return }
        customSeconds = min(max(value, 1), 3600)
        prefs.options.maxDuration = .seconds(customSeconds)
    }

    private func folderLabel(_ url: URL) -> some View {
        Label {
            Text(FileManager.default.displayName(atPath: url.path))
        } icon: {
            Image(nsImage: Self.icon(for: url))
        }
        .labelStyle(.titleAndIcon)
    }

    private static let standardFolders: [URL] = [
        FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory, .picturesDirectory, .moviesDirectory,
    ].compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }

    private static func icon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path).copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
