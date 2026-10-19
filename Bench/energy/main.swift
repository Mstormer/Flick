import AppKit
import Darwin
NSApplication.shared.setActivationPolicy(.prohibited)
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func sh(_ c: String) -> String { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", c]; let o = Pipe(); p.standardOutput = o; try? p.run(); p.waitUntilExit(); return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
func usage(_ pid: Int32) -> (cpu: Double, j: Double, wake: UInt64) {
    var info = rusage_info_v6()
    let r = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) } }
    guard r == 0 else { return (0, 0, 0) }
    var tb = mach_timebase_info(); mach_timebase_info(&tb)
    return (Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom) / 1e9, Double(info.ri_energy_nj) / 1e9, info.ri_pkg_idle_wkups + info.ri_interrupt_wkups)
}
let wc = PlayerWindowController(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let w = wc.window!; w.setFrame(NSRect(x: -20000, y: -20000, width: 1600, height: 900), display: false); w.orderFrontRegardless()
spin(3)
wc.view.backend?.isMuted = true
let vts = sh("pgrep -f VTDecoderXPCService").split(separator: "\n").compactMap { Int32($0) }
let me = getpid()
let a0 = usage(me), v0 = vts.map(usage)
spin(10)
let a1 = usage(me), v1 = vts.map(usage)
let vcpu = zip(v0, v1).map { $1.cpu - $0.cpu }.reduce(0, +), vj = zip(v0, v1).map { $1.j - $0.j }.reduce(0, +)
print(String(format: "%@ | 10 s playing: app CPU %.2f s, %.2f J, %llu wakeups | decoder services CPU %.2f s, %.2f J | total CPU %.1f%%",
             ProcessInfo.processInfo.environment["LABEL"] ?? "", a1.cpu - a0.cpu, a1.j - a0.j, a1.wake - a0.wake, vcpu, vj, (a1.cpu - a0.cpu + vcpu) * 10))
w.orderOut(nil); wc.view.teardown()
