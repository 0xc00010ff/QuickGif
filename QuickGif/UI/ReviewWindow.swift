import AppKit
import QuartzCore
import SwiftUI

/// What became of a reviewed recording.
enum ReviewResult {
    case saved(SavedRecording)
    case discarded
    case failed(Error)
}

/// Shows a finished recording (still in a temporary file) so the user can trim it,
/// then saves it to its destination or throws it away. Closing the window saves.
@MainActor
final class ReviewController: NSObject, NSWindowDelegate {
    var onFinish: ((ReviewResult) -> Void)?

    private let recording: SavedRecording
    private let destination: URL
    private let model: ReviewModel
    private let window: NSWindow
    private let backingScale: CGFloat
    private var keyMonitor: Any?
    private var isTerminating = false
    private var isFinished = false

    /// `recording.url` is the temporary file; `pointSize` is the captured region's size in points.
    init(recording: SavedRecording, destination: URL, pointSize: CGSize, screen: NSScreen?) {
        self.recording = recording
        self.destination = destination
        backingScale = screen?.backingScaleFactor ?? 2

        // Fit in 720 × 450, never more than 2x the captured size.
        let w = max(1, pointSize.width), h = max(1, pointSize.height)
        let scale = min(720 / w, 450 / h, 2)
        let preview = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        model = ReviewModel(previewSize: preview, recordedBytes: recording.byteCount,
                            recordedDuration: recording.duration)

        // A floating, non-activating panel: Stop is clicked on a panel that leaves the
        // browser active, so a normal window would open behind it. This one comes up on top,
        // takes the keyboard without needing the app to activate, and follows into full screen.
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window = panel
        super.init()
        window.title = destination.lastPathComponent
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        let hosting = NSHostingView(rootView: ReviewView(model: model))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        let area = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        window.setFrameOrigin(NSPoint(x: (area.midX - window.frame.width / 2).rounded(),
                                      y: (area.midY - window.frame.height / 2).rounded()))

        model.onSave = { [weak self] in self?.save() }
        model.onTrash = { [weak self] in self?.trash() }
    }

    func show() {
        installKeyMonitor()
        bringToFront()
        load()
    }

    func bringToFront() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// The app is quitting: save with the current trim, without asking anything.
    func saveForTermination() {
        isTerminating = true
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        save()
    }

    // MARK: Loading

    private func load() {
        let url = recording.url
        let maxPixels = Int((max(model.previewSize.width, model.previewSize.height) * backingScale).rounded())
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try GIFTimeline(url: url) } }.value
            guard let self, !self.isFinished else { return }
            switch result {
            case .success(let timeline):
                guard let frames = ReviewFrameSource(url: url, timeline: timeline, maxPixelSize: maxPixels) else {
                    model.fail(GIFTrimmer.TrimError.unreadable.localizedDescription)
                    return
                }
                model.load(timeline, frames: frames)
                loadThumbnails(timeline, frames: frames)
            case .failure(let error):
                model.fail(error.localizedDescription)
            }
        }
    }

    private func loadThumbnails(_ timeline: GIFTimeline, frames: ReviewFrameSource) {
        let aspect = CGFloat(timeline.width) / CGFloat(timeline.height)
        let thumbWidth = max(8, TrimStrip.trackHeight * aspect)
        let count = min(60, max(1, Int((model.trackWidth / thumbWidth).rounded(.up))))
        let indices = (0..<count).map { timeline.frame(at: (Double($0) + 0.5) / Double(count) * timeline.duration) }
        frames.thumbnails(of: indices, pixelHeight: Int(TrimStrip.trackHeight * backingScale)) { [weak self] images in
            self?.model.thumbnails = images
        }
    }

    // MARK: Save and trash

    private func save() {
        guard !isFinished, !model.isSaving else { return }
        model.pause()
        model.isSaving = true
        model.saveProgress = 0
        let model = model
        let cut = model.timeline.map { (timeline: $0, frames: model.trimStart...model.trimEnd) }
        let source = recording.url, destination = destination, duration = recording.duration
        let progress: (Double) -> Void = { value in
            DispatchQueue.main.async { MainActor.assumeIsolated { model.saveProgress = value } }
        }
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try GIFTrimmer.save(source, to: destination, cut: cut, untrimmedDuration: duration,
                                             progress: progress) }
            }.value
            guard let self, !self.isFinished else { return }
            switch result {
            case .success(let saved):
                finish(.saved(saved))
            case .failure(let error):
                model.isSaving = false
                if isTerminating {
                    finish(.failed(error))
                } else {
                    showSaveError(error)
                }
            }
        }
    }

    private func showSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t save the GIF"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    private func trash() {
        guard !isFinished, !model.isSaving else { return }
        try? FileManager.default.removeItem(at: recording.url)
        finish(.discarded)
    }

    private func finish(_ result: ReviewResult) {
        isFinished = true
        model.pause()
        model.frames = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window.delegate = nil
        window.orderOut(nil)
        window.close()
        onFinish?(result)
    }

    // MARK: Window and keyboard

    /// The close button and ⌘W save with the current trim, so nothing is lost by accident.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        save()
        return false
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Space plays/pauses; ←/→ move the last-dragged trim handle one frame (Shift: ten).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        else { return false }
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 49: model.togglePlay()
        case 123: model.nudge(-step)
        case 124: model.nudge(step)
        default: return false
        }
        return true
    }
}

// MARK: - Model

/// Playback and trim state of the review window.
@MainActor
@Observable
final class ReviewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum Handle { case start, end }

    static let minimumWidth: CGFloat = 560
    static let padding: CGFloat = 16

    let previewSize: CGSize
    let recordedBytes: Int
    let recordedDuration: TimeInterval

    private(set) var phase: Phase = .loading
    private(set) var timeline: GIFTimeline?
    /// First and last kept frame (inclusive).
    private(set) var trimStart = 0
    private(set) var trimEnd = 0
    /// Position in the whole recording, in seconds.
    private(set) var playhead: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var image: CGImage?
    var thumbnails: [CGImage] = []
    var isSaving = false
    var saveProgress: Double = 0
    /// The handle ←/→ move: the one dragged last.
    private(set) var activeHandle: Handle = .start

    @ObservationIgnored var frames: ReviewFrameSource?
    @ObservationIgnored var onSave: () -> Void = {}
    @ObservationIgnored var onTrash: () -> Void = {}
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var wantedIndex = -1

    init(previewSize: CGSize, recordedBytes: Int, recordedDuration: TimeInterval) {
        self.previewSize = previewSize
        self.recordedBytes = recordedBytes
        self.recordedDuration = recordedDuration
    }

    // MARK: Layout

    var contentWidth: CGFloat { max(previewSize.width, ReviewModel.minimumWidth) }
    var previewAreaHeight: CGFloat { max(previewSize.height, 180) }
    /// Width of the frame strip between its two handle gutters.
    var trackWidth: CGFloat { contentWidth - 2 * ReviewModel.padding - 2 * TrimStrip.handleWidth }

    // MARK: Derived

    var canEdit: Bool { phase == .ready && !isSaving }
    var totalDuration: TimeInterval { timeline?.duration ?? recordedDuration }
    var keptStart: TimeInterval { timeline?.starts[trimStart] ?? 0 }
    var keptEnd: TimeInterval { timeline?.starts[trimEnd + 1] ?? recordedDuration }
    var keptDuration: TimeInterval { keptEnd - keptStart }
    var isTrimmed: Bool {
        guard let timeline else { return false }
        return trimStart > 0 || trimEnd < timeline.frameCount - 1
    }

    /// Proportional to the kept frames: a rough guide, not a promise.
    var estimatedBytes: Int {
        guard let timeline, isTrimmed else { return recordedBytes }
        return Int(Double(recordedBytes) * Double(trimEnd - trimStart + 1) / Double(timeline.frameCount))
    }

    /// Two decimals when frames are shorter than a tenth of a second, so each nudge shows.
    var decimals: Int {
        guard let timeline, timeline.frameCount > 1 else { return 1 }
        let sorted = timeline.delays.sorted()
        return sorted[sorted.count / 2] >= 0.095 ? 1 : 2
    }

    // MARK: Setup

    func load(_ timeline: GIFTimeline, frames: ReviewFrameSource) {
        self.timeline = timeline
        self.frames = frames
        trimStart = 0
        trimEnd = timeline.frameCount - 1
        playhead = 0
        phase = .ready
        frames.onFrame = { [weak self] index, image in self?.frameReady(index, image) }
        showFrame()
        play()
    }

    func fail(_ message: String) {
        pause()
        phase = .failed(message)
    }

    // MARK: Playback

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard canEdit, !isPlaying, timeline != nil else { return }
        // Start over from the cut's first frame when outside it or parked on its last frame.
        let onLastFrame = trimEnd > trimStart && playhead >= (timeline?.starts[trimEnd] ?? 0)
        if playhead < keptStart || playhead >= keptEnd || onLastFrame {
            playhead = keptStart
        }
        isPlaying = true
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        showFrame()
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.25)
        lastTick = now
        var t = playhead + dt
        if t >= keptEnd {
            t = keptStart + (t - keptEnd).truncatingRemainder(dividingBy: max(keptDuration, 0.01))
        }
        playhead = max(t, keptStart)
        showFrame()
    }

    private func showFrame() {
        guard let timeline, let frames else { return }
        let index = timeline.frame(at: playhead)
        guard index != wantedIndex else { return }
        wantedIndex = index
        if let cached = frames.cachedImage(at: index) { image = cached }
        var upcoming = [index]
        if isPlaying {
            var next = index
            for _ in 0..<4 {
                next = next >= trimEnd ? trimStart : next + 1
                if next == index { break }
                upcoming.append(next)
            }
        }
        frames.request(upcoming)
    }

    private func frameReady(_ index: Int, _ image: CGImage) {
        if index == wantedIndex { self.image = image }
    }

    // MARK: Trimming

    /// Frame boundary `k` (0...frameCount) becomes the cut's start.
    func setStart(boundary k: Int) {
        guard canEdit else { return }
        trimStart = min(max(0, k), trimEnd)
        activeHandle = .start
        peek(at: trimStart)
    }

    /// Frame boundary `k` (1...frameCount) becomes the cut's end.
    func setEnd(boundary k: Int) {
        guard canEdit, let timeline else { return }
        trimEnd = max(trimStart, min(timeline.frameCount, k) - 1)
        activeHandle = .end
        peek(at: trimEnd)
    }

    func nudge(_ frames: Int) {
        switch activeHandle {
        case .start: setStart(boundary: trimStart + frames)
        case .end: setEnd(boundary: trimEnd + 1 + frames)
        }
    }

    /// Shows any moment of the recording, inside the cut or not, and pauses.
    func scrub(to time: TimeInterval) {
        guard canEdit else { return }
        pause()
        playhead = min(max(0, time), max(0, totalDuration - 0.0001))
        showFrame()
    }

    private func peek(at frame: Int) {
        pause()
        playhead = timeline?.starts[frame] ?? 0
        showFrame()
    }

    // MARK: Text

    func stamp(_ time: TimeInterval) -> String {
        let factor = decimals == 1 ? 10.0 : 100.0
        let t = (time * factor).rounded() / factor
        let minutes = Int(t / 60)
        return String(format: "%d:%0*.*f", minutes, decimals + 3, decimals, t - Double(minutes * 60))
    }

    var readout: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(estimatedBytes), countStyle: .file)
        guard phase == .ready else { return "\(DurationText.summary(recordedDuration)) · \(size)" }
        let kept = String(format: "%.*f s", decimals, keptDuration)
        let total = String(format: "%.*f s", decimals, totalDuration)
        return "\(kept) of \(total) · \(isTrimmed ? "~" : "")\(size)"
    }
}

// MARK: - Views

private struct ReviewView: View {
    let model: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(width: model.contentWidth, height: model.previewAreaHeight)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            VStack(spacing: 12) {
                TrimStrip(model: model)
                    .frame(width: model.contentWidth - 2 * ReviewModel.padding, height: TrimStrip.totalHeight)
                controls
            }
            .padding(ReviewModel.padding)
        }
        .frame(width: model.contentWidth)
    }

    @ViewBuilder
    private var preview: some View {
        switch model.phase {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Can’t preview this recording").font(.headline)
                Text("\(message) You can still save it as recorded.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        case .ready:
            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: model.previewSize.width, height: model.previewSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture { model.togglePlay() }
                    .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canEdit)
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            if model.isSaving {
                ProgressView(value: model.saveProgress)
                    .frame(width: 120)
                Text("Saving…").foregroundStyle(.secondary)
            } else {
                Text(model.readout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Trash") { model.onTrash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Discard this recording (⌘⌫)")
            Button("Save") { model.onSave() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .help(model.isTrimmed ? "Save the trimmed GIF (Return)" : "Save the GIF (Return)")
        }
        .disabled(model.isSaving)
    }
}

/// Frame thumbnails with a draggable trim range, a playhead and the cut's times below.
/// The strip is a timeline: x is proportional to time, so long frames take more room.
struct TrimStrip: View {
    static let trackHeight: CGFloat = 44
    static let handleWidth: CGFloat = 11
    static let labelHeight: CGFloat = 14
    static var totalHeight: CGFloat { trackHeight + 4 + labelHeight }

    let model: ReviewModel
    @State private var drag: Drag?

    private enum Drag {
        case start(origin: CGFloat)
        case end(origin: CGFloat)
        case scrub
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(spacing: 4) {
                track(width: width)
                labels(width: width)
            }
        }
    }

    // MARK: Geometry

    private func x(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        let duration = max(model.totalDuration, 0.0001)
        return Self.handleWidth + CGFloat(time / duration) * (width - 2 * Self.handleWidth)
    }

    private func time(_ x: CGFloat, width: CGFloat) -> TimeInterval {
        let track = max(1, width - 2 * Self.handleWidth)
        return Double(min(max(0, (x - Self.handleWidth) / track), 1)) * model.totalDuration
    }

    // MARK: Track

    private func track(width: CGFloat) -> some View {
        let h = Self.trackHeight, hw = Self.handleWidth
        let trackWidth = width - 2 * hw
        let ready = model.phase == .ready
        let xs = x(model.keptStart, width: width), xe = x(model.keptEnd, width: width)

        return ZStack(alignment: .topLeading) {
            // Thumbnails, dimmed outside the cut.
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.quaternary)
                if ready {
                    HStack(spacing: 0) {
                        ForEach(model.thumbnails.indices, id: \.self) { i in
                            Image(decorative: model.thumbnails[i], scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: trackWidth / CGFloat(model.thumbnails.count), height: h)
                                .clipped()
                        }
                    }
                    Rectangle().fill(.black.opacity(0.5))
                        .frame(width: max(0, xs - hw), height: h)
                    Rectangle().fill(.black.opacity(0.5))
                        .frame(width: max(0, width - hw - xe), height: h)
                        .offset(x: xe - hw)
                } else {
                    Text(model.phase == .loading ? "Loading frames…" : "Trimming isn’t available")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: trackWidth, height: h)
                }
            }
            .frame(width: trackWidth, height: h, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .offset(x: hw)

            if ready {
                selection(xs: xs, xe: xe)
                Capsule()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .frame(width: 3, height: h + 6)
                    .offset(x: x(model.playhead, width: width) - 1.5, y: -3)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
        // AppKit handles the mouse: first click always lands, a drag never moves the window,
        // and the handles get resize cursors.
        .overlay(
            TrimMouseArea(
                hit: { handle(at: $0, width: width) },
                began: { begin(at: $0, width: width) },
                moved: { move(to: $0, width: width) },
                ended: { drag = nil }
            )
        )
    }

    /// Yellow frame around the kept range, with grab handles just outside its edges.
    private func selection(xs: CGFloat, xe: CGFloat) -> some View {
        let h = Self.trackHeight, hw = Self.handleWidth
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: xe - xs + 2 * hw, height: h)
            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                .fill(Color.yellow)
                .frame(width: hw, height: h)
                .overlay(chevron("chevron.compact.left"))
            UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                .fill(Color.yellow)
                .frame(width: hw, height: h)
                .overlay(chevron("chevron.compact.right"))
                .offset(x: xe - xs + hw)
        }
        .offset(x: xs - hw)
        .allowsHitTesting(false)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.black.opacity(0.6))
    }

    /// Which handle (if any) is under `x0`. Generous hit zones, nearest wins.
    private func handle(at x0: CGFloat, width: CGFloat) -> TrimMouseArea.Hit {
        guard model.canEdit else { return .none }
        let hw = Self.handleWidth
        let xs = x(model.keptStart, width: width), xe = x(model.keptEnd, width: width)
        let toStart = abs(x0 - (xs - hw / 2)), toEnd = abs(x0 - (xe + hw / 2))
        guard min(toStart, toEnd) <= hw * 1.5 else { return .none }
        let pickStart = toStart == toEnd ? x0 < (xs + xe) / 2 : toStart < toEnd
        return pickStart ? .start : .end
    }

    private func begin(at x0: CGFloat, width: CGFloat) {
        guard model.canEdit else { return }
        let xs = x(model.keptStart, width: width), xe = x(model.keptEnd, width: width)
        switch handle(at: x0, width: width) {
        case .start: drag = .start(origin: xs - x0)
        case .end: drag = .end(origin: xe - x0)
        case .none: drag = .scrub
        }
        move(to: x0, width: width)
    }

    /// `origin` is the grab offset, so the handle doesn't jump to the pointer.
    private func move(to x1: CGFloat, width: CGFloat) {
        guard model.canEdit, let timeline = model.timeline, let drag else { return }
        switch drag {
        case .start(let offset):
            model.setStart(boundary: timeline.nearestBoundary(to: time(x1 + offset, width: width)))
        case .end(let offset):
            model.setEnd(boundary: timeline.nearestBoundary(to: time(x1 + offset, width: width)))
        case .scrub:
            model.scrub(to: time(x1, width: width))
        }
    }

    // MARK: Labels

    @ViewBuilder
    private func labels(width: CGFloat) -> some View {
        if model.phase == .ready {
            let xs = x(model.keptStart, width: width), xe = x(model.keptEnd, width: width)
            let inset: CGFloat = 26
            ZStack {
                if xe - xs < 80 {
                    label("\(model.stamp(model.keptStart)) – \(model.stamp(model.keptEnd))")
                        .position(x: min(max((xs + xe) / 2, inset * 2), width - inset * 2), y: Self.labelHeight / 2)
                } else {
                    label(model.stamp(model.keptStart))
                        .position(x: min(max(xs, inset), width - inset), y: Self.labelHeight / 2)
                    label(model.stamp(model.keptEnd))
                        .position(x: min(max(xe, inset), width - inset), y: Self.labelHeight / 2)
                }
            }
            .frame(width: width, height: Self.labelHeight)
        } else {
            Color.clear.frame(width: width, height: Self.labelHeight)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// Transparent AppKit layer over the trim strip that turns mouse events into x positions.
private struct TrimMouseArea: NSViewRepresentable {
    enum Hit { case start, end, none }

    var hit: (CGFloat) -> Hit
    var began: (CGFloat) -> Void
    var moved: (CGFloat) -> Void
    var ended: () -> Void

    func makeNSView(context: Context) -> TrimMouseView { update(TrimMouseView()) }
    func updateNSView(_ view: TrimMouseView, context: Context) { _ = update(view) }

    private func update(_ view: TrimMouseView) -> TrimMouseView {
        view.hit = hit
        view.began = began
        view.moved = moved
        view.ended = ended
        return view
    }
}

final class TrimMouseView: NSView {
    fileprivate var hit: (CGFloat) -> TrimMouseArea.Hit = { _ in .none }
    fileprivate var began: (CGFloat) -> Void = { _ in }
    fileprivate var moved: (CGFloat) -> Void = { _ in }
    fileprivate var ended: () -> Void = {}

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        began(x)
        updateCursor(dragging: hit(x))
    }

    override func mouseDragged(with event: NSEvent) {
        moved(convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        ended()
        updateCursor(dragging: nil)
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(dragging: nil, event: event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(dragging: nil, event: event) }

    private func updateCursor(dragging: TrimMouseArea.Hit?, event: NSEvent? = nil) {
        let x = convert((event ?? NSApp.currentEvent)?.locationInWindow ?? .zero, from: nil).x
        switch dragging ?? hit(x) {
        case .start, .end: NSCursor.resizeLeftRight.set()
        case .none: NSCursor.arrow.set()
        }
    }
}
