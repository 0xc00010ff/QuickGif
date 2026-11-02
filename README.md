# QuickGif

LICEcap, but modern. A small macOS app that records a region of the screen straight to an animated GIF.

Click the dock icon, drag a box, click to record. That is the whole app.

## Using it

1. **Click the QuickGif dock icon.** The screen goes white-translucent, like ⌘⇧4.
2. **Drag a box** around what you want to record, or click **Select Entire Screen** (⌘A). Resize with the handles or drag it to move. **Reset Selection** (or Delete) clears it so you can start over.
3. **Start**: click anywhere (or press Return, or the **Record** button) to start now, or pick a **1s / 3s / 5s / 10s** delay. During the countdown the screen is yours: arrange windows, position the cursor. Esc during a countdown goes back to the selection.
4. **Options** in the panel under the box (drag the panel if it is in the way):
   - **Timer** (auto-stop): Off, 3s, 6s, 30s, 60s, or Custom seconds.
   - **Save to**: Desktop, Downloads, Pictures, Movies, or Choose…
   - **Name**: defaults to `QuickGif 2026-11-01 at 14.22.05.gif`.
   - **FPS** (5–30, default 10) and **Size** (1x or Retina).
5. **While recording** the box is transparent with a thin red frame. Big **Pause** and **Stop** buttons sit at the bottom right. While paused, **Restart** throws the take away and starts again from 0:00. QuickGif's own windows are never captured.
6. **Stop** writes the GIF and shows a toast with a *Show in Finder* button. The toast goes away on its own, or click its ×.

Esc cancels at any point before recording. ⌘N starts a new selection, ⌘. stops a recording, and the dock menu has both. Quitting mid-recording saves first.

The first launch asks for **Screen Recording** permission (System Settings → Privacy & Security). macOS requires a relaunch after granting it.

## Building

Open `QuickGif.xcodeproj` in Xcode 16 or later and run, or:

```bash
xcodebuild -project QuickGif.xcodeproj -scheme QuickGif -configuration Debug -derivedDataPath build/DerivedData build
```

The app lands in `build/DerivedData/Build/Products/Debug/QuickGif.app`. Requires macOS 14 Sonoma or later. No dependencies.

## How it works

| Piece | File(s) | Notes |
|---|---|---|
| Session flow | `App/SessionController.swift` | `idle → selecting → countdown → recording → saving` |
| Region picker | `UI/SelectionOverlayWindow.swift`, `UI/SelectionView.swift`, `UI/SelectionHintView.swift` | One borderless window per display at screen-saver level; the hint offers Select Entire Screen |
| Options panel | `UI/OptionsPanel.swift` | SwiftUI, bound to `Preferences.shared` (UserDefaults) |
| Recording controls | `UI/RecordingControlsPanel.swift`, `UI/RecordingBorderWindow.swift` | Non-activating panel, so Pause/Stop never steal focus |
| Capture | `Capture/ScreenRecorder.swift` | ScreenCaptureKit, region via `sourceRect`, QuickGif's own app excluded from the filter |
| Encoding | `Encoding/GIFEncoder.swift` | Streaming GIF89a writer: frame differencing, transparent unchanged pixels, exact palettes for UI content, median cut otherwise |

Frames stream from ScreenCaptureKit straight into the encoder, so memory stays flat for long recordings. A frame is shown until the next frame arrives, and identical frames are coalesced, so an idle screen costs almost nothing.

## License

MIT. See [LICENSE](LICENSE).
