import AppKit
import AVFoundation
// Plays a file off screen, muted, changes the speed mid-playback and prints how the playback clock moved around the
// change (clock seconds per wall second in 25 ms steps), to find a stall. Never takes focus.
//   swiftc -O -swift-version 5 -target arm64-apple-macos14 -o Bench/ratetest/ratetest $(print -l Player/*.swift | grep -v /main.swift) \
//     Bench/Park.swift Bench/ratetest/main.swift -I Player/CFFmpeg -Xcc -IVendor/ffmpeg/include -L Vendor/ffmpeg/lib \
//     -Xlinker -rpath -Xlinker $PWD/Vendor/ffmpeg/lib
//   Bench/ratetest/ratetest file from to
NSApplication.shared.setActivationPolicy(.prohibited)
PlayerView.startMuted = true
let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "rate test")
let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1]), from = Float(args[2]) ?? 1, to = Float(args[3]) ?? 1.5
let wc = PlayerWindowController(url: url)
let w = wc.window!
let observers = adopt(w)
var waited = 0.0
while wc.view.backend == nil && !wc.view.openFailed && waited < 20 { spin(0.1); waited += 0.1 }
guard let b = wc.view.backend else { print("no player"); exit(1) }
print(String(describing: type(of: b)))
b.play(rate: from)
spin(3)
var samples: [(Double, Double)] = []
let t0 = CACurrentMediaTime()
var changedAt = 0.0
var did = false
while CACurrentMediaTime() - t0 < 3 {
    spin(0.002)
    let now = CACurrentMediaTime() - t0
    if !did && now > 1 { did = true; changedAt = now; b.setRate(to) }
    samples.append((now, b.currentSeconds))
}
// clock speed over 25 ms windows
var out: [String] = []
var i = 0
while i < samples.count {
    var j = i
    while j < samples.count && samples[j].0 - samples[i].0 < 0.025 { j += 1 }
    if j >= samples.count { break }
    let v = (samples[j].1 - samples[i].1) / (samples[j].0 - samples[i].0)
    if abs(samples[i].0 - changedAt) < 0.6 { out.append(String(format: "%+.3f:%.2f", samples[i].0 - changedAt, v)) }
    i = j
}
print("clock speed (media s per wall s) from -0.6 to +0.6 s around the change; wanted \(from)→\(to):")
print(out.joined(separator: " "))
var mn = 99.0, mx = 0.0
var k = 0
for s in samples where s.0 > changedAt + 0.8 || s.0 < changedAt - 0.1 { k += 1 }
w.orderOut(nil); wc.view.teardown()
exit(0)
