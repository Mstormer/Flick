import AVFoundation
setvbuf(stdout, nil, _IONBF, 0)
import CoreVideo
import VideoToolbox
var xfer: VTPixelTransferSession? = { var x: VTPixelTransferSession?; VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &x); return x }()
func readable(_ px: CVPixelBuffer) -> CVPixelBuffer {
    var out: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(px), CVPixelBufferGetHeight(px), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &out)
    VTPixelTransferSessionTransferImage(xfer!, from: px, to: out!)
    return out!
}

func barcode(_ px: CVPixelBuffer) -> Int {
    let ft = CVPixelBufferGetPixelFormatType(px); if ft != 875704422 && ft != 875704438 && ft != 2016686640 { print("fmt", String(format: "%08x", ft), CVPixelBufferGetPlaneCount(px)); return -1 }
    CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
    let w = CVPixelBufferGetWidthOfPlane(px, 0)
    let sx = Double(w) / 3840
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(px, 0)!
    let tenBit = CVPixelBufferGetPixelFormatType(px) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    func y(_ x: Double, _ yy: Double) -> Int {
        let xi = Int(x * sx), yi = Int(yy * sx)
        if tenBit { return Int(base.load(fromByteOffset: yi * bpr + xi * 2, as: UInt16.self) >> 8) }
        return Int(base.load(fromByteOffset: yi * bpr + xi, as: UInt8.self))
    }
    var n = 0
    for b in 0..<16 { let x = 1920 + 48 + Double(b) * 96; if y(x, 624) > y(x, 672) { n |= 1 << b } }
    return n
}

let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.absoluteURL
let sema = DispatchSemaphore(value: 0)
Task {
    let t0 = CFAbsoluteTimeGetCurrent()
    let idx: MediaIndex
    if ["mkv", "webm"].contains(url.pathExtension.lowercased()) {
        guard let m = MKVFile(url: url) else { print("mkv parse failed"); exit(1) }
        let tp = CFAbsoluteTimeGetCurrent() - t0
        print(String(format: "mkv: %.1f ms parse, tracks %@, scale %lld, dur %.1fs", tp * 1000, m.tracks.map { "\($0.number):\($0.codecID) n=\(m.packets[$0.number]?.count ?? 0)" }.joined(separator: " "), m.timecodeScale, m.duration))
        for a in m.audioTracks { print("  audio \(a.codecID): format", MKVCodecs.audioFormat(a) != nil ? "ok" : "unsupported") }
        guard let i = MediaIndex(mkv: m) else { print("index failed"); exit(1) }
        idx = i
    } else {
        guard let i = await MediaIndex(asset: AVURLAsset(url: url)) else { print("index failed"); exit(1) }
        idx = i
    }
    print(String(format: "index: %d samples, %.1f ms, sync=%d droppable=%d dur=%.1fs", idx.samples.count,
                 (CFAbsoluteTimeGetCurrent() - t0) * 1000, idx.samples.filter(\.sync).count,
                 idx.samples.filter(\.droppable).count, idx.duration))
    let eng = ScrubEngine(index: idx)!
    let done = DispatchSemaphore(value: 0)
    var gotPx: CVPixelBuffer?
    var tStart = 0.0, first = -1.0, want = -1, wrong = 0
    eng.onFrame = { px, d, exact in
        if first < 0 { first = CFAbsoluteTimeGetCurrent() - tStart }
        if exact && d == want {
            gotPx = px
            done.signal()
        }
    }
    var lat: [Double] = [], firsts: [Double] = []
    var rng = SystemRandomNumberGenerator()
    let given = CommandLine.arguments.count > 2 ? try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).split(separator: "\n").compactMap { Double($0) } : []
    for k in 0..<(given.isEmpty ? 40 : given.count) {
        let s = given.isEmpty ? Double.random(in: 0..<idx.duration - 1, using: &rng) : given[k]
        want = idx.frame(at: s); first = -1
        tStart = CFAbsoluteTimeGetCurrent()
        eng.seek(frame: want)
        done.wait()
        lat.append((CFAbsoluteTimeGetCurrent() - tStart) * 1000); firsts.append(first * 1000)
        let got = barcode(readable(gotPx!)), exp = idx.byPTS.firstIndex(of: Int32(want))!
        if got != exp { wrong += 1; print("  MISMATCH frame \(exp) shows \(got)") }
    }
    print("RAW " + lat.map { String(format: "%.1f", $0) }.joined(separator: ","))
    lat.sort(); firsts.sort()
    print(String(format: "exact seek ms: median %.1f p90 %.1f max %.1f | first picture median %.1f | wrong %d",
                 lat[lat.count/2], lat[lat.count*9/10], lat.last!, firsts[firsts.count/2], wrong))
    sema.signal()
}
sema.wait()
