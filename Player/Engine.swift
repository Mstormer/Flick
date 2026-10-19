import AVFoundation
import CoreMedia
import VideoToolbox

/// One video sample, in decode order.
struct Sample {
    var pts: Int64
    var dts: Int64
    var dur: Int64
    var offset: Int64
    var size: Int32
    var sync: Bool
    var droppable: Bool
}

/// A flat sample table for the video track plus a read-only mapping of the file,
/// so the scrub engine can hand raw samples to VideoToolbox with no demuxer in between.
final class MediaIndex {
    let samples: [Sample]          // decode order
    let byPTS: [Int32]             // decode indices sorted by presentation time
    let syncOf: [Int32]            // decode index of the sync sample governing each sample
    let timescale: Int32
    let format: CMVideoFormatDescription
    let duration: Double
    let frameDuration: Double
    private let base: UnsafeMutableRawPointer
    private let mappedLength: Int
    private let codec: CMVideoCodecType
    private let nalLen: Int
    private let dropState: UnsafeMutablePointer<UInt8>   // 0 not read yet, 1 droppable, 2 referenced

    convenience init?(asset: AVURLAsset) async {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              (try? await track.load(.canProvideSampleCursors)) == true,
              let fmt = try? await track.load(.formatDescriptions).first,
              let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder()
        else { return nil }
        let ts = (try? await track.load(.naturalTimeScale)) ?? 600
        let url = asset.url.standardizedFileURL.absoluteURL

        var out: [Sample] = []
        out.reserveCapacity(1 << 16)
        func conv(_ t: CMTime) -> Int64 { t.convertScale(ts, method: .roundHalfAwayFromZero).value }
        let ownPath = url.standardizedFileURL.path
        var lastURL: URL?
        repeat {
            // external data refs: not supported (normalising a path per sample cost ~0.4 s on long files)
            let u = cursor.currentChunkStorageURL
            if u != lastURL { guard u?.standardizedFileURL.path == ownPath else { return nil }; lastURL = u }
            let r = cursor.currentSampleStorageRange
            let si = cursor.currentSampleSyncInfo
            out.append(Sample(pts: conv(cursor.presentationTimeStamp),
                              dts: conv(cursor.decodeTimeStamp),
                              dur: conv(cursor.currentSampleDuration),
                              offset: r.offset, size: Int32(r.length),
                              sync: si.sampleIsFullSync.boolValue,
                              droppable: si.sampleIsDroppable.boolValue))
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        self.init(url: url, samples: out, timescale: ts, format: fmt)
    }

    /// Matroska: the same table, from the EBML block list (decode order = file order, no DTS stored).
    convenience init?(mkv: MKVFile) {
        guard let v = mkv.video, let fmt = MKVCodecs.videoFormat(v), let pk = mkv.packets[v.number], !pk.isEmpty else { return nil }
        let ts = Int32(clamping: 1_000_000_000 / max(1, mkv.timecodeScale))
        let fixed = v.defaultDuration > 0 ? Int64((Double(v.defaultDuration) / Double(mkv.timecodeScale)).rounded()) : 0
        // Durations from the gap to the next frame in presentation order when the track doesn't state one.
        let order = pk.indices.sorted { pk[$0].pts < pk[$1].pts }
        var dur = [Int64](repeating: fixed, count: pk.count)
        if fixed == 0 {
            for (k, i) in order.enumerated() {
                dur[i] = k + 1 < order.count ? max(1, pk[order[k + 1]].pts - pk[i].pts) : (k > 0 ? dur[order[k - 1]] : 1)
            }
        }
        // Matroska stores no decode timestamps. Derive them the usual way: the i-th sample in decode order
        // gets the i-th smallest PTS, shifted back by the deepest reorder so DTS never passes PTS. Without
        // them the playback renderer mis-orders B-frames right after a seek.
        let sortedPTS = order.map { pk[$0].pts }
        let delay = pk.indices.map { sortedPTS[$0] - pk[$0].pts }.max().map { max(0, $0) } ?? 0
        let out = pk.indices.map { i in
            Sample(pts: pk[i].pts, dts: sortedPTS[i] - delay, dur: dur[i], offset: pk[i].offset, size: pk[i].size,
                   sync: pk[i].keyframe, droppable: pk[i].discardable)
        }
        self.init(url: mkv.url, samples: out, timescale: ts, format: fmt)
    }

    init?(url: URL, samples out: [Sample], timescale ts: Int32, format fmt: CMVideoFormatDescription) {
        var out = out
        guard !out.isEmpty else { return nil }
        if !out.contains(where: { $0.sync }) { for i in out.indices { out[i].sync = true } }
        out[0].sync = true

        var sync = [Int32](repeating: 0, count: out.count)
        var last: Int32 = 0
        for i in out.indices { if out[i].sync { last = Int32(i) }; sync[i] = last }

        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        guard let p = mmap(nil, Int(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }

        // Container rarely flags non-reference frames; the first slice NAL header says. It's read lazily
        // (isDroppable): scanning every sample up front reads pages across the whole file, 0.5-2 s for 4K.
        let codec = CMFormatDescriptionGetMediaSubType(fmt)
        var nalLen: Int32 = 4
        if codec == kCMVideoCodecType_H264 {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalLen)
        } else if codec == kCMVideoCodecType_HEVC {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalLen)
        }
        self.codec = codec
        self.nalLen = Int(nalLen)
        dropState = .allocate(capacity: out.count)
        dropState.initialize(repeating: 0, count: out.count)

        samples = out
        byPTS = out.indices.sorted { out[$0].pts < out[$1].pts }.map(Int32.init)
        syncOf = sync
        timescale = ts
        format = fmt
        base = p
        mappedLength = Int(st.st_size)
        let lastS = out[Int(byPTS.last!)]
        let first = out[Int(byPTS[0])].pts
        duration = Double(lastS.pts + lastS.dur - first) / Double(ts)
        frameDuration = Double(out.map(\.dur).max() ?? 1) / Double(ts)
    }

    deinit { munmap(base, mappedLength); dropState.deallocate() }

    /// Nothing references this frame: skip it unless it's the one to show. Byte-sized entries, so the
    /// chase thread and the playback queue can both fill them in.
    func isDroppable(_ i: Int) -> Bool {
        let s = samples[i]
        if s.sync { return false }
        if s.droppable { return true }
        switch dropState[i] {
        case 1: return true
        case 2: return false
        default: break
        }
        var drop = false
        if codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var o = Int(s.offset)
            let end = min(o + Int(s.size), mappedLength)
            while o + nalLen + 2 <= end {
                var n = 0
                for k in 0..<nalLen { n = n << 8 | Int(bytes[o + k]) }
                let h = bytes[o + nalLen]
                if codec == kCMVideoCodecType_H264 {
                    let type = h & 0x1f
                    if type == 1 || type == 5 { drop = (h & 0x60) == 0; break }
                } else {
                    let type = (h >> 1) & 0x3f
                    if type < 32 { drop = type <= 14 && type % 2 == 0; break }
                }
                o += nalLen + n
            }
        }
        dropState[i] = drop ? 1 : 2
        return drop
    }

    var startPTS: Int64 { samples[Int(byPTS[0])].pts }

    /// Decode index of the frame on screen at `seconds` (the last frame starting at or before it).
    func frame(at seconds: Double) -> Int {
        let t = startPTS + Int64((seconds * Double(timescale)).rounded(.down))
        var lo = 0, hi = byPTS.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[Int(byPTS[mid])].pts <= t { lo = mid } else { hi = mid - 1 }
        }
        return Int(byPTS[lo])
    }

    /// Presentation-order neighbour of a decode index.
    func step(_ d: Int, by n: Int) -> Int {
        guard let i = byPTS.firstIndex(of: Int32(d)) else { return d }
        return Int(byPTS[max(0, min(byPTS.count - 1, i + n))])
    }

    func seconds(_ d: Int) -> Double { Double(samples[d].pts - startPTS) / Double(timescale) }

    /// Sync sample a decode must start from to reach `d` (steps back one GOP for open-GOP leading pictures).
    func gopStart(for d: Int) -> Int {
        var g = Int(syncOf[d])
        if samples[d].pts < samples[g].pts, g > 0 { g = Int(syncOf[g - 1]) }
        return g
    }

    func sampleBuffer(_ d: Int) -> CMSampleBuffer? {
        let s = samples[d]
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: base + Int(s.offset),
                                                 blockLength: Int(s.size), blockAllocator: kCFAllocatorNull,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: Int(s.size),
                                                 flags: 0, blockBufferOut: &block) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: s.dur, timescale: timescale),
                                        presentationTimeStamp: CMTime(value: s.pts, timescale: timescale),
                                        decodeTimeStamp: s.dts == Int64.min ? .invalid : CMTime(value: s.dts, timescale: timescale))
        var size = Int(s.size)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                  sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        return sb
    }
}

/// Opt-in event trace (FLICK_TRACE=/path) for tuning the chase; off in normal use.
enum Trace {
    static let fh: FileHandle? = {
        guard let p = ProcessInfo.processInfo.environment["FLICK_TRACE"] ?? (UserDefaults.standard.string(forKey: "trace")) else { return nil }
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }()
    static let q = DispatchQueue(label: "trace")
    static func log(_ s: @autoclosure () -> String) {
        guard let fh else { return }
        let line = String(format: "%.4f ", CACurrentMediaTime()) + s() + "\n"
        q.async { fh.write(line.data(using: .utf8)!) }
    }
}

/// Small LRU of decoded frames, bounded by bytes.
final class FrameCache {
    private var map: [Int: (CVPixelBuffer, UInt64)] = [:]
    private var tick: UInt64 = 0
    private(set) var bytes = 0
    let budget: Int
    init(budget: Int) { self.budget = budget }

    func peek(_ k: Int) -> CVPixelBuffer? { map[k]?.0 }

    func removeAll() { map = [:]; bytes = 0 }

    func get(_ k: Int) -> CVPixelBuffer? {
        guard let e = map[k] else { return nil }
        tick += 1; map[k] = (e.0, tick)
        return e.0
    }

    func put(_ k: Int, _ px: CVPixelBuffer) {
        if map[k] != nil { return }
        tick += 1
        map[k] = (px, tick)
        bytes += CVPixelBufferGetDataSize(px)
        while bytes > budget, let victim = map.min(by: { $0.value.1 < $1.value.1 }) {
            bytes -= CVPixelBufferGetDataSize(victim.value.0)
            map[victim.key] = nil
        }
    }
}

/// The scrub engine: a single decoder that continuously "chases" the latest target frame.
/// Moving the target never queues work; it just redirects the chase. Every decoded picture that is
/// closer to the current target than what's on screen gets shown, so the picture keeps moving even
/// when the exact frame is hundreds of decodes away (long-GOP camera footage).
final class ScrubEngine {
    let index: MediaIndex
    /// Called on the decode thread with a frame to display immediately.
    var onFrame: ((CVPixelBuffer, Int, _ exact: Bool) -> Void)?
    /// The chase could not produce this frame (decoder error); called on the chase thread.
    var onFail: ((Int) -> Void)?

    private let lock = NSLock()
    private var target = -1               // decode index we want on screen (-1: nothing asked for yet)
    private var gen = 0
    private var prefetchList: [Int] = []   // frames worth decoding ahead of time while idle
    private var idle = false               // player paused: the decoder is ours to use in the background
    private lazy var keyframes: [Int] = index.samples.indices.filter { index.samples[$0].sync }
    private let wake = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private var alive = true

    /// One hardware decoder session positioned somewhere in the file. Two lanes let one chase the GOP under
    /// the pointer while the other pre-decodes the keyframe of the GOP the pointer is heading into, hiding the
    /// 15-20 ms a 4K keyframe takes to decode.
    private final class Lane {
        let session: VTDecompressionSession
        var gop = -1                       // sync sample this lane was last reset to
        var next = -1                      // next decode index to feed in that GOP
        var used = 0
        var broken = false                 // the decoder reported an error: rebuild before next use (guarded by outLock)
        init(_ s: VTDecompressionSession) { session = s }
    }

    // decode-thread state
    private var lanes: [Lane] = []
    private var tick = 0
    private var direction = 0              // +1 dragging forward, -1 backward (guarded by lock)
    private var lastSeekAt = 0.0           // when the target last moved (guarded by lock)
    private var prevSeekAt = 0.0           // the move before that (guarded by lock)

    /// The pointer is still moving: worth showing in-between pictures and pre-decoding the next GOP.
    /// Once it stops, every decode goes to reaching the exact frame. A lone seek (a click, a single skip)
    /// isn't motion: it goes straight to full batches, ~20 ms sooner to a deep frame.
    private var moving: Bool {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        // a run of seeks (a drag, a held key: its first repeat comes ~0.27 s after the press) is motion
        return now - lastSeekAt < 0.06 && lastSeekAt - prevSeekAt < 0.35
    }

    /// The pointer was released: stop treating the last seeks as motion.
    func settle() {
        lock.lock(); lastSeekAt = 0; prevSeekAt = 0; lock.unlock()
        wake.signal()
    }
    private var failedGen = -1
    private var retries = 0
    private var failedPrefetch = -1
    // shared with VideoToolbox's output thread (guarded by outLock)
    private let outLock = NSLock()
    private var shown = -1                 // decode index currently on screen
    /// Decoded-frame cache. A 4K frame is ~15 MB, so this is the main memory cost of fast seeking.
    /// `defaults write app.flick.player cacheMB <n>` overrides the default for experiments.
    static let defaultCacheMB = 32
    private let cache: FrameCache = {
        let mb = UserDefaults.standard.integer(forKey: "cacheMB")
        return FrameCache(budget: (mb > 0 ? mb : ScrubEngine.defaultCacheMB) << 20)
    }()

    init?(index: MediaIndex) {
        self.index = index
        guard let first = ScrubEngine.makeLane(index) else { return nil }
        VTDecompressionSessionInvalidate(first.session)
        let t = Thread { [weak self] in self?.run() }
        t.qualityOfService = .userInteractive
        t.name = "flick.chase"
        t.start()
    }

    /// Decoder sessions are created when seeking starts and released after a few idle seconds:
    /// each 4K session keeps a pool of decoded-frame buffers alive (~250 MB) for as long as it exists.
    private static func makeLane(_ index: MediaIndex) -> Lane? {
        let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                     kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: index.format, decoderSpecification: spec,
                                           imageBufferAttributes: attrs, outputCallback: nil,
                                           decompressionSessionOut: &s) == noErr, let s else { return nil }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        return Lane(s)
    }

    private func ensureLanes(_ n: Int) {
        while lanes.count < n, let l = ScrubEngine.makeLane(index) {
            Trace.log("lane created (\(lanes.count + 1))")
            lanes.append(l)
        }
    }

    private func releaseLanes() {
        guard !lanes.isEmpty else { return }
        for l in lanes {
            VTDecompressionSessionWaitForAsynchronousFrames(l.session)
            VTDecompressionSessionInvalidate(l.session)
        }
        Trace.log("lanes released")
        lanes = []
    }

    /// Whether VideoToolbox will decode this stream at all (e.g. AV1 needs an M3 or later).
    static func canDecode(_ index: MediaIndex) -> Bool {
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: index.format, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &s) == noErr,
              let s else { return false }
        VTDecompressionSessionInvalidate(s)
        return true
    }

    func stop() {
        lock.lock(); alive = false; lock.unlock()
        wake.signal()
    }

    deinit { lanes.forEach { VTDecompressionSessionInvalidate($0.session) } }

    /// Point the chase at a new frame (decode index). Returns immediately.
    func seek(frame d: Int) {
        Trace.log("seek \(d)")
        lock.lock()
        if d != target { direction = d > target ? 1 : -1 }
        prevSeekAt = lastSeekAt
        lastSeekAt = CACurrentMediaTime()
        target = d; gen &+= 1
        lock.unlock()
        wake.signal()
    }

    var targetFrame: Int { current().0 }

    /// The scrub layer was cleared: show the target again even if it was already on screen.
    func redisplay() {
        outLock.lock(); shown = -1; outLock.unlock()
        lock.lock(); gen &+= 1; lock.unlock()
        wake.signal()
    }

    /// Frames the user is likely to ask for next (e.g. ±5 s). Decoded into the cache only while otherwise idle.
    func prefetch(_ frames: [Int]) {
        lock.lock(); prefetchList = frames; lock.unlock()
        wake.signal()
    }

    /// Allow background decoding (only while the player is paused, so playback never loses the decoder).
    /// Playback starting empties the cache: its 4K frames sit in the system decoder's memory (~12 MB
    /// each) and nothing uses them while playing. Pausing fills it again.
    func setIdle(_ on: Bool) {
        lock.lock(); idle = on; lock.unlock()
        if on { wake.signal() } else { outLock.lock(); cache.removeAll(); outLock.unlock() }
    }

    private func nextPrefetch() -> Int? {
        lock.lock(); let l = prefetchList, on = idle, t = target; lock.unlock()
        guard on else { return nil }
        outLock.lock(); defer { outLock.unlock() }
        if let p = l.first(where: { cache.peek($0) == nil }) { return p }
        // Then warm the keyframe cache outward from the playhead, so a drag across GOPs shows
        // every keyframe it crosses without decoding. Stop at 60% of the budget to leave room.
        guard cache.bytes < cache.budget * 6 / 10 else { return nil }
        guard t >= 0 else { return nil }
        let tp = index.samples[t].pts
        return keyframes.filter { cache.peek($0) == nil }
            .min { abs(index.samples[$0].pts - tp) < abs(index.samples[$1].pts - tp) }
    }

    private func isWanted(_ d: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return d == target || prefetchList.contains(d)
    }

    private func current() -> (Int, Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (target, gen, alive)
    }

    private func shownFrame() -> Int { outLock.lock(); defer { outLock.unlock() }; return shown }

    private func distance(_ a: Int, _ b: Int) -> Int64 {
        abs(index.samples[a].pts - index.samples[b].pts)
    }

    /// Show `d` if it is closer to the current target than what's on screen. Caller holds outLock.
    private func offer(_ px: CVPixelBuffer, _ d: Int) {
        let t = current().0
        if shown >= 0, d != t, distance(d, t) >= distance(shown, t) { return }
        shown = d
        Trace.log("show \(d) target \(t)")
        onFrame?(px, d, d == t)
    }

    private func run() {
        while true {
            let (t, g, alive) = current()
            if !alive { return }
            if t < 0 {                                   // nothing asked for yet: don't decode on spec
                if wake.wait(timeout: .now() + 1.5) == .timedOut { releaseLanes() }
                continue
            }
            outLock.lock()
            let done = shown == t
            let cached = done ? nil : cache.get(t)
            if let cached { offer(cached, t) }
            outLock.unlock()
            if done || cached != nil || g == failedGen {
                if done, let p = nextPrefetch(), p != failedPrefetch {
                    chase(toward: p, gen: g, prefetching: true)
                } else if wake.wait(timeout: .now() + 1.5) == .timedOut {
                    releaseLanes()
                }
                continue
            }
            chase(toward: t, gen: g)
        }
    }

    private func feed(_ lane: Lane, _ d: Int) {
        guard let sb = index.sampleBuffer(d) else { return }
        let keep = index.samples[d].sync
        Trace.log("feed \(d)")
        let st = VTDecompressionSessionDecodeFrame(lane.session, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression],
                                                   infoFlagsOut: nil) { [weak self, weak lane] status, _, image, _, _ in
            guard let self else { return }
            if status != noErr {
                Trace.log("decode error \(status) at \(d)")
                self.outLock.lock(); lane?.broken = true; self.outLock.unlock()
            }
            guard status == noErr, let image else { return }
            Trace.log("out \(d)")
            self.outLock.lock()
            if keep || self.isWanted(d) { self.cache.put(d, image) }
            self.offer(image, d)
            self.outLock.unlock()
        }
        if st != noErr {
            Trace.log("decode refused \(st) at \(d)")
            outLock.lock(); lane.broken = true; outLock.unlock()
        }
    }

    /// Throw away sessions the decoder gave up on (e.g. after the hardware decoder reset); fresh ones follow.
    private func dropBrokenLanes() -> Bool {
        outLock.lock(); let bad = lanes.filter { $0.broken }; outLock.unlock()
        guard !bad.isEmpty else { return false }
        Trace.log("dropping \(bad.count) broken lanes")
        for l in bad { VTDecompressionSessionInvalidate(l.session) }
        lanes.removeAll { l in bad.contains { $0 === l } }
        return true
    }

    /// Feed a short batch toward `t`, then return so the run loop can notice a retarget.
    private func chase(toward t: Int, gen g: Int, prefetching: Bool = false) {
        let start = index.gopStart(for: t)
        _ = dropBrokenLanes()
        ensureLanes(1)
        guard !lanes.isEmpty else { return }
        let lane: Lane
        if let l = lanes.first(where: { $0.gop == start && $0.next >= 0 && $0.next <= t }) {
            lane = l
        } else {
            // No drain: feeding a keyframe resets the session's references, and any stale pictures still
            // in flight lose the closest-to-target test in offer(). Retargeting costs nothing.
            lane = lanes.min { $0.used < $1.used }!
            Trace.log("reset gop \(start) target \(t)")
            lane.gop = start; lane.next = start
            outLock.lock()
            if let px = cache.get(start) { offer(px, start) }
            outLock.unlock()
        }
        tick += 1; lane.used = tick
        let live = moving
        let batch = live ? 4 : 12
        var fed = 0
        var i = lane.next
        while i <= t && fed < batch {
            // the user moved: drop speculation at once, but remember what this lane has already been fed;
            // feeding those frames again corrupts the decoder's references (HEVC reports bad data, -12909)
            if prefetching && current().0 != shownFrame() { lane.next = i; return }
            if i != t && index.isDroppable(i) { i += 1; continue }   // nothing references it and it isn't the goal
            feed(lane, i)
            fed += 1
            i += 1
        }
        // H.264 holds decoded pictures back for B-frame reordering; we tag frames ourselves, so ask for them now.
        // H.264 holds pictures back for B-frame reordering. Pull them out only while the pointer moves
        // (so in-between frames show); forcing it on a settled chase stalls the decoder pipeline.
        if fed > 0 && live { VTDecompressionSessionFinishDelayedFrames(lane.session) }
        lane.next = i
        if !prefetching && live { speculate(from: start, besides: lane) }
        if i > t {
            VTDecompressionSessionWaitForAsynchronousFrames(lane.session)
            outLock.lock()
            let reached = prefetching ? cache.get(t) != nil : shown == t
            outLock.unlock()
            if !reached {
                if dropBrokenLanes(), retries < 2 {
                    retries += 1                       // decoder error: start this frame over on a fresh session
                } else if prefetching {
                    failedPrefetch = t; retries = 0
                } else if current().1 == g {
                    failedGen = g; retries = 0
                    onFail?(t)
                }
            } else {
                retries = 0
            }
        }
    }

    /// While the pointer moves, put the other lane on the keyframe of the GOP it is heading into.
    private func speculate(from start: Int, besides active: Lane) {
        lock.lock(); let dir = direction; lock.unlock()
        guard dir != 0, let k = keyframes.firstIndex(of: start) else { return }
        let n = k + dir
        guard keyframes.indices.contains(n) else { return }
        let g = keyframes[n]
        guard !lanes.contains(where: { $0.gop == g }) else { return }
        ensureLanes(2)
        guard let spare = lanes.first(where: { $0 !== active }) else { return }
        Trace.log("speculate gop \(g)")
        spare.gop = g
        feed(spare, g)
        spare.next = g + 1
        VTDecompressionSessionFinishDelayedFrames(spare.session)
    }
}
