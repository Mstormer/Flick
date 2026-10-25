import Foundation

/// A Matroska / WebM reader: parses the EBML tree straight out of a memory-mapped file and produces
/// a packet table per track. No demuxer library; ~1 µs per block on Apple silicon, so a two-hour
/// film indexes in well under a second once the pages are cached.
final class MKVFile {
    struct Track {
        var number = 0
        var type = 0                     // 1 video, 2 audio, 17 subtitle
        var codecID = ""
        var codecPrivate: Data?
        var defaultDuration: Int64 = 0   // ns per frame, 0 if absent
        var width = 0, height = 0
        var displayWidth = 0, displayHeight = 0
        var sampleRate = 8000.0
        var channels = 1
        var bitDepth = 0
        var codecDelay: Int64 = 0        // ns
        var isDefault = true
        var language = "eng"
        var name = ""
        // colour (ISO/IEC 23091-4 code points)
        var matrix = 2, transfer = 2, primaries = 2, range = 0
    }

    struct Packet {
        var pts: Int64          // in timecodeScale units (normally ms)
        var offset: Int64
        var size: Int32
        var keyframe: Bool
        var discardable: Bool
        var duration: Int32     // timecodeScale units, 0 if unknown
    }

    let url: URL
    private(set) var tracks: [Track] = []
    typealias Packets = MappedTable<Packet>
    private(set) var packets: [Int: Packets] = [:]   // by track number
    /// Per-track totals that outlive the packet tables (the info panel's bitrate and frame rate).
    struct Totals { var count = 0; var bytes = 0; var first: Packet? }
    private(set) var totals: [Int: Totals] = [:]
    private(set) var timecodeScale: Int64 = 1_000_000  // ns per timestamp unit
    private(set) var duration: Double = 0              // seconds
    let base: UnsafePointer<UInt8>
    let length: Int
    let headerOnly: Bool
    private let raw: UnsafeMutableRawPointer

    /// `headerOnly`: stop at the first cluster, so only the tracks and info are read (a few KB instead of
    /// every block header, which on a network share means pulling most of the file across).
    init?(url: URL, headerOnly: Bool = false) {
        self.url = url
        self.headerOnly = headerOnly
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        guard st.st_size > 64, let p = mmap(nil, Int(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }
        madvise(p, Int(st.st_size), MADV_SEQUENTIAL)
        raw = p
        base = UnsafePointer(p.assumingMemoryBound(to: UInt8.self))
        length = Int(st.st_size)
        guard parse() else { munmap(raw, length); return nil }
    }

    deinit { munmap(raw, length) }

    /// Once the players are built (they keep their own copies of what they play), the audio and video
    /// tables aren't needed here: two hours of three audio tracks is ~30 MB. Subtitle tables stay for captions.
    func dropPlaybackPackets() {
        let keep = Set(tracks.filter { $0.type == 17 }.map(\.number))
        packets = packets.filter { keep.contains($0.key) }
    }

    var video: Track? { tracks.first { $0.type == 1 } }
    var audioTracks: [Track] { tracks.filter { $0.type == 2 } }

    func seconds(_ ts: Int64) -> Double { Double(ts) * Double(timecodeScale) / 1e9 }

    // MARK: EBML primitives

    private static let unknownSize: Int64 = -1

    /// Element ID with its length-marker bits kept (as the spec writes IDs).
    private func readID(_ o: inout Int) -> UInt32? {
        guard o < length else { return nil }
        let b = base[o]
        var len = 1
        var mask: UInt8 = 0x80
        while len <= 4 && b & mask == 0 { len += 1; mask >>= 1 }
        guard len <= 4, o + len <= length else { return nil }
        var v: UInt32 = 0
        for i in 0..<len { v = v << 8 | UInt32(base[o + i]) }
        o += len
        return v
    }

    /// Data size (marker stripped). All-ones means "unknown" (live / streamed clusters).
    private func readSize(_ o: inout Int) -> Int64? {
        guard o < length else { return nil }
        let b = base[o]
        var len = 1
        var mask: UInt8 = 0x80
        while len <= 8 && b & mask == 0 { len += 1; mask >>= 1 }
        guard len <= 8, o + len <= length else { return nil }
        var v = Int64(b & (mask &- 1))
        var allOnes = v == Int64(mask &- 1)
        for i in 1..<len {
            let x = base[o + i]
            if x != 0xFF { allOnes = false }
            v = v << 8 | Int64(x)
        }
        o += len
        return allOnes ? MKVFile.unknownSize : v
    }

    private func uint(_ o: Int, _ n: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<min(n, 8) { v = v << 8 | Int64(base[o + i]) }
        return v
    }

    private func float(_ o: Int, _ n: Int) -> Double {
        if n == 4 { return Double(Float(bitPattern: UInt32(truncatingIfNeeded: uint(o, 4)))) }
        if n == 8 { return Double(bitPattern: UInt64(bitPattern: uint(o, 8))) }
        return 0
    }

    private func string(_ o: Int, _ n: Int) -> String {
        let d = Data(bytes: base + o, count: n)
        return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Walk the children of [start, end), calling `f(id, dataOffset, dataSize)`.
    private func children(_ start: Int, _ end: Int, _ f: (UInt32, Int, Int) -> Void) {
        var o = start
        while o < end {
            guard let id = readID(&o), let sz = readSize(&o) else { return }
            let n = sz < 0 ? end - o : Int(min(sz, Int64(end - o)))
            f(id, o, n)
            o += n
        }
    }

    // MARK: structure

    private static let clusterLevelIDs: Set<UInt32> = [0x1F43B675, 0x1C53BB6B, 0x1254C367, 0x1941A469, 0x1043A770, 0x114D9B74, 0x1549A966, 0x1654AE6B]

    private func parse() -> Bool {
        var o = 0
        guard readID(&o) == 0x1A45DFA3, let hs = readSize(&o), hs >= 0 else { return false }   // EBML header
        o += Int(hs)
        guard readID(&o) == 0x18538067, let segSize = readSize(&o) else { return false }       // Segment
        let segEnd = segSize < 0 ? length : min(length, o + Int(segSize))

        while o < segEnd {
            let elemStart = o
            guard let id = readID(&o), let sz = readSize(&o) else { break }
            switch id {
            case 0x1549A966: // Info
                let end = min(segEnd, o + Int(sz))
                var dur = 0.0
                children(o, end) { cid, co, cn in
                    if cid == 0x2AD7B1 { self.timecodeScale = self.uint(co, cn) }
                    if cid == 0x4489 { dur = self.float(co, cn) }
                }
                duration = dur * Double(timecodeScale) / 1e9
                o = end
            case 0x1654AE6B: // Tracks
                let end = min(segEnd, o + Int(sz))
                children(o, end) { cid, co, cn in if cid == 0xAE { self.parseTrack(co, co + cn) } }
                o = end
            case 0x1F43B675: // Cluster
                if headerOnly { return video != nil }
                if sz < 0 {
                    o = parseCluster(o, segEnd, unknownSize: true)
                } else {
                    let end = min(segEnd, o + Int(sz))
                    _ = parseCluster(o, end, unknownSize: false)
                    o = end
                }
            default:
                if sz < 0 { return !tracks.isEmpty }
                o += Int(sz)
            }
            if o <= elemStart { break }
        }
        for (k, a) in packets {
            a.sort { $0.offset < $1.offset }
            totals[k] = Totals(count: a.count, bytes: a.reduce(0) { $0 + Int($1.size) }, first: a.first)
        }
        if duration <= 0, let v = video, let last = packets[v.number]?.max(by: { $0.pts < $1.pts }) {
            duration = seconds(last.pts + Int64(last.duration))
        }
        return !tracks.isEmpty && video != nil && !(packets[video!.number]?.isEmpty ?? true)
    }

    private func parseTrack(_ start: Int, _ end: Int) {
        var t = Track()
        children(start, end) { id, o, n in
            switch id {
            case 0xD7: t.number = Int(self.uint(o, n))
            case 0x83: t.type = Int(self.uint(o, n))
            case 0x86: t.codecID = self.string(o, n)
            case 0x63A2: t.codecPrivate = Data(bytes: self.base + o, count: n)
            case 0x23E383: t.defaultDuration = self.uint(o, n)
            case 0x56AA: t.codecDelay = self.uint(o, n)
            case 0x88: t.isDefault = self.uint(o, n) != 0
            case 0x22B59C: t.language = self.string(o, n)
            case 0x536E: t.name = self.string(o, n)
            case 0xE0:
                self.children(o, o + n) { vid, vo, vn in
                    switch vid {
                    case 0xB0: t.width = Int(self.uint(vo, vn))
                    case 0xBA: t.height = Int(self.uint(vo, vn))
                    case 0x54B0: t.displayWidth = Int(self.uint(vo, vn))
                    case 0x54BA: t.displayHeight = Int(self.uint(vo, vn))
                    case 0x55B0:
                        self.children(vo, vo + vn) { cid, co, cn in
                            switch cid {
                            case 0x55B1: t.matrix = Int(self.uint(co, cn))
                            case 0x55BA: t.transfer = Int(self.uint(co, cn))
                            case 0x55BB: t.primaries = Int(self.uint(co, cn))
                            case 0x55B9: t.range = Int(self.uint(co, cn))
                            default: break
                            }
                        }
                    default: break
                    }
                }
            case 0xE1:
                self.children(o, o + n) { aid, ao, an in
                    switch aid {
                    case 0xB5: t.sampleRate = self.float(ao, an)
                    case 0x9F: t.channels = Int(self.uint(ao, an))
                    case 0x6264: t.bitDepth = Int(self.uint(ao, an))
                    default: break
                    }
                }
            default: break
            }
        }
        if t.number > 0 { tracks.append(t); packets[t.number] = Packets() }
    }

    /// Returns where parsing stopped (needed for unknown-size clusters).
    private func parseCluster(_ start: Int, _ end: Int, unknownSize: Bool) -> Int {
        var o = start
        var clusterTime: Int64 = 0
        while o < end {
            let elemStart = o
            guard let id = readID(&o) else { return end }
            if unknownSize && MKVFile.clusterLevelIDs.contains(id) { return elemStart }   // next top-level element
            guard let sz = readSize(&o), sz >= 0 else { return end }
            let n = Int(min(sz, Int64(end - o)))
            switch id {
            case 0xE7: clusterTime = uint(o, n)
            case 0xA3: block(o, n, clusterTime: clusterTime, simple: true, refs: false, duration: 0)
            case 0xA0:
                var bo = -1, bn = 0, hasRef = false, dur: Int64 = 0
                children(o, o + n) { cid, co, cn in
                    if cid == 0xA1 { bo = co; bn = cn }
                    if cid == 0xFB { hasRef = true }
                    if cid == 0x9B { dur = self.uint(co, cn) }
                }
                if bo >= 0 { block(bo, bn, clusterTime: clusterTime, simple: false, refs: hasRef, duration: dur) }
            default: break
            }
            o += n
        }
        return end
    }

    private func block(_ start: Int, _ n: Int, clusterTime: Int64, simple: Bool, refs: Bool, duration: Int64) {
        var o = start
        guard let tn = readSize(&o), o + 3 <= start + n, packets[Int(tn)] != nil else { return }
        let rel = Int16(bitPattern: UInt16(base[o]) << 8 | UInt16(base[o + 1]))
        let flags = base[o + 2]
        o += 3
        let pts = clusterTime + Int64(rel)
        let key = simple ? flags & 0x80 != 0 : !refs
        let disc = simple && flags & 0x01 != 0
        let end = start + n
        let track = Int(tn)
        let lacing = (flags >> 1) & 3
        if lacing == 0 {
            packets[track]?.append(Packet(pts: pts, offset: Int64(o), size: Int32(end - o), keyframe: key, discardable: disc, duration: Int32(duration)))
            return
        }
        // Laced frames (audio): split, and give each its own timestamp from the track's frame duration.
        guard o < end else { return }
        let count = Int(base[o]) + 1
        o += 1
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph
            for _ in 0..<(count - 1) {
                var s = 0
                while o < end { let b = Int(base[o]); o += 1; s += b; if b != 255 { break } }
                sizes.append(s)
            }
        case 3: // EBML
            guard let first = readSize(&o) else { return }
            sizes.append(Int(first))
            for _ in 1..<(count - 1) {
                let p0 = o
                guard let raw = readSize(&o) else { return }
                let len = o - p0
                let bias = (Int64(1) << (7 * len - 1)) - 1
                sizes.append(sizes.last! + Int(raw - bias))
            }
        default: // fixed
            let each = (end - o) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        let used = sizes.reduce(0, +)
        sizes.append(end - o - used)
        let ns = tracks.first { $0.number == track }?.defaultDuration ?? 0
        let step = ns > 0 ? Int64((Double(ns) / Double(timecodeScale)).rounded()) : 0
        for (i, s) in sizes.enumerated() where s > 0 && o + s <= end {
            packets[track]?.append(Packet(pts: pts + Int64(i) * step, offset: Int64(o), size: Int32(s), keyframe: key, discardable: disc, duration: Int32(step)))
            o += s
        }
    }
}

/// A table of plain values in memory mapped straight from the system rather than the allocator. Growing
/// copies it to a fresh mapping and unmaps the old one, so the pages go back to macOS at once (freed Swift
/// arrays this size stay cached by the allocator, still counted against the app: ~100 MB after indexing
/// a two-hour film). Pages past the end are never touched and cost nothing. Filled once, then read-only.
final class MappedTable<Element: BitwiseCopyable>: RandomAccessCollection {
    private var base: UnsafeMutablePointer<Element>?
    private var capacity = 0
    private(set) var count = 0

    init() {}
    deinit { if let base { munmap(base, capacity * MemoryLayout<Element>.stride) } }

    var startIndex: Int { 0 }
    var endIndex: Int { count }
    subscript(i: Int) -> Element { precondition(i >= 0 && i < count); return base![i] }

    func append(_ e: Element) {
        if count == capacity { grow() }
        base![count] = e
        count += 1
    }

    func sort(by less: (Element, Element) -> Bool) {
        guard let base, count > 1 else { return }
        var b = UnsafeMutableBufferPointer(start: base, count: count)
        if zip(b, b.dropFirst()).contains(where: { less($1, $0) }) { b.sort(by: less) }   // file order normally is offset order
    }

    private func grow() {
        let stride = MemoryLayout<Element>.stride
        let n = Swift.max(16384 / stride, capacity * 2)                       // whole pages
        guard let p = mmap(nil, n * stride, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), p != MAP_FAILED
        else { fatalError("out of memory") }
        let fresh = p.bindMemory(to: Element.self, capacity: n)
        if let base { fresh.update(from: base, count: count); munmap(base, capacity * stride) }
        base = fresh
        capacity = n
    }
}
