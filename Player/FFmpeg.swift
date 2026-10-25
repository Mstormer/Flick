import AVFoundation
import Accelerate
import CFFmpeg
import VideoToolbox

// Formats macOS can't decode (WMV/VC-1, WMA, DTS, TrueHD, Vorbis, and VP9 the hardware decoder refuses),
// through the bundled LGPL FFmpeg libraries (Tools/build-ffmpeg.sh). Everything here decodes in software,
// so it only runs for files nothing else can play.

/// A value shared between the feed queue and the main thread.
final class Locked<T> {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

/// An Int several threads read and one writes: lets a running decode notice a newer seek and stop.
final class Latest {
    private let lock = NSLock()
    private var v = 0
    var value: Int { lock.withLock { v } }
    @discardableResult func bump() -> Int { lock.withLock { v &+= 1; return v } }
}

// MARK: - Audio

/// Compressed audio packets for FFAudio, from the Matroska table or from libavformat.
protocol PacketFeed: AnyObject {
    var timeBase: AVRational { get }
    func reset(at seconds: Double)
    /// Fills `pkt` with the next packet; false at the end.
    func next(_ pkt: UnsafeMutablePointer<AVPacket>) -> Bool
}

/// Decoded to interleaved Float32 for AudioOut. Used on one queue only.
final class FFAudio: AudioSource {
    let format: CMAudioFormatDescription
    private let ctx: UnsafeMutablePointer<AVCodecContext>
    private let feed: PacketFeed
    private let pkt = av_packet_alloc()!
    private let frame = av_frame_alloc()!
    private let channels: Int
    private let rate: Int32
    private var nextTime = 0.0
    private var skipBefore = -Double.infinity      // after a reset: audio before the target is dropped, not played early
    private var drained = false

    convenience init?(codec id: AVCodecID, extradata: Data?, sampleRate: Int, channels ch: Int, feed: PacketFeed) {
        guard let codec = avcodec_find_decoder(id), let c = avcodec_alloc_context3(codec) else { return nil }
        c.pointee.sample_rate = Int32(sampleRate)
        av_channel_layout_default(&c.pointee.ch_layout, Int32(ch))
        if let e = extradata, !e.isEmpty, let p = av_mallocz(e.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)) {
            e.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: e.count)
            c.pointee.extradata = p.assumingMemoryBound(to: UInt8.self)
            c.pointee.extradata_size = Int32(e.count)
        }
        self.init(ctx: c, codec: codec, feed: feed)
    }

    convenience init?(parameters par: UnsafePointer<AVCodecParameters>, feed: PacketFeed) {
        guard let codec = avcodec_find_decoder(par.pointee.codec_id), let c = avcodec_alloc_context3(codec) else { return nil }
        avcodec_parameters_to_context(c, par)
        self.init(ctx: c, codec: codec, feed: feed)
    }

    private init?(ctx c: UnsafeMutablePointer<AVCodecContext>, codec: UnsafePointer<AVCodec>, feed: PacketFeed) {
        var c: UnsafeMutablePointer<AVCodecContext>? = c
        c!.pointee.pkt_timebase = feed.timeBase
        c!.pointee.request_sample_fmt = AV_SAMPLE_FMT_FLTP
        guard avcodec_open2(c, codec, nil) >= 0 else { avcodec_free_context(&c); return nil }
        ctx = c!
        self.feed = feed
        // the real channel layout and rate are only known once a frame is out
        feed.reset(at: 0)
        var probe: (ch: Int, rate: Int32, mask: UInt64)?
        var tries = 0
        while probe == nil && tries < 64 && feed.next(pkt) {
            tries += 1
            if avcodec_send_packet(ctx, pkt) >= 0, avcodec_receive_frame(ctx, frame) >= 0 {
                let l = frame.pointee.ch_layout
                probe = (Int(l.nb_channels), frame.pointee.sample_rate, l.order == AV_CHANNEL_ORDER_NATIVE ? l.u.mask : 0)
            }
            av_packet_unref(pkt)
            av_frame_unref(frame)
        }
        guard let probe, probe.ch > 0, probe.rate > 0 else { avcodec_free_context(&c); return nil }
        avcodec_flush_buffers(ctx)
        channels = probe.ch
        rate = probe.rate
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(probe.rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * probe.ch), mFramesPerPacket: 1,
                                               mBytesPerFrame: UInt32(4 * probe.ch), mChannelsPerFrame: UInt32(probe.ch),
                                               mBitsPerChannel: 32, mReserved: 0)
        // FFmpeg's channel mask uses the same bits, in the same sample order, as Core Audio's channel bitmap
        var layout = AudioChannelLayout()
        if probe.ch == 1 { layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono }
        else if probe.ch == 2 { layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo }
        else if probe.mask != 0, probe.mask <= UInt64(UInt32.max), probe.mask.nonzeroBitCount == probe.ch {
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
            layout.mChannelBitmap = AudioChannelBitmap(rawValue: UInt32(probe.mask))
        } else { layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(probe.ch) }
        var f: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &f) == noErr,
              let f else { avcodec_free_context(&c); return nil }
        format = f
    }

    deinit {
        var c: UnsafeMutablePointer<AVCodecContext>? = ctx
        avcodec_free_context(&c)
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
        var fr: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&fr)
    }

    func reset(at seconds: Double) {
        avcodec_flush_buffers(ctx)
        feed.reset(at: seconds)
        nextTime = seconds
        skipBefore = seconds
        drained = false
    }

    func next() -> CMSampleBuffer? {
        while true {
            let r = avcodec_receive_frame(ctx, frame)
            if r >= 0 {
                defer { av_frame_unref(frame) }
                if let sb = buffer() { return sb }
                continue
            }
            if r != ff_eagain() || drained { return nil }
            if feed.next(pkt) {
                avcodec_send_packet(ctx, pkt)        // a damaged packet is skipped, like any player would
                av_packet_unref(pkt)
            } else {
                avcodec_send_packet(ctx, nil)
                drained = true
            }
        }
    }

    private func buffer() -> CMSampleBuffer? {
        let n0 = Int(frame.pointee.nb_samples)
        guard n0 > 0, Int(frame.pointee.ch_layout.nb_channels) == channels, frame.pointee.sample_rate == rate else { return nil }
        let ts = frame.pointee.best_effort_timestamp
        var t = ts != ff_nopts() ? Double(ts) * av_q2d(feed.timeBase) : nextTime
        nextTime = t + Double(n0) / Double(rate)
        // the demuxer can only land on a packet boundary (or, without an audio index, well before): trim to the target
        var from = 0
        if t < skipBefore {
            guard nextTime > skipBefore else { return nil }
            from = min(n0 - 1, Int(((skipBefore - t) * Double(rate)).rounded(.down)))
            t += Double(from) / Double(rate)
        }
        skipBefore = -Double.infinity
        let n = n0 - from
        let bytes = n * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var raw: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &raw)
        guard let raw else { return nil }
        let out = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: Float.self)
        Self.interleave(frame, n0, channels, from: from, into: out)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: n,
                                                             presentationTimeStamp: CMTime(seconds: t, preferredTimescale: rate),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    /// Any of the sample formats these decoders put out, as interleaved Float32.
    private static func interleave(_ f: UnsafeMutablePointer<AVFrame>, _ total: Int, _ ch: Int, from: Int, into out: UnsafeMutablePointer<Float>) {
        let n = total - from
        let fmt = AVSampleFormat(rawValue: f.pointee.format)
        let planar = av_sample_fmt_is_planar(fmt) != 0
        func plane(_ c: Int) -> UnsafeMutableRawPointer {
            UnsafeMutableRawPointer((f.pointee.extended_data[planar ? c : 0])!)
        }
        let bytesPer = Int(av_get_bytes_per_sample(fmt))
        for c in 0..<(planar ? ch : 1) {
            let src = plane(c) + from * bytesPer * (planar ? 1 : ch)
            let count = planar ? n : n * ch
            let stride = planar ? ch : 1
            let dst = out + (planar ? c : 0)
            switch fmt {
            case AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_FLT:
                let s = src.assumingMemoryBound(to: Float.self)
                for i in 0..<count { dst[i * stride] = s[i] }
            case AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_S16:
                let s = src.assumingMemoryBound(to: Int16.self)
                for i in 0..<count { dst[i * stride] = Float(s[i]) / 32768 }
            case AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_S32:
                let s = src.assumingMemoryBound(to: Int32.self)
                for i in 0..<count { dst[i * stride] = Float(s[i]) / 2_147_483_648 }
            case AV_SAMPLE_FMT_DBLP, AV_SAMPLE_FMT_DBL:
                let s = src.assumingMemoryBound(to: Double.self)
                for i in 0..<count { dst[i * stride] = Float(s[i]) }
            default:
                for i in 0..<count { dst[i * stride] = 0 }
            }
        }
    }
}

/// Matroska audio packets (already split from their laces) for FFAudio.
final class MKVPacketFeed: PacketFeed {
    private let mkv: MKVFile
    private let packets: [MKVFile.Packet]
    let timeBase: AVRational
    private var nextIndex = 0

    init(_ mkv: MKVFile, track: MKVFile.Track) {
        self.mkv = mkv
        packets = mkv.packets[track.number] ?? []
        timeBase = AVRational(num: 1, den: Int32(clamping: 1_000_000_000 / max(1, mkv.timecodeScale)))
    }

    func reset(at seconds: Double) {
        // the packet playing at `seconds`; FFAudio trims it to the exact sample
        let t = Int64(seconds / av_q2d(timeBase))
        nextIndex = max(0, (packets.firstIndex { $0.pts > t } ?? packets.count) - 1)
    }

    func next(_ pkt: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard nextIndex < packets.count else { return false }
        let p = packets[nextIndex]
        nextIndex += 1
        guard av_new_packet(pkt, p.size) >= 0 else { return false }
        memcpy(pkt.pointee.data, mkv.base + Int(p.offset), Int(p.size))
        pkt.pointee.pts = p.pts
        pkt.pointee.dts = p.pts
        return true
    }
}

extension MKVCodecs {
    /// Matroska audio only FFmpeg decodes here.
    static func ffAudioCodec(_ t: MKVFile.Track) -> AVCodecID? {
        switch t.codecID {
        case let id where id.hasPrefix("A_DTS"): return AV_CODEC_ID_DTS
        case "A_TRUEHD": return AV_CODEC_ID_TRUEHD
        case "A_MLP": return AV_CODEC_ID_MLP
        case "A_VORBIS": return AV_CODEC_ID_VORBIS
        case "A_ALAC": return AV_CODEC_ID_ALAC
        default: return nil
        }
    }

    /// The audio to play from a Matroska file: the default track if anything here decodes it, else the
    /// first track that decodes. The system's decoders first, FFmpeg's for the rest.
    static func audioSource(_ mkv: MKVFile) -> AudioSource? {
        let tracks = mkv.audioTracks
        func make(_ t: MKVFile.Track) -> AudioSource? {
            if audioFormat(t) != nil { return MKVAudio(mkv, track: t) }
            guard let id = ffAudioCodec(t) else { return nil }
            var extra = t.codecPrivate
            // Matroska keeps ALAC's bare 24-byte config; FFmpeg wants it inside its 'alac' atom
            if id == AV_CODEC_ID_ALAC, let c = extra, c.count == 24 { extra = Data([0, 0, 0, 36]) + Data("alac".utf8) + Data(count: 4) + c }
            return FFAudio(codec: id, extradata: extra, sampleRate: Int(t.sampleRate), channels: t.channels,
                           feed: MKVPacketFeed(mkv, track: t))
        }
        for t in tracks.filter(\.isDefault) + tracks { if let s = make(t) { return s } }
        return nil
    }
}

// MARK: - Demuxing

/// One stream of a file through libavformat; every other stream is skipped at the demuxer.
final class FFDemux: PacketFeed {
    let ctx: UnsafeMutablePointer<AVFormatContext>
    let stream: Int32
    let timeBase: AVRational

    init?(url: URL, type: CFFmpeg.AVMediaType) {
        var c: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&c, url.path, nil, nil) >= 0, let c0 = c else { return nil }
        guard avformat_find_stream_info(c0, nil) >= 0 else { avformat_close_input(&c); return nil }
        let s = av_find_best_stream(c0, type, -1, -1, nil, 0)
        guard s >= 0 else { avformat_close_input(&c); return nil }
        for i in 0..<Int(c0.pointee.nb_streams) where i != Int(s) { c0.pointee.streams[i]!.pointee.discard = AVDISCARD_ALL }
        ctx = c0
        stream = s
        timeBase = c0.pointee.streams[Int(s)]!.pointee.time_base
    }

    deinit { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c) }

    var parameters: UnsafeMutablePointer<AVCodecParameters> { ctx.pointee.streams[Int(stream)]!.pointee.codecpar }
    var avStream: UnsafeMutablePointer<AVStream> { ctx.pointee.streams[Int(stream)]! }

    /// File duration in seconds.
    var duration: Double {
        let s = avStream.pointee
        if s.duration > 0 { return Double(s.duration) * av_q2d(s.time_base) }
        return ctx.pointee.duration > 0 ? Double(ctx.pointee.duration) / Double(AV_TIME_BASE) : 0
    }

    var startSeconds: Double {
        let s = avStream.pointee
        return s.start_time != ff_nopts() ? Double(s.start_time) * av_q2d(s.time_base) : 0
    }

    /// To the keyframe at or before `seconds` (stream time).
    func reset(at seconds: Double) {
        let ts = Int64((seconds / av_q2d(timeBase)).rounded(.down))
        if avStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
            // audio rarely has its own index (ASF has none): seek by the container's default stream instead
            let us = Int64(seconds * Double(AV_TIME_BASE))
            if av_seek_frame(ctx, -1, us, AVSEEK_FLAG_BACKWARD) >= 0 { return }
        }
        if av_seek_frame(ctx, stream, ts, AVSEEK_FLAG_BACKWARD) < 0 { av_seek_frame(ctx, stream, ts, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY) }
    }

    func next(_ pkt: UnsafeMutablePointer<AVPacket>) -> Bool {
        while av_read_frame(ctx, pkt) >= 0 {
            if pkt.pointee.stream_index == stream { return true }
            av_packet_unref(pkt)
        }
        return false
    }
}

// MARK: - Video

/// Decodes one video stream to IOSurface-backed NV12 (or P010) pixel buffers.
final class FFVideo {
    let demux: FFDemux
    private let ctx: UnsafeMutablePointer<AVCodecContext>
    private let pkt = av_packet_alloc()!
    private let frame = av_frame_alloc()!
    private var pool: CVPixelBufferPool?
    private var poolKey = (0, 0, OSType(0))
    private var drained = false
    let width: Int, height: Int
    let displaySize: CGSize
    let frameDuration: Double

    init?(url: URL, threads: Bool = true) {
        guard let d = FFDemux(url: url, type: AVMEDIA_TYPE_VIDEO) else { return nil }
        let par = d.parameters
        guard let codec = avcodec_find_decoder(par.pointee.codec_id), let c = avcodec_alloc_context3(codec) else { return nil }
        avcodec_parameters_to_context(c, par)
        c.pointee.pkt_timebase = d.timeBase
        c.pointee.thread_count = threads ? 0 : 1
        c.pointee.thread_type = threads ? FF_THREAD_FRAME | FF_THREAD_SLICE : FF_THREAD_SLICE
        var cc: UnsafeMutablePointer<AVCodecContext>? = c
        guard avcodec_open2(c, codec, nil) >= 0 else { avcodec_free_context(&cc); return nil }
        demux = d
        ctx = c
        width = Int(par.pointee.width); height = Int(par.pointee.height)
        guard width > 0, height > 0 else { avcodec_free_context(&cc); return nil }
        let sar = av_guess_sample_aspect_ratio(d.ctx, d.avStream, nil)
        let aspect = sar.num > 0 && sar.den > 0 ? av_q2d(sar) : 1
        displaySize = CGSize(width: (Double(width) * aspect).rounded(), height: Double(height))
        let fr = av_guess_frame_rate(d.ctx, d.avStream, nil)
        frameDuration = fr.num > 0 && fr.den > 0 ? 1 / av_q2d(fr) : 1.0 / 30
    }

    deinit {
        var c: UnsafeMutablePointer<AVCodecContext>? = ctx
        avcodec_free_context(&c)
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
        var fr: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&fr)
    }

    static let eightBit = [AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUV444P, AV_PIX_FMT_YUVJ444P]

    /// Whether this file's pictures can be shown: 8-bit 4:2:0/4:2:2/4:4:4 (all WMV and VC-1) or 10-bit 4:2:0.
    var supported: Bool {
        (Self.eightBit + [AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_NONE]).contains(AVPixelFormat(rawValue: ctx.pointee.pix_fmt.rawValue))
    }

    func seek(to seconds: Double) {
        avcodec_flush_buffers(ctx)
        demux.reset(at: seconds)
        drained = false
    }

    /// The next picture in display order, or nil at the end (or when `abort` says a newer request came in).
    /// Frames `skip` turns down are decoded for their references but never converted.
    func next(skip: (Double, Double) -> Bool = { _, _ in false }, abort: () -> Bool = { false }) -> (CVPixelBuffer, pts: Double, dur: Double)? {
        while !abort() {
            let r = avcodec_receive_frame(ctx, frame)
            if r >= 0 {
                defer { av_frame_unref(frame) }
                let ts = frame.pointee.best_effort_timestamp
                guard ts != ff_nopts() else { continue }
                let pts = Double(ts) * av_q2d(demux.timeBase)
                let dur = frame.pointee.duration > 0 ? Double(frame.pointee.duration) * av_q2d(demux.timeBase) : frameDuration
                if skip(pts, dur) { continue }
                guard let px = pixelBuffer() else { continue }
                return (px, pts, dur)
            }
            if r != ff_eagain() || drained { return nil }
            if demux.next(pkt) {
                avcodec_send_packet(ctx, pkt)
                av_packet_unref(pkt)
            } else {
                avcodec_send_packet(ctx, nil)
                drained = true
            }
        }
        return nil
    }

    private func pixelBuffer() -> CVPixelBuffer? {
        let f = frame.pointee
        let w = Int(f.width), h = Int(f.height)
        let fmt = AVPixelFormat(rawValue: f.format)
        let ten = fmt == AV_PIX_FMT_YUV420P10LE
        guard ten || Self.eightBit.contains(fmt), w > 0, h > 0, let desc = av_pix_fmt_desc_get(fmt) else { return nil }
        let full = [AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P].contains(fmt) || f.color_range == AVCOL_RANGE_JPEG
        let type = ten ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                       : (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        if pool == nil || poolKey != (w, h, type) {
            let attrs = [kCVPixelBufferPixelFormatTypeKey: type, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                         kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                         kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
            CVPixelBufferPoolCreate(nil, nil, attrs, &pool)
            poolKey = (w, h, type)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let px = out else { return nil }
        CVPixelBufferLockBaseAddress(px, [])
        defer { CVPixelBufferUnlockBaseAddress(px, []) }
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!, yStride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let uv = CVPixelBufferGetBaseAddressOfPlane(px, 1)!, uvStride = CVPixelBufferGetBytesPerRowOfPlane(px, 1)
        let src = (f.data.0!, f.data.1!, f.data.2!)
        let ls = (Int(f.linesize.0), Int(f.linesize.1), Int(f.linesize.2))
        if !ten {
            // interlaced (VC-1 broadcast, DVD-sourced WMV): a [1 2 1] vertical blend hides the combing
            let interlaced = f.flags & AV_FRAME_FLAG_INTERLACED != 0
            func plane(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ pw: Int, _ ph: Int) -> vImage_Buffer {
                vImage_Buffer(data: p, height: vImagePixelCount(ph), width: vImagePixelCount(pw), rowBytes: stride)
            }
            func blend(_ from: inout vImage_Buffer, _ to: inout vImage_Buffer) {
                let kernel: [Int16] = [1, 2, 1]
                vImageConvolve_Planar8(&from, &to, nil, 0, 0, kernel, 3, 1, 4, 0, vImage_Flags(kvImageEdgeExtend))
            }
            var yIn = plane(src.0, ls.0, w, h), yOut = plane(y.assumingMemoryBound(to: UInt8.self), yStride, w, h)
            if interlaced { blend(&yIn, &yOut) } else { for r in 0..<h { memcpy(y + r * yStride, src.0 + r * ls.0, w) } }
            // chroma at 4:2:0 size: 4:2:2 and 4:4:4 are averaged down
            let sx = Int(desc.pointee.log2_chroma_w), sy = Int(desc.pointee.log2_chroma_h)
            var temps: [UnsafeMutablePointer<UInt8>] = []
            defer { temps.forEach { $0.deallocate() } }
            func chroma(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int) -> vImage_Buffer {
                var b: vImage_Buffer
                if sx == 1 && sy == 1 { b = plane(p, stride, cw, ch) }
                else {
                    let t = UnsafeMutablePointer<UInt8>.allocate(capacity: cw * ch); temps.append(t)
                    let fw = sx == 1 ? 1 : 2, fh = sy == 1 ? 1 : 2
                    let pw = (w + (1 << sx) - 1) >> sx, ph = (h + (1 << sy) - 1) >> sy
                    for r in 0..<ch { for c in 0..<cw {
                        var sum = 0, n = 0
                        for dy in 0..<fh { for dx in 0..<fw {
                            let rr = min(ph - 1, r * fh + dy), cc = min(pw - 1, c * fw + dx)
                            sum += Int(p[rr * stride + cc]); n += 1
                        } }
                        t[r * cw + c] = UInt8((sum + n / 2) / n)
                    } }
                    b = plane(t, cw, cw, ch)
                }
                guard interlaced else { return b }
                let t = UnsafeMutablePointer<UInt8>.allocate(capacity: cw * ch); temps.append(t)
                var o = plane(t, cw, cw, ch)
                blend(&b, &o)
                return o
            }
            var u = chroma(src.1, ls.1), v = chroma(src.2, ls.2)
            withUnsafePointer(to: &u) { up in withUnsafePointer(to: &v) { vp in
                var planes: [UnsafePointer<vImage_Buffer>?] = [up, vp]
                var dest: [UnsafeMutableRawPointer?] = [uv, uv + 1]
                vImageConvert_PlanarToChunky8(&planes, &dest, 2, 2, vImagePixelCount(cw), vImagePixelCount(ch), uvStride, vImage_Flags(kvImageNoFlags))
            } }
        } else {
            // 10-bit little-endian in the low bits → P010 (high bits)
            for r in 0..<h {
                let s = UnsafeRawPointer(src.0 + r * ls.0).assumingMemoryBound(to: UInt16.self)
                let d = (y + r * yStride).assumingMemoryBound(to: UInt16.self)
                for i in 0..<w { d[i] = s[i] << 6 }
            }
            for r in 0..<ch {
                let su = UnsafeRawPointer(src.1 + r * ls.1).assumingMemoryBound(to: UInt16.self)
                let sv = UnsafeRawPointer(src.2 + r * ls.2).assumingMemoryBound(to: UInt16.self)
                let d = (uv + r * uvStride).assumingMemoryBound(to: UInt16.self)
                for i in 0..<cw { d[2 * i] = su[i] << 6; d[2 * i + 1] = sv[i] << 6 }
            }
        }
        // colour: the stream's own tags (ISO/IEC 23091-4 code points), else BT.601 for SD and BT.709 above
        let sd = h < 720
        let matrix = f.colorspace != AVCOL_SPC_UNSPECIFIED ? Int32(f.colorspace.rawValue) : (sd ? 6 : 1)
        let prim = f.color_primaries != AVCOL_PRI_UNSPECIFIED ? Int32(f.color_primaries.rawValue) : (sd ? 6 : 1)
        let trc = f.color_trc != AVCOL_TRC_UNSPECIFIED ? Int32(f.color_trc.rawValue) : 1
        if let m = CVYCbCrMatrixGetStringForIntegerCodePoint(matrix)?.takeUnretainedValue() {
            CVBufferSetAttachment(px, kCVImageBufferYCbCrMatrixKey, m, .shouldPropagate)
        }
        if let p = CVColorPrimariesGetStringForIntegerCodePoint(prim)?.takeUnretainedValue() {
            CVBufferSetAttachment(px, kCVImageBufferColorPrimariesKey, p, .shouldPropagate)
        }
        if let t = CVTransferFunctionGetStringForIntegerCodePoint(trc)?.takeUnretainedValue() {
            CVBufferSetAttachment(px, kCVImageBufferTransferFunctionKey, t, .shouldPropagate)
        }
        if displaySize.width != CGFloat(width) {
            CVBufferSetAttachment(px, kCVImageBufferPixelAspectRatioKey,
                                  [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(displaySize.width),
                                   kCVImageBufferPixelAspectRatioVerticalSpacingKey: width] as CFDictionary, .shouldPropagate)
        }
        return px
    }
}

// MARK: - Playback

/// Software-decoded video into a sample-buffer display layer, with audio from FFAudio (or the Matroska
/// path), both on one render synchronizer, like NativePlayback. Times are stream seconds throughout.
final class FFPlayback: Playback {
    private let video: FFVideo
    private let display = AVSampleBufferDisplayLayer()
    private var sound: SyncedAudio?
    private let sync = AVSampleBufferRenderSynchronizer()
    private let q = DispatchQueue(label: "flick.ff.video", qos: .userInitiated)
    private let audioSource: AudioSource?
    private let wanted = Latest()                  // newest seek; a decode for an older one stops
    // on q
    private var hideBefore = -Double.infinity      // pictures that end before this are decoded, not shown
    private var queued: [Double] = []              // pts of pictures the layer holds that aren't on screen yet
    private var shown: [(at: Double, pts: Double)] = []   // handed to the layer, newest last (to know what's on screen)
    private var ended = false
    private var lastEnd = -Double.infinity         // end of the latest picture ever decoded
    private let dataEnd = Locked(Double.infinity)  // where the pictures really stop (truncated files), once known
    private var pumpPending = false
    private var flushedGen = -1
    private var targetQueuedGen = -1
    private var endTimer: Timer?
    private(set) var isPlaying = false
    private var rate: Float = 1
    let duration: Double
    let start: Double
    let displaySize: CGSize
    var frameDuration: Double { video.frameDuration }
    var onEnd: (() -> Void)?
    var layer: CALayer { display }
    var isSuspended: Bool { false }
    func suspend() {}                              // SD software decode holds a few small frames only

    /// Opens and probes the file (tens of ms, so off the main thread); for Matroska the caller can pass the
    /// audio it already has.
    static func open(_ url: URL, audio source: AudioSource? = nil) -> (FFVideo, AudioSource?)? {
        guard let v = FFVideo(url: url), v.supported else { return nil }
        if let source { return (v, source) }
        return (v, FFDemux(url: url, type: AVMEDIA_TYPE_AUDIO).flatMap { d in FFAudio(parameters: d.parameters, feed: d) })
    }

    /// On the main thread: it makes the layers.
    init(video v: FFVideo, audio source: AudioSource?) {
        video = v
        audioSource = source
        start = v.demux.startSeconds
        duration = v.demux.duration
        displaySize = v.displaySize
        display.videoGravity = .resizeAspect
        sync.addRenderer(display.sampleBufferRenderer)
        sound = source.flatMap { SyncedAudio(source: $0, sync: sync) }
        sync.delaysRateChangeUntilHasSufficientMediaData = false
        go(to: 0)
    }

    var currentSeconds: Double { max(0, sync.currentTime().seconds - start) }
    private var level: (volume: Float, muted: Bool) = (1, false)       // kept when there's no audio
    var volume: Float { get { sound?.volume ?? level.volume } set { level.volume = newValue; sound?.volume = newValue } }
    var isMuted: Bool { get { sound?.isMuted ?? level.muted } set { level.muted = newValue; sound?.isMuted = newValue } }

    func play(rate r: Float) {
        rate = r
        if currentSeconds >= min(duration, dataEnd.value - start) - 0.05 { seek(to: 0) { _ in } }
        isPlaying = true
        startEndWatch()
        if sound == nil { sync.setRate(r, time: sync.currentTime()) }
        let g = wanted.value
        q.async { [self] in sound?.play(rate: r); pump(g) }       // after any reset queued by a seek
    }

    func pause() {
        isPlaying = false
        sync.rate = 0
        sound?.pause()
        endTimer?.invalidate()
    }

    func setRate(_ r: Float) {
        rate = r
        if let sound { sound.setRate(r, playing: isPlaying) } else if isPlaying { sync.rate = r }
        let g = wanted.value
        q.async { [self] in pump(g) }
    }

    func cancelSeeks() { wanted.bump() }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        let wasPlaying = isPlaying
        sync.rate = 0
        go(to: seconds) { [weak self] ok in
            guard let self else { return }
            if wasPlaying && self.isPlaying {
                if let s = self.sound { self.q.async { s.play(rate: self.rate) } }
                else { self.sync.setRate(self.rate, time: self.sync.currentTime()) }
            }
            completion(ok)
        }
    }

    /// One frame forward or back from the picture on screen.
    func step(_ n: Int) {
        let now = sync.currentTime().seconds
        let onScreen = q.sync { shown.last { $0.at <= now + 0.001 }?.pts } ?? now
        seek(to: onScreen - start + Double(n) * frameDuration + frameDuration * 0.5) { _ in }
    }

    func teardown() {
        pause()
        wanted.bump()
        display.sampleBufferRenderer.stopRequestingMediaData()
        sound?.stop()
    }

    // MARK: feeding

    private func go(to seconds: Double, completion: ((Bool) -> Void)? = nil) {
        let g = wanted.bump()
        let target = start + min(max(0, seconds), max(0, duration - 0.001))
        q.async { [self] in
            guard g == wanted.value else { DispatchQueue.main.async { completion?(false) }; return }
            display.sampleBufferRenderer.stopRequestingMediaData()
            flushedGen = -1
            display.sampleBufferRenderer.flush(removingDisplayedImage: true) { [weak self] in self?.q.async { self?.flushedGen = g } }
            sync.setRate(0, time: CMTime(seconds: target, preferredTimescale: 90000))
            queued = []; shown = []
            ended = false
            pumpPending = false
            hideBefore = target
            video.seek(to: target)
            // audio waits (paused) at the exact target until play resumes
            sound?.pause()
            sound?.reset(at: target)
            pump(g)
            if let completion { waitForPicture(g, deadline: CACurrentMediaTime() + 3, completion) }
        }
    }

    private var lead: Int { max(3, Int((0.1 * Double(max(rate, 1)) / frameDuration).rounded(.up))) }

    private func pump(_ g: Int, timer: Bool = false) {
        if timer { pumpPending = false }
        guard g == wanted.value else { return }
        let now = sync.currentTime().seconds
        queued.removeAll { $0 <= now }
        if shown.count > 64 { shown.removeFirst(shown.count - 64) }
        while !ended && queued.count < lead {
            let hide = hideBefore
            var seen = -Double.infinity
            guard let (px, pts, dur) = video.next(skip: { p, d in seen = max(seen, p + d); return p + d <= hide + 0.0005 },
                                                  abort: { [wanted] in g != wanted.value })
            else {
                guard g == wanted.value else { break }
                ended = true
                lastEnd = max(lastEnd, seen)
                dataEnd.value = lastEnd
                // nothing at or after the target (the file stops before its stated length): show the last picture
                if targetQueuedGen != g && lastEnd > start && hideBefore > lastEnd - 0.001 {
                    let back = lastEnd - frameDuration * 1.5
                    hideBefore = back
                    video.seek(to: back)
                    ended = false
                    continue
                }
                break
            }
            lastEnd = max(lastEnd, pts + dur)
            enqueue(px, pts, dur, g)
        }
        if sync.rate > 0 && !pumpPending && !ended {
            pumpPending = true
            let wait = Double(max(1, lead / 2)) * frameDuration / Double(sync.rate)
            q.asyncAfter(deadline: .now() + wait) { [weak self] in self?.pump(g, timer: true) }
        }
    }

    private func enqueue(_ px: CVPixelBuffer, _ pts: Double, _ dur: Double, _ g: Int) {
        var f: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: px, formatDescriptionOut: &f)
        // the first picture after a seek can start a little before the target: show it at the target
        let t = targetQueuedGen == g ? pts : max(pts, hideBefore)
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: dur, preferredTimescale: 90000),
                                        presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 90000), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard let f else { return }
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: px, formatDescription: f, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        display.sampleBufferRenderer.enqueue(sb)
        queued.append(t)
        shown.append((t, pts))
        targetQueuedGen = g
    }

    private func waitForPicture(_ g: Int, deadline: Double, _ completion: @escaping (Bool) -> Void) {
        guard g == wanted.value else { DispatchQueue.main.async { completion(false) }; return }
        let done: Bool
        if #available(macOS 14.4, *) {
            done = flushedGen == g && targetQueuedGen == g && display.sampleBufferRenderer.displayedPixelBuffer() != nil
        } else { done = targetQueuedGen == g && flushedGen == g }
        if done || ended || CACurrentMediaTime() > deadline {
            DispatchQueue.main.async { completion(true) }
            return
        }
        q.asyncAfter(deadline: .now() + 0.004) { [weak self] in self?.waitForPicture(g, deadline: deadline, completion) }
    }

    private func startEndWatch() {
        endTimer?.invalidate()
        defer { endTimer?.tolerance = 0.1 }
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            if self.currentSeconds >= min(self.duration, self.dataEnd.value - self.start) - 0.02 {
                self.pause()
                self.onEnd?()
            }
            self.sound?.steer(rate: self.rate)
        }
    }
}

// MARK: - Preview pictures

/// Thumbnails for the seek bar from FFmpeg-only files: the keyframe before the asked-for time, scaled by
/// a VideoToolbox pixel transfer. Same rules as Thumbnailer: latest request only, a few cached, all
/// released after a few idle seconds.
final class FFThumbnailer: PreviewSource {
    private let url: URL
    private let q = DispatchQueue(label: "flick.ff.thumbs", qos: .userInitiated)
    private let targetWidth: Int
    // on q
    private var video: FFVideo?
    private var transfer: VTPixelTransferSession?
    private var cache: [Int: CGImage] = [:]
    private var order: [Int] = []
    private var wanted: (Double, (CGImage, Int) -> Void)?
    private var busy = false
    private var idle: DispatchWorkItem?
    var spacing: Double = 0

    init(url: URL, width: Int = 384) { self.url = url; targetWidth = width }

    deinit { if let t = transfer { VTPixelTransferSessionInvalidate(t) } }

    func request(seconds t: Double, _ done: @escaping (CGImage, Int) -> Void) {
        let gap = spacing
        q.async { [self] in
            let k = key(t)
            if let k, let img = cache[k] { DispatchQueue.main.async { done(img, k) }; return }
            wanted = (t, done)
            if !busy { next(gap) }
        }
    }

    /// The keyframe's time in ms, when the demuxer's index already knows it.
    private func key(_ t: Double) -> Int? {
        guard let v = video else { return nil }
        let s = v.demux.avStream
        let ts = Int64((v.demux.startSeconds + t) / av_q2d(v.demux.timeBase))
        guard let e = avformat_index_get_entry_from_timestamp(s, ts, AVSEEK_FLAG_BACKWARD) else { return nil }
        return Int(Double(e.pointee.timestamp) * av_q2d(v.demux.timeBase) * 1000)
    }

    private func next(_ gap: Double) {
        guard let (t, done) = wanted else { busy = false; scheduleIdle(); return }
        wanted = nil
        busy = true
        if video == nil { video = FFVideo(url: url, threads: false) }
        if let v = video {
            v.seek(to: v.demux.startSeconds + t)
            if let (px, pts, _) = v.next(), let img = image(px, v) {
                let k = key(t) ?? Int(pts * 1000)
                cache[k] = img
                if let i = order.firstIndex(of: k) { order.remove(at: i) }
                order.append(k)
                while order.count > 24 { cache[order.removeFirst()] = nil }
                DispatchQueue.main.async { done(img, k) }
            }
        }
        if gap > 0 { q.asyncAfter(deadline: .now() + gap) { [self] in next(spacing) } } else { next(0) }
    }

    private func image(_ px: CVPixelBuffer, _ v: FFVideo) -> CGImage? {
        let w = min(targetWidth, Int(v.displaySize.width)) & ~1
        let h = (w * Int(v.displaySize.height) / max(1, Int(v.displaySize.width))) & ~1
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
        guard let t = transfer, let out, VTPixelTransferSessionTransferImage(t, from: px, to: out) == noErr else { return nil }
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(out, options: nil, imageOut: &img)
        return img
    }

    private func scheduleIdle() {
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            self.video = nil
            if let t = self.transfer { VTPixelTransferSessionInvalidate(t) }
            self.transfer = nil
            self.cache = [:]; self.order = []
        }
        idle = w
        q.asyncAfter(deadline: .now() + 4, execute: w)
    }
}
