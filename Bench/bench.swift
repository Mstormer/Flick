// Black-box player benchmark.
// Launches a player on a barcoded test video, drives it with real HID events (keys / mouse),
// records the screen with ScreenCaptureKit at the display's refresh rate, and reads the frame
// number burned into every video frame. Output: one JSON file with every input event and every
// picture the player put on screen, both on the host clock.
//
// usage: bench <player> <video> <scenario> <out.json> [--bar x0,x1,yFromBottom]
//   player:   Flick | Leah | IINA | VLC | mpv
//   scenario: hold | drag | click | play4x

import AppKit
import ApplicationServices
import CoreMedia
import CoreImage
import ScreenCaptureKit

setvbuf(stdout, nil, _IONBF, 0)
_ = NSApplication.shared

let args = CommandLine.arguments
guard args.count >= 5 else { print("usage: bench <player> <video> <scenario> <out.json> [--bar x0,x1,yb]"); exit(2) }
let playerName = args[1], videoPath = args[2], scenario = args[3], outPath = args[4]
var barSpec: (Double, Double, Double)?
if let i = args.firstIndex(of: "--bar"), i + 1 < args.count {
    let p = args[i + 1].split(separator: ",").compactMap { Double($0) }
    if p.count == 3 { barSpec = (p[0], p[1], p[2]) }
}

func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
func sleep(_ s: Double) { Thread.sleep(forTimeInterval: s) }

// MARK: - Launching and placing the player

struct Launch { let ownerName: String; let bundleID: String? }
let launch: Launch = {
    switch playerName {
    case "mpv": return Launch(ownerName: "mpv", bundleID: nil)
    case "IINA": return Launch(ownerName: "IINA", bundleID: "com.colliderli.iina")
    case "VLC": return Launch(ownerName: "VLC", bundleID: "org.videolan.vlc")
    case "Leah": return Launch(ownerName: "Leah", bundleID: nil)
    default: return Launch(ownerName: "Flick", bundleID: "app.flick.player")
    }
}()

func appPath() -> String {
    switch playerName {
    case "Flick": return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/../build/Flick.app").standardizedFileURL.path
    default: return "/Applications/\(playerName).app"
    }
}

var proc: Process?
func startPlayer() {
    if playerName == "mpv" {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
        p.arguments = ["--no-config", "--pause", "--keep-open=yes", "--hwdec=auto", "--geometry=1600x900+0+40", videoPath]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run()
        proc = p
    } else {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", appPath(), videoPath]
        try! p.run(); p.waitUntilExit()
    }
}

func runningApp() -> NSRunningApplication? {
    // CGWindowList is always current (NSWorkspace's list goes stale in a CLI process)
    let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in l where (w[kCGWindowOwnerName as String] as? String) == launch.ownerName {
        if let pid = w[kCGWindowOwnerPID as String] as? Int32, let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated { return a }
    }
    return nil
}

func quitPlayer() {
    if let p = proc { p.terminate(); p.waitUntilExit(); return }
    runningApp()?.terminate()
    for _ in 0..<50 where runningApp() != nil { sleep(0.1) }
    runningApp()?.forceTerminate()
}

/// Place the player's main window at the same spot and size for every player.
// global points, top-left origin, main display. BENCH_X shifts the window sideways (e.g. to keep the barcode
// clear of a system prompt sitting mid-screen); every player in a run gets the same position.
let target = CGRect(x: Double(ProcessInfo.processInfo.environment["BENCH_X"] ?? "") ?? 0, y: 40, width: 1600, height: 900)
func placeWindow(_ pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
          let wins = v as? [AXUIElement], let w = wins.first else { return false }
    var pos = target.origin, size = target.size
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    return true
}

// MARK: - Input

let src = CGEventSource(stateID: .hidSystemState)
var inputs: [[String: Any]] = []
func log(_ kind: String, _ extra: [String: Any] = [:]) {
    var e = extra; e["t"] = now(); e["kind"] = kind
    inputs.append(e)
}

func key(_ code: CGKeyCode, down: Bool, repeat r: Bool = false) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
    if r { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    if (123...126).contains(code) { e.flags = [.maskSecondaryFn, .maskNumericPad] }   // what a real arrow key carries
    log(down ? (r ? "keyRepeat" : "keyDown") : "keyUp", ["code": Int(code)])
    e.post(tap: .cghidEventTap)
}

func tap(_ code: CGKeyCode) { key(code, down: true); sleep(0.03); key(code, down: false) }

func mouse(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    let kind: String
    switch type {
    case .leftMouseDown: kind = "down"
    case .leftMouseUp: kind = "up"
    case .leftMouseDragged: kind = "drag"
    default: kind = "move"
    }
    log(kind, ["x": p.x, "y": p.y])
    e.post(tap: .cghidEventTap)
}

// MARK: - Capture + barcode

final class Recorder: NSObject, SCStreamOutput {
    var frames: [(Double, Int)] = []
    var latest: CVPixelBuffer?
    var video: CGRect?            // video rect inside the captured image, in pixels
    var lastDump = 0.0
    var misses = 0
    var recalibrating = false
    var recalibrations = 0
    static let calQ = DispatchQueue(label: "cal", qos: .utility)
    static let dumpDir = ProcessInfo.processInfo.environment["BENCH_DUMP"]
    static let ciContext = CIContext()
    let lock = NSLock()

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        lock.lock(); defer { lock.unlock() }
        latest = px
        if let d = Recorder.dumpDir, t - lastDump > 0.25 {
            lastDump = t
            let ci = CIImage(cvPixelBuffer: px)
            if let cg = Recorder.ciContext.createCGImage(ci, from: ci.extent) {
                let n = String(format: "%@/%.3f.png", d, t)
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: n))
            }
        }
        if let v = video {
            let n = Recorder.decode(px, v)
            frames.append((t, n))
            // A player that re-lays out its window mid-run (IINA does) moves the strip: find it again.
            misses = n < 0 ? misses + 1 : 0
            if misses >= 24 && !recalibrating {
                recalibrating = true
                Recorder.calQ.async { [weak self] in
                    let r = calibrate(px)
                    self?.lock.lock()
                    if let r { self?.video = r; self?.recalibrations += 1 }
                    self?.misses = 0; self?.recalibrating = false
                    self?.lock.unlock()
                }
            }
        }
    }

    func snapshot() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return latest }
    func setVideo(_ r: CGRect) { lock.lock(); video = r; lock.unlock() }
    func take() -> [(Double, Int)] { lock.lock(); defer { lock.unlock() }; return frames }

    /// Read the 16-bit frame number. -1 if the strip isn't cleanly visible (overlay, transition, mid-blend).
    static func decode(_ px: CVPixelBuffer, _ v: CGRect) -> Int {
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        let bpr = CVPixelBufferGetBytesPerRow(px)
        let base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
        func luma(_ fx: Double, _ fy: Double) -> Int {
            let cx = Int(v.minX + v.width * fx), cy = Int(v.minY + v.height * fy)
            var sum = 0
            for dy in -1...1 { for dx in -1...1 {
                let x = max(0, min(w - 1, cx + dx * 2)), y = max(0, min(h - 1, cy + dy * 2))
                sum += Int(base[y * bpr + x * 4 + 1])
            } }
            return sum / 9
        }
        var n = 0
        for b in 0..<16 {
            let fx = (1920 + 48 + Double(b) * 96) / 3840
            let top = luma(fx, 624 / 2160), bot = luma(fx, 672 / 2160)
            // the two rows are exact complements: one near black, one near white
            if min(top, bot) > 70 || max(top, bot) < 170 { return -1 }
            if top > bot { n |= 1 << b }
        }
        return n
    }

    /// Alignment quality: how cleanly every bit's rows hit black and white. Higher is better.
    static func score(_ px: CVPixelBuffer, _ v: CGRect) -> Int {
        var total = 0
        for dy in [-4.0, 0, 4] {
            for dx in [-4.0, 0, 4] {
                if decode(px, v.offsetBy(dx: dx, dy: dy)) < 0 { return -1 }
                total += 1
            }
        }
        return total
    }
}

/// Find where the 16:9 video sits inside the captured window (titlebars and toolbars differ per player).
func calibrate(_ px: CVPixelBuffer) -> CGRect? {
    let W = Double(CVPixelBufferGetWidth(px)), H = Double(CVPixelBufferGetHeight(px))
    // Gather every aspect-fit candidate whose barcode reads robustly (survives ±4 px jitter), then take the
    // centre of that region so we sit in the middle of the strip rows, not on an edge.
    var ok: [CGRect] = []
    for top in stride(from: 0.0, through: 140, by: 1) {
        for bottom in stride(from: 0.0, through: 200, by: 2) {
            let ah = H - top - bottom
            var vw = W, vh = W * 9 / 16
            if vh > ah { vh = ah; vw = ah * 16 / 9 }
            let r = CGRect(x: (W - vw) / 2, y: top + (ah - vh) / 2, width: vw, height: vh)
            if Recorder.score(px, r) > 0 { ok.append(r) }
        }
    }
    guard !ok.isEmpty else { return nil }
    // Several near-miss rects decode a still frame. Take the one deepest inside the valid region:
    // the most offsets in a ±8 px grid that still decode; ties go to the larger rect.
    func depth(_ r: CGRect) -> Int {
        var n = 0
        for dy in stride(from: -8.0, through: 8, by: 2) { for dx in stride(from: -8.0, through: 8, by: 2) {
            if Recorder.decode(px, r.offsetBy(dx: dx, dy: dy)) >= 0 { n += 1 }
        } }
        return n
    }
    let step = max(1, ok.count / 400)
    let scored = stride(from: 0, to: ok.count, by: step).map { (ok[$0], depth(ok[$0])) }
    return scored.max { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.width < $1.0.width }?.0
}

// MARK: - Run

let rec = Recorder()
var result: [String: Any] = ["player": playerName, "video": videoPath, "scenario": scenario]
let done = DispatchSemaphore(value: 0)

Task.detached {
    quitPlayer()
    startPlayer()
    var app: NSRunningApplication?
    var placed = false
    for _ in 0..<60 {
        sleep(0.25)
        guard let a = runningApp(), !a.isTerminated else { continue }
        app = a
        if placeWindow(a.processIdentifier) { placed = true; break }
    }
    guard let app else { print("player did not start"); exit(1) }
    if !placed { print("could not place window") }
    sleep(1.0)
    app.activate(options: [.activateIgnoringOtherApps])
    _ = placeWindow(app.processIdentifier)
    sleep(1.0)

    let content = try! await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let win = content.windows.filter({ $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 400 })
            .max(by: { $0.frame.width < $1.frame.width }) else { print("no window"); exit(1) }
    let display = content.displays.first { $0.frame.contains(CGPoint(x: win.frame.midX, y: win.frame.midY)) } ?? content.displays[0]
    let cfg = SCStreamConfiguration()
    let scale = 1.0
    cfg.sourceRect = CGRect(x: win.frame.minX - display.frame.minX, y: win.frame.minY - display.frame.minY, width: win.frame.width, height: win.frame.height)
    cfg.width = Int(win.frame.width * scale); cfg.height = Int(win.frame.height * scale)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
    cfg.queueDepth = 8
    cfg.showsCursor = false
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    try! stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap", qos: .userInteractive))
    try! await stream.startCapture()
    result["window"] = ["x": win.frame.minX, "y": win.frame.minY, "w": win.frame.width, "h": win.frame.height]

    // Make the window frontmost and settle; then pause if the player auto-played.
    let wf = win.frame
    // Focus by clicking the window's top edge (titlebar strip: no player acts on it), then insist it's frontmost.
    mouse(.mouseMoved, CGPoint(x: wf.midX, y: wf.minY + 6)); sleep(0.1)
    mouse(.leftMouseDown, CGPoint(x: wf.midX, y: wf.minY + 6)); sleep(0.05)
    mouse(.leftMouseUp, CGPoint(x: wf.midX, y: wf.minY + 6)); sleep(0.4)
    var front = false
    for _ in 0..<20 { if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { front = true; break }; sleep(0.1) }
    guard front else { print("player is not frontmost; refusing to send keys"); try? await stream.stopCapture(); quitPlayer(); exit(1) }
    result["windowAfterPlace"] = ["w": wf.width, "h": wf.height]
    mouse(.mouseMoved, CGPoint(x: wf.midX, y: wf.midY))
    sleep(0.8)
    var vrect: CGRect?
    for _ in 0..<30 { if let px = rec.snapshot(), let r = calibrate(px) { vrect = r; break }; sleep(0.2) }
    if vrect == nil, let px = rec.snapshot() {
        let ci = CIImage(cvPixelBuffer: px)
        let cg = CIContext().createCGImage(ci, from: ci.extent)!
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath + ".calfail.png"))
    }
    guard let vrect else { print("calibration failed (barcode not found)"); try? await stream.stopCapture(); quitPlayer(); exit(1) }
    rec.setVideo(vrect)
    result["videoRect"] = ["x": vrect.minX, "y": vrect.minY, "w": vrect.width, "h": vrect.height]
    sleep(0.6)
    func moving() -> Bool {
        // compare the last *readable* frame numbers half a second apart
        func lastValid() -> Int? { rec.take().last(where: { $0.1 >= 0 })?.1 }
        var a: Int?
        for _ in 0..<10 { a = lastValid(); if a != nil { break }; sleep(0.1) }
        sleep(0.5)
        return a != lastValid()
    }
    if true {   // every scenario starts paused (playback scenarios press Play themselves)
        if moving() { tap(49); sleep(0.4) }
        if moving() { tap(49); sleep(0.4) }
        if moving() { print("could not pause player") }
    }
    sleep(1.0)
    for _ in 0..<20 { if let px = rec.snapshot(), let r = calibrate(px) { rec.setVideo(r); result["videoRect"] = ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]; break }; sleep(0.2) }
    sleep(0.3)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
        print("lost focus; aborting"); try? await stream.stopCapture(); quitPlayer(); exit(1)
    }
    log("start")

    switch scenario {
    case "hold":
        // Hold → for 4 s with key repeat every 33 ms (fast user key-repeat setting), release, then watch it settle.
        // IINA on this Mac is configured with "x = seek 10" and no arrow binding: use the owner's skip key.
        let k: CGKeyCode = playerName == "IINA" ? 7 : 124
        result["holdKey"] = Int(k)
        key(k, down: true)
        sleep(0.25)
        let t0 = now()
        while now() - t0 < 4.0 { key(k, down: true, repeat: true); sleep(0.033) }
        key(k, down: false)
        sleep(2.5)
    case "drag", "click":
        guard let (x0, x1, yb) = barSpec else { print("--bar needed"); exit(2) }
        let y = wf.maxY - yb
        let ax = wf.minX + x0, bx = wf.minX + x1
        mouse(.mouseMoved, CGPoint(x: ax + 40, y: y)); sleep(0.7)
        mouse(.mouseMoved, CGPoint(x: ax + 50, y: y)); sleep(0.3)
        if scenario == "drag" {
            // forward sweep 5% → 95% in 3 s, rest 0.5 s, back sweep to 30% in 1.5 s, release
            let fx = ax + (bx - ax) * 0.05, tx = ax + (bx - ax) * 0.95, back = ax + (bx - ax) * 0.30
            mouse(.leftMouseDown, CGPoint(x: fx, y: y))
            log("dragStart")
            var t0 = now()
            while true { let f = (now() - t0) / 3.0; if f >= 1 { break }; mouse(.leftMouseDragged, CGPoint(x: fx + (tx - fx) * f, y: y)); sleep(0.008) }
            mouse(.leftMouseDragged, CGPoint(x: tx, y: y))
            log("dragRest")
            sleep(0.5)
            t0 = now()
            while true { let f = (now() - t0) / 1.5; if f >= 1 { break }; mouse(.leftMouseDragged, CGPoint(x: tx + (back - tx) * f, y: y)); sleep(0.008) }
            mouse(.leftMouseDragged, CGPoint(x: back, y: y))
            mouse(.leftMouseUp, CGPoint(x: back, y: y))
            sleep(2.0)
        } else {
            // the same 12 spots on the bar for every run and every player, so medians compare like with like
            // (time to an exact frame depends on how far past a keyframe the click lands)
            let spots = [0.62, 0.17, 0.83, 0.41, 0.09, 0.71, 0.28, 0.94, 0.53, 0.35, 0.77, 0.22]
            for f in spots {
                let x = ax + (bx - ax) * f
                mouse(.mouseMoved, CGPoint(x: x, y: y)); sleep(0.15)
                mouse(.leftMouseDown, CGPoint(x: x, y: y)); sleep(0.05)
                mouse(.leftMouseUp, CGPoint(x: x, y: y))
                sleep(1.6)
            }
        }
    case "play1", "play2", "play4":
        // Normal playback for 10 s at 1×, 2× or 4×; frames shown vs expected comes from the capture,
        // CPU time and CPU energy from the kernel's per-process accounting (player + video decoder services).
        let rate = Int(scenario.dropFirst(4))!
        if playerName == "Flick" {
            tap(CGKeyCode([1: 18, 2: 19, 4: 21][rate]!))          // Flick: number keys set the speed
            sleep(0.4)
        } else if rate != 1 { print("\(playerName) has no speed control"); exit(3) }
        func pids() -> [Int32] {
            var out = [app.processIdentifier]
            let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            _ = l
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "VTDecoderXPCService"]
            let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
            out += String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
            return out
        }
        func usage(_ pid: Int32) -> (cpu: Double, nj: Double) {
            var info = rusage_info_v6()
            let r = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) } }
            guard r == 0 else { return (0, 0) }
            var tb = mach_timebase_info(); mach_timebase_info(&tb)
            return (Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom) / 1e9, Double(info.ri_energy_nj))
        }
        tap(49)                                                     // Space: play
        log("playStart")
        sleep(0.8)                                                  // let playback settle before measuring
        let ps = pids()
        let before = ps.map(usage)
        log("measureStart")
        sleep(10.0)
        let after = ps.map(usage)
        log("measureEnd")
        if ProcessInfo.processInfo.environment["BENCH_KEEP"] == nil { tap(49) }   // kept open for a memory sample: keep playing
        var appCPU = 0.0, vtCPU = 0.0, appJ = 0.0, vtJ = 0.0
        for (i, pid) in ps.enumerated() {
            let c = after[i].cpu - before[i].cpu, j = (after[i].nj - before[i].nj) / 1e9
            if pid == app.processIdentifier { appCPU += c; appJ += j } else { vtCPU += c; vtJ += j }
        }
        result["playback"] = ["rate": rate, "seconds": 10, "appCPU": appCPU, "vtCPU": vtCPU, "appJoules": appJ, "vtJoules": vtJ]
        sleep(0.3)
    case "ui":
        // reveal controls and leave the player open for a screenshot
        mouse(.mouseMoved, CGPoint(x: wf.midX, y: wf.maxY - 40)); sleep(0.3)
        mouse(.mouseMoved, CGPoint(x: wf.midX + 10, y: wf.maxY - 30)); sleep(0.3)
        let content2 = try! await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        if let w2 = content2.windows.first(where: { $0.windowID == win.windowID }) {
            let c = SCStreamConfiguration(); c.width = Int(w2.frame.width); c.height = Int(w2.frame.height)
            let img = try! await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w2), configuration: c)
            try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath + ".png"))
        }
        try? await stream.stopCapture()
        quitPlayer()
        exit(0)
    default: break
    }
    log("end")
    sleep(0.3)
    try? await stream.stopCapture()
    result["inputs"] = inputs
    result["frames"] = rec.take().map { [$0.0, $0.1] }
    result["recalibrations"] = rec.recalibrations
    result["pid"] = Int(app.processIdentifier)
    if ProcessInfo.processInfo.environment["BENCH_KEEP"] == nil { quitPlayer() }
    let data = try! JSONSerialization.data(withJSONObject: result, options: [])
    try! data.write(to: URL(fileURLWithPath: outPath))
    print("ok \(playerName) \(scenario): \(rec.take().count) captured frames")
    exit(0)
}
RunLoop.main.run()
