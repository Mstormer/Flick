import AppKit
import AVFoundation
import ScreenCaptureKit
// Colour check: pauses each grey-ramp video (16 bars, Y = 16…235) and reads the bars from a capture of the
// window in sRGB. mpv/IINA shows (Y-16)*255/219: 0, 17, 34 … 255. Never takes focus; windows parked by Bench/Park.swift.
//   built like opentest (see Bench/opentest/main.swift), with Bench/colortest/main.swift and -o Bench/colortest/colortest
//   Bench/colortest/colortest Media/color/*   (exits 1 if a file doesn't open or can't be captured)
NSApplication.shared.setActivationPolicy(.prohibited)
PlayerView.startMuted = true
let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "colour test")
/// The 16 bars' levels (green channel, sRGB), read across the middle of a capture of the window.
func bars(_ w: NSWindow) -> [Int]? {
    let cfg = SCStreamConfiguration(); cfg.width = 1280; cfg.height = 720
    cfg.colorSpaceName = CGColorSpace.sRGB
    cfg.showsCursor = false
    guard let img = capture(w, cfg) else { return nil }
    let W = img.width, H = img.height
    var px = [UInt8](repeating: 0, count: W * H * 4)
    let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    let y = H * 2 / 5
    return (0..<16).map { i in Int(px[(y * W + Int((Double(i) + 0.5) / 16.0 * Double(W))) * 4 + 1]) }   // green (grey: all equal)
}

var failures = 0
let ideal: [Int] = (0..<16).map { (i: Int) -> Int in Int((Double(i) * 17).rounded()) }
print("IINA (mpv)       ", ideal.map { String(format: "%3d", $0) }.joined(separator: " "))
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let wc = PlayerWindowController(url: url)
    let w = wc.window!
    let observers = adopt(w)
    defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    var waited = 0.0
    while wc.view.backend == nil && !wc.view.openFailed && waited < 10 { spin(0.1); waited += 0.1 }
    guard let b = wc.view.backend else {
        failures += 1
        print(url.lastPathComponent, wc.view.openFailed ? "says it can't open the file" : "no player", String(format: "after %.1f s", waited))
        w.orderOut(nil); wc.view.teardown(); spin(0.3); continue
    }
    spin(1.5)
    b.pause()
    spin(0.5)
    guard let v = bars(w) else { failures += 1; print(url.lastPathComponent, "capture failed"); w.orderOut(nil); wc.view.teardown(); spin(0.3); continue }
    let name = (url.lastPathComponent + " " + String(describing: type(of: b))).padding(toLength: 34, withPad: " ", startingAt: 0)
    let err = zip(v, ideal).map { abs($0 - $1) }
    print(name, v.map { String(format: "%3d", $0) }.joined(separator: " "), "| max diff", err.max() ?? -1, "mean", err.isEmpty ? -1 : err.reduce(0, +) / err.count)
    w.orderOut(nil); wc.view.teardown(); spin(0.3)
}
print("ticks a test window showed more than a 2×2-pt corner on the mouse\u{2019}s screen:", cameOnScreen)
exit(failures > 0 ? 1 : 0)
