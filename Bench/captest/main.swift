import AppKit
import ScreenCaptureKit
NSApplication.shared.setActivationPolicy(.prohibited)
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let shotDir = CommandLine.arguments[2]
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

print("== parsers")
for f in ["subs.srt", "other.vtt"] {
    if case .cues(let t, let c)? = CaptionParser.load(dir.appendingPathComponent(f)) {
        print(f, "→", t, c.map { String(format: "[%.1f–%.1f] %@", $0.start, $0.end, $0.text.replacingOccurrences(of: "\n", with: " / ")) })
    } else { print(f, "→ FAILED") }
}
let ass = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\i1}Styled{\\i0} text, with comma\\Nline two\n"
print("ass →", CaptionParser.ass(ass).map { "\($0.start)-\($0.end) \($0.text.replacingOccurrences(of: "\n", with: " / "))" })
if let m = MKVFile(url: dir.appendingPathComponent("cap.mkv")) {
    for t in m.tracks where t.type == 17 {
        if case .cues(let title, let c) = CaptionParser.mkvTrack(m, t) { print("mkv track", t.codecID, "→", title, c.map { String(format: "[%.1f–%.1f] %@", $0.start, $0.end, $0.text.replacingOccurrences(of: "\n", with: " / ")) }) }
    }
}
print("sidecars for side.mp4:", CaptionParser.sidecars(for: dir.appendingPathComponent("side.mp4")).map(\.lastPathComponent))

func capture(_ w: NSWindow, _ name: String) async {
    let c = try! await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let sw = c.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) else { print("no window"); return }
    let cfg = SCStreamConfiguration(); cfg.width = Int(sw.frame.width); cfg.height = Int(sw.frame.height)
    let img = try! await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(shotDir)/\(name).png"))
}

for (file, pick) in [("cap.mp4", 0), ("cap.mkv", 1), ("side.mp4", 2)] {
    let wc = PlayerWindowController(url: dir.appendingPathComponent(file))
    let w = wc.window!
    w.setFrameOrigin(NSPoint(x: -20000, y: -20000)); w.orderFrontRegardless()
    spin(1.5)
    let v = wc.view
    print("==", file, "sources:", v.captionSources.map(\.title), "auto-selected:", v.captionChoice as Any)
    let item = NSMenuItem(); item.tag = min(pick, v.captionSources.count - 1)
    v.chooseCaption(item)
    print("   chose", item.tag, "→", v.captionChoice.map { v.captionSources[$0].title } as Any)
    spin(1.2)   // playback is now ~2.7 s in: cue 1 (1–4 s) on screen
    let done = DispatchSemaphore(value: 0)
    Task.detached { await capture(w, "cap-\(file)"); done.signal() }
    while done.wait(timeout: .now()) == .timedOut { spin(0.05) }
    w.orderOut(nil); v.teardown()
}

print("== menu bar")
let app = AppDelegate()
let menu = MainMenu.build(app)
func dump(_ m: NSMenu, _ d: Int) {
    for i in m.items {
        if i.isSeparatorItem { continue }
        var k = ""
        if !i.keyEquivalent.isEmpty {
            let f = i.keyEquivalentModifierMask
            k = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
            let names = [" ": "Space", "\u{f702}": "←", "\u{f703}": "→", "\u{f700}": "↑", "\u{f701}": "↓", "\u{f72c}": "PgUp", "\u{f72d}": "PgDn"]
            k += names[i.keyEquivalent] ?? i.keyEquivalent.uppercased()
        }
        print(String(repeating: "  ", count: d) + (i.submenu?.title ?? i.title) + (k.isEmpty ? "" : "   " + k))
        if let s = i.submenu, d < 2 { dump(s, d + 1) }
    }
}
dump(menu, 0)
