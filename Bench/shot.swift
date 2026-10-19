import ScreenCaptureKit
import AppKit
// usage: shot <owner app name> <out.png>
_ = NSApplication.shared
let sema = DispatchSemaphore(value: 0)
Task {
  do {
    let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let w = c.windows.first(where: { $0.owningApplication?.applicationName == CommandLine.arguments[1] && $0.windowLayer == 0 }) else { print("no window"); exit(1) }
    let cfg = SCStreamConfiguration(); cfg.width = Int(w.frame.width) * 2; cfg.height = Int(w.frame.height) * 2
    let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
    let rep = NSBitmapImageRep(cgImage: img)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("ok", w.frame)
  } catch { print("err", error) }
  sema.signal()
}
sema.wait()
