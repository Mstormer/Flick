import AppKit
import ScreenCaptureKit
// Window parking and capture shared by the off-screen harnesses (opentest, colortest). Declarations only:
// globals outside main.swift start lazily, so each tool's main.swift keeps its own process setup (activation
// policy, muting, the activity that keeps timers awake).

/// The window under test. ScreenCaptureKit only captures a window that touches a screen, and macOS keeps a
/// titled window partly on one, so: borderless, behind every other window, with just a 2×2-point corner on
/// a screen the mouse is NOT on (re-checked every tick; with one screen, the first of its corners clear of the mouse).
var testWindow: NSWindow?
var cameOnScreen = 0              // ticks the window showed more than its 2×2-point parking corner on the mouse's screen (should stay 0)
func parkOrigin(_ w: NSWindow) -> NSPoint {
    let mouse = NSEvent.mouseLocation
    let screens = NSScreen.screens.map(\.frame)
    let size = w.frame.size
    // a screen without the mouse (with one screen, that one), and a corner of it that no other screen touches:
    // the window overlaps its screen by 2×2 points and nothing else
    let candidates = screens.filter { !$0.contains(mouse) }.isEmpty ? screens : screens.filter { !$0.contains(mouse) }
    for s in candidates {
        let corners = [NSPoint(x: s.minX - size.width + 2, y: s.minY - size.height + 2), NSPoint(x: s.maxX - 2, y: s.minY - size.height + 2),
                       NSPoint(x: s.minX - size.width + 2, y: s.maxY - 2), NSPoint(x: s.maxX - 2, y: s.maxY - 2)]
        for c in corners {
            let r = NSRect(origin: c, size: size)
            if screens.allSatisfy({ $0 == s || !$0.intersects(r) }) && !r.contains(mouse) { return c }
        }
    }
    return NSPoint(x: -30000, y: -30000)      // nowhere safe: fully off screen (pictures can't be checked then)
}
func park() {
    guard let w = testWindow else { return }
    if w.isVisible, w.alphaValue > 0, let m = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
       (m.frame.intersection(w.frame).width > 2 || m.frame.intersection(w.frame).height > 2) { cameOnScreen += 1; if cameOnScreen <= 3 { print("overlap: window", w.frame, "mouse", NSEvent.mouseLocation) } }
    let o = parkOrigin(w)
    if w.frame.origin != o { w.setFrameOrigin(o) }
}
func spin(_ s: Double) {
    let end = Date().addingTimeInterval(s)
    repeat { park(); RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01))) } while Date() < end
    park()
}

/// Takes over a player's window before it is ever shown: borderless (macOS keeps part of a titled window on
/// a screen, not a borderless one), transparent, parked, behind everything, and every move or resize (the
/// player sizing it after load) goes straight back. Returns the observers to remove when done.
func adopt(_ w: NSWindow) -> [NSObjectProtocol] {
    testWindow = w
    w.styleMask = [.borderless]
    w.alphaValue = 0
    w.setFrameOrigin(parkOrigin(w))
    w.orderBack(nil)
    park()
    return [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map {
        NotificationCenter.default.addObserver(forName: $0, object: w, queue: nil) { _ in park() }
    }
}

/// The window's content right now (ScreenCaptureKit works on off-screen windows). Shown only for the capture,
/// already parked; transparent the rest of the time (the player moves its window while loading, and nothing
/// may flash onto a screen meanwhile).
func capture(_ w: NSWindow, _ cfg: SCStreamConfiguration) -> CGImage? {
    park(); w.alphaValue = 1
    defer { w.alphaValue = 0 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    var out: CGImage?
    let done = DispatchSemaphore(value: 0)
    let id = CGWindowID(w.windowNumber)
    Task.detached {
        defer { done.signal() }
        guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let sw = c.windows.first(where: { $0.windowID == id }) else { print("capture: window not listed"); return }
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg) else { print("capture failed"); return }
        out = img
    }
    while done.wait(timeout: .now()) == .timedOut { spin(0.02) }
    return out
}
