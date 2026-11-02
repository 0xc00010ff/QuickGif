import AppKit
import Observation

/// Delay before recording starts, in seconds. `.now` starts immediately.
enum StartDelay: Int, CaseIterable, Identifiable {
    case now = 0
    case one = 1
    case three = 3
    case five = 5
    case ten = 10

    var id: Int { rawValue }
    var label: String { self == .now ? "Now" : "\(rawValue)s" }
}

/// Maximum recording length. Recording stops automatically when reached.
enum MaxDuration: Hashable, Codable {
    case off
    case seconds(Int)

    /// Quick-select presets shown in the options panel. "Custom" is any other `.seconds` value.
    static let presets: [MaxDuration] = [.off, .seconds(3), .seconds(6), .seconds(30), .seconds(60)]

    var seconds: Int? {
        if case .seconds(let s) = self { return s }
        return nil
    }

    var isPreset: Bool { MaxDuration.presets.contains(self) }

    var label: String {
        switch self {
        case .off: return "Off"
        case .seconds(let s): return "\(s)s"
        }
    }
}

/// Output pixel density. `.points` is 1 pixel per point (small files, LICEcap-like);
/// `.retina` captures at the display's native backing scale.
enum CaptureScale: Int, CaseIterable, Codable, Identifiable {
    case points = 1
    case retina = 2

    var id: Int { rawValue }
    var label: String { self == .points ? "1x" : "Retina" }
}

/// Everything the user can tweak before recording.
struct RecordingOptions: Equatable, Codable {
    static let fpsChoices = [5, 10, 15, 20, 30]
    static let defaultDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser

    var fps: Int = 10
    var scale: CaptureScale = .points
    var maxDuration: MaxDuration = .off
    var saveDirectory: URL = RecordingOptions.defaultDirectory
    /// Base file name without extension. Empty means "auto": `QuickGif 2026-11-01 at 14.22.05`.
    var fileName: String = ""

    static func autoFileName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "QuickGif \(f.string(from: date))"
    }

    /// Final output URL: uses `fileName` (or the auto name), appends `.gif`,
    /// and adds " 2", " 3", … if a file already exists.
    func resolvedOutputURL(now: Date = Date()) -> URL {
        var base = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = RecordingOptions.autoFileName(for: now) }
        if base.lowercased().hasSuffix(".gif") { base = String(base.dropLast(4)) }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")

        let fm = FileManager.default
        var candidate = saveDirectory.appendingPathComponent(base).appendingPathExtension("gif")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = saveDirectory.appendingPathComponent("\(base) \(n)").appendingPathExtension("gif")
            n += 1
        }
        return candidate
    }
}

/// A rectangle on one display, chosen by the user.
///
/// `rect` and `screenFrame` are in Cocoa global coordinates (points; origin at the
/// bottom-left of the primary display, y grows upward), exactly as `NSScreen.frame`
/// and `NSEvent.mouseLocation` report them.
struct CaptureRegion: Equatable {
    var displayID: CGDirectDisplayID
    var screenFrame: CGRect
    var backingScale: CGFloat
    var rect: CGRect

    /// Creates a region for `rect` (Cocoa global coords) on `screen`. Returns nil if too small.
    init?(rect: CGRect, screen: NSScreen) {
        let r = rect.standardized.integral.intersection(screen.frame)
        guard r.width >= 16, r.height >= 16,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        self.displayID = CGDirectDisplayID(number.uint32Value)
        self.screenFrame = screen.frame
        self.backingScale = screen.backingScaleFactor
        self.rect = r
    }

    /// `rect` expressed in the display's own coordinate space: origin at the display's
    /// top-left corner, y grows downward, in points. This is what
    /// `SCStreamConfiguration.sourceRect` expects for a display content filter.
    var rectInDisplayCoordinates: CGRect {
        CGRect(x: rect.minX - screenFrame.minX,
               y: screenFrame.maxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// Output size in pixels for the given scale. Always even numbers (video-friendly).
    func pixelSize(for scale: CaptureScale) -> (width: Int, height: Int) {
        let factor: CGFloat = scale == .points ? 1 : backingScale
        var w = Int((rect.width * factor).rounded())
        var h = Int((rect.height * factor).rounded())
        if w % 2 == 1 { w += 1 }
        if h % 2 == 1 { h += 1 }
        return (max(w, 2), max(h, 2))
    }

    var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}

/// Persisted user options (UserDefaults). Observable so SwiftUI panels update live.
@Observable
final class Preferences {
    static let shared = Preferences()

    private static let key = "QuickGif.RecordingOptions"

    var options: RecordingOptions {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Preferences.key),
           let decoded = try? JSONDecoder().decode(RecordingOptions.self, from: data) {
            var o = decoded
            o.fileName = "" // the name is per-recording; never persisted
            if !FileManager.default.fileExists(atPath: o.saveDirectory.path) {
                o.saveDirectory = RecordingOptions.defaultDirectory
            }
            options = o
        } else {
            options = RecordingOptions()
        }
    }

    private func save() {
        var o = options
        o.fileName = ""
        if let data = try? JSONEncoder().encode(o) {
            UserDefaults.standard.set(data, forKey: Preferences.key)
        }
    }
}
