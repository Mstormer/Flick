import AppKit
import ScreenCaptureKit
NSApplication.shared.setActivationPolicy(.prohibited)   // never active, never takes focus
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let wc = PlayerWindowController(url: url)
let w = wc.window!
w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
w.orderFrontRegardless()
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
spin(2.5)
let view = wc.view
let btn = { w.standardWindowButton(.closeButton)!.alphaValue }
print("after load+idle: buttons alpha", btn())
view.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 300, y: 300), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
spin(0.3); print("0.3 s after hover: buttons alpha", btn())
spin(0.9); print("1.2 s after hover: buttons alpha", btn())
guard let b = view.backend else { print("no backend"); exit(1) }
b.isMuted = true
b.volume = 0.5
func swipe(_ dy: Int32) {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0)!
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    view.scrollWheel(with: NSEvent(cgEvent: cg)!)
}
let inv = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!.isDirectionInvertedFromDevice
for _ in 0..<5 { swipe(20) }
let v1 = b.volume
for _ in 0..<10 { swipe(-20) }
let v2 = b.volume
print("natural scrolling:", inv, "| vol 0.50 → after +100pt swipe:", String(format: "%.2f", v1), "→ after −200pt swipe:", String(format: "%.2f", v2))
for _ in 0..<3 { swipe(20) }
spin(0.15)
let done = DispatchSemaphore(value: 0)
Task.detached {
    let c = try! await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    let sw = c.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) })!
    let cfg = SCStreamConfiguration(); cfg.width = Int(sw.frame.width) * 2; cfg.height = Int(sw.frame.height) * 2
    let img = try! await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
    let crop = img.cropping(to: CGRect(x: img.width - 520, y: img.height - 300, width: 520, height: 300))!
    try! NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { spin(0.05) }
spin(1.6)
print("badge alpha 1.6 s later:", wc.view.subviews.first { $0 is VolumeBadge }?.alphaValue as Any)
w.orderOut(nil); wc.view.teardown()
