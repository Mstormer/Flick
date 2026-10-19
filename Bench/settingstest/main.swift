import AppKit
import ScreenCaptureKit
_ = NSApplication.shared
func ev(_ c: String, _ f: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil,
                     characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
}
for (c, f) in [("v", []), ("a", []), ("s", []), ("z", []), ("x", []), ("d", []), ("r", []), ("R", NSEvent.ModifierFlags.shift), ("q", [])] as [(String, NSEvent.ModifierFlags)] {
    let m = Shortcuts.shared.match(ev(c, f))
    print(c, f.contains(.shift) ? "+shift" : "", "->", m.map { "\($0.action.title) \($0.value)" } ?? "none")
}
NSApp.setActivationPolicy(.prohibited)   // never becomes the active app, never takes focus
let wc = SettingsWindowController.shared
let w = wc.window!
w.appearance = NSAppearance(named: CommandLine.arguments.count > 2 ? .darkAqua : .aqua)
w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
w.orderFrontRegardless()
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
let done = DispatchSemaphore(value: 0)
Task.detached {
    let c = try! await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let sw = c.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) else { print("window not found"); exit(1) }
    let cfg = SCStreamConfiguration(); cfg.width = Int(sw.frame.width) * 2; cfg.height = Int(sw.frame.height) * 2
    let img = try! await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("rendered", img.width, img.height)
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
w.orderOut(nil)
