import AppKit
NSApplication.shared.setActivationPolicy(.prohibited)
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func sh(_ c: String) -> String { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", c]; let o = Pipe(); p.standardOutput = o; try? p.run(); p.waitUntilExit(); return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
func mb(_ pid: String) -> Int { Int(sh("footprint -p \(pid) 2>/dev/null | awk '/Footprint:/ {v=$(NF-5); u=$(NF-4); if (u==\"GB\") v*=1024; if (u==\"KB\") v/=1024; print int(v); exit}'").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
func vt() -> Int { sh("pgrep -f VTDecoderXPCService").split(separator: "\n").map { mb(String($0)) }.reduce(0, +) }
let base = vt()
let wc = PlayerWindowController(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let w = wc.window!; w.setFrame(NSRect(x: -20000, y: -20000, width: 1600, height: 900), display: false); w.orderFrontRegardless()
spin(3)
wc.view.backend?.isMuted = true
let playing = (mb(String(getpid())), vt() - base)
wc.view.togglePlay()          // pause, as a viewer would
spin(8)
let paused = (mb(String(getpid())), vt() - base)
print(String(format: "%@ | vt baseline %d MB | playing: app %d + vt %d = %d MB | paused 8 s: app %d + vt %d = %d MB",
             ProcessInfo.processInfo.environment["LABEL"] ?? "", base, playing.0, playing.1, playing.0 + playing.1, paused.0, paused.1, paused.0 + paused.1))
let t0 = wc.view.backend?.currentSeconds ?? -1
let t1 = Date()
wc.view.togglePlay()
var resumed = -1.0
for _ in 0..<200 { spin(0.01); if wc.view.backend?.isPlaying == true && (wc.view.backend?.currentSeconds ?? 0) > t0 + 0.01 { resumed = Date().timeIntervalSince(t1); break } }
spin(2)
print(String(format: "   suspended while paused: %@ | play after trim: playing=%@, resumed in %.0f ms, time %.2f → %.2f s",
             "\(wc.view.backend?.isSuspended == false ? "no longer (revived)" : "still")", "\(wc.view.backend?.isPlaying == true)", resumed * 1000, t0, wc.view.backend?.currentSeconds ?? -1))
w.orderOut(nil); wc.view.teardown()
