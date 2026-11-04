import AppKit
import QuartzCore

/// Drives one recording at a time:
/// idle → selecting → countdown(n) → starting → recording(paused:) → saving → (reviewing →) idle.
@MainActor
final class SessionController {
    enum State: Equatable {
        case idle
        case selecting
        case countdown(Int)
        /// Selection is gone; waiting for `ScreenRecorder.start()` to return.
        case starting
        case recording(paused: Bool)
        case saving
        /// The review window is open on the finished recording.
        case reviewing
    }

    private(set) var state: State = .idle

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // Selection and countdown.
    private var overlay: SelectionOverlayController?
    private var countdownHUD: CountdownHUD?
    private var countdownTimer: Timer?
    private var keyMonitor: Any?

    // Capture. `capture` exists from the moment the recorder is started (possibly
    // during the countdown's last second) until the file is saved or discarded.
    private struct Capture {
        let region: CaptureRegion
        let recorder: ScreenRecorder
        let pipeline: RecordingPipeline
        let limit: TimeInterval?
        let startTask: Task<Void, Error>
        /// Where a reviewed recording goes once saved; nil when it is written there directly.
        let destination: URL?
    }
    private var capture: Capture?
    private var captureIsRunning = false
    private var borderWindow: RecordingBorderWindow?
    private var controlsPanel: RecordingControlsPanel?
    private var controlsModel: RecordingControlsModel?
    private var elapsedTimer: Timer?

    private var permissionWindow: PermissionWindow?
    private var didRequestPermission = false
    private var toast: ToastPanel?
    private var review: ReviewController?
    private var terminationReply: (() -> Void)?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
    }

    // MARK: Selection

    func beginSelection() {
        if state == .reviewing {
            review?.bringToFront()
            return
        }
        guard state == .idle else { return }
        guard ScreenCapturePermission.isGranted else {
            showPermissionWindow()
            return
        }
        permissionWindow?.close()
        permissionWindow = nil
        guard !NSScreen.screens.isEmpty else {
            NSSound.beep()
            return
        }
        toast?.dismiss(animated: false)

        let overlay = SelectionOverlayController()
        overlay.onStart = { [weak self] region, delay in self?.start(region, delay: delay) }
        self.overlay = overlay
        state = .selecting
        installKeyMonitor()
        overlay.show()
    }

    private func cancelSelection() {
        tearDownSelection()
        becomeIdle()
    }

    private func tearDownSelection() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownHUD?.orderOut(nil)
        countdownHUD?.close()
        countdownHUD = nil
        overlay?.close()
        overlay = nil
        removeKeyMonitor()
    }

    private func start(_ region: CaptureRegion, delay: StartDelay) {
        guard state == .selecting else { return }
        if delay == .now {
            tearDownSelection()
            state = .starting
            guard startCapture(region) else { return }
            capture?.pipeline.begin(at: CACurrentMediaTime())
        } else {
            beginCountdown(region, seconds: delay.rawValue)
        }
    }

    // MARK: Countdown

    private func beginCountdown(_ region: CaptureRegion, seconds: Int) {
        overlay?.enterCountdown()
        let hud = CountdownHUD(seconds: seconds, centeredOn: region.rect, screenFrame: region.screenFrame)
        hud.orderFrontRegardless()
        countdownHUD = hud
        state = .countdown(seconds)
        // ScreenCaptureKit takes a moment to deliver its first frame, so start it during the last second.
        if seconds == 1, !startCapture(region) { return }

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countdownTick(region) }
        }
    }

    private func countdownTick(_ region: CaptureRegion) {
        guard case .countdown(let n) = state else { return }
        let remaining = n - 1
        guard remaining > 0 else {
            countdownDidFinish()
            return
        }
        state = .countdown(remaining)
        countdownHUD?.remaining = remaining
        if remaining == 1 { _ = startCapture(region) }
    }

    private func countdownDidFinish() {
        capture?.pipeline.begin(at: CACurrentMediaTime())
        tearDownSelection()
        if captureIsRunning {
            enterRecording()
        } else {
            state = .starting
        }
    }

    private func cancelCountdown() {
        guard case .countdown = state else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownHUD?.orderOut(nil)
        countdownHUD?.close()
        countdownHUD = nil
        abandonCapture()
        overlay?.exitCountdown()
        state = .selecting
    }

    // MARK: Capture

    /// Creates the encoder and starts the recorder. On failure, tears everything down,
    /// reports the error and returns false.
    @discardableResult
    private func startCapture(_ region: CaptureRegion) -> Bool {
        let options = Preferences.shared.options
        let destination = options.resolvedOutputURL()
        let url = options.reviewBeforeSaving ? Self.reviewFileURL() : destination
        let size = region.pixelSize(for: options.scale)
        let limit = options.maxDuration.seconds.map(TimeInterval.init)

        let pipeline: RecordingPipeline
        do {
            pipeline = try RecordingPipeline(url: url, width: size.width, height: size.height, limit: limit)
        } catch {
            failToStart(error)
            return false
        }
        let recorder = ScreenRecorder(region: region, fps: options.fps, scale: options.scale)
        recorder.onFrame = pipeline.append
        recorder.onError = { [weak self, weak recorder] _ in
            guard let self, let recorder, self.capture?.recorder === recorder else { return }
            // Display gone or stream died: keep what was captured.
            switch self.state {
            case .recording: self.stopRecording()
            case .countdown, .starting: self.failToStart(ScreenRecorder.RecorderError.displayNotFound)
            default: break
            }
        }

        let startTask = Task { try await recorder.start() }
        capture = Capture(region: region, recorder: recorder, pipeline: pipeline, limit: limit, startTask: startTask,
                          destination: options.reviewBeforeSaving ? destination : nil)
        captureIsRunning = false

        Task { @MainActor [weak self] in
            do {
                try await startTask.value
                self?.captureDidStart(recorder)
            } catch {
                self?.captureDidFail(recorder, error)
            }
        }
        return true
    }

    private func captureDidStart(_ recorder: ScreenRecorder) {
        guard capture?.recorder === recorder else { return }
        captureIsRunning = true
        if state == .starting { enterRecording() }
    }

    private func captureDidFail(_ recorder: ScreenRecorder, _ error: Error) {
        guard capture?.recorder === recorder else { return }
        failToStart(error)
    }

    private func failToStart(_ error: Error) {
        if let capture {
            self.capture = nil
            capture.pipeline.discard()
            Task { await capture.recorder.stop() }
        }
        captureIsRunning = false
        tearDownSelection()
        guard !becomeIdle() else { return }
        if (error as? ScreenRecorder.RecorderError) == .permissionDenied {
            showPermissionWindow()
        } else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t start recording"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    /// Stops a recorder that was started early for a countdown that was then cancelled.
    private func abandonCapture(then completion: (() -> Void)? = nil) {
        guard let capture else { completion?(); return }
        self.capture = nil
        captureIsRunning = false
        capture.pipeline.discard()
        Task { @MainActor in
            _ = try? await capture.startTask.value
            await capture.recorder.stop()
            completion?()
        }
    }

    // MARK: Recording

    private func enterRecording() {
        guard let capture else { return }
        state = .recording(paused: false)
        // The typed name applied to this recording only.
        Preferences.shared.options.fileName = ""

        if terminationReply != nil {
            stopRecording()
            return
        }

        let rect = capture.region.rect
        let border = RecordingBorderWindow(around: rect)
        border.orderFrontRegardless()
        borderWindow = border

        let model = RecordingControlsModel(limit: capture.limit)
        model.onTogglePause = { [weak self] in self?.togglePause() }
        model.onRestart = { [weak self] in self?.restartRecording() }
        model.onStop = { [weak self] in self?.stopRecording() }
        let panel = RecordingControlsPanel(model: model)
        panel.place(near: rect, on: capture.region.screenFrame)
        panel.orderFrontRegardless()
        controlsPanel = panel
        controlsModel = model

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
    }

    private func updateElapsed() {
        guard let capture, isRecording else { return }
        let elapsed = capture.pipeline.elapsed()
        controlsModel?.elapsed = elapsed
        if let limit = capture.limit, elapsed >= limit { stopRecording() }
    }

    func togglePause() {
        guard case .recording(let paused) = state, let capture else { return }
        capture.pipeline.setPaused(!paused)
        state = .recording(paused: !paused)
        borderWindow?.isPaused = !paused
        controlsModel?.isPaused = !paused
        controlsModel?.elapsed = capture.pipeline.elapsed()
    }

    /// Throws the current take away and records the same region again from 0:00.
    /// The stream keeps running, so there is no startup gap.
    func restartRecording() {
        guard isRecording, let capture else { return }
        capture.recorder.onFrame = nil
        capture.pipeline.discard(wait: true)

        let size = capture.region.pixelSize(for: capture.recorder.scale)
        let pipeline: RecordingPipeline
        do {
            pipeline = try RecordingPipeline(url: capture.pipeline.url, width: size.width, height: size.height,
                                             limit: capture.limit)
        } catch {
            // The output folder went away mid-recording; there is nothing left to save.
            self.capture = nil
            captureIsRunning = false
            hideRecordingChrome()
            Task { await capture.recorder.stop() }
            guard !becomeIdle() else { return }
            showToast(.message(title: "Couldn’t restart the recording", detail: error.localizedDescription),
                      on: capture.region.screen)
            return
        }

        self.capture = Capture(region: capture.region, recorder: capture.recorder, pipeline: pipeline,
                               limit: capture.limit, startTask: capture.startTask, destination: capture.destination)
        capture.recorder.onFrame = pipeline.append
        pipeline.begin(at: CACurrentMediaTime())
        state = .recording(paused: false)
        borderWindow?.isPaused = false
        controlsModel?.isPaused = false
        controlsModel?.elapsed = 0
    }

    func stopRecording() {
        guard isRecording, let capture else { return }
        state = .saving
        let duration = capture.pipeline.stop()
        hideRecordingChrome()

        Task { @MainActor [weak self] in
            await capture.recorder.stop()
            let outcome = await capture.pipeline.finish(at: duration)
            self?.didFinishSaving(outcome, capture: capture)
        }
    }

    /// A fresh temporary file for a recording that will be reviewed before saving.
    private static func reviewFileURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuickGif", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("gif")
    }

    private func hideRecordingChrome() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        borderWindow?.orderOut(nil)
        borderWindow?.close()
        borderWindow = nil
        controlsPanel?.orderOut(nil)
        controlsPanel?.close()
        controlsPanel = nil
        controlsModel = nil
    }

    private func didFinishSaving(_ outcome: RecordingOutcome, capture: Capture) {
        self.capture = nil
        captureIsRunning = false
        let screen = capture.region.screen
        if case .saved(let recording) = outcome, let destination = capture.destination {
            if terminationReply != nil {
                // Quitting: no time for a review, keep the whole take.
                _ = try? GIFTrimmer.save(recording.url, to: destination, cut: nil,
                                         untrimmedDuration: recording.duration)
            } else {
                beginReview(recording, destination: destination, region: capture.region)
                return
            }
        }
        guard !becomeIdle() else { return }
        switch outcome {
        case .saved(let recording):
            showToast(.saved(recording), on: screen)
        case .nothingRecorded:
            showToast(.message(title: "Nothing was recorded",
                               detail: "Recording stopped before any frames were captured."), on: screen)
        case .failed(let error):
            showToast(.message(title: "Couldn’t save the GIF", detail: error.localizedDescription), on: screen)
        }
    }

    // MARK: Review

    private func beginReview(_ recording: SavedRecording, destination: URL, region: CaptureRegion) {
        let screen = region.screen
        let controller = ReviewController(recording: recording, destination: destination,
                                          pointSize: region.rect.size, screen: screen)
        controller.onFinish = { [weak self] result in self?.didFinishReview(result, screen: screen) }
        review = controller
        state = .reviewing
        controller.show()
    }

    private func didFinishReview(_ result: ReviewResult, screen: NSScreen?) {
        review = nil
        guard !becomeIdle() else { return }
        switch result {
        case .saved(let recording):
            showToast(.saved(recording), on: screen)
        case .discarded:
            break
        case .failed(let error):
            showToast(.message(title: "Couldn’t save the GIF", detail: error.localizedDescription), on: screen)
        }
    }

    // MARK: Termination

    /// Returns true when the app must wait for `reply` (a recording is being saved first).
    func prepareForTermination(reply: @escaping () -> Void) -> Bool {
        switch state {
        case .idle:
            return false
        case .selecting:
            tearDownSelection()
            state = .idle
            return false
        case .countdown:
            tearDownSelection()
            state = .idle
            guard capture != nil else { return false }
            abandonCapture(then: reply)
            return true
        case .starting, .saving:
            terminationReply = reply
            return true
        case .recording:
            terminationReply = reply
            stopRecording()
            return true
        case .reviewing:
            terminationReply = reply
            review?.saveForTermination()
            return true
        }
    }

    /// Returns true if the app is quitting (and has been told it may), so no further UI should appear.
    @discardableResult
    private func becomeIdle() -> Bool {
        state = .idle
        guard let reply = terminationReply else { return false }
        terminationReply = nil
        reply()
        return true
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard NSApp.modalWindow == nil, let overlay else { return false }
        if let window = event.window, !overlay.owns(window) { return false }
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }

        switch (event.keyCode, state) {
        case (53, .selecting): // Esc
            if !overlay.endEditing() { cancelSelection() }
            return true
        case (53, .countdown):
            cancelCountdown()
            return true
        case (36, .selecting), (76, .selecting): // Return, Enter
            guard let region = overlay.currentRegion else { return false }
            overlay.endEditing()
            start(region, delay: .now)
            return true
        case (51, .selecting), (117, .selecting): // Delete, Forward Delete
            guard !overlay.isEditingText, overlay.currentRegion != nil else { return false }
            overlay.clearSelection()
            return true
        default:
            return false
        }
    }

    // MARK: Screens, permission, toasts

    private func screensDidChange() {
        switch state {
        case .selecting:
            tearDownSelection()
            state = .idle
            beginSelection()
        case .countdown:
            tearDownSelection()
            abandonCapture()
            state = .idle
            beginSelection()
        case .recording:
            // The display may have moved; keep the chrome on the region. A lost display arrives via onError.
            if let capture, let screen = capture.region.screen, screen.frame == capture.region.screenFrame {
                controlsPanel?.place(near: capture.region.rect, on: screen.frame)
            }
        default:
            break
        }
    }

    private func showPermissionWindow() {
        if !didRequestPermission {
            didRequestPermission = true
            ScreenCapturePermission.request()
        }
        let window = permissionWindow ?? PermissionWindow()
        permissionWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func showToast(_ content: ToastPanel.Content, on screen: NSScreen?) {
        toast?.dismiss(animated: false)
        let panel = ToastPanel(content)
        panel.onDismiss = { [weak self, weak panel] in
            if let self, self.toast === panel { self.toast = nil }
        }
        toast = panel
        panel.show(on: screen)
    }
}
